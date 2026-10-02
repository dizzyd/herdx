//! Does a client that knows its connection is stale get a new one at once?
//!
//! The reconnect loop was always there; what these ask about is the lever that
//! skips the wait for a transport to notice a path that died silently.
//! `hx_reattach_remotes` says why that wait is not good enough, and
//! `ARCHITECTURE.md` has the history.
//!
//! These exercise the loop end to end against a server. The synchronisation
//! boundaries underneath it — a wake that lands between a transport being
//! built and being armed, or while an attempt is still failing — cannot be
//! timed from out here, and are covered by `halt_tests` in `ffi.rs`.

mod mock_server;

use std::time::Duration;

use mock_server::MockServer;

use herdr_core::ffi::{
    hx_endpoint_attachments, hx_reattach, hx_reattach_remotes, hx_session_connect, hx_session_free,
};

/// Connects one session to `server` and returns once the client itself counts
/// itself attached.
///
/// Not just once the server has logged the hello: the mock records that
/// *before* it answers, and the client only counts an attachment after the
/// welcome comes back and the connection is set up. Waiting on the server's
/// side alone leaves every later assertion racing that gap.
fn connect(server: &MockServer) -> *mut herdr_core::ffi::HxSession {
    let socket = std::ffi::CString::new(server.socket().to_str().unwrap()).unwrap();
    let session = unsafe { hx_session_connect(80, 24, 8, 16, socket.as_ptr(), false) };
    assert!(!session.is_null(), "the mock server should have answered");
    assert!(
        server.wait_until(Duration::from_secs(5), |a| !a.is_empty()),
        "the session never said hello"
    );
    assert!(
        attached(session, 1),
        "the server saw the hello but the client never finished the handshake"
    );
    session
}

/// Waits for the endpoint to have attached `count` times.
fn attached(session: *const herdr_core::ffi::HxSession, count: u64) -> bool {
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while std::time::Instant::now() < deadline {
        if unsafe { hx_endpoint_attachments(session, 0) } >= count {
            return true;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    false
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
fn reattaching_a_live_connection_pays_no_backoff_at_all() {
    let server = MockServer::start("reattach-is-prompt");
    let session = connect(&server);

    // A live connection's next attempt used to pay the opening 250ms, because
    // the wake was only consulted after the wait rather than inside it. There
    // is nothing to back off from here — the machine never refused us — so the
    // reattachment should land about as fast as a handshake takes.
    let started = std::time::Instant::now();
    assert!(unsafe { hx_reattach(session, 0) });
    assert!(attached(session, 2), "nothing reattached");
    let took = started.elapsed();

    // Measures at about 12ms, most of which is this test's own polling. Well
    // under 250ms is the discriminating claim: paying the backoff is the only
    // thing that puts it over.
    assert!(
        took < Duration::from_millis(150),
        "reattaching took {took:?}, which is the opening backoff being waited \
         out; a wake should not pay it"
    );

    unsafe { hx_session_free(session) };
}

#[test]
fn a_reattached_endpoint_can_be_reattached_again() {
    let server = MockServer::start("reattach-repeatedly");
    let session = connect(&server);

    // A laptop opened four times is four wakes, and the loop has to survive
    // every one of them: a nudge must not be mistaken for a stop, and the
    // generation must keep moving.
    for round in 1..=4u64 {
        assert!(unsafe { hx_reattach(session, 0) });
        assert!(
            attached(session, round + 1),
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

    // Comfortably longer than the opening backoff, so a reconnect that was
    // going to happen has had several chances.
    std::thread::sleep(Duration::from_millis(1500));
    assert_eq!(
        server.attachment_count(),
        1,
        "the local connection was replaced by a wake it should have ignored"
    );
    assert_eq!(unsafe { hx_endpoint_attachments(session, 0) }, 1);

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

    // Against the server's own count, so the number only ever means a
    // connection the far side actually accepted.
    assert!(
        attached(session, 2),
        "the server logged {} attachments, but the endpoint reports {}",
        server.attachment_count(),
        unsafe { hx_endpoint_attachments(session, 0) }
    );

    unsafe { hx_session_free(session) };
}
