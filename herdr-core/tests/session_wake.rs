//! Does a client that knows its connection is stale get a new one at once?
//!
//! A Mac waking from sleep holds remote connections whose path stopped
//! existing while it slept. Neither end will say so — the far side has no
//! reason to speak, and this side is parked in a read that never returns — so
//! ssh only works it out from missed keepalives, measured at two minutes.
//! These tests are about the lever that skips that wait.

mod mock_server;

use std::time::Duration;

use mock_server::MockServer;

use herdr_core::ffi::{
    hx_endpoint_attachments, hx_reattach, hx_reattach_remotes, hx_session_connect,
    hx_session_free,
};

fn connect(server: &MockServer) -> *mut herdr_core::ffi::HxSession {
    let socket = std::ffi::CString::new(server.socket().to_str().unwrap()).unwrap();
    let session = unsafe { hx_session_connect(80, 24, 8, 16, socket.as_ptr(), false) };
    assert!(!session.is_null(), "the mock server should have answered");
    assert!(
        server.wait_until(Duration::from_secs(5), |a| !a.is_empty()),
        "the session never attached"
    );
    session
}

#[test]
fn reattaching_drops_the_connection_and_makes_a_new_one() {
    let server = MockServer::start("reattach-replaces");
    let session = connect(&server);

    assert!(unsafe { hx_reattach(session, 0) });

    assert!(
        server.wait_until(Duration::from_secs(5), |a| a[0].closed),
        "the stale connection was left open"
    );
    assert!(
        server.wait_until(Duration::from_secs(5), |a| a.len() > 1),
        "nothing reattached"
    );

    unsafe { hx_session_free(session) };
}

#[test]
fn reattaching_does_not_wait_out_a_backoff_that_had_been_climbing() {
    let server = MockServer::start("reattach-is-prompt");
    let session = connect(&server);

    // The whole point is that this is quick. A reconnect that arrives after
    // the transport's own timeout would have been free; one that arrives in
    // under a second is the thing being asked for.
    let started = std::time::Instant::now();
    assert!(unsafe { hx_reattach(session, 0) });
    assert!(
        server.wait_until(Duration::from_secs(5), |a| a.len() > 1),
        "nothing reattached"
    );
    let took = started.elapsed();

    assert!(
        took < Duration::from_secs(2),
        "reattaching took {took:?}; it waited rather than acting"
    );

    unsafe { hx_session_free(session) };
}

#[test]
fn a_reattached_endpoint_can_be_reattached_again() {
    let server = MockServer::start("reattach-repeatedly");
    let session = connect(&server);

    // A nudge must not be mistaken for a stop: a laptop opened four times is
    // four wakes, and the loop has to survive every one of them.
    for round in 1..=4 {
        assert!(unsafe { hx_reattach(session, 0) });
        assert!(
            server.wait_until(Duration::from_secs(5), |a| a.len() > round),
            "round {round} never reattached; the loop stopped"
        );
    }

    unsafe { hx_session_free(session) };
}

#[test]
fn the_wake_policy_leaves_a_local_endpoint_alone() {
    let server = MockServer::start("reattach-skips-local");
    let session = connect(&server);

    // A unix socket comes back from sleep exactly as it went in, so dropping
    // it to prove the point would cost a surface resend and buy nothing.
    assert_eq!(
        unsafe { hx_reattach_remotes(session) },
        0,
        "the wake policy asked a local endpoint to reattach"
    );

    // Comfortably longer than the 250ms first backoff, so a reconnect that was
    // going to happen has had several chances.
    std::thread::sleep(Duration::from_millis(1500));
    assert_eq!(
        server.attachment_count(),
        1,
        "the local connection was replaced by a wake it should have ignored"
    );

    unsafe { hx_session_free(session) };
}

#[test]
fn the_attachment_count_climbs_so_a_reconnect_can_be_told_from_none() {
    let server = MockServer::start("reattach-counts");
    let session = connect(&server);

    // What a probe has to read. Status cannot answer this: a drop and a
    // reattach that both land between two samples leave it reading `online`
    // either side, which is exactly what a wake that does nothing looks like.
    assert_eq!(unsafe { hx_endpoint_attachments(session, 0) }, 1);

    assert!(unsafe { hx_reattach(session, 0) });
    assert!(
        server.wait_until(Duration::from_secs(5), |a| a.len() > 1),
        "nothing reattached"
    );

    // Against the server's own count, not just our own: the number is only
    // worth reading if it means a connection the far side actually accepted.
    assert!(
        wait_for(Duration::from_secs(5), || unsafe {
            hx_endpoint_attachments(session, 0)
        } == 2),
        "attached {} times by the server's count, but reported {}",
        server.attachment_count(),
        unsafe { hx_endpoint_attachments(session, 0) }
    );

    unsafe { hx_session_free(session) };
}

/// Polls `condition` until it holds or `timeout` runs out.
fn wait_for(timeout: Duration, condition: impl Fn() -> bool) -> bool {
    let deadline = std::time::Instant::now() + timeout;
    while std::time::Instant::now() < deadline {
        if condition() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    false
}
