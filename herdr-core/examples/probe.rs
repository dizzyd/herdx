//! Connects to the running herdr server and reports what generation 1 gives us.

use herdr_core::client::{default_socket_path, hello, EndpointConnection};
use herdr_core::protocol::{ClientShellSnapshot, ServerMessage};

fn main() -> std::io::Result<()> {
    let path = default_socket_path();
    println!("socket: {}", path.display());

    let mut conn = EndpointConnection::connect(&path, &hello(120, 32, 8, 17))?;
    let w = conn.welcome();
    println!(
        "welcome: server {} generation {}\n  codecs: {} / {} / {} / {}\n  capabilities: {}\n  methods: {}",
        w.server_version,
        w.generation,
        w.snapshot_codec,
        w.surface_codec,
        w.input_codec,
        w.blob_codec,
        w.capabilities.join(", "),
        w.methods.len(),
    );

    for _ in 0..40 {
        match conn.recv()? {
            ServerMessage::EndpointControl { kind, data } if kind == "shell.snapshot.v1" => {
                let s: ClientShellSnapshot = serde_json::from_str(&data).unwrap();
                println!(
                    "\nsnapshot rev {}: {} workspace(s), {} tab(s), {} pane(s), {} agent(s), {} command(s)",
                    s.revision,
                    s.workspaces.len(),
                    s.tabs.len(),
                    s.panes.len(),
                    s.agents.len(),
                    s.commands.len()
                );
                for ws in &s.workspaces {
                    println!("  workspace {} {:?} status={:?}", ws.number, ws.label, ws.agent_status);
                }
                for a in &s.agents {
                    println!(
                        "  agent pane={} {:?} status={:?}",
                        a.pane_id, a.display_agent, a.agent_status
                    );
                }
                println!("  sample bindings:");
                for c in s.commands.iter().take(6) {
                    println!("    {:24} {}", c.command_id, c.binding_label);
                }
            }
            ServerMessage::PaneSurface(f) => {
                println!(
                    "\nPaneSurface rev {}: {}x{} = {} cells, {} pane(s), {} split(s)",
                    f.surface_revision,
                    f.frame.width,
                    f.frame.height,
                    f.frame.cells.len(),
                    f.panes.len(),
                    f.splits.len()
                );
                for p in &f.panes {
                    println!(
                        "  pane {} rect={:?} focused={} alt_screen={}",
                        p.pane_id, p.rect, p.focused, p.alternate_screen_active
                    );
                }
                let row: String = f
                    .frame
                    .cells
                    .iter()
                    .take(f.frame.width as usize)
                    .map(|c| c.symbol.as_str())
                    .collect();
                println!("  first row: {:?}", row.trim_end());
                return Ok(());
            }
            ServerMessage::EndpointControl { kind, .. } => println!("  control: {kind}"),
            other => println!("  {:?}", std::mem::discriminant(&other)),
        }
    }
    Ok(())
}
