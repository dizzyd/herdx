//! Does freeing a session actually end the connections it made?

mod mock_server;

use std::time::Duration;

use mock_server::MockServer;

use herdr_core::ffi::{hx_session_connect, hx_session_free};

/// Connects one session to `server`, with no machines attached, and returns
/// once it has actually attached.
///
/// Counted rather than checked against one, so a test that connects more than
/// once does not pass on the previous round's attachment.
fn connect(server: &MockServer) -> *mut herdr_core::ffi::HxSession {
    let before = server.attachment_count();
    let socket = std::ffi::CString::new(server.socket().to_str().unwrap()).unwrap();
    let session = unsafe { hx_session_connect(80, 24, 8, 16, socket.as_ptr(), false) };
    assert!(!session.is_null(), "the mock server should have answered");
    assert!(
        server.wait_until(Duration::from_secs(5), |a| a.len() > before),
        "the session never attached"
    );
    session
}

#[test]
fn freeing_a_session_closes_its_connection() {
    let server = MockServer::start("free-closes");
    let session = connect(&server);

    unsafe { hx_session_free(session) };

    assert!(
        server.wait_until(Duration::from_secs(5), |a| a[0].closed),
        "the connection outlived the session that owned it"
    );
}

#[test]
fn a_freed_session_does_not_reconnect() {
    let server = MockServer::start("free-no-reconnect");
    let session = connect(&server);

    unsafe { hx_session_free(session) };
    assert!(server.wait_until(Duration::from_secs(5), |a| a[0].closed));

    // Comfortably longer than the 250ms first backoff: a reconnect loop still
    // running would have come back several times over by now.
    std::thread::sleep(Duration::from_millis(1500));
    assert_eq!(
        server.attachment_count(),
        1,
        "a freed session reconnected; its worker is still running"
    );
}

#[test]
fn freeing_a_session_does_not_hang_on_a_server_that_never_speaks() {
    let server = MockServer::start("free-is-prompt");
    let session = connect(&server);

    // The receive thread is parked in a read that nothing is going to satisfy,
    // which is where it spends nearly all of its life. Disposal has to break
    // it rather than wait it out.
    let started = std::time::Instant::now();
    unsafe { hx_session_free(session) };
    let took = started.elapsed();

    assert!(
        took < Duration::from_secs(2),
        "freeing a session took {took:?}; it waited for the far end instead of \
         interrupting the read"
    );
}

#[test]
fn sessions_freed_in_turn_leave_nothing_behind() {
    let server = MockServer::start("free-repeatedly");

    // What switching machines or editing them does: each one used to leave a
    // live client behind, and they accumulated invisibly.
    for round in 0..4 {
        let session = connect(&server);
        unsafe { hx_session_free(session) };
        assert!(
            server.wait_until(Duration::from_secs(5), |a| a.iter().all(|a| a.closed)),
            "round {round} left a connection open"
        );
    }

    std::thread::sleep(Duration::from_millis(1500));
    assert_eq!(
        server.attachment_count(),
        4,
        "one connection per session, and no reconnects from the freed ones"
    );
}
