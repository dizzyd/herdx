//! Minimal stand-in for herdr's `sound` module.
//!
//! herdr's real `sound` embeds MP3 assets and shells out to a system audio
//! player through `noninteractive_process` and `integration`. The Mac app plays
//! notification audio itself via `NSSound`, so only the `Sound` discriminant is
//! needed here — `config::SoundConfig::path_for` resolves a user-configured
//! override file for each kind.
//!
//! No serde derives upstream, so this is not wire-visible.
//!
//! Not upstream's file. `Sound` and its variants are reproduced from herdr's
//! `sound` (Apache-2.0; see NOTICE) so the vendored sources compile against
//! them.

/// Which notification sound to play.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Sound {
    /// Agent finished work (transitioned to Idle).
    Done,
    /// Agent needs input (transitioned to Blocked).
    Request,
}
