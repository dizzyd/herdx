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
