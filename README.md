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
- [x] Real `NSView` per pane, with a native focus ring
- [x] Copy mode (`prefix+[`, ⇧⌘[) with vi motions, search (⌘F), and visual selection
- [x] Light and dark themes, font and appearance settings (⌘,)
- [x] Kitty graphics (images in panes)
- [x] Federated machines: the local server plus saved SSH remotes

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

### Chrome

The sidebar is two levels: every attached machine, and its workspaces. Tabs live
in a bar above the terminal instead of nested in the sidebar. Nesting them meant
workspace, tab and agent all highlighted at once — each is "focused" in the
snapshot — which read as noise rather than as one selection.

Only the machine you are looking at shows a selected workspace. The others have
a focused workspace on their own server, which is not the same as being what you
are looking at; clicking one switches machines first, and carries that machine's
boot id so the command does not land on the wrong server.

The tab bar and the terminal are arranged by a split view rather than as
constrained siblings in a plain container. That is not stylistic: as siblings,
whichever was added last drew and the other never did, which left the terminal
blank.

### Machines

herdr clients are federated: the local server and every saved SSH machine appear
together, so an agent needing attention on another box is visible without
switching to it. Machines come from herdr's own catalog at
`~/.local/state/herdr/client/endpoints.json`, and the app opens on whichever one
herdr last had selected.

A remote endpoint is `ssh <target> herdr remote-client-bridge`, which speaks the
identical generation-1 protocol over stdio — so one connection implementation
serves both, with only the transport differing.

Every machine stays attached for its snapshots, but only the active one is asked
to render a surface (`surface_active` in the handshake). That is what keeps
watching several machines cheap.

Each endpoint connects and reconnects on its own thread with its own backoff. A
machine that is asleep must not stop the others from working, which is exactly
what a session-wide retry did: the first version tore down every connection each
frame because the *active* endpoint was still completing an ssh handshake, so it
never finished one.

ssh runs with `BatchMode=yes` — there is no terminal to answer a password or
host-key prompt, and a stall would be indistinguishable from a slow machine —
and its stderr is captured, since discarding it makes an unknown host key, a
missing remote herdr and a refused connection all look like "the stream ended".

### Images

Panes carry a graphics scene alongside their cells: image assets keyed by
fingerprint, sent once, plus the complete desired set of placements each frame,
already clipped and in surface cell coordinates. So there is no placement state
to reconcile — decode, cache, and draw back to front.

Decoded images are cached by asset id and pruned when a scene stops referring to
them. Pruning happens on every surface rather than while drawing, because a
scene that has lost all its placements never draws and would otherwise hold its
images for the life of the session.

**Ligatures are deliberately not supported.** The renderer positions every glyph
at its own cell origin, which is what keeps long runs aligned to their columns;
a ligature spans cells by definition and cannot coexist with that. Choosing
alignment over ligatures is the right trade for a terminal, but it is a choice,
not an oversight.

### Copy mode

`prefix+[` or ⇧⌘[ enters copy mode; ⌘F enters it searching. Movement that only
needs coordinates (`hjkl`, arrows, paging, `g`/`G`) is computed locally, while
anything that depends on what the text says — word and paragraph motions,
search — is asked of the server, which holds the scrollback. `v` starts a visual
selection, `y` or Return copies, `q` or Esc leaves; Esc clears a selection before
it exits, so mashing it cannot lose work.

A note on `content_revision`, which is easy to get wrong: the server rejects a
revision that no longer matches *or* that is odd, odd meaning the pane is
mid-update. Pinning it therefore makes an operation fail whenever output is
flowing, which in an agent session is almost always. Selection reads and motions
omit it, matching what herdr's own client does for live selections. Search is
the one call that requires it, so it retries once against a fresher revision.

### Theme

Light mode is not the dark palette inverted — the same hues at dark-mode
luminance are unreadable on white — so the two palettes are tuned separately.
The terminal's palette is a setting of its own, separate from the window's
appearance, and it is what gets published to the server as the host background.

That separation exists because herdr is multi-client. The server keeps a host
theme per client and applies whichever client is *foreground*, chosen by a
monotonic activity stamp. With this app and a herdr TUI attached to the same
session, whichever of them you typed in last decides what colour the terminal
is — so if they disagree, a pane whose program follows the background re-themes
every time focus moves between them, and switches back as soon as you type.

Not publishing does not avoid this: the server then applies herdr's default for
this client, which disagrees just as readily. The fix is for the two clients to
agree, so set **Terminal** to match the other terminal's theme and the pane
stops moving. Following the window is right when this is the only client.

Cells carrying explicit colours still come from the program in the pane, so an
agent with a dark theme stays dark inside a light window. That is the program's
choice to make, not the client's.

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
./scripts/check.sh                         # build and test everything
./scripts/bundle.sh                        # just build build/HerdX.app
```

Examples talk to a running server, which is the only way to check the parts
that assumptions get wrong:

```sh
cargo run -p herdr-core --example probe      # handshake, snapshot, first surface
cargo run -p herdr-core --example dump       # print the current surface as text
cargo run -p herdr-core --example call       # invoke any endpoint method
cargo run -p herdr-core --example selection  # read selected text back
cargo run -p herdr-core --example copymode   # copy-mode motions and search
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

### Running it without a window in your face

Development means running the app constantly, and a window that steals focus
every time is not acceptable when someone is working. `HERDX_HEADLESS=1` lays
the window out off-screen and never activates, so nothing appears on any
display:

```sh
HERDX_HEADLESS=1 ./build/HerdX.app/Contents/MacOS/HerdX
```

`HERDX_CAPTURE` implies it. Always use one of them when testing.

The capture composites the terminal separately from the rest of the window.
`cacheDisplay` on the whole tree silently omits the grid's layer-backed pane
views, so a working terminal came out blank — which cost real time chasing a bug
in the app that was actually a bug in the capture.

### Looking at the renderer without a window in your face

```sh
HERDX_CAPTURE=/tmp/herdx.png ./build/HerdX.app/Contents/MacOS/HerdX
```

`HERDX_CAPTURE_DELAY` sets how long to wait first, which is how reconnection
gets checked: capture late enough to land after a server restart.

The window is laid out off-screen and never activates, so this does not steal
focus or appear on any display. It also avoids `screencapture -R`, which picks
the wrong display on multi-monitor setups.
