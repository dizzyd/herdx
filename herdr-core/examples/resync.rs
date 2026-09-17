//! Does a same-size resize make the server send a complete surface again?
//!
//! That is the lever a client needs when it has to refuse a patch: the server
//! tracks surface revisions per connection, so a refused patch desyncs it
//! permanently unless something forces a recompute.

use herdr_core::client::{default_socket_path, hello, EndpointConnection};
use herdr_core::protocol::{ClientMessage, ClientSurfaceSize, ServerMessage};

fn main() -> std::io::Result<()> {
    let (cols, rows) = (100u16, 30u16);
    let mut conn = EndpointConnection::connect(&default_socket_path(), &hello(cols, rows, 8, 16))?;

    let mut seen_surface = false;
    for _ in 0..80 {
        if let ServerMessage::PaneSurface(frame) = conn.recv()? {
            println!("initial surface rev {}", frame.surface_revision);
            seen_surface = true;
            break;
        }
    }
    if !seen_surface {
        println!("no initial surface");
        return Ok(());
    }

    println!("sending a resize with the same dimensions…");
    conn.send(&ClientMessage::ClientShellResize {
        cell_width_px: 8,
        cell_height_px: 16,
        surface_size: ClientSurfaceSize { cols, rows },
        pixel_mouse: true,
    })?;

    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
    let (mut surfaces, mut patches) = (0, 0);
    while std::time::Instant::now() < deadline {
        match conn.recv()? {
            ServerMessage::PaneSurface(frame) => {
                surfaces += 1;
                println!("  full surface rev {}", frame.surface_revision);
                break;
            }
            ServerMessage::PaneSurfacePatch(patch) => {
                patches += 1;
                if patches <= 2 {
                    println!("  patch base {} -> {}", patch.base_surface_revision, patch.surface_revision);
                }
            }
            _ => {}
        }
    }
    println!("same-size resize produced {surfaces} full surface(s), {patches} patch(es)");
    Ok(())
}
