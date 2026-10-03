import Foundation

/// The naming rules herdr applies to a linked worktree checkout.
///
/// Ported rather than asked for, because the create sheet has to show where a
/// branch will land *before* anything is created and there is no method that
/// will say. The ports are exact — `herdr-core`'s `worktree.rs` is the
/// original, and `WorktreeNamingTests` carries its own test vectors over so a
/// change upstream fails here rather than quietly drawing a path herdr would
/// not use.
enum Worktrees {
    /// The branch namespace herdr puts generated branches in, and its fallback
    /// folder name.
    static let prefix = "worktree"

    /// A branch name as a folder name: lowercase, alphanumerics kept, every
    /// other run collapsed to one dash, no leading or trailing dash.
    ///
    /// By scalar, not by `Character`. Swift's `Character` is a grapheme
    /// cluster, so `"cafe" + U+0301` iterates as four of them and the accent
    /// takes the `e` with it — slugging to `caf` where herdr, which iterates
    /// scalars, writes `cafe`. A preview that disagrees with the directory
    /// that then appears is worse than no preview.
    static func pathSlug(_ branch: String) -> String {
        var slug = ""
        var lastWasDash = false
        for scalar in branch.unicodeScalars {
            if let kept = asciiAlphanumericLowercased(scalar) {
                slug.unicodeScalars.append(kept)
                lastWasDash = false
            } else if !lastWasDash {
                slug.append("-")
                lastWasDash = true
            }
        }
        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? prefix : trimmed
    }

    /// Rust's `is_ascii_alphanumeric` and `to_ascii_lowercase` in one, spelled
    /// out against code points rather than borrowed from Swift's Unicode-aware
    /// predicates — those answer a different and larger question.
    private static func asciiAlphanumericLowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar? {
        switch scalar.value {
        case 0x30...0x39, 0x61...0x7A: return scalar
        case 0x41...0x5A: return Unicode.Scalar(scalar.value + 0x20)
        default: return nil
        }
    }

    /// The branch name the sheet opens on, so the common case is one keystroke.
    ///
    /// Same word lists and the same arithmetic as herdr's, so a HerdX-made
    /// worktree is indistinguishable from one made in the TUI.
    static func generatedBranch(seed: UInt64) -> String {
        let adjectives = ["brave", "calm", "clear", "green", "lucky", "quiet", "rapid", "silver"]
        let nouns = ["river", "cloud", "field", "forest", "harbor", "meadow", "stone", "valley"]
        let adjective = adjectives[Int(seed % UInt64(adjectives.count))]
        let noun = nouns[Int((seed / UInt64(adjectives.count)) % UInt64(nouns.count))]
        let suffix = String(format: "%04x", seed & 0xffff)
        return "\(prefix)/\(adjective)-\(noun)-\(suffix)"
    }

    /// A seed from the clock, which is what herdr's own dialog uses.
    static func branchSuggestion(now: Date = Date()) -> String {
        generatedBranch(seed: UInt64(now.timeIntervalSince1970 * 1_000_000))
    }

    /// Where a branch will be checked out, for the sheet to show as you type.
    ///
    /// This is a path on the *endpoint*, which may be a machine with different
    /// separators from the one drawing the sheet — so the separator comes from
    /// the root herdr published rather than from this Mac.
    static func checkoutPath(root: String, repo: String, branch: String) -> String {
        let separator: Character = !root.hasPrefix("/") && root.contains("\\") ? "\\" : "/"
        var trimmed = Substring(root)
        while trimmed.last == separator { trimmed = trimmed.dropLast() }
        return "\(trimmed)\(separator)\(repo)\(separator)\(pathSlug(branch))"
    }

    /// Why an action cannot start from this workspace, or nil when it can.
    ///
    /// herdr's rule, and its wording: new and open work on the repo itself, so
    /// they are refused from inside a linked checkout, and remove only has
    /// meaning inside one. Saying which way round it is matters more than
    /// saying no — the fix is to move to a different workspace first, and
    /// nothing else on screen says that.
    static func refusal(for action: Keymap.Action, workspace: Snapshot.Workspace?) -> String? {
        guard let workspace else { return "no workspace is focused" }
        let linked = workspace.worktree?.isLinkedWorktree ?? false
        switch action {
        case .newWorktree, .openWorktree:
            return linked
                ? "New and open worktree actions start from the repo parent workspace."
                : nil
        case .removeWorktree:
            return linked ? nil : "This workspace is not a Herdr-managed worktree checkout."
        default:
            return nil
        }
    }

    /// The machine a worktree flow is working on, pinned for its whole life.
    ///
    /// A flow is several requests with a person's decisions between them, and
    /// the window can move to another machine in the gaps — a sheet or a
    /// picker can sit open for as long as you like. Workspace ids and paths
    /// are only unique within a server, so one carried forward and resolved
    /// against whatever is active *now* names somebody else's work.
    struct Target: Equatable {
        /// Which session object, by token rather than by reference: a flow
        /// that held its session would keep it alive through the reply
        /// callback it is waiting on, and a reply that never comes would keep
        /// it alive for good.
        let session: UUID
        let endpoint: Int
        let bootID: String
        /// For saying which machine, when a flow has to be abandoned.
        let label: String
    }

    /// Why a pinned flow may no longer act, or nil when it may.
    ///
    /// Abandoning is the answer rather than redirecting, and rather than
    /// switching the window back: the decision was made about one machine, and
    /// both acting on another and yanking the view to the first are worse than
    /// stopping and saying so. The case that matters is a force-removal — a
    /// question asked about machine A, answered after the window moved to B,
    /// and sent with A's workspace id to B.
    ///
    /// A new boot id counts as a different machine: the server restarted, and
    /// the ids the flow is holding describe a session that no longer exists.
    static func drift(
        from target: Target, session: UUID?, activeEndpoint: Int, bootID: String?
    ) -> String? {
        guard session == target.session else { return "the connection was rebuilt" }
        guard activeEndpoint == target.endpoint, bootID == target.bootID else {
            return "\(target.label) is no longer in front of you"
        }
        return nil
    }

    /// Whether a refused removal is asking to be forced rather than failing.
    ///
    /// herdr answers a dirty checkout with a code, and a checkout whose
    /// directory has already gone with a `worktree_remove_failed` whose message
    /// is git's. Both mean the same thing to the person: it will not go without
    /// being told twice.
    static func needsForce(_ failure: Reply.Failure) -> Bool {
        switch failure.code {
        case "dirty_worktree_requires_force": return true
        case "worktree_remove_failed":
            // git's wording, which herdr matches on for the same reason.
            return (failure.message ?? "").contains("is not a working tree")
        default: return false
        }
    }
}
