import AppKit

/// Composed input: the seam between an input method and the pane.
///
/// A terminal cannot simply read `event.characters`. For anything that composes
/// — Japanese, Chinese, Korean, a dead key on a European layout — those are the
/// keystrokes, not the text they are building towards, and the text only exists
/// once the input method says it does. Sending them straight on meant those
/// input methods could not work through this path at all.
///
/// So a keystroke that is not one of herdr's semantic keys goes to the input
/// context, and what comes back out of `insertText` is what reaches the pane.
/// The composition itself stays here and is drawn over the cells: the server
/// has never been told about it, and a pane handed each candidate keystroke
/// would run them as input.
extension TerminalGridView: @preconcurrency NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = Self.string(from: string)
        markedText = nil
        needsDisplay = true
        guard !text.isEmpty, let session, let pane = focusedPane else { return }
        session.send(text: text, to: pane)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = Self.string(from: string)
        markedText = text.isEmpty ? nil : text
        needsDisplay = true
    }

    func unmarkText() {
        markedText = nil
        needsDisplay = true
    }

    func hasMarkedText() -> Bool { markedText != nil }

    /// Ranges cover the composition and nothing else.
    ///
    /// What a text view would index into is the document, and this one's lives
    /// on the server: the grid holds only what is on screen, and none of it is
    /// addressable from here. The composition is the only text this view can
    /// honestly speak for, so that is what the ranges describe.
    func markedRange() -> NSRange {
        guard let markedText else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: markedText.utf16.count)
    }

    func selectedRange() -> NSRange {
        NSRange(location: markedText?.utf16.count ?? 0, length: 0)
    }

    func attributedSubstring(
        forProposedRange range: NSRange, actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        // For the same reason: there is no document here to take a substring of.
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Where the candidate window goes: over the cursor, in screen coordinates.
    ///
    /// Without this it lands in a corner of the screen, far from the text being
    /// composed, which is unusable for anything that shows a candidate list.
    func firstRect(
        forCharacterRange range: NSRange, actualRange: NSRangePointer?
    ) -> NSRect {
        let rect = cursorRect()
        guard let window else { return rect }
        return window.convertToScreen(convert(rect, to: nil))
    }

    /// No surface position can be named as a character index; see `markedRange`.
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// Swallowed rather than passed up the responder chain.
    ///
    /// Everything with a name of its own is mapped before the event ever gets
    /// here, so what reaches this is a key the input method declined — and the
    /// default behaviour for that is a beep.
    override func doCommand(by selector: Selector) {}

    private static func string(from value: Any) -> String {
        switch value {
        case let attributed as NSAttributedString: return attributed.string
        case let plain as String: return plain
        default: return ""
        }
    }
}
