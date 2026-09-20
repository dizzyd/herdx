import Foundation

/// A workspace whose processes have been ended and whose conversation has not.
///
/// The conversation was never herdr's to lose: Claude, Codex and the rest keep
/// their own session stores, and closing a workspace does not touch them. All
/// that dies with the workspace is herdr's pointer to it, so that pointer — and
/// enough of the shape to put it back — is what gets written down here.
struct Hibernated: Codable, Equatable, Identifiable {
    var id: UUID
    /// Which machine it belongs to, by herdr's endpoint id.
    ///
    /// Not the index. An index is positional and means a different machine as
    /// soon as the catalog changes, and this record outlives several of those.
    var endpointID: String
    /// Where it sat among the live workspaces, so the row goes back in place
    /// rather than to the bottom of the list.
    var number: Int
    var label: String
    var cwd: String
    var branch: String?
    /// When it was hibernated, which is what the row counts from.
    var at: Date
    var tabs: [Tab]

    struct Tab: Codable, Equatable {
        var label: String?
        /// Reapplied with `pane.zoom` afterwards: `layout.apply` reports zoom
        /// on the way out but takes no parameter for it on the way in.
        var zoomed: Bool
        var root: LayoutNode
        /// The leaf that had focus, by path.
        var focused: [Bool]?
        var agents: [Agent]
    }

    /// An agent that was in a pane, and how to put it back there.
    struct Agent: Codable, Equatable {
        /// Which leaf it occupied. Pane ids do not survive a revive; position
        /// does. See `LayoutNode.leaves`.
        var path: [Bool]
        /// herdr's `agent_session`, kept whole rather than reduced to an id:
        /// what the value means depends on `source` and `kind`, and a bare
        /// string would make that somebody else's problem later.
        var source: String
        var agent: String
        var kind: String
        var value: String
    }

    /// Every agent in the workspace, whichever tab it sat in.
    var agents: [Agent] { tabs.flatMap(\.agents) }
}

/// Where hibernated workspaces are remembered between launches.
///
/// A file rather than `UserDefaults`. Two reasons, and the second is the one
/// that decided it: `Preferences` is deliberately a handful of scalars and this
/// is a growing list of structured records; and every dev probe in this app
/// writes the real `dev.herdr.herdx`, where `defaults import` merges rather
/// than replaces. A pointer to a live conversation should not live somewhere a
/// probe can add to and a restore cannot fully undo.
struct HibernationStore {
    let url: URL

    static let shared = HibernationStore(url: defaultURL)

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("HerdX/hibernated.json")
    }

    /// What has been hibernated, or nothing when the file is missing.
    ///
    /// A file that will not decode is moved aside rather than overwritten. It
    /// holds the only reference to conversations that are otherwise
    /// unreachable, and silently starting fresh would throw that away at the
    /// one moment somebody might still want it back by hand.
    func load() -> [Hibernated] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([Hibernated].self, from: data)
        } catch {
            let aside = url.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            FileHandle.standardError.write(
                Data("herdx: could not read \(url.path): \(error); kept at \(aside.path)\n".utf8))
            return []
        }
    }

    func save(_ records: [Hibernated]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomic: a half-written file here is a workspace nobody can get back.
        try encoder.encode(records).write(to: url, options: .atomic)
    }
}
