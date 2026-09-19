# Working on HerdX

`README.md` explains what HerdX is and how it is put together. This file is
about working on it: the rules that protect the person whose machine this runs
on, and the things that have already cost a day each to learn.

## Two rules that are not negotiable

**Never touch the developer's real herdr session.** It is their live work —
running agents, unsaved terminals, panes they are in the middle of. A stray
`herdr server stop` once killed it and lost a tab.

- `HERDR_CONFIG_DIR` does **not** isolate the CLI. It was tried; the CLI still
  used the real socket. Do not rely on it.
- Use a throwaway session instead:
  ```sh
  herdr --session hxtest server                       # starts only a server
  HERDR_CLIENT_SOCKET_PATH=~/.config/herdr/sessions/hxtest/herdr-client.sock …
  herdr --session hxtest server stop                  # when finished
  ```
- `herdr --session <name>` is genuinely isolated: its own socket under
  `~/.config/herdr/sessions/<name>/`. Verify with
  `herdr --session hxtest status` before assuming.
- Reading the real session is fine — attaching a client is harmless. Writing to
  it is not: no `pane split`, no `server stop`, no sending input.
- Shell state to be aware of: a terminal inside herdr has `HERDR_ENV=1`,
  `HERDR_SOCKET_PATH` and `HERDR_PANE_ID` set. `HERDR_SOCKET_PATH` will point a
  test run straight back at the real server — clear it with `env -u`.
  `HERDR_ENV=1` makes `herdr` refuse to start a nested TUI (subcommands are
  exempt).

**Never put the window on screen unasked.** Development means running the app
dozens of times; each one stealing focus from whoever is at the keyboard is not
acceptable.

- `HERDX_HEADLESS=1` runs without ever ordering a window in. `HERDX_CAPTURE`
  implies it.
- If something genuinely needs a real compositor, ask first, then use
  `HERDX_QUIET_FRONT=1`, which orders the window in without `NSApp.activate`.
- **Never take a full-screen `screencapture`.** It has twice caught things that
  were nobody's business — a video call, a calendar. Capture the app's own view,
  or nothing.

## Building and testing

```sh
./scripts/check.sh      # cargo test + bundle — run before every commit
./scripts/bundle.sh     # assembles build/HerdX.app
./scripts/package.sh    # signs and notarizes a release .dmg (see RELEASING.md)
./scripts/icon.sh       # redraws assets/HerdX.icns — only when the icon changes
```

The icon is a drawing (`scripts/icon.swift`), not an exported image, so its
colours can follow the palettes in `Palette.swift`. `bundle.sh` copies the
committed `.icns` and stops if it is missing: an app wearing the generic bundle
icon looks broken, and nothing else in the build would mention it.

`bundle.sh` deletes the SwiftPM product before building. SwiftPM does not know
about `libherdr_core.a` — it arrives through a raw `-L` flag and is not a
tracked input — so without that a Rust-only change leaves the old code linked in
and the build silently lies to you.

That `-L` comes from `HERDX_CORE_LIB_DIR`, which `bundle.sh` sets to the profile
it just built. A bare `swift build` still works — the manifest falls back to
`../target/debug` — but it will link whatever is sitting there.

`HERDX_UNIVERSAL=1` builds both slices and lipos the staticlib, which releases
need. Two traps live in that path, both of which fail quietly rather than
loudly: SwiftPM wants `--arch arm64` where Rust says `aarch64`, and hands back a
thin binary if you give it the Rust spelling; and the universal build lands in
`.build/apple/Products/<Config>`, not `.build/<config>`, so the binary is found
via `--show-bin-path` rather than a hardcoded path. `bundle.sh` asserts both
slices are present before it claims success.

## Verify by measuring, never by reasoning

Nearly every bug in this app's history looked obviously-fixed in the source and
was not. The habit that works:

- **Check what the server did, not what you sent.** Printing a payload is
  checking your own homework. Four commands were sending parameters herdr
  rejects, and the payloads all looked right.
- **A capture can lie.** `cacheDisplay` walks subviews and draws them in order;
  a real window composites layers. A status strip was "visible, opaque, in the
  window, correctly coloured" in every probe and invisible on screen, because
  layer order is the one thing an offscreen render cannot show. There is a
  comment in `main.swift` about this; it is there because it cost hours.
- **Ask the right question.** "Is it visible?" was the wrong question three
  times running. "Where is it?" found it.
