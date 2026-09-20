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

        /// Whether nothing is running in this pane but its own shell.
        ///
        /// The foreground process group is the shell's own only while no job
        /// has been started under it. Measured rather than assumed, and it is
        /// the reason a revived pane is always a shell: a pane launched with an
        /// argv *is* that process, so its group id equals its "shell" pid and
        /// this reads true while it is busy. Such panes are refused earlier, by
        /// the command they carry in the exported layout.
        var isIdleShell: Bool {
            guard let shellPid, let group = foregroundProcessGroupID else { return false }
            return shellPid == group
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
