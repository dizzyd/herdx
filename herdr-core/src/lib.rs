//! Rust core for HerdX, the native macOS client for herdr.
//!
//! Rather than hand-writing a bincode implementation in Swift, this crate
//! reuses herdr's own protocol sources directly from the pinned
//! `vendor/herdr` submodule. `herdr-core/src` mirrors herdr's module layout
//! with symlinks, so the wire codec stays bit-identical to the server we talk
//! to and tracks the submodule automatically.
//!
//! Only the modules a *client* needs are included; see `protocol` for the one
//! deliberate omission.

pub mod api;
pub mod client;
pub mod ffi;
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
