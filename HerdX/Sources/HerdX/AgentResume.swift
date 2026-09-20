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

    /// The whole line to submit to a pane's shell, or nil when the agent has
    /// no resume form here.
    ///
    /// `clear &&` is not decoration. The shell echoes what it is given, so
    /// without it the pane keeps a line reading `claude --resume 6d4c51cd-…`
    /// above the agent for as long as the agent runs — Claude and most of
    /// these render inline rather than on the alternate screen, so nothing
    /// ever paints over it. Only the shell can remove it, between echoing the
    /// line and starting the agent, which is what the clear does.
    ///
    /// Built here rather than through `agent.start` for that reason alone:
    /// herdr submits exactly the argv it is given, with nothing before it.
    static func commandLine(agent: String, kind: String, value: String) -> String? {
        guard let arguments = arguments(agent: agent, kind: kind, value: value) else {
            return nil
        }
        let argv = [executable(for: agent)] + arguments
        return "clear && " + argv.map(quoted).joined(separator: " ")
    }

    /// What the agent is called on disk.
    ///
    /// herdr's `interactive_agent_executable`. Every one of these is its own
    /// label except cursor, whose binary is `cursor-agent`.
    static func executable(for agent: String) -> String {
        agent == "cursor" ? "cursor-agent" : agent
    }

    /// POSIX single-quoting, as herdr's `interactive_shell_command` does it.
    ///
    /// Everything is quoted rather than only what needs it: a session ref can
    /// be a path, and a path can contain anything.
    private static func quoted(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The agents herdr will resume from a path as well as from an id.
    static let acceptsPath: Set<String> = ["pi", "omp"]

    /// Every agent with a resume form, for the drift test and for deciding
    /// whether a workspace can be brought back at all.
    static let supported: Set<String> = [
        "claude", "codex", "copilot", "devin", "droid", "kimi", "mastracode", "pi", "omp",
        "hermes", "opencode", "qodercli", "qwen", "kilo", "cursor", "agy", "grok", "letta",
    ]

}
