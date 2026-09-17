//! Connects with no surface, then asks for one — the endpoint-switch sequence.

use herdr_core::client::{default_socket_path, hello_with_surface, EndpointConnection};
use herdr_core::protocol::{ClientMessage, ClientShellSnapshot, ServerMessage};

fn main() -> std::io::Result<()> {
    let mut conn = EndpointConnection::connect(
        &default_socket_path(),
        &hello_with_surface(100, 30, 8, 16, false),
    )?;
    println!("connected with surface_active=false");

    let mut boot_id = String::new();
    for _ in 0..20 {
        if let ServerMessage::EndpointControl { kind, data } = conn.recv()? {
            if kind == "shell.snapshot.v1" {
                let snapshot: ClientShellSnapshot = serde_json::from_str(&data).unwrap();
                boot_id = snapshot.boot_id;
                break;
            }
        }
    }
    println!("boot_id = {boot_id:?}");

    for (label, boot) in [("empty boot id", String::new()), ("real boot id", boot_id)] {
        println!("\n-- activating with {label}");
        conn.send(&ClientMessage::ClientShellEndpointRequest {
            boot_id: boot,
            request: r#"{"id":"act","method":"client_shell.surface.set","params":{"active":true}}"#
                .into(),
        })?;

        let mut surfaces = 0;
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(4);
        while std::time::Instant::now() < deadline {
            match conn.recv()? {
                ServerMessage::PaneSurface(frame) => {
                    surfaces += 1;
                    println!("   surface {}x{}", frame.frame.width, frame.frame.height);
                    break;
                }
                ServerMessage::ClientShellEndpointResponseChunk { data, .. } => {
                    println!("   reply: {}", String::from_utf8_lossy(&data));
                }
                _ => {}
            }
        }
        if surfaces == 0 {
            println!("   no surface arrived");
        } else {
            // Turn it back off so the next attempt starts from the same place.
            conn.send(&ClientMessage::ClientShellEndpointRequest {
                boot_id: String::new(),
                request: r#"{"id":"off","method":"client_shell.surface.set","params":{"active":false}}"#.into(),
            })?;
            return Ok(());
        }
    }
    Ok(())
}
