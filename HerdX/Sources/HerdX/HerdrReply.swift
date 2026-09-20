import Foundation

/// The replies hibernation reads.
///
/// A subset of each, decoded the way `Snapshot` decodes its own: generation 1
/// guarantees unknown fields are safe to ignore, so naming only what is used
/// stays forward-compatible with newer servers.
///
/// Replies are read at all because a rejected request does nothing and says
/// nothing. Hibernation ends processes, so every step of it has to know
/// whether the last one actually happened.
enum Reply {
    /// `{"id": …, "result": {…}}` or `{"id": …, "error": {…}}`.
    struct Envelope<Result: Decodable>: Decodable {
        let result: Result?
        let error: Failure?
    }

    struct Failure: Decodable, Equatable, Error {
        let code: String?
        let message: String?

        var text: String { message ?? code ?? "rejected" }
    }

    /// For a reply whose body says only that it worked, such as a close.
    struct Empty: Decodable {}

    struct PaneList: Decodable {
        let panes: [PaneEntry]
    }

    /// A pane as `pane.list` reports it.
    ///
    /// Read from the pane list rather than from `agent.list` because the
    /// session ref lives on the pane: one request then answers both questions
    /// hibernation asks — what is in this workspace, and which of it can be
    /// resumed.
    struct PaneEntry: Decodable, Equatable {
        let paneID: String
        let workspaceID: String
        let tabID: String
        let agentStatus: Snapshot.AgentStatus
        /// Absent when herdr never learned which conversation this pane holds —
        /// which makes the agent unresumable, and the workspace unhibernatable.
        let agentSession: Session?

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case workspaceID = "workspace_id"
            case tabID = "tab_id"
            case agentStatus = "agent_status"
            case agentSession = "agent_session"
        }

        /// Whether there is an agent here at all.
        ///
        /// Either reading counts. A pane herdr has detected an agent in but
        /// never got a session for is still an agent pane — and saying so is
        /// what gets it the refusal that names the real problem, rather than
        /// the vaguer one about a process running in a shell.
        var holdsAgent: Bool { agentSession != nil || agentStatus != .unknown }

        var agentName: String { agentSession?.agent ?? "an agent" }
    }

    /// herdr's pointer into the agent's own conversation store.
    struct Session: Decodable, Equatable {
        let source: String
        let agent: String
        /// `id` or `path`; what `value` means depends on it.
        let kind: String
        let value: String
    }

    struct ProcessInfo: Decodable {
        let processInfo: Info

        enum CodingKeys: String, CodingKey {
            case processInfo = "process_info"
        }
    }

    struct Info: Decodable, Equatable {
        let paneID: String
        let shellPid: UInt32?
        let foregroundProcessGroupID: UInt32?
        let foregroundProcesses: [Process]

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case shellPid = "shell_pid"
            case foregroundProcessGroupID = "foreground_process_group_id"
            case foregroundProcesses = "foreground_processes"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            paneID = try container.decode(String.self, forKey: .paneID)
            shellPid = try container.decodeIfPresent(UInt32.self, forKey: .shellPid)
            foregroundProcessGroupID = try container.decodeIfPresent(
                UInt32.self, forKey: .foregroundProcessGroupID)
            // Omitted entirely when empty, which is not the same as absent data.
            foregroundProcesses =
                try container.decodeIfPresent([Process].self, forKey: .foregroundProcesses) ?? []
        }

        /// Whether this pane is a shell sitting at a prompt.
        ///
        /// Deliberately the same three conditions `available_pane_shell_from_job`
        /// applies before `agent.start` will use a pane, because anything looser
        /// is a revive that dies with "is not an available shell":
        /// the foreground group is the pane's own process, it is the *only*
        /// process in that group, and it is a shell by name.
        ///
        /// The middle one is not pedantry. A zsh running its startup files
        /// spawns conda's python *in its own process group*, so the group id
        /// still equals the shell's while two or three processes are in it —
        /// measured, after a revive failed on exactly that.
        ///
        /// It is also why a revived pane is always a plain shell: a pane
        /// launched with an argv *is* that process, so its group id equals its
        /// "shell" pid and a group-only test reads true while it is busy.
        var isIdleShell: Bool {
            guard let shellPid, foregroundProcessGroupID == shellPid else { return false }
            guard foregroundProcesses.count == 1, let only = foregroundProcesses.first,
                only.pid == shellPid
            else { return false }
            return Self.isShellName(only.name)
        }

        /// herdr's list, normalised its way: basename, no leading dash from a
        /// login shell, no .exe, lowercased.
        static func isShellName(_ name: String) -> Bool {
            let base = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
                ?? name
            let normalised = base.drop(while: { $0 == "-" })
                .replacingOccurrences(of: ".exe", with: "").lowercased()
            return [
                "sh", "bash", "dash", "zsh", "fish", "ksh", "mksh", "csh", "tcsh", "elvish",
                "xonsh", "nu", "pwsh", "powershell",
            ].contains(normalised)
        }

        /// What is running, for saying why a workspace was left alone.
        var runningDescription: String {
            foregroundProcesses.map(\.name).joined(separator: " | ")
        }
    }

    struct Process: Decodable, Equatable {
        let pid: UInt32
        let name: String
        let argv: [String]?
    }

    struct LayoutExport: Decodable {
        let layout: Layout
    }

    /// `layout.apply` replies with what it made — the same tree shape, carrying
    /// the new pane ids, which is how a stored agent finds its pane again.
    struct LayoutApplied: Decodable {
        let layout: Layout
    }

    struct WorkspaceCreated: Decodable {
        let workspace: Workspace
        let tab: Tab
        let rootPane: Pane

        enum CodingKeys: String, CodingKey {
            case workspace, tab
            case rootPane = "root_pane"
        }

        struct Workspace: Decodable {
            let workspaceID: String
            enum CodingKeys: String, CodingKey { case workspaceID = "workspace_id" }
        }
        struct Tab: Decodable {
            let tabID: String
            enum CodingKeys: String, CodingKey { case tabID = "tab_id" }
        }
        struct Pane: Decodable {
            let paneID: String
            enum CodingKeys: String, CodingKey { case paneID = "pane_id" }
        }
    }

    /// herdr echoes the argv it ran, which is worth reading: it is the proof
    /// the agent was started with the arguments meant for it.
    struct AgentStarted: Decodable {
        let argv: [String]
    }

    struct Layout: Decodable, Equatable {
        let tabID: String
        let zoomed: Bool
        let focusedPaneID: String
        let root: LayoutNode

        enum CodingKeys: String, CodingKey {
            case tabID = "tab_id"
            case zoomed
            case focusedPaneID = "focused_pane_id"
            case root
        }
    }

    /// Decodes a reply body, turning a rejection into an error rather than a
    /// silently empty result.
    static func decode<Result: Decodable>(_ type: Result.Type, from body: String) -> Swift.Result<
        Result, Failure
    > {
        guard let data = body.data(using: .utf8) else {
            return .failure(Failure(code: "unreadable", message: "reply was not text"))
        }
        do {
            let envelope = try JSONDecoder().decode(Envelope<Result>.self, from: data)
            if let error = envelope.error { return .failure(error) }
            guard let result = envelope.result else {
                return .failure(Failure(code: "empty", message: "reply carried no result"))
            }
            return .success(result)
        } catch {
            return .failure(Failure(code: "undecodable", message: "\(error)"))
        }
    }
}
