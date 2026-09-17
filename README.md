# HerdX

A native macOS client for [herdr](https://github.com/herdrdev/herdr).

## Architecture

herdr's server already does the terminal emulation (it vendors `libghostty-vt`)
and exposes a **stable, versioned contract for client-owned shells** — the
"endpoint" protocol, generation 1, which herdr commits to keeping available
indefinitely. HerdX is a first-class consumer of that contract rather than a
terminal emulator.

```
┌─────────────────────────────┐
│  SwiftUI / AppKit chrome    │  tabs, sidebar, menus — from ClientShellSnapshot
├─────────────────────────────┤
│  Metal/CoreText grid view   │  draws CellData
├─────────────────────────────┤
│  C ABI shim (staticlib)     │
│  herdr-core (Rust)          │  protocol + framing + handshake
└──────────┬──────────────────┘
           │ unix socket (bincode frames)
      herdr server
```

Two consequences worth stating plainly:

- **No terminal emulator in the client.** The server sends composed cell grids
  (`PaneSurfaceFrame` / `PaneSurfacePatch`), not raw PTY bytes. SwiftTerm and
  friends want to own a VT parser and a PTY; both are already taken. What HerdX
  needs is a fast *cell-grid renderer*.
- **Chrome is structured data.** Workspaces, tabs, panes and agent status arrive
  as JSON in `ClientShellSnapshot`, so the sidebar and tab bar are real AppKit
  views, not a picture of a TUI.

## `herdr-core`

Rather than hand-writing a bincode implementation in Swift, `herdr-core` reuses
herdr's own protocol sources directly from the pinned `vendor/herdr` submodule.
`herdr-core/src` mirrors herdr's module layout with symlinks, so the wire codec
is bit-identical to the server's and tracks the submodule automatically.

Only what a *client* needs is included. Deliberately omitted:

| Omitted | Why |
| --- | --- |
| `protocol::render_ansi` | Server-side ANSI encoder, and the only file under `protocol/` that needs `libghostty-vt` — which would pull a **Zig toolchain** into this build. |
| `detect`, `platform`, `sound` | Replaced by small local shims (`src/detect.rs`, `src/platform.rs`, `src/sound.rs`). The real ones reach into PTY spawning, `interprocess` and embedded MP3 assets for a handful of types. None are wire-visible; `tests/protocol.rs` fails loudly if upstream's definitions drift. |

The result builds with a plain `cargo build` — no Zig, no tokio, no PTY.

## Protocol compatibility

Two lanes, with different guarantees:

- **JSON over `EndpointControl`** (handshake, snapshot, agent view) — frozen by
  herdr for generation 1. Safe across server versions; unknown fields are
  ignored by design.
- **Private bincode variants** (`PaneSurface`, `PaneSurfacePatch`) — positional
  tags. Safe only while the vendored `PROTOCOL_VERSION` matches the server's
  `private_protocol`. `EndpointConnection::version_note()` reports a mismatch so
  it surfaces as an error instead of a mis-decoded frame.

## Status

- [x] `herdr-core` builds against the vendored protocol, no Zig
- [x] Generation-1 handshake, snapshot and pane surfaces verified against a live server
- [ ] C ABI shim
- [ ] Swift app: cell-grid renderer, native chrome, ⌘ chords + `ctrl+b` prefix

## Development

```sh
git submodule update --init
cargo test -p herdr-core          # protocol + shim-drift guards
cargo run -p herdr-core --example probe   # talk to a running herdr server
```
