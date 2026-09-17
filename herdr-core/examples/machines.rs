//! Lists discovered endpoints and attaches to each, reporting what came back.

use herdr_core::client::{default_socket_path, hello_with_surface, EndpointConnection};
use herdr_core::endpoint;
use herdr_core::protocol::{ClientShellSnapshot, ServerMessage};

fn main() {
    let endpoints = endpoint::discover();
    println!("selection: {:?}\n", endpoint::saved_selection());

    for ep in endpoints {
        println!("== {} ({}) {:?}", ep.label, ep.id, ep.kind);
        let started = std::time::Instant::now();
        // Only the endpoint you are looking at needs a surface; the rest are
        // attached purely for their snapshots.
        let hello = hello_with_surface(100, 30, 8, 16, false);
        let mut conn = match EndpointConnection::attach(&ep, &default_socket_path(), &hello) {
            Ok(conn) => conn,
            Err(err) => {
                println!("   offline: {err}\n");
                continue;
            }
        };
        println!(
            "   connected in {:?}, server {}",
            started.elapsed(),
            conn.welcome().server_version
        );

        for _ in 0..40 {
            match conn.recv() {
                Ok(ServerMessage::EndpointControl { kind, data })
                    if kind == "shell.snapshot.v1" =>
                {
                    let snapshot: ClientShellSnapshot = serde_json::from_str(&data).unwrap();
                    println!(
                        "   {} workspace(s), {} tab(s), {} agent(s)",
                        snapshot.workspaces.len(),
                        snapshot.tabs.len(),
                        snapshot.agents.len()
                    );
                    for workspace in &snapshot.workspaces {
                        println!(
                            "     workspace {} {:?} branch={:?} status={:?}",
                            workspace.number, workspace.label, workspace.branch,
                            workspace.agent_status
                        );
                    }
                    for agent in &snapshot.agents {
                        println!(
                            "     agent {:?} status={:?}",
                            agent.display_agent, agent.agent_status
                        );
                    }
                    break;
                }
                Ok(_) => {}
                Err(err) => {
                    println!("   stream ended: {err}");
                    break;
                }
            }
        }
        println!();
    }
}
