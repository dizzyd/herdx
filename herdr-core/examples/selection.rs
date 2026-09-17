//! Reads the first few lines of the focused pane through `pane.selection.read`.
//!
//! This checks the absolute-scrollback coordinate maths the Swift selection
//! model uses, against a live server. It only reads.

use herdr_core::client::{default_socket_path, hello, EndpointConnection};
use herdr_core::protocol::{ClientMessage, ClientShellSnapshot, ServerMessage};

fn main() -> std::io::Result<()> {
    let mut conn = EndpointConnection::connect(&default_socket_path(), &hello(100, 24, 8, 16))?;

    let mut boot_id = None;
    let mut target = None;

    for _ in 0..60 {
        match conn.recv()? {
            ServerMessage::EndpointControl { kind, data } if kind == "shell.snapshot.v1" => {
                let snapshot: ClientShellSnapshot = serde_json::from_str(&data).unwrap();
                boot_id = Some(snapshot.boot_id);
            }
            ServerMessage::PaneSurface(frame) => {
                if let Some(pane) = frame.panes.iter().find(|p| p.focused) {
                    let top = pane
                        .scroll
                        .map_or(0, |s| s.max_offset_from_bottom.saturating_sub(s.offset_from_bottom));
                    target = Some((
                        pane.pane_id.clone(),
                        top,
                        pane.inner_rect.width,
                        pane.content_revision,
                    ));
                }
            }
            _ => {}
        }
        if boot_id.is_some() && target.is_some() {
            break;
        }
    }

    let (Some(boot_id), Some((pane_id, top, width, revision))) = (boot_id, target) else {
        println!("no focused pane found");
        return Ok(());
    };
    println!("pane {pane_id}: viewport top row {top}, width {width}, content revision {revision}");

    // The first three viewport rows, in absolute scrollback coordinates.
    let request = format!(
        r#"{{"id":"sel-1","method":"pane.selection.read","params":{{"pane_id":"{pane_id}","anchor":{{"row":{top},"col":0}},"cursor":{{"row":{},"col":{}}},"content_revision":{revision}}}}}"#,
        top + 2,
        width.saturating_sub(1)
    );
    println!("-> {request}");
    conn.send(&ClientMessage::ClientShellEndpointRequest { boot_id, request })?;

    let mut body = Vec::new();
    for _ in 0..400 {
        match conn.recv()? {
            ServerMessage::ClientShellEndpointResponseChunk {
                final_chunk, data, ..
            } => {
                body.extend_from_slice(&data);
                if final_chunk {
                    println!("<- {}", String::from_utf8_lossy(&body));
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
