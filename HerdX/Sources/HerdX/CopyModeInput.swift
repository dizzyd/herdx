import AppKit

extension TerminalGridView {
    /// Enters copy mode on the focused pane, placing the cursor at its top.
    func enterCopyMode(searching: Bool = false) {
        guard let pane = panes.first(where: { $0.id == focusedPane }) ?? panes.first else {
            return
        }
        copyModeGeneration += 1
        // Nothing to reset: what a session is waiting on is part of the
        // session, so a new one starts with an empty queue by construction.
        var mode = CopyMode(
            generation: copyModeGeneration,
            paneID: pane.id,
            contentRevision: pane.contentRevision,
            cursor: Selection.Point(row: pane.viewportTopRow, column: 0))
        if searching { mode.field = .search(forward: true, query: "") }
        copyMode = mode
        selection = nil
        needsDisplay = true
        onCopyModeChanged?(mode.statusText)
    }

    func exitCopyMode() {
        // The queue goes with it, which is the point of it living in there.
        copyMode = nil
        selection = nil
        needsDisplay = true
        onCopyModeChanged?(nil)
    }

    /// Handles a key while copy mode is active. Returns false to pass it on.
    func handleCopyModeKey(_ event: NSEvent) -> Bool {
        guard var mode = copyMode else { return false }
        let characters = event.charactersIgnoringModifiers ?? ""
        let shift = event.modifierFlags.contains(.shift)
        let control = event.modifierFlags.contains(.control)

        // Everything waits for a request the cursor depends on, not just the
        // next motion: a local key run while one was out moved from the stale
        // cursor and was then overwritten by the reply.
        //
        // Except the two that end copy mode. Those do not depend on the cursor,
        // and they are the way out — queueing them behind a reply that never
        // arrives would make a lost motion something you cannot escape.
        if mode.pending.requestOutstanding, !Self.leavesCopyMode(event) {
            mode.pending.keys.append(event)
            copyMode = mode
            return true
        }

        // A search query swallows ordinary typing until it is run or abandoned.
        if case .search(let forward, var query) = mode.field {
            switch Int(event.keyCode) {
            case 53:  // Esc
                mode.field = .none
            case 36:  // Return
                mode.field = .none
                mode.lastQuery = query
                copyMode = mode
                if !query.isEmpty { runSearch(query: query, forward: forward) }
                onCopyModeChanged?(mode.statusText)
                return true
            case 51:  // Backspace
                if query.isEmpty {
                    mode.field = .none
                } else {
                    query.removeLast()
                    mode.field = .search(forward: forward, query: query)
                }
            default:
                guard !characters.isEmpty, !control else { break }
                query += characters
                mode.field = .search(forward: forward, query: query)
            }
            copyMode = mode
            onCopyModeChanged?(mode.statusText)
            needsDisplay = true
            return true
        }

        guard let pane = panes.first(where: { $0.id == mode.paneID }) else {
            exitCopyMode()
            return true
        }
        let lastRow = pane.viewportTopRow + UInt64(max(pane.inner.height - 1, 0))
        let lastColumn = max(pane.inner.width - 1, 0)
        let page = UInt64(max(pane.inner.height - 1, 1))

        func move(rows: Int64, columns: Int64) {
            let row = Int64(mode.cursor.row) + rows
            mode.cursor.row = UInt64(max(row, 0))
            // Staying inside the viewport keeps the cursor visible; scrolling
            // copy mode through history is a separate concern.
            mode.cursor.row = min(max(mode.cursor.row, pane.viewportTopRow), lastRow)
            mode.cursor.column = Int(
                max(0, min(Int64(mode.cursor.column) + columns, Int64(lastColumn))))
        }

        switch Int(event.keyCode) {
        case 53:  // Esc
            // Esc clears a selection first, then leaves — the same two-step
            // herdr's own copy mode uses, so it is hard to lose work by mashing it.
            if mode.anchor != nil {
                mode.anchor = nil
                copyMode = mode
                selection = nil
                needsDisplay = true
                onCopyModeChanged?(mode.statusText)
            } else {
                exitCopyMode()
            }
            return true
        case 123: move(rows: 0, columns: -1)
        case 124: move(rows: 0, columns: 1)
        case 125: move(rows: 1, columns: 0)
        case 126: move(rows: -1, columns: 0)
        case 116: move(rows: -Int64(page), columns: 0)  // Page Up
        case 121: move(rows: Int64(page), columns: 0)  // Page Down
        case 36:  // Return copies
            copySelectionAndExit(mode)
            return true
        default:
            if control {
                switch characters {
                case "b": move(rows: -Int64(page), columns: 0)
                case "f": move(rows: Int64(page), columns: 0)
                case "u": move(rows: -Int64(page / 2), columns: 0)
                case "d": move(rows: Int64(page / 2), columns: 0)
                default: return true
                }
                break
            }
            switch characters.lowercased() {
            case "q":
                exitCopyMode()
                return true
            case "h": move(rows: 0, columns: -1)
            case "j": move(rows: 1, columns: 0)
            case "k": move(rows: -1, columns: 0)
            case "l": move(rows: 0, columns: 1)
            case "g":
                mode.cursor = Selection.Point(
                    row: shift ? lastRow : pane.viewportTopRow, column: 0)
            case "v", " ":
                mode.anchor = mode.anchor == nil ? mode.cursor : nil
            case "y":
                copySelectionAndExit(mode)
                return true
            case "/":
                mode.field = .search(forward: true, query: "")
            case "?":
                mode.field = .search(forward: false, query: "")
            case "n":
                if let query = mode.lastQuery {
                    copyMode = mode
                    runSearch(query: query, forward: !shift)
                    return true
                }
            default:
                if let motion = CopyMode.Motion.forKey(characters.lowercased(), shift: shift) {
                    copyMode = mode
                    runMotion(motion)
                    return true
                }
                return true
            }
        }

        copyMode = mode
        selection = mode.selection
        needsDisplay = true
        onCopyModeChanged?(mode.statusText)
        return true
    }

