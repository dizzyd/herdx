//! herdr's wire protocol, minus the server-only ANSI renderer.
//!
//! `render_ansi` is intentionally absent: it is the server-side encoder and the
//! only file under `protocol/` that depends on `libghostty-vt`, which would
//! pull a Zig toolchain into this build. A client never needs it.

mod wire;
pub use wire::*;

pub mod endpoint;
pub(crate) mod surface_delta;
pub(crate) mod surface_reuse;

/// Decodes herdr's optional compact surface encodings into plain surfaces.
///
/// `surface_reuse` resends a surface without its cells when only metadata
/// changed, and `surface_delta` sends changed spans against the last one. Both
/// arrive as named `EndpointControl` messages, and both matter over ssh, where
/// a full 120x34 surface per frame is a lot of bytes.
///
/// The decoder keeps a baseline, so **every** server message must pass through
/// it, not only the compact ones — a plain surface or patch is what the next
/// compact message is expressed against.
pub struct SurfaceDecoder {
    inner: surface_reuse::Decoder,
    surface_delta: bool,
}

impl SurfaceDecoder {
    pub fn new(surface_delta: bool) -> Self {
        Self {
            inner: surface_reuse::Decoder::new(surface_delta),
            surface_delta,
        }
    }

    /// Normalises one message, returning it unchanged when it is not encoded.
    ///
    /// An error means the baseline and the sender have diverged; the caller
    /// should `reset` and ask the server for a complete surface.
    pub fn decode(&mut self, message: ServerMessage) -> Result<ServerMessage, String> {
        self.inner.decode(message)
    }

    pub fn reset(&mut self) {
        self.inner = surface_reuse::Decoder::new(self.surface_delta);
    }
}
