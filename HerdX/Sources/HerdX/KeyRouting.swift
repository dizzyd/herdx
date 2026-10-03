import AppKit

/// Whose keystroke is it?
///
/// herdr's bindings are resolved by a local event monitor, which AppKit calls
/// for *every* key this application receives — the Settings window, the
/// Machines sheet, the rename prompt, the picker's filter field. Nothing was
/// asked about where the event came from, so a prefix chord typed into a text
/// field was carried out against the terminal: `⌃b x` while renaming a tab
/// closed a pane instead of typing an x.
///
/// A monitor cannot be scoped at registration, so the question has to be asked
/// on each event, and it is worth a name of its own because getting it wrong is
/// invisible until somebody's text field eats their work.
enum KeyRouting {
    /// Whether this keystroke is the terminal's to interpret.
    ///
    /// Two conditions, and both are needed. The event must belong to the
    /// terminal's own window, which excludes every other window and every
    /// sheet — a sheet is a window of its own, so a prompt's field is ruled out
    /// here. And the terminal view must be what holds keyboard input inside
    /// that window, which is the condition that survives a text field being
    /// added to the terminal window later: it is the only responder anything
    /// ever makes first there, so anything else holding it means the keystroke
    /// is not ours.
    static func belongsToTerminal(
        event: NSWindow?, terminal: NSWindow, firstResponder: NSResponder?, terminalView: NSResponder
    ) -> Bool {
        event === terminal && firstResponder === terminalView
    }
}
