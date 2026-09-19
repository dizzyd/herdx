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
        let session = hx_session_connect(120, 34, 9, 18, std::ptr::null());
        if session.is_null() {
            println!("connect failed: {}", text(hx_connect_error()));
            return;
        }

        // Switch machines part-way, which is what clicking a sidebar row does.
        let switch_to: Option<usize> = std::env::args().nth(1).and_then(|a| a.parse().ok());
        // Or focus a workspace, which is the other thing a sidebar row does.
        let focus_workspace = std::env::var("FOCUS_WORKSPACE").ok();
        let mut boot_id = String::new();

        for tick in 0..16 {
            if tick == 4 {
                if let Some(workspace) = &focus_workspace {
                    let request = format!(
                        r#"{{"id":"ws","method":"workspace.focus","params":{{"workspace_id":"{workspace}"}}}}"#
                    );
                    let ok = std::ffi::CString::new(request).unwrap();
                    let boot = std::ffi::CString::new(boot_id.clone()).unwrap();
                    println!(">> focusing workspace {workspace} (boot {boot_id}): {}",
                        hx_endpoint_request(session, boot.as_ptr(), ok.as_ptr()));
                }
            }
            if Some(tick) == switch_to.map(|_| 5) {
                let target = switch_to.unwrap();
                println!(">> switching to endpoint {target}: {}",
                    hx_set_active_endpoint(session, target));
            }
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
                    if index == active {
                        if let Some(id) = snapshot
                            .split(r#""boot_id":""#)
                            .nth(1)
                            .and_then(|rest| rest.split('"').next())
                        {
                            boot_id = id.to_owned();
                        }
                    }
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

            if grid.width > 0 && std::env::var("SHOW_ROW").is_ok() {
                let cells = std::slice::from_raw_parts(grid.cells, grid.cell_count);
                let glyphs = std::slice::from_raw_parts(grid.glyphs, grid.glyph_bytes);
                let first = (0..grid.height as usize)
                    .map(|row| {
                        (0..grid.width as usize)
                            .map(|col| {
                                let c = &cells[row * grid.width as usize + col];
                                let start = c.glyph_off as usize;
                                std::str::from_utf8(&glyphs[start..start + c.glyph_len as usize])
                                    .unwrap_or(" ")
                            })
                            .collect::<String>()
                    })
                    .find(|line| !line.trim().is_empty())
                    .unwrap_or_default();
                println!("   first: {}", first.trim().chars().take(90).collect::<String>());
            }
            if grid.width > 0 && focus_workspace.is_some() {
                let cells = std::slice::from_raw_parts(grid.cells, grid.cell_count);
                let glyphs = std::slice::from_raw_parts(grid.glyphs, grid.glyph_bytes);
                let all: String = cells
                    .iter()
                    .map(|c| {
                        let start = c.glyph_off as usize;
                        std::str::from_utf8(&glyphs[start..start + c.glyph_len as usize])
                            .unwrap_or(" ")
                    })
                    .collect();
                let marker = if all.contains("AAAA-WORKSPACE-ONE") {
                    "shows W1"
                } else if all.contains("BBBB-WORKSPACE-TWO") {
                    "shows W2"
                } else {
                    "shows neither"
                };
                println!("   {marker}");
            }
            if tick == 5 && grid.width > 0 && focus_workspace.is_none() {
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

            for index in 0..count {
                let error = text(hx_endpoint_error(session, index));
                if !error.is_empty() {
                    println!("   [{index}] error: {error}");
                }
            }
            for index in 0..count {
                loop {
                    let event = text(hx_next_endpoint_event(session, index));
                    if event.is_empty() {
                        break;
                    }
                    if event.contains("response") || event.contains("error") {
                        println!("   [{index}] event: {}", &event[..event.len().min(240)]);
                    }
                }
            }
        }
        hx_session_free(session);
    }
}
