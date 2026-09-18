//! Sends input the way the Swift app does, to separate core bugs from UI bugs.
//!
//! Point it at a throwaway session:
//!   HERDR_CLIENT_SOCKET_PATH=~/.config/herdr/sessions/hxtest/herdr-client.sock \
//!     cargo run -p herdr-core --example input

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

/// The surface as rows of characters, so a change is visible as text.
unsafe fn rows(session: *mut HxSession) -> Vec<String> {
    let mut g = std::mem::zeroed::<HxGrid>();
    if !hx_grid_acquire(session, &mut g) || g.cells.is_null() {
        return Vec::new();
    }
    let cells = std::slice::from_raw_parts(g.cells, (g.width as usize) * (g.height as usize));
    let glyphs = std::slice::from_raw_parts(g.glyphs, g.glyph_bytes);
    (0..g.height as usize)
        .map(|row| {
            (0..g.width as usize)
                .map(|col| {
                    let cell = cells[row * g.width as usize + col];
                    let start = cell.glyph_off as usize;
                    let end = start + cell.glyph_len as usize;
                    if end <= glyphs.len() && start < end {
                        String::from_utf8_lossy(&glyphs[start..end]).into_owned()
                    } else {
                        " ".to_owned()
                    }
                })
                .collect::<String>()
                .trim_end()
                .to_owned()
        })
        .collect()
}

fn main() {
    unsafe {
        let session = hx_session_connect(100, 28, 8, 18);
        if session.is_null() {
            println!("connect failed: {}", text(hx_connect_error()));
            return;
        }

        // Wait for the first snapshot, which is what names the focused pane.
        let mut pane = String::new();
        for _ in 0..40 {
            std::thread::sleep(std::time::Duration::from_millis(250));
            let snapshot = text(hx_endpoint_snapshot_json(session, hx_active_endpoint(session)));
            if let Some(found) = snapshot
                .split("\"focused_pane_id\":\"")
                .nth(1)
                .and_then(|rest| rest.split('"').next())
            {
                pane = found.to_owned();
                break;
            }
        }
        if pane.is_empty() {
            println!("no focused pane in any snapshot");
            return;
        }
        println!("focused pane: {pane}");

        let before = rows(session);
        println!("--- before ---");
        for row in before.iter().filter(|r| !r.is_empty()) {
            println!("  {row}");
        }

        // The marker is echoed back by the shell, so seeing it in the surface
        // proves the whole round trip, not just that the write succeeded.
        let marker = "hxprobe";
        let pane_c = std::ffi::CString::new(pane.clone()).unwrap();
        let text_c = std::ffi::CString::new(format!("echo {marker}")).unwrap();
        println!(">> hx_send_text: {}", hx_send_text(session, pane_c.as_ptr(), text_c.as_ptr()));

        std::thread::sleep(std::time::Duration::from_millis(600));
        let typed = rows(session);
        let echoed = typed.iter().any(|r| r.contains(marker));
        println!("marker visible after typing: {echoed}");

        // Enter goes through the semantic key path, which is the other half.
        println!(
            ">> hx_send_key(ENTER): {}",
            hx_send_key(session, pane_c.as_ptr(), HX_KEY_ENTER, 0, 0)
        );
        std::thread::sleep(std::time::Duration::from_millis(1200));

        println!("--- after ---");
        for row in rows(session).iter().filter(|r| !r.is_empty()) {
            println!("  {row}");
        }
        hx_session_free(session);
    }
}
