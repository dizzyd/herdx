//! Is a connection replaced by a reattach actually working, both ways?
//!
//! `tests/session_wake.rs` asks whether the connection is replaced, against a
//! mock that answers a handshake and then says nothing. That cannot tell a
//! reattachment that works from one that comes back and renders nothing: the
//! front buffer still holds the last picture, so "there is a grid" is true
//! either way. This asks a live server instead, and asks the only question
//! that cannot be answered by a stale buffer — type something new through the
//! new connection and see the picture change.
//!
//! Point it at a throwaway session, which is the only kind it may touch: it
//! types into the focused pane.
//!   HERDR_CLIENT_SOCKET_PATH=~/.config/herdr/sessions/hxtest/herdr-client.sock \
//!     cargo run -p herdr-core --example reattach

use herdr_core::ffi::*;

fn text(ptr: *mut std::ffi::c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    unsafe {
        let value = std::ffi::CStr::from_ptr(ptr).to_string_lossy().into_owned();
        hx_string_free(ptr);
        value
    }
}

unsafe fn grid(session: *mut HxSession) -> (u64, u16, u16) {
    let mut out = std::mem::zeroed::<HxGrid>();
    hx_grid_acquire(session, &mut out);
    (out.revision, out.width, out.height)
}

/// Waits for `condition`, and says whether it ever held.
unsafe fn wait(mut condition: impl FnMut() -> bool) -> bool {
    for _ in 0..300 {
        if condition() {
            return true;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    false
}

fn main() {
    unsafe {
        let session = hx_session_connect(100, 30, 9, 18, std::ptr::null(), true);
        if session.is_null() {
            println!("connect failed: {}", text(hx_connect_error()));
            return;
        }
        if !wait(|| grid(session).1 > 0) {
            println!("no surface ever arrived; is this a running session?");
            return;
        }
        // Whatever pane the session is focused on. The snapshot names it, but
        // the grid already knows, and this only needs somewhere to type.
        let pane = text(hx_pane_id(session, 0));
        println!(
            "attached: attachments={} pane={pane} grid={:?}",
            hx_endpoint_attachments(session, 0),
            grid(session)
        );

        for round in 1..=3u64 {
            let started = std::time::Instant::now();
            assert!(hx_reattach(session, 0), "no endpoint 0");
            let replaced = wait(|| hx_endpoint_attachments(session, 0) > round);
            let took = started.elapsed();

            // The front buffer still holds the old picture, so the proof that
            // this connection is live is that something new comes back through
            // it — not that there is anything there at all.
            let before = grid(session).0;
            let marker = std::ffi::CString::new(format!("# reattach {round}\r")).unwrap();
            let pane_id = std::ffi::CString::new(pane.clone()).unwrap();
            let sent = hx_send_text(session, pane_id.as_ptr(), marker.as_ptr());
            let rendered = wait(|| grid(session).0 != before);

            println!(
                "reattached {round} in {took:?}: replaced={replaced} status={} \
                 typed={sent} picture_changed={rendered} grid={:?}",
                hx_endpoint_status(session, 0),
                grid(session)
            );
            let error = text(hx_endpoint_error(session, 0));
            if !error.is_empty() {
                println!("  error after a reattach we asked for: {error}");
            }
        }

        hx_session_free(session);
    }
}
