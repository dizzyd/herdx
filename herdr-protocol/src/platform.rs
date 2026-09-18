//! Minimal stand-in for herdr's `platform` module.
//!
//! herdr's real `platform` reaches into `integration`, `ipc` and `interprocess`
//! to manage servers and PTYs. The client protocol path needs exactly one thing
//! from it, so shimming avoids pulling that whole subsystem into this crate.
//!
//! The upstream definition is pure `cfg!()`, so this cannot drift in behaviour
//! without a compile-visible change upstream.
//!
//! Not upstream's file. `PlatformCapabilities` and its values are reproduced
//! from herdr's `platform` (Apache-2.0; see NOTICE) so the vendored sources
//! compile against them.

pub(crate) struct PlatformCapabilities {
    #[allow(dead_code)]
    pub(crate) live_handoff: bool,
    #[allow(dead_code)]
    pub(crate) direct_terminal_attach: bool,
    pub(crate) preserve_legacy_doubled_escape_input: bool,
}

pub(crate) const fn capabilities() -> PlatformCapabilities {
    PlatformCapabilities {
        live_handoff: cfg!(unix),
        direct_terminal_attach: cfg!(unix),
        preserve_legacy_doubled_escape_input: cfg!(target_os = "macos"),
    }
}
