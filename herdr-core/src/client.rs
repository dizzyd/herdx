//! Endpoint client: connect to a herdr server and speak generation 1.
//!
//! This is the seam the Swift app sits on. It owns the socket, the handshake
//! and framing; everything above it works in terms of decoded protocol types.

use std::io::{self, Write};
use std::path::{Path, PathBuf};

use herdr_protocol::protocol::endpoint::{
    EndpointClientHello, EndpointServerWelcome, ENDPOINT_HELLO_KIND, ENDPOINT_PROTOCOL_GENERATION,
    ENDPOINT_WELCOME_KIND, BLOB_CODEC_V1, INPUT_CODEC_V1, SNAPSHOT_CODEC_V1, SURFACE_CODEC_V1,
};
use herdr_protocol::protocol::{
    read_message, write_message, ClientMessage, ClientSurfaceSize, ServerMessage,
};

/// Where the running server's client socket lives.
///
/// Mirrors herdr's own override order: `HERDR_SOCKET_PATH` derives the client
/// socket from the API socket, `HERDR_CLIENT_SOCKET_PATH` overrides it
/// directly, and otherwise it sits in the session data directory.
pub fn default_socket_path() -> PathBuf {
    if let Ok(api) = std::env::var("HERDR_SOCKET_PATH") {
        let api = PathBuf::from(api);
        let stem = api
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("herdr")
            .to_owned();
        return api
            .parent()
            .unwrap_or_else(|| Path::new(""))
            .join(format!("{stem}-client.sock"));
    }
    if let Ok(explicit) = std::env::var("HERDR_CLIENT_SOCKET_PATH") {
        return PathBuf::from(explicit);
    }
    config_dir().join("herdr-client.sock")
}

fn config_dir() -> PathBuf {
    if let Ok(dir) = std::env::var("HERDR_CONFIG_DIR") {
        return PathBuf::from(dir);
    }
    if let Ok(dir) = std::env::var("XDG_CONFIG_HOME") {
        return PathBuf::from(dir).join("herdr");
    }
    PathBuf::from(std::env::var("HOME").unwrap_or_default())
        .join(".config")
        .join("herdr")
}

/// A generation-1 hello describing a native client surface.
///
/// `surface_active` is what makes federation cheap: every machine stays
/// connected so its agents show up in the sidebar, but only the one you are
/// looking at renders a surface. An inactive endpoint still sends snapshots.
pub fn hello_with_surface(
    cols: u16,
    rows: u16,
    cell_width_px: u32,
    cell_height_px: u32,
    surface_active: bool,
) -> EndpointClientHello {
    let mut hello = hello(cols, rows, cell_width_px, cell_height_px);
    hello.surface_active = surface_active;
    hello
}

pub fn hello(cols: u16, rows: u16, cell_width_px: u32, cell_height_px: u32) -> EndpointClientHello {
    EndpointClientHello {
        generation: ENDPOINT_PROTOCOL_GENERATION,
        cell_width_px,
        cell_height_px,
        surface_size: ClientSurfaceSize { cols, rows },
        // The Mac app reports exact pixel geometry, so SGR pixel mouse is coherent.
        pixel_mouse: true,
        // Kitty graphics passthrough is a terminal-host concern; we render
        // images ourselves from the surface graphics scene.
        direct_graphics: false,
        // The client owns its keymap so ⌘ chords and the ctrl+b prefix can
        // coexist; see the keybinding layer.
        endpoint_keybindings: false,
        mouse_capture: true,
        surface_active: true,
        // Only advertised once decoded: a server that supports these stops
        // sending plain surfaces entirely, so claiming them without handling
        // them leaves the view frozen on whatever arrived first.
        surface_reuse: false,
        surface_delta: false,
        snapshot_codecs: vec![SNAPSHOT_CODEC_V1.into()],
        surface_codecs: vec![SURFACE_CODEC_V1.into()],
        input_codecs: vec![INPUT_CODEC_V1.into()],
        blob_codecs: vec![BLOB_CODEC_V1.into()],
    }
}

/// An established endpoint connection.
pub struct EndpointConnection {
    reader: crate::endpoint::ReadHalf,
    writer: Option<crate::endpoint::WriteHalf>,
    welcome: EndpointServerWelcome,
}

impl EndpointConnection {
    /// Connects to the local server over its socket.
    pub fn connect(path: &Path, hello: &EndpointClientHello) -> io::Result<Self> {
        Self::attach(
            &crate::endpoint::Endpoint {
                id: "local".into(),
                label: "Local".into(),
                kind: crate::endpoint::EndpointKind::Local,
            },
            path,
            hello,
        )
    }

