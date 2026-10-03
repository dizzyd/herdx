//! What does a reconnect tell the server about the window?

mod mock_server;

use std::time::Duration;

use mock_server::MockServer;

use herdr_core::ffi::{
    hx_resize, hx_session_connect, hx_session_free, hx_set_appearance, hx_set_default_color,
    hx_set_focus, hx_set_palette, HxSession,
};
use herdr_core::protocol::ClientMessage;

/// Whether this connection was told the window has focus.
fn was_told_focused(server: &MockServer, attachment: usize) -> Option<bool> {
    server.attachments()[attachment]
        .messages
        .iter()
        .rev()
        .find_map(|message| match message {
            ClientMessage::ClientShellFocus { focused, .. } => Some(*focused),
            _ => None,
        })
}

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

/// Focus is not in the hello, and the server forgets it with the connection.
///
/// A client that had already said "I am focused" said nothing about it after
/// reconnecting: the focus was only kept when a *failed* write left it behind,
/// and a successful one was dropped. The server reports focus lost when the
/// old connection goes, and only `ClientShellFocus(true)` takes it back — so
/// anything in a pane that reports focus stayed unfocused until somebody
/// happened to click away and back.
#[test]
fn a_reconnect_says_again_that_the_window_has_focus() {
    let server = MockServer::start("reconnect-focus");
    let session = connect(&server, 80, 24);

    unsafe { hx_set_focus(session, true) };
    assert!(
        server.wait_until(Duration::from_secs(5), |_| was_told_focused(&server, 0)
            == Some(true)),
        "the first connection was never told about focus"
    );

    server.disconnect_all();
    assert!(
        server.wait_until(Duration::from_secs(10), |a| a.len() >= 2),
        "the endpoint never reconnected"
    );

    assert!(
        server.wait_until(Duration::from_secs(5), |_| was_told_focused(&server, 1)
            == Some(true)),
        "the reconnect never said the window has focus, so the server still \
         has the pane unfocused"
    );

    unsafe { hx_session_free(session) };
}

/// And it says the truth, not just something: a window that lost focus before
/// the reconnect must not come back claiming to have it.
#[test]
fn a_reconnect_does_not_claim_focus_the_window_has_lost() {
    let server = MockServer::start("reconnect-unfocus");
    let session = connect(&server, 80, 24);

    unsafe { hx_set_focus(session, true) };
    assert!(server.wait_until(Duration::from_secs(5), |_| was_told_focused(&server, 0).is_some()));
    unsafe { hx_set_focus(session, false) };

    server.disconnect_all();
    assert!(server.wait_until(Duration::from_secs(10), |a| a.len() >= 2));

    assert!(
        server.wait_until(Duration::from_secs(5), |_| was_told_focused(&server, 1)
            == Some(false)),
        "the reconnect reported stale focus"
    );

    unsafe { hx_session_free(session) };
}

/// The size is kept the same way, and keeping it must not make it a one-shot:
/// two reconnects both need telling.
#[test]
fn a_second_reconnect_is_told_as_much_as_the_first() {
    let server = MockServer::start("reconnect-twice");
    let session = connect(&server, 80, 24);
    unsafe { hx_set_focus(session, true) };

    for round in 1..=2usize {
        server.disconnect_all();
        assert!(
            server.wait_until(Duration::from_secs(10), |a| a.len() > round),
            "reconnect {round} never happened"
        );
        assert!(
            server.wait_until(Duration::from_secs(5), |_| was_told_focused(&server, round)
                == Some(true)),
            "reconnect {round} did not report focus; the state was consumed by \
             an earlier attach"
        );
    }

    unsafe { hx_session_free(session) };
}

/// Whether this connection was told the palette, and what it was told.
fn theme_updates(
    server: &MockServer, attachment: usize,
) -> Vec<herdr_core::protocol::ClientHostThemeUpdate> {
    server.attachments()[attachment]
        .messages
        .iter()
        .filter_map(|message| match message {
            ClientMessage::ClientShellHostTheme { update } => Some(update.clone()),
            _ => None,
        })
        .collect()
}

/// A server starts every connection on its own default theme, so a reconnect
/// that says nothing comes back in the wrong colours and stays there.
///
/// The palette was kept only when a write *failed*, like focus before it, so a
/// theme that had been sent successfully was forgotten. The window did not
/// make up for it either: it republished when the set of online machines
/// gained one, and a reconnect finishing between two samples never changes
/// that set — a real window now that a reattach can finish in about twelve
/// milliseconds.
#[test]
fn a_reconnect_says_the_palette_again() {
    let server = MockServer::start("reconnect-theme");
    let session = connect(&server, 80, 24);

    // Foreground first: the server drops a host theme from a client it does
    // not consider foreground, and says nothing about having done so.
    unsafe { hx_set_focus(session, true) };
    // A whole publication, as the window makes one: two default colours, the
    // palette, and the appearance.
    let palette: Vec<u8> = (0u8..48).collect();
    unsafe {
        hx_set_default_color(session, false, 10, 20, 30);
        hx_set_default_color(session, true, 200, 210, 220);
        hx_set_palette(session, palette.as_ptr(), palette.len() / 3);
        hx_set_appearance(session, true);
    }
    assert!(
        server.wait_until(Duration::from_secs(5), |_| theme_updates(&server, 0).len() >= 4),
        "the first connection was not told the whole theme"
    );

    server.disconnect_all();
    assert!(
        server.wait_until(Duration::from_secs(10), |a| a.len() >= 2),
        "the endpoint never reconnected"
    );

    assert!(
        server.wait_until(Duration::from_secs(5), |_| theme_updates(&server, 1).len() >= 4),
        "the reconnect did not say the whole theme, so the panes keep some of \
         the server's own default colours"
    );
    // All four statements, not merely the last one: a publication is a
    // background, a foreground, a palette and an appearance, and the server
    // tracks each separately.
    assert_eq!(
        theme_updates(&server, 1),
        theme_updates(&server, 0),
        "the reconnect was told a different theme than the one in use"
    );

    unsafe { hx_session_free(session) };
}

/// And it is said after focus, not before: a server applies a host theme from
/// the foreground client and silently drops one from anybody else, so a
/// palette sent ahead of the focus that earns it is thrown away.
#[test]
fn the_palette_is_replayed_after_focus() {
    let server = MockServer::start("theme-order");
    let session = connect(&server, 80, 24);
    unsafe { hx_set_focus(session, true) };
    let palette: Vec<u8> = (0u8..48).collect();
    unsafe { hx_set_palette(session, palette.as_ptr(), palette.len() / 3) };
    assert!(server.wait_until(Duration::from_secs(5), |_| !theme_updates(&server, 0).is_empty()));

    server.disconnect_all();
    assert!(server.wait_until(Duration::from_secs(10), |a| a.len() >= 2));
    assert!(server.wait_until(Duration::from_secs(5), |_| !theme_updates(&server, 1).is_empty()));

    let messages = &server.attachments()[1].messages;
    let focus = messages
        .iter()
        .position(|m| matches!(m, ClientMessage::ClientShellFocus { .. }));
    let theme = messages
        .iter()
        .position(|m| matches!(m, ClientMessage::ClientShellHostTheme { .. }));
    assert!(
        focus < theme,
        "the palette was replayed before the focus that lets the server accept it"
    );

    unsafe { hx_session_free(session) };
}
