import AppKit

/// Whether herdr itself is on this Mac.
///
/// HerdX is a client: it renders what a herdr server composes and has nothing
/// to show without one. Someone who installs the app first — which is the
/// ordinary way round for a Mac app — gets an empty window and "Local is
/// offline", which names the symptom and not the cause.
enum LocalHerdr {
    enum State {
        /// herdr is installed and its server answered.
        case running
        /// herdr is here but no server is listening.
        case installed(at: String)
        /// No herdr on this machine at all.
        case missing
    }

    /// Where herdr would be.
    ///
    /// Known locations rather than a PATH search alone: an app launched from
    /// the Finder inherits a minimal PATH that does not include `~/.local/bin`,
    /// which is where herdr's own installer puts it, so a PATH miss says
    /// nothing about whether herdr is installed.
    static func binaryPath() -> String? {
        let manager = FileManager.default
        var candidates: [String] = []

        if let named = ProcessInfo.processInfo.environment["HERDR_BIN_PATH"] {
            candidates.append(named)
        }
        candidates.append(
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/herdr"))
        candidates += ["/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"]

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map {
                ($0 as NSString).appendingPathComponent("herdr")
            }
        }
        return candidates.first { manager.isExecutableFile(atPath: $0) }
    }

    /// What to tell someone, given whether the local server answered.
    static func state(serverIsUp: Bool) -> State {
        if serverIsUp { return .running }
        guard let path = binaryPath() else { return .missing }
        return .installed(at: path)
    }

    /// The install line herdr's own README gives.
    static let installCommand = "curl -fsSL https://herdr.dev/install.sh | sh"

    static let homePage = URL(string: "https://herdr.dev")!
}

extension LocalHerdr {
    /// Offers the install line in a form it can be taken away from.
    ///
    /// The line was only ever painted into the terminal as placeholder text —
    /// glyphs in a custom view, with nothing to select and no pasteboard
    /// anywhere near them. So the first thing a new user saw was a curl
    /// pipeline they had to retype by hand from a window that had no other way
    /// to give it to them. This is the one moment the app has nothing else to
    /// offer, and handing over a command it is asking you to run is the least
    /// it can do.
    ///
    /// A selectable field as well as the Copy button: a dialog that copies on a
    /// click is fine until someone wants to read the thing before piping it
    /// into a shell, which is a reasonable way to feel about `curl … | sh`.
    @MainActor
    static func offerInstall(over parent: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "HerdX needs herdr"
        alert.informativeText =
            "HerdX draws the terminals; herdr runs them. Install herdr and this window "
            + "will start a session on its own — there is nothing else to set up."

        let field = NSTextField(string: installCommand)
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.isEditable = false
        // Selectable, and sized here: an accessory view gets no layout pass, so
        // one without a frame is a dialog with a gap where the command should be.
        field.isSelectable = true
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = field

        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Open herdr.dev")
        alert.addButton(withTitle: "Close")

        let answer: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(installCommand, forType: .string)
            case .alertSecondButtonReturn:
                NSWorkspace.shared.open(homePage)
            default:
                break
            }
        }

        // A sheet where there is a window to hang it on: the explanation behind
        // it is half of the answer, and a detached dialog covers it.
        if let parent {
            alert.beginSheetModal(for: parent, completionHandler: answer)
        } else {
            answer(alert.runModal())
        }
    }
}
