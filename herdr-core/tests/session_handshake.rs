//! What does a reconnect tell the server about the window?

mod mock_server;

use std::time::Duration;

use mock_server::MockServer;

use herdr_core::ffi::{hx_resize, hx_session_connect, hx_session_free, HxSession};

fn connect(server: &MockServer, cols: u16, rows: u16) -> *mut HxSession {
    let socket = std::ffi::CString::new(server.socket().to_str().unwrap()).unwrap();
    let session = unsafe { hx_session_connect(cols, rows, 8, 16, socket.as_ptr(), false) };
    assert!(!session.is_null(), "the mock server should have answered");
    assert!(
        server.wait_until(Duration::from_secs(5), |a| !a.is_empty()),
        "the session never attached"
    );
    session
}

#[test]
fn the_first_hello_carries_the_size_it_was_given() {
    let server = MockServer::start("first-hello");
    let session = connect(&server, 80, 24);

    let hello = &server.attachments()[0].hello;
    assert_eq!(hello.surface_size.cols, 80);
    assert_eq!(hello.surface_size.rows, 24);
    assert_eq!(hello.cell_width_px, 8);
    assert_eq!(hello.cell_height_px, 16);

    unsafe { hx_session_free(session) };
}

#[test]
fn a_reconnect_announces_the_window_as_it_is_now() {
    let server = MockServer::start("reconnect-geometry");
    let session = connect(&server, 80, 24);

    unsafe { hx_resize(session, 132, 43, 9, 18) };
    server.disconnect_all();

    assert!(
        server.wait_until(Duration::from_secs(10), |a| a.len() >= 2),
        "the endpoint never reconnected"
    );

    let hello = &server.attachments()[1].hello;
    assert_eq!(
        (hello.surface_size.cols, hello.surface_size.rows),
        (132, 43),
        "the reconnect asked for a surface the window has not been for a while"
    );
    assert_eq!((hello.cell_width_px, hello.cell_height_px), (9, 18));

    unsafe { hx_session_free(session) };
}

#[test]
fn a_reconnect_still_asks_for_a_surface() {
    let server = MockServer::start("reconnect-surface");
    let session = connect(&server, 80, 24);

    assert!(server.attachments()[0].hello.surface_active);
    server.disconnect_all();
    assert!(server.wait_until(Duration::from_secs(10), |a| a.len() >= 2));

    assert!(
        server.attachments()[1].hello.surface_active,
        "the only endpoint there is stopped rendering when it came back"
    );

    unsafe { hx_session_free(session) };
}
