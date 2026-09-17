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

## Crates

| Crate | What it is |
| --- | --- |
| `herdr-protocol` | herdr's own protocol sources, vendored. Carries `test = false`, because herdr's `#[cfg(test)]` modules reach into subsystems omitted here. |
| `herdr-core` | Everything we write: connection, handshake, surface model, C ABI. Ordinary unit tests. |

Rather than hand-writing a bincode implementation in Swift, `herdr-protocol`
reuses herdr's own sources directly from the pinned `vendor/herdr` submodule.
`herdr-protocol/src` mirrors herdr's module layout with symlinks, so the wire
codec is bit-identical to the server's and tracks the submodule automatically.

Only what a *client* needs is included. Deliberately omitted:

| Omitted | Why |
| --- | --- |
| `protocol::render_ansi` | Server-side ANSI encoder, and the only file under `protocol/` that needs `libghostty-vt` — which would pull a **Zig toolchain** into this build. |
| `detect`, `platform`, `sound` | Replaced by small local shims. The real ones reach into PTY spawning, `interprocess` and embedded MP3 assets for a handful of types. None are wire-visible; `tests/protocol.rs` fails loudly if upstream's definitions drift. |

The result builds with a plain `cargo build` — no Zig, no tokio, no PTY.

## Protocol compatibility

Two lanes, with different guarantees:

- **JSON over `EndpointControl`** (handshake, snapshot, agent view) — frozen by
  herdr for generation 1. Safe across server versions; unknown fields are
  ignored by design.
- **Private bincode variants** (`PaneSurface`, `PaneSurfacePatch`) — positional
  tags. Safe only while the vendored `PROTOCOL_VERSION` matches the server's
  `private_protocol`. `herdr-protocol`'s build script reads the pinned herdr
  version out of the submodule so `EndpointConnection::version_note()` can
  report a mismatch, instead of silently mis-decoding a frame.

Surfaces arrive either complete or as sparse row spans against the last
committed revision. A patch that does not build on the surface we hold is
refused and the last coherent frame stays on screen until the server sends a
complete one — a stitched grid is worse than a slightly stale one.

## Status

- [x] `herdr-core` builds against the vendored protocol, no Zig
- [x] Generation-1 handshake, snapshot and pane surfaces verified against a live server
- [x] C ABI shim
- [x] Swift app: cell-grid renderer, native sidebar, ⌘ chords + `ctrl+b` prefix
- [x] Mouse input: click-to-focus, drag, right-click, scroll
- [x] Native notifications, clipboard (OSC 52), window title, bell
- [x] Drag selection, double-click word, triple-click line, copy and paste
- [x] Reconnects when the server restarts
- [ ] Copy mode (`prefix+[`) and search
- [ ] Promote panes to real `NSView`s (the patch-routing seam is already in place)
- [ ] Kitty graphics, ligatures, font configuration

### Selection

Selections are held in absolute scrollback coordinates, not viewport rows, so
they survive the pane scrolling and new output arriving underneath — which is
what happens constantly while an agent works. The text itself comes back from
`pane.selection.read` rather than from the drawn cells, because a selection can
cover scrollback the client never rendered.

A program that asked for mouse reporting owns its drags, which is what keeps
editors and pagers usable; hold ⌥ to select out of one anyway.

Double-click reads the drawn cells rather than asking the server: a double-click
targets something visible, so the rendered row is the right source. Word
characters lean inclusive (`_-./~:@+=%#?&`) because what people double-click in a
terminal is paths, URLs and identifiers.

Paste is its own protocol event rather than committed text, so the pane can wrap
it in bracketed-paste markers when the program asked for them.

### Rendering

Rows are drawn as runs of identical style through CoreText, with every glyph
placed at its own cell origin. Both halves matter: batching avoids running the
text pipeline per cell, and explicit positioning stops a long run from drifting
out of its columns, which happens because a monospace advance is rarely exactly
the integral cell width the grid snaps to. Clusters and glyphs the font lacks
fall back to AppKit so its font fallback still covers emoji and box drawing.

## Development

```sh
git submodule update --init
cargo test                                 # protocol guards, shim drift, surface model
cargo run -p herdr-core --example probe    # handshake against a running server
cargo run -p herdr-core --example dump     # print the current surface as text
./scripts/bundle.sh                        # build build/HerdX.app
```

HerdX attaches to a herdr server that is already running; start one with `herdr`
in a terminal first.

### Notifications

herdr reports *semantic* events — `NeedsAttention`, `Finished` — and leaves
presentation to each client. HerdX turns those into macOS notifications, with
`NeedsAttention` raised to a time-sensitive interruption, since an agent waiting
on you is the one thing worth breaking concentration for.

This needs the bundle: `UNUserNotificationCenter` raises rather than returning an
error when the process has no bundle identifier, so notifications are disabled
when running the executable outside `HerdX.app`.

### Testing against a throwaway session

Never test disconnects against the session you are working in. herdr runs
isolated named sessions with their own sockets, so use one of those:

```sh
herdr --session hxtest server &                     # real server, headless
export SOCK=~/.config/herdr/sessions/hxtest/herdr-client.sock
HERDR_CLIENT_SOCKET_PATH=$SOCK ./build/HerdX.app/Contents/MacOS/HerdX
herdr --session hxtest server stop                  # exercise reconnect
herdr session delete hxtest
```

Note that `HERDR_SOCKET_PATH` takes precedence over `HERDR_CLIENT_SOCKET_PATH`,
and herdr sets it for processes running inside a pane — so from a herdr pane,
`env -u HERDR_SOCKET_PATH` is needed or you will talk to your own session.

### Looking at the renderer without a window in your face

```sh
HERDX_CAPTURE=/tmp/herdx.png ./build/HerdX.app/Contents/MacOS/HerdX
```

`HERDX_CAPTURE_DELAY` sets how long to wait first, which is how reconnection
gets checked: capture late enough to land after a server restart.

The window is laid out off-screen and never activates, so this does not steal
focus or appear on any display. It also avoids `screencapture -R`, which picks
the wrong display on multi-monitor setups.