    private func copySelectionAndExit(_ mode: CopyMode) {
        // With no visual selection, copy the single line the cursor is on,
        // which is what `y` does when nothing is marked.
        let selection =
            mode.selection
            ?? Selection(
                paneID: mode.paneID,
                anchor: Selection.Point(row: mode.cursor.row, column: 0),
                cursor: Selection.Point(
                    row: mode.cursor.row,
                    column: panes.first(where: { $0.id == mode.paneID })
                        .map { max($0.inner.width - 1, 0) } ?? mode.cursor.column))

        if let request = selection.readRequest(id: "copy-\(UUID().uuidString)") {
            onReadSelection?(request)
        }
        exitCopyMode()
    }

    /// The copy mode on screen, if it is still the one `issued` came from.
    ///
    /// Every reply goes through this. A reply that arrives after copy mode was
    /// left and entered again belongs to nothing on screen, and applying it
    /// moves the new session's cursor to a result found in the old one's pane.
    /// Esc and q, which leave copy mode (Esc clears a selection first).
    ///
    /// Never queued, so a request that is never answered cannot trap anyone in
    /// copy mode.
    private static func leavesCopyMode(_ event: NSEvent) -> Bool {
        if Int(event.keyCode) == 53 { return true }
        let characters = (event.charactersIgnoringModifiers ?? "").lowercased()
        return characters == "q" && !event.modifierFlags.contains(.control)
    }

    /// Replays what was typed while the server was being waited on.
    ///
    /// One at a time and in order: the first replayed key may itself issue a
    /// request, and the rest have to wait behind that one exactly as they
    /// waited behind the first.
    private func drainCopyModeKeys() {
        while let mode = copyMode, !mode.pending.requestOutstanding,
            !mode.pending.keys.isEmpty
        {
            var next = mode
            let key = next.pending.keys.removeFirst()
            copyMode = next
            _ = handleCopyModeKey(key)
        }
    }

    private func session(matching issued: CopyMode) -> CopyMode? {
        guard let mode = copyMode, mode.isSameSession(as: issued) else { return nil }
        return mode
    }

    /// Asks the server to move the cursor, and holds everything behind it.
    ///
    /// A motion is relative to where the cursor is, and where it is comes back
    /// from the server. Anything run before that answer arrives moves from
    /// where the cursor *was*: `ww` on "one two three" sent two next-word
    /// requests from column 0 and both landed on "two", so the second
    /// keystroke was spent for nothing. There is only ever one of these out,
    /// because `handleCopyModeKey` queues the keystrokes rather than the
    /// motions.
    private func runMotion(_ motion: CopyMode.Motion) {
        guard var issued = copyMode else { return }
        let id = "motion-\(UUID().uuidString)"
        guard let request = issued.motionRequest(motion, id: id) else { return }
        issued.pending.requestOutstanding = true
        copyMode = issued
        onCopyModeRequest?(request, id) { [weak self] body in
            guard let self else { return }
            // Whose reply this is, before anything of the current session is
            // touched. Released first, a reply from a session that had already
            // ended let this one's next keystroke run while its own request
            // was still out — both moving from the same place.
            guard var mode = self.session(matching: issued) else { return }
            mode.pending.requestOutstanding = false
            // A reply this session cannot read still releases this session's
            // queue; what it must not do is release somebody else's.
            guard let point = Self.cursor(fromReply: body) else {
                self.copyMode = mode
                self.drainCopyModeKeys()
                return
            }
            mode.cursor = point
            self.copyMode = mode
            self.selection = mode.selection
            self.needsDisplay = true
            self.drainCopyModeKeys()
        }
    }

