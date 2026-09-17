//! Does publishing a host theme change the colours a pane's program uses?
//!
//! The app republishes its theme whenever the system appearance is
//! re-evaluated, which happens on activation changes. If a pane re-themes
//! itself in response, that is why switching apps inverts the terminal.

use herdr_core::client::{default_socket_path, hello, EndpointConnection};
use herdr_core::protocol::{
    ClientHostColor, ClientHostDefaultColorKind, ClientHostThemeUpdate, ClientMessage,
    ServerMessage,
};

/// The most common background colour in a surface, as 0xRRGGBB.
fn dominant_background(frame: &herdr_core::protocol::PaneSurfaceFrame) -> Option<(u32, usize)> {
    let mut counts = std::collections::HashMap::new();
    for cell in &frame.frame.cells {
        *counts.entry(cell.bg).or_insert(0usize) += 1;
    }
    counts.into_iter().max_by_key(|(_, n)| *n)
}

fn wait_for_surface(conn: &mut EndpointConnection) -> std::io::Result<Option<(u32, usize)>> {
    for _ in 0..200 {
        if let ServerMessage::PaneSurface(frame) = conn.recv()? {
            return Ok(dominant_background(&frame));
        }
    }
    Ok(None)
}

fn main() -> std::io::Result<()> {
    let mut conn = EndpointConnection::connect(&default_socket_path(), &hello(100, 30, 8, 16))?;
    println!("before: dominant bg {:x?}", wait_for_surface(&mut conn)?);

    for (label, r, g, b) in [("light", 252u8, 252u8, 253u8), ("dark", 18, 20, 26)] {
        println!("\npublishing a {label} background…");
        conn.send(&ClientMessage::ClientShellHostTheme {
            update: ClientHostThemeUpdate::DefaultColor {
                kind: ClientHostDefaultColorKind::Background,
                color: ClientHostColor { r, g, b },
            },
        })?;
        std::thread::sleep(std::time::Duration::from_millis(1500));
        println!("  after {label}: dominant bg {:x?}", wait_for_surface(&mut conn)?);
    }
    Ok(())
}
