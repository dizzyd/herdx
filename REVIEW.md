# Correctness review

Rechecked September 19, 2026 against commit `34494e2`. Scope: HerdX-owned code
and its relevant vendored protocol contracts. Only findings with remaining gaps
are retained below; the original issue numbers are preserved.

`./scripts/check.sh` passed: 47 Rust tests, 58 Swift tests, and the macOS app
bundle build. Additional focused probes reproduced the gaps below despite the
passing suite. Input composition was checked through event routing, not a
physical IME interaction. The developer's live herdr session was not modified.

## 8. [P2] The terminal input path still bypasses composition for Option dead keys

Current locations: `HerdX/Sources/HerdX/KeyMapper.swift:40` (`map`),
`HerdX/Sources/HerdX/TerminalGridView.swift:980` (`keyDown`).

**Original problem:** printable keys were sent directly from `event.characters`;
the view neither implemented `NSTextInputClient` nor invoked text interpretation.
Those characters were keystrokes, not committed IME text, so input methods
requiring composition could not work through that path.

**Fix implemented:** the view now implements `NSTextInputClient`, holds marked
text, and sends committed text from `insertText`. Unmapped printable events and
keys received while text is marked go through `interpretKeyEvents`.

**Remaining gap:** `KeyMapper.map` treats Option as a control-like modifier and
returns a semantic key before the event reaches text interpretation. An Option
dead key therefore cannot start composition. For example, Option+E on the U.S.
layout is sent as an Alt-modified E instead of beginning the acute-accent
composition used to type é.

**Verified:** a synthetic Option+E event returned a non-nil mapping, which takes
the semantic-key send branch in `keyDown` and bypasses `interpretKeyEvents`.
The existing text-input tests exercise marked-text callbacks directly and do
not cover starting composition through an Option dead key. A physical IME
interaction was not exercised.

**Suggested fix:** let text-producing Option events reach the input context,
while preserving intentional terminal Alt shortcuts. Add a regression covering
the initiating dead-key event and the subsequent committed text.

## 9. [P2] Supported user keybindings are still misparsed or matched too broadly

Current locations: `HerdX/Sources/HerdX/Keymap.swift:272` (`spellings`),
`HerdX/Sources/HerdX/Keymap.swift:343` (`action`).

**Original problem:** direct bindings and array-valued bindings were supported
by the vendored server and preserved in its exported profile, but HerdX ignored
them. `new_tab = "alt+t"` never dispatched, and an array-valued `next_tab`
binding disappeared during parsing.

**Fix implemented:** the parser now gathers multiline arrays and creates a
binding for each spelling; the chord resolver dispatches direct bindings as
well as prefixed ones. The original simple examples now work.

**Remaining gaps:**

- Array parsing splits on every comma, including commas inside quoted strings.
  With `next_tab = ["prefix+n", "alt+,"]`, the Alt+comma spelling disappears,
  so that shortcut reaches the terminal instead of switching tabs. This is a
  supported upstream binding and can appear in the exported profile.
- Matching retries unconditionally with Shift ignored. With
  `new_tab = "ctrl+shift+t"`, Ctrl+T also creates a tab, stealing a distinct
  keystroke from the terminal. The fallback intended for shifted punctuation
  also removes explicitly required Shift modifiers.

**Verified:** a focused Swift probe using the current parser and resolver found
only one `next_tab` binding in the comma example and returned no action for
Alt+comma. A second probe returned `newTab` for Ctrl+T with only Ctrl+Shift+T
configured. Neither case is covered by the existing keymap tests.

**Suggested fix:** use quote-aware TOML parsing for array values and restrict
Shift fallback to the punctuation cases it is intended to support. Add
regressions for quoted commas and for direct bindings with explicit Shift.
