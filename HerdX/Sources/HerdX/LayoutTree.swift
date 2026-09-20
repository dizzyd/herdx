import Foundation

/// The pane tree herdr exports, as `layout.export` writes it.
///
/// Modelled rather than passed through as opaque JSON because a hibernated
/// workspace is stored as one of these and handed back to `layout.apply`
/// months later: the shape has to survive a round trip through a file, and a
/// dictionary that happens to re-encode today is not that guarantee.
///
/// The field names are herdr's, so the encoded form is the wire form and there
/// is no translation step to get wrong. `LayoutTreeTests` decodes a tree taken
/// from a live server and re-encodes it, which is what keeps that true.
indirect enum LayoutNode: Equatable {
    case pane(Pane)
    case split(Split)

    /// A leaf. Everything is optional because `layout.apply` accepts a tree
    /// with none of it — that is how a plain shell in the default directory is
    /// spelled.
    struct Pane: Equatable {
        var paneID: String?
        var label: String?
        var cwd: String?
        /// What the pane was launched as, when it was launched as something.
        ///
        /// Read on the way out, deliberately dropped on the way back in — see
        /// `withoutCommands`.
        var command: [String]?
        var env: [String: String]?
    }

    struct Split: Equatable {
        var direction: String
        var ratio: Double
        var first: LayoutNode
        var second: LayoutNode
    }

    /// The same tree with every `command` removed.
    ///
    /// A pane applied with a command becomes that command: herdr spawns the
    /// argv as the pane's own process, with no shell under it. Measured
    /// consequence — the pane then reports its foreground process group as its
    /// own shell pid, so a pane busy running something is indistinguishable
    /// from an idle one, and the idle test that decides what may be hibernated
    /// silently starts lying.
    ///
    /// So a revived pane is always a shell, and whatever should run in it is
    /// submitted afterwards. That is also what herdr does to itself when it
    /// resumes an agent on restore.
    var withoutCommands: LayoutNode {
        switch self {
        case .pane(var pane):
            pane.command = nil
            return .pane(pane)
        case .split(let split):
            return .split(
                Split(
                    direction: split.direction, ratio: split.ratio,
                    first: split.first.withoutCommands,
                    second: split.second.withoutCommands))
        }
    }

    /// Every leaf, with the path that addresses it.
    ///
    /// Paths rather than pane ids because ids do not survive a revive — the
    /// workspace comes back as a new one, with new panes in the same places.
    /// Position is the only address that means the same thing on both sides.
    /// `false` is `first`, `true` is `second`, which is how herdr's own
    /// `layout.set_split_ratio` addresses a node.
    var leaves: [(path: [Bool], pane: Pane)] {
        switch self {
        case .pane(let pane): return [(path: [], pane: pane)]
        case .split(let split):
            return split.first.leaves.map { (path: [false] + $0.path, pane: $0.pane) }
                + split.second.leaves.map { (path: [true] + $0.path, pane: $0.pane) }
        }
    }

    /// The leaf at a path, or nil when the tree does not have that shape.
    func leaf(at path: [Bool]) -> Pane? {
        switch (self, path.first) {
        case (.pane(let pane), nil): return pane
        case (.split(let split), .some(let step)):
            return (step ? split.second : split.first).leaf(at: Array(path.dropFirst()))
        default: return nil
        }
    }
}

extension LayoutNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case paneID = "pane_id"
        case label, cwd, command, env
        case direction, ratio, first, second
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "pane":
            self = .pane(
                Pane(
                    paneID: try container.decodeIfPresent(String.self, forKey: .paneID),
                    label: try container.decodeIfPresent(String.self, forKey: .label),
                    cwd: try container.decodeIfPresent(String.self, forKey: .cwd),
                    command: try container.decodeIfPresent([String].self, forKey: .command),
                    env: try container.decodeIfPresent([String: String].self, forKey: .env)))
        case "split":
            self = .split(
                Split(
                    direction: try container.decode(String.self, forKey: .direction),
                    ratio: try container.decode(Double.self, forKey: .ratio),
                    first: try container.decode(LayoutNode.self, forKey: .first),
                    second: try container.decode(LayoutNode.self, forKey: .second)))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "unknown layout node type \"\(other)\"")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let pane):
            try container.encode("pane", forKey: .type)
            // Absent rather than null: herdr's params skip empty fields, and a
            // null where it expects a missing key is a different document.
            try container.encodeIfPresent(pane.paneID, forKey: .paneID)
            try container.encodeIfPresent(pane.label, forKey: .label)
            try container.encodeIfPresent(pane.cwd, forKey: .cwd)
            try container.encodeIfPresent(pane.command, forKey: .command)
            if let env = pane.env, !env.isEmpty { try container.encode(env, forKey: .env) }
        case .split(let split):
            try container.encode("split", forKey: .type)
            try container.encode(split.direction, forKey: .direction)
            try container.encode(split.ratio, forKey: .ratio)
            try container.encode(split.first, forKey: .first)
            try container.encode(split.second, forKey: .second)
        }
    }
}
