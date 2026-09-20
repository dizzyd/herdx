import Foundation

/// How each agent is told to pick up the conversation it was in.
///
/// herdr keeps this table itself, in `agent_resume::plan`, and uses it when it
/// resumes agents on restore. It is Rust-internal and nothing on the wire
/// exposes it: `agent.start` takes the arguments and prepends the executable,
/// so the flags have to be spelled here as well.
///
/// That is exactly the guessing `Keymap` exists to avoid, and there is no
/// server to read it from — so instead `AgentResumeTests` reads the vendored
/// source and fails when the two drift. If that test ever goes red, herdr is
/// right and this file is wrong.
enum AgentResume {
    /// The arguments for an agent, or nil when herdr could not resume it
    /// either.
    ///
    /// `kind` is herdr's `AgentSessionRefKind`: most agents are resumed by an
    /// id, and only `pi` and `omp` will take a path.
    static func arguments(agent: String, kind: String, value: String) -> [String]? {
        guard !value.isEmpty else { return nil }
        guard kind == "id" || acceptsPath.contains(agent) else { return nil }

        switch agent {
        case "claude", "devin", "droid", "hermes", "qodercli", "qwen", "cursor", "grok":
            return ["--resume", value]
        // A subcommand rather than a flag.
        case "codex":
            return ["resume", value]
        // Joined with an equals sign; these have no separated form.
        case "copilot", "omp":
            return ["--resume=\(value)"]
        case "kimi", "pi", "opencode", "kilo":
            return ["--session", value]
        case "mastracode":
            return ["--thread", value]
        case "agy":
            return ["--conversation", value]
        case "letta":
            // A conversation named `default` carries the agent id after it,
            // which is a shape none of the others have. Written as herdr writes
            // it — strip the prefix, and an empty remainder names nothing —
            // because splitting on the colon quietly kept "default" as the id.
            if value.hasPrefix("default:") {
                let agentID = String(value.dropFirst("default:".count))
                guard !agentID.isEmpty else { return nil }
                return ["--conversation", "default", "--agent", agentID]
            }
            return ["--conversation", value]
        default:
            // An agent this does not know is left alone rather than started
            // with arguments invented for it.
            return nil
        }
    }

    /// The agents herdr will resume from a path as well as from an id.
    static let acceptsPath: Set<String> = ["pi", "omp"]

    /// Every agent with a resume form, for the drift test and for deciding
    /// whether a workspace can be brought back at all.
    static let supported: Set<String> = [
        "claude", "codex", "copilot", "devin", "droid", "kimi", "mastracode", "pi", "omp",
        "hermes", "opencode", "qodercli", "qwen", "kilo", "cursor", "agy", "grok", "letta",
    ]

    /// A name for the agent herdr will accept.
    ///
    /// `agent.start` requires a name starting with a lowercase letter, at most
    /// 32 characters of lowercase, digits, dash or underscore — and one that no
    /// live agent is already using, or it refuses the whole request.
    ///
    /// Named after the workspace rather than after `agent-workspace`, because a
    /// revived agent has to look like the one that was hibernated. herdr leaves
    /// a detected agent unnamed, and a row with no name falls back to showing
    /// its workspace — so a workspace called `augur` came back reading
    /// `claude-augur`, which is a rename nobody asked for.
    ///
    /// Clearing the name afterwards would be truer still, and does not work: an
    /// agent counts as launch-pending until it settles, a resumed agent that
    /// wants you settles as *blocked*, and `agent.rename` refuses either way.
    static func name(for agent: String, in workspace: String, avoiding taken: Set<String>)
        -> String
    {
        let base = sanitised(workspace)
        guard taken.contains(base) else { return base }
        // Suffixed rather than randomised, so a second claude in the same
        // workspace reads as the second one.
        for suffix in 2...99 {
            let candidate = sanitised("\(base)-\(suffix)")
            if !taken.contains(candidate) { return candidate }
        }
        return sanitised("\(base)-\(UUID().uuidString.prefix(6))")
    }

    private static func sanitised(_ text: String) -> String {
        var cleaned = text.lowercased().map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character : "-"
        }
        // Must begin with a letter; a workspace called "2fa" would otherwise
        // produce a name herdr rejects outright.
        if cleaned.first?.isLetter != true { cleaned.insert("a", at: 0) }
        return String(cleaned.prefix(32))
    }
}