    /// Runs a search, retrying once against a fresher revision.
    ///
    /// Search is the only copy-mode call that must carry a content revision,
    /// and the server rejects one that is stale *or* odd — odd meaning the pane
    /// is mid-update. A single retry with the latest surface revision covers
    /// the ordinary case of output landing between frames.
    private func runSearch(query: String, forward: Bool, retrying: Bool = false) {
        guard var mode = copyMode else { return }
        if retrying, let pane = panes.first(where: { $0.id == mode.paneID }) {
            mode.contentRevision = pane.contentRevision
            copyMode = mode
        }
        mode.pending.requestOutstanding = true
        copyMode = mode
        let issued = mode
        let id = "search-\(UUID().uuidString)"
        guard let request = mode.searchRequest(query: query, forward: forward, id: id) else {
            // Nothing is out after all, so nothing should be waiting on it.
            mode.pending.requestOutstanding = false
            copyMode = mode
            drainCopyModeKeys()
            return
        }
        onCopyModeRequest?(request, id) { [weak self] body in
            // Checked before the retry as well as before the result: retrying
            // a search for a copy mode nobody is in asks the server a question
            // whose answer has nowhere to go.
            guard let self, var mode = self.session(matching: issued) else { return }
            // The retry is still this session waiting on the server, so the
            // queue stays held rather than draining between the two attempts.
            if !retrying, Self.isStale(body) {
                self.runSearch(query: query, forward: forward, retrying: true)
                return
            }
            mode.pending.requestOutstanding = false
            guard let match = Self.selectedMatch(fromReply: body) else {
                self.copyMode = mode
                self.drainCopyModeKeys()
                return
            }
            mode.cursor = match.start
            mode.anchor = match.end
            mode.lastQuery = query
            self.copyMode = mode
            self.selection = mode.selection
            self.needsDisplay = true
            self.onCopyModeChanged?(mode.statusText)
            self.drainCopyModeKeys()
        }
    }

    /// Whether a reply is the server refusing a stale content revision.
    private static func isStale(_ body: String) -> Bool {
        struct Reply: Decodable {
            struct Failure: Decodable { let code: String }
            let error: Failure?
        }
        guard let data = body.data(using: .utf8),
            let reply = try? JSONDecoder().decode(Reply.self, from: data)
        else { return false }
        return reply.error?.code == "stale_content"
    }

    private static func cursor(fromReply body: String) -> Selection.Point? {
        struct Reply: Decodable {
            struct Result: Decodable {
                struct Point: Decodable {
                    let row: UInt64
                    let col: Int
                }
                let cursor: Point?
            }
            let result: Result?
        }
        guard let data = body.data(using: .utf8),
            let reply = try? JSONDecoder().decode(Reply.self, from: data),
            let cursor = reply.result?.cursor
        else { return nil }
        return Selection.Point(row: cursor.row, column: cursor.col)
    }

    /// The match the server went to, not the first one it found.
    ///
    /// `matches` is every hit in document order and `current` indexes the one
    /// the search actually selected — searching forward from the top of
    /// "alpha beta alpha" answers with two matches and `current: 1`. Taking
    /// the first instead sent the cursor to column 0, which is where the
    /// search started, so pressing n again asked the same question and got the
    /// same answer: the cursor never moved off the first hit.
    static func selectedMatch(fromReply body: String)
        -> (start: Selection.Point, end: Selection.Point)?
    {
        struct Reply: Decodable {
            struct Result: Decodable {
                struct Point: Decodable {
                    let row: UInt64
                    let col: Int
                }
                struct Range: Decodable {
                    let start: Point
                    let end: Point
                }
                let matches: [Range]?
                let current: Int?
            }
            let result: Result?
        }
        guard let data = body.data(using: .utf8),
            let reply = try? JSONDecoder().decode(Reply.self, from: data),
            let matches = reply.result?.matches, !matches.isEmpty
        else { return nil }
        // Bounds-checked rather than trusted: an index that does not name one
        // of these matches is worse than the first, which is at least real.
        let chosen = reply.result?.current.flatMap { matches.indices.contains($0) ? $0 : nil } ?? 0
        let match = matches[chosen]
        return (
            Selection.Point(row: match.start.row, column: match.start.col),
            Selection.Point(row: match.end.row, column: match.end.col)
        )
    }
}