- **Reproduce the failure before believing the fix.** The focus bug only
  reproduced with a second client holding foreground; without that, the fix and
  the bug were indistinguishable.
- Python edits that `str.replace` without asserting the match land silently and
  build clean. Assert first. A commit once claimed a fix that was never applied.

## Dev affordances

All are development-only and read from the environment.

| Variable | Does |
| --- | --- |
| `HERDX_HEADLESS=1` | Never order a window in |
| `HERDX_QUIET_FRONT=1` | Show the window without taking focus |
| `HERDX_CAPTURE=<path>` | Render and exit; implies headless |
| `HERDX_CAPTURE_DELAY=<s>` | How long to settle first |
| `HERDX_CAPTURE_COMPOSITED=1` | Ask the window server instead of `cacheDisplay` (needs Screen Recording; returns nil without it) |
| `HERDX_CAPTURE_SETTINGS` / `_MACHINES` / `_THEMES` | Photograph those windows |
| `HERDX_CAPTURE_HELP=<action>` | Photograph the sheet an action opens |
| `HERDX_PROBE_INPUT=<text>` | Report input state, then type through the real AppKit path |
| `HERDX_PROBE_CHORDS=1` | Report any prefix binding no keystroke can reach |
| `HERDX_PROBE_COMMANDS=1` | Run commands against a live server and report what it made of them — throwaway sessions only |
| `HERDX_PROBE_RESIZE=1` | Put resize mode up so it can be photographed |
| `HERDX_ENDPOINT=<id>` | Pick an endpoint for one run (`local`, or a profile id) without writing the selection the TUI shares |

`herdr-core/examples/` holds the same idea for the Rust half — each is one
question, and its first line says which. `ffi_drive` and `input` exist to tell a
core bug from a UI bug.

## Things herdr does that are not obvious

- **One host theme per session.** herdr applies the *foreground* client's
  palette to every pane and re-applies it on every promotion, so two clients
  with different colours will fight. Not publishing does not help — the stored
  theme is applied whether or not it was just sent. The only fix is for both
  clients to hold the same palette.
- **A client is promoted by saying it has focus.** Without `ClientShellFocus`,
  you are only promoted as a side effect of typing or resizing — and the server
  drops a host-theme update from anyone who is not foreground, silently.
- **Parameters must match the schema exactly.** `tab.focus` takes a `tab_id` and
  has no relative form. `pane.close` and `tab.close` need an explicit id.
  `tab.create` and `workspace.create` default `focus` to false. Read
  `vendor/herdr/src/api/schema/` rather than guessing.
- **Read replies.** A rejected request does nothing and says nothing; that is
  how four broken commands went unnoticed.
- **Commands carry a boot id**, and it must be the boot id of the machine being
  targeted, not of whichever was active a moment ago. Stale or odd
  `content_revision` values are rejected too.
- **Pane ids are only unique within a server.** Two attached machines really do
  both have a `w1:p1`. Key anything cross-machine by endpoint as well.
- **The keymap belongs to the user.** Every snapshot carries
  `server_keybindings_toml`. Read it; do not hand-write bindings. Additions go
  in `Keymap.additions` and are only adopted where herdr left the key free.
- **The machine catalog is herdr's file**, read with `deny_unknown_fields` — an
  extra key makes herdr reject the whole thing. Write exactly its five fields,
  through a temporary file.
- **herdr installs itself on a remote machine** only via `herdr --remote` or
  `herdr machine add`, and refuses unless stdin is a terminal. Do not work
  around that; run it in a pane, which is a terminal.

## Conventions in this codebase

- **Two palettes, and mixing them is the most repeated bug here.** Anything
  drawn over the terminal takes `Chrome`; anything in a standard Mac window
  takes system colours; a system control sitting on the chrome must be told the
  chrome's appearance. Four separate bugs came from getting this wrong.
- **Chrome is built from the colour the panes are actually painted in**, not
  from the configured one. A program that sets its own background wins on
  screen, and the window should follow what is on screen.
- **Context belongs to the thing it describes.** A working directory and an
  agent state belong to a pane, so they are drawn on that pane's frame — not in
  a window-level header that silently changes meaning as focus moves.
- **Views rebuilt every frame cannot be hovered or clicked.** The list views
  compare a signature and return early. Assigning a struct fires `didSet`
  whether or not it changed; compare before invalidating.
- Comments say why, not what. Several in here are the only record of a failed
  approach — leave them.
- Commit messages: concise, plain, and no mention of the assistant.
