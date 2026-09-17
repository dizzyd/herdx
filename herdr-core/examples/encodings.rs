//! Counts which surface encodings a server actually sends.
//!
//! Advertising `surface_reuse`/`surface_delta` without decoding them is only a
//! bug if the server uses them, so this measures it rather than assuming.

use herdr_core::client::{default_socket_path, hello, EndpointConnection};
use herdr_core::endpoint;
use herdr_core::protocol::ServerMessage;

fn main() -> std::io::Result<()> {
    let label = std::env::args().nth(1).unwrap_or_else(|| "Local".into());
    let endpoints = endpoint::discover();
    let Some(target) = endpoints.iter().find(|e| e.label == label) else {
        println!("no endpoint named {label}");
        return Ok(());
    };

    let mut conn =
        EndpointConnection::attach(target, &default_socket_path(), &hello(120, 34, 9, 18))?;
    println!(
        "{label}: server {} capabilities {:?}",
        conn.welcome().server_version,
        conn.welcome().capabilities
    );

    let (mut full, mut patch, mut delta, mut reuse, mut other) = (0, 0, 0, 0, 0);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while std::time::Instant::now() < deadline {
        match conn.recv()? {
            ServerMessage::PaneSurface(_) => full += 1,
            ServerMessage::PaneSurfacePatch(_) => patch += 1,
            ServerMessage::EndpointControl { kind, .. } => {
                if kind.contains("surface-delta") {
                    delta += 1;
                } else if kind.contains("surface-reuse") {
                    reuse += 1;
                } else {
                    other += 1;
                }
            }
            _ => {}
        }
    }
    println!("  full surfaces: {full}");
    println!("  patches:       {patch}");
    println!("  deltas:        {delta}");
    println!("  reuse:         {reuse}");
    println!("  other control: {other}");
    Ok(())
}
