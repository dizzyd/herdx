//! herdr's wire protocol, vendored from the pinned `vendor/herdr` submodule.
//!
//! Rather than hand-writing a bincode implementation in Swift, this crate
//! reuses herdr's own protocol sources: `src` mirrors herdr's module layout
//! with symlinks, so the wire codec stays bit-identical to the server we talk
//! to and tracks the submodule automatically.
//!
//! This crate is *only* the vendored code. It carries `test = false`, because
//! herdr's own `#[cfg(test)]` modules reach into subsystems omitted here;
//! `tests/` holds the compatibility guards instead, and anything we write
//! ourselves lives in `herdr-core` where it can have ordinary unit tests.
//!
//! Only the modules a *client* needs are included; see `protocol` for the one
//! deliberate omission.

pub mod api;
pub mod protocol;

pub mod agent_resume;
pub mod build_info;
pub mod config;
pub mod input;
pub mod popup_size;
pub mod raw_input;

// Shims standing in for herdr subsystems a client does not need; see each file.
pub mod detect;
pub(crate) mod platform;
pub mod sound;
pub mod terminal_theme;

/// The herdr release the `vendor/herdr` submodule is pinned to.
///
/// This is herdr's version, not this crate's. Use it to check whether a server
/// is running the same build these protocol sources describe.
pub const VENDORED_HERDR_VERSION: &str = env!("HERDR_VENDORED_VERSION");

/// The private wire protocol version these sources implement.
///
/// herdr bumps this whenever the bincode layout changes incompatibly, so a
/// server reporting the same number is safe to exchange pane surfaces with.
pub const VENDORED_PROTOCOL_VERSION: u32 = protocol::PROTOCOL_VERSION;
