//! Endpoint client and C ABI for HerdX, the native macOS client for herdr.
//!
//! The wire protocol itself lives in `herdr-protocol`, which vendors herdr's
//! own sources. This crate is the part we write: connecting, handshaking, and
//! maintaining the surface the renderer draws.

pub mod client;
pub mod ffi;

/// Re-exported so callers need only depend on this crate.
pub use herdr_protocol::protocol;
