//! Sends one read-only endpoint method and prints the reply.
//!
//! This checks the request envelope end to end against a live server without
//! changing any session state.

use herdr_core::client::{default_socket_path, hello, EndpointConnection};
use herdr_core::protocol::{ClientMessage, ClientShellSnapshot, ServerMessage};

fn main() -> std::io::Result<()> {
    let method = std::env::args().nth(1).unwrap_or_else(|| "integration.list".into());
    let mut conn = EndpointConnection::connect(&default_socket_path(), &hello(80, 24, 8, 16))?;

    // The boot id identifies which endpoint process the request belongs to.
    let mut boot_id = None;
    for _ in 0..40 {
        if let ServerMessage::EndpointControl { kind, data } = conn.recv()? {
            if kind == "shell.snapshot.v1" {
                let snapshot: ClientShellSnapshot = serde_json::from_str(&data).unwrap();
                boot_id = Some(snapshot.boot_id);
                break;
            }
        }
    }
    let Some(boot_id) = boot_id else {
        println!("no snapshot arrived");
        return Ok(());
    };

    // Always send `params`: Method is an adjacently tagged enum, so the content
    // key is not optional even for methods that take nothing.
    let request = format!(r#"{{"id":"probe-1","method":"{method}","params":{{}}}}"#);
    println!("-> {request}");
    conn.send(&ClientMessage::ClientShellEndpointRequest {
        boot_id: boot_id.clone(),
        request,
    })?;

    let mut body = Vec::new();
    for _ in 0..200 {
        match conn.recv()? {
            ServerMessage::ClientShellEndpointResponseChunk {
                request_id,
                final_chunk,
                data,
                ..
            } => {
                body.extend_from_slice(&data);
                if final_chunk {
                    println!("<- [{request_id}] {}", String::from_utf8_lossy(&body));
                    return Ok(());
                }
            }
            ServerMessage::ClientShellError { message } => {
                println!("<- error: {message}");
                return Ok(());
            }
            _ => {}
        }
    }
    println!("no response");
    Ok(())
}
