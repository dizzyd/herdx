//! Prints the keybinding profile the server publishes in its snapshot.

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
        let session = hx_session_connect(100, 28, 8, 18, std::ptr::null());
        if session.is_null() {
            println!("connect failed: {}", text(hx_connect_error()));
            return;
        }
        for _ in 0..40 {
            std::thread::sleep(std::time::Duration::from_millis(250));
            let snapshot = text(hx_endpoint_snapshot_json(session, hx_active_endpoint(session)));
            if snapshot.is_empty() {
                continue;
            }
            let Some(rest) = snapshot.split("\"server_keybindings_toml\":").nth(1) else {
                println!("field absent from snapshot");
                return;
            };
            if rest.starts_with("null") {
                println!("server sent null");
                return;
            }
            // A JSON string: unescape enough to read it back as TOML.
            let body: String = rest.trim_start().trim_start_matches('"').to_owned();
            let mut out = String::new();
            let mut chars = body.chars();
            while let Some(c) = chars.next() {
                match c {
                    '\\' => match chars.next() {
                        Some('n') => out.push('\n'),
                        Some('"') => out.push('"'),
                        Some('\\') => out.push('\\'),
                        Some(other) => out.push(other),
                        None => break,
                    },
                    '"' => break,
                    other => out.push(other),
                }
            }
            println!("{out}");
            return;
        }
        println!("no snapshot arrived");
    }
}
