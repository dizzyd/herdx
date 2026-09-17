//! Drives the C ABI the way the Swift app does, to separate core bugs from UI bugs.

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

fn main() {
    unsafe {
        let session = hx_session_connect(120, 34, 9, 18);
        if session.is_null() {
            println!("connect failed: {}", text(hx_connect_error()));
            return;
        }

        for tick in 0..12 {
            std::thread::sleep(std::time::Duration::from_secs(1));

            let count = hx_endpoint_count(session);
            let active = hx_active_endpoint(session);
            let mut line = format!("t={tick}s active={active}");
            for index in 0..count {
                line.push_str(&format!(
                    "  [{index}] {} status={} remote={}",
                    text(hx_endpoint_label(session, index)),
                    hx_endpoint_status(session, index),
                    hx_endpoint_is_remote(session, index),
                ));
                let snapshot = text(hx_endpoint_snapshot_json(session, index));
                if !snapshot.is_empty() {
                    line.push_str(&format!(" snapshot={}b", snapshot.len()));
                }
            }

            let mut grid = std::mem::zeroed::<HxGrid>();
            if hx_grid_acquire(session, &mut grid) {
                line.push_str(&format!(
                    "  grid={}x{} rev={} panes={}",
                    grid.width, grid.height, grid.revision, grid.pane_count
                ));
            } else {
                line.push_str("  grid=none");
            }
            println!("{line}");

            if tick == 5 && grid.width > 0 {
                let cells = std::slice::from_raw_parts(grid.cells, grid.cell_count);
                let glyphs = std::slice::from_raw_parts(grid.glyphs, grid.glyph_bytes);
                let non_blank = cells
                    .iter()
                    .filter(|c| {
                        let start = c.glyph_off as usize;
                        let text = &glyphs[start..start + c.glyph_len as usize];
                        !text.is_empty() && text != b" "
                    })
                    .count();
                println!("   non-blank cells: {non_blank}");
                for row in 0..3.min(grid.height as usize) {
                    let line: String = (0..grid.width as usize)
                        .map(|col| {
                            let c = &cells[row * grid.width as usize + col];
                            let start = c.glyph_off as usize;
                            let text = &glyphs[start..start + c.glyph_len as usize];
                            std::str::from_utf8(text).unwrap_or(" ").chars().next().unwrap_or(' ')
                        })
                        .collect();
                    println!("   |{}|", line.trim_end());
                }
            }

            while let Some(error) = Some(text(hx_last_error(session))).filter(|e| !e.is_empty()) {
                println!("   error: {error}");
            }
        }
        hx_session_free(session);
    }
}
