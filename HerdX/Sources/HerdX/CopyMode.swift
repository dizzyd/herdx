import AppKit

/// herdr's copy mode, driven from the keyboard.
///
/// Kept because it is muscle memory for anyone coming from tmux, and because
/// selecting scrollback without reaching for the mouse is genuinely faster.
/// Movement that only needs coordinates is computed here; anything that needs
/// to know what the text actually says — word and paragraph motions, search —
/// is asked of the server, which holds the scrollback.
struct CopyMode {
    enum Field {
        case none
        /// Typing a search query, with the direction it will run.
        case search(forward: Bool, query: String)
    }

    var paneID: String
    var contentRevision: UInt64
    var cursor: Selection.Point
    /// Where a selection started, once one has.
    var anchor: Selection.Point?
    var field: Field = .none
    /// The last query, so `n` and `N` can repeat it.
    var lastQuery: String?

    var selection: Selection? {
        guard let anchor else { return nil }
        return Selection(
            paneID: paneID, anchor: anchor, cursor: cursor)
    }

    /// What to show in the status strip.
    var statusText: String {
        switch field {
        case .search(let forward, let query):
            return (forward ? "/" : "?") + query
        case .none:
            return anchor == nil ? "COPY" : "COPY — visual"
        }
    }

    /// Server-side motions. The wire names are snake_case.
    enum Motion: String {
        case lineEnd = "line_end"
        case firstNonBlank = "first_non_blank"
        case nextWordStart = "next_word_start"
        case previousWordStart = "previous_word_start"
        case nextWordEnd = "next_word_end"
        case nextBigWordStart = "next_big_word_start"
        case previousBigWordStart = "previous_big_word_start"
        case nextBigWordEnd = "next_big_word_end"
        case previousParagraph = "previous_paragraph"
        case nextParagraph = "next_paragraph"

        /// The vi key that runs this motion, if any.
        static func forKey(_ key: String, shift: Bool) -> Motion? {
            switch (key, shift) {
            case ("w", false): return .nextWordStart
            case ("b", false): return .previousWordStart
            case ("e", false): return .nextWordEnd
            case ("w", true): return .nextBigWordStart
            case ("b", true): return .previousBigWordStart
            case ("e", true): return .nextBigWordEnd
            case ("{", _): return .previousParagraph
            case ("}", _): return .nextParagraph
            case ("$", _): return .lineEnd
            case ("^", _), ("0", _): return .firstNonBlank
            default: return nil
            }
        }
    }

    /// Motions omit `content_revision` for the same reason selection reads do:
    /// a pane that is producing output would otherwise refuse to move.
    func motionRequest(_ motion: Motion, id: String) -> String? {
        let body: [String: Any] = [
            "id": id,
            "method": "pane.copy_motion",
            "params": [
                "pane_id": paneID,
                "cursor": ["row": cursor.row, "col": cursor.column],
                "motion": motion.rawValue,
            ],
        ]
        return Self.json(body)
    }

    /// Search is the one call that *must* carry a revision, so it can fail with
    /// `stale_content` against a busy pane; the caller retries with a fresh one.
    func searchRequest(query: String, forward: Bool, id: String) -> String? {
        let body: [String: Any] = [
            "id": id,
            "method": "pane.copy_search",
            "params": [
                "pane_id": paneID,
                "query": query,
                "direction": forward ? "forward" : "backward",
                "cursor": ["row": cursor.row, "col": cursor.column],
                "content_revision": contentRevision,
            ],
        ]
        return Self.json(body)
    }

    private static func json(_ body: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
