//! Exercises the copy-mode endpoint calls the Swift client makes.
//!
//! The content revision has to come from the pane *surface*, not from
//! `pane.list`, or the server rejects the call as stale.

use herdr_core::client::{default_socket_path, hello, EndpointConnection};
use herdr_core::protocol::{ClientMessage, ClientShellSnapshot, ServerMessage};

fn call(conn: &mut EndpointConnection, boot_id: &str, request: String) -> std::io::Result<()> {
    println!("-> {request}");
    conn.send(&ClientMessage::ClientShellEndpointRequest {
        boot_id: boot_id.to_owned(),
        request,
    })?;
    let mut body = Vec::new();
    for _ in 0..400 {
        match conn.recv()? {
            ServerMessage::ClientShellEndpointResponseChunk { final_chunk, data, .. } => {
                body.extend_from_slice(&data);
                if final_chunk {
                    println!("<- {}\n", String::from_utf8_lossy(&body));
                    return Ok(());
                }
            }
            ServerMessage::ClientShellError { message } => {
                println!("<- error: {message}\n");
                return Ok(());
            }
            _ => {}
        }
    }
    println!("<- no response\n");
    Ok(())
}

fn main() -> std::io::Result<()> {
    let mut conn = EndpointConnection::connect(&default_socket_path(), &hello(100, 24, 8, 16))?;

    let mut boot_id = None;
    let mut pane = None;
    for _ in 0..60 {
        match conn.recv()? {
            ServerMessage::EndpointControl { kind, data } if kind == "shell.snapshot.v1" => {
                let snapshot: ClientShellSnapshot = serde_json::from_str(&data).unwrap();
                boot_id = Some(snapshot.boot_id);
            }
            ServerMessage::PaneSurface(frame) => {
                if let Some(p) = frame.panes.iter().find(|p| p.focused) {
                    let top = p.scroll.map_or(0, |s| {
                        s.max_offset_from_bottom.saturating_sub(s.offset_from_bottom)
                    });
                    pane = Some((p.pane_id.clone(), p.content_revision, top));
                }
            }
            _ => {}
        }
        if boot_id.is_some() && pane.is_some() {
            break;
        }
    }

    let (Some(boot_id), Some((pane_id, revision, top))) = (boot_id, pane) else {
        println!("no focused pane");
        return Ok(());
    };
    println!("pane {pane_id}, surface content_revision {revision}, viewport top {top}\n");

    let query = std::env::args().nth(1).unwrap_or_else(|| "dizzyd".into());
    call(
        &mut conn,
        &boot_id,
        format!(
            r#"{{"id":"search","method":"pane.copy_search","params":{{"pane_id":"{pane_id}","query":"{query}","direction":"forward","cursor":{{"row":{top},"col":0}},"content_revision":{revision}}}}}"#
        ),
    )?;

    call(
        &mut conn,
        &boot_id,
        format!(
            r#"{{"id":"motion","method":"pane.copy_motion","params":{{"pane_id":"{pane_id}","cursor":{{"row":{top},"col":0}},"motion":"next_word_start"}}}}"#
        ),
    )?;

    call(
        &mut conn,
        &boot_id,
        format!(
            r#"{{"id":"eol","method":"pane.copy_motion","params":{{"pane_id":"{pane_id}","cursor":{{"row":{top},"col":0}},"motion":"line_end"}}}}"#
        ),
    )?;
    Ok(())
}
