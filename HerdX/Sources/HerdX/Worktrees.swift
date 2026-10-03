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
    static func pathSlug(_ branch: String) -> String {
        var slug = ""
        var lastWasDash = false
        for character in branch {
            if character.isASCII, character.isLetter || character.isNumber {
                slug.append(Character(character.lowercased()))
                lastWasDash = false
            } else if !lastWasDash {
                slug.append("-")
                lastWasDash = true
            }
        }
        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? prefix : trimmed
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