    /// Connects to any endpoint — the local socket or a machine over ssh — and
    /// completes the generation-1 handshake.
    pub fn attach(
        endpoint: &crate::endpoint::Endpoint,
        socket: &Path,
        hello: &EndpointClientHello,
    ) -> io::Result<Self> {
        let (mut reader, mut writer) = crate::endpoint::Transport::connect(endpoint, socket)?;

        let data = serde_json::to_string(hello).map_err(io::Error::other)?;
        write_message(
            &mut writer,
            &ClientMessage::EndpointControl {
                kind: ENDPOINT_HELLO_KIND.into(),
                data,
            },
        )
        .map_err(|e| io::Error::other(e.to_string()))?;
        writer.flush()?;

        let reply: ServerMessage =
            match read_message(&mut reader, herdr_protocol::protocol::MAX_FRAME_SIZE) {
                Ok(reply) => reply,
                Err(error) => {
                    // A transport that died during the handshake usually knows
                    // why; saying "the stream ended" hides the real reason.
                    return Err(io::Error::other(match reader.diagnostics() {
                        Some(details) => format!("{error}: {details}"),
                        None => error.to_string(),
                    }));
                }
            };

        let ServerMessage::EndpointControl { kind, data } = reply else {
            return Err(io::Error::other(
                "server did not answer the endpoint hello with an endpoint control",
            ));
        };
        if kind != ENDPOINT_WELCOME_KIND {
            return Err(io::Error::other(format!(
                "unexpected handshake reply kind: {kind}"
            )));
        }

        let welcome: EndpointServerWelcome =
            serde_json::from_str(&data).map_err(io::Error::other)?;
        if let Some(error) = &welcome.error {
            return Err(io::Error::other(format!(
                "handshake refused [{}]: {}",
                error.code, error.message
            )));
        }

        Ok(Self {
            reader,
            writer: Some(writer),
            welcome,
        })
    }

    /// Whether the server is running the same build this crate vendored.
    ///
    /// This matters more than it looks. Snapshots, input and handshake travel
    /// as JSON inside `EndpointControl`, which herdr freezes for generation 1 —
    /// those are safe across versions. But pane surfaces arrive as
    /// `ServerMessage::PaneSurface`, a *private-protocol* bincode variant whose
    /// tag is positional. If a newer server inserts a variant ahead of it, we
    /// would silently decode surfaces as the wrong type.
    ///
    /// herdr bumps `PROTOCOL_VERSION` whenever that layout changes
    /// incompatibly, so equal versions mean the surface lane is safe. Callers
    /// should surface a mismatch rather than trust rendered output.
    pub fn version_note(&self) -> Option<String> {
        let vendored = herdr_protocol::VENDORED_HERDR_VERSION;
        if self.welcome.server_version == vendored {
            return None;
        }
        Some(format!(
            "server is herdr {} but these protocol sources are from {vendored} \
             (private protocol {}); the JSON endpoint lane is stable across \
             versions, but pane surfaces ride the private protocol, so confirm \
             the server reports the same number before trusting them",
            self.welcome.server_version,
            herdr_protocol::VENDORED_PROTOCOL_VERSION,
        ))
    }

    pub fn welcome(&self) -> &EndpointServerWelcome {
        &self.welcome
    }

    pub fn send(&mut self, message: &ClientMessage) -> io::Result<()> {
        let Some(writer) = self.writer.as_mut() else {
            return Err(io::Error::other("write half already taken"));
        };
        write_message(writer, message).map_err(|e| io::Error::other(e.to_string()))?;
        writer.flush()
    }

    /// Takes the write half, for sending from another thread.
    ///
    /// The receive loop blocks in `recv`, so outbound messages need their own
    /// handle rather than waiting for it to return.
    pub fn take_writer(&mut self) -> Option<crate::endpoint::WriteHalf> {
        self.writer.take()
    }

    pub fn recv(&mut self) -> io::Result<ServerMessage> {
        match read_message(&mut self.reader, herdr_protocol::protocol::MAX_FRAME_SIZE) {
            Ok(message) => Ok(message),
            Err(error) => Err(io::Error::other(match self.reader.diagnostics() {
                Some(details) => format!("{error}: {details}"),
                None => error.to_string(),
            })),
        }
    }
}
