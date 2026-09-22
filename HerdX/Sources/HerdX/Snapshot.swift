import Foundation

/// The parts of herdr's `ClientShellSnapshot` the chrome needs.
///
/// Generation 1 guarantees unknown fields are safe to ignore, so this decodes a
/// subset deliberately and stays forward-compatible with newer servers.
struct Snapshot: Decodable {
    let bootID: String
    let revision: UInt64
    /// The user's own keybindings, normalised by the server.
    let serverKeybindingsToml: String?
    let focusedWorkspaceID: String?
    let focusedTabID: String?
    let focusedPaneID: String?
    let workspaces: [Workspace]
    let tabs: [Tab]
    let panes: [Pane]
    let agents: [Agent]

    enum CodingKeys: String, CodingKey {
        case bootID = "boot_id"
        case revision
        case serverKeybindingsToml = "server_keybindings_toml"
        case focusedWorkspaceID = "focused_workspace_id"
        case focusedTabID = "focused_tab_id"
        case focusedPaneID = "focused_pane_id"
        case workspaces, tabs, panes, agents
    }

    /// herdr's agent lifecycle. `unknown` is the documented fallback for values
    /// a newer server may add.
    enum AgentStatus: String, Decodable {
        case working, blocked, idle, done, unknown

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = AgentStatus(rawValue: raw.lowercased()) ?? .unknown
        }
    }

    /// How many panes share the focused tab.
    ///
    /// What decides whether an arrow key belongs to the panes or to the
    /// sidebar. Counted rather than measured: the surface carries geometry and
    /// could answer "is there a pane above me" outright, but that answer has to
    /// agree with herdr's own idea of which pane is above, and a key that
    /// silently disagrees is worse than one that only claims the easy case.
    var panesInFocusedTab: Int {
        guard let focusedTabID else { return panes.count }
        return panes.filter { $0.tabID == focusedTabID }.count
    }

    struct Workspace: Decodable {
        let workspaceID: String
        let number: Int
        let label: String
        let branch: String?
        let focused: Bool
        let agentStatus: AgentStatus
        /// Which of its tabs is the one you would land in.
        ///
        /// A tab's own `focused` is about the session, not the workspace: only
        /// one tab anywhere carries it, so it cannot say which tab a workspace
        /// you are *not* in would open at.
        let activeTabID: String?

        enum CodingKeys: String, CodingKey {
            case workspaceID = "workspace_id"
            case number, label, branch, focused
            case agentStatus = "agent_status"
            case activeTabID = "active_tab_id"
        }
    }

    struct Tab: Decodable {
        let tabID: String
        let workspaceID: String
        let number: Int
        let label: String
        let zoomed: Bool
        let focused: Bool
        let agentStatus: AgentStatus

        enum CodingKeys: String, CodingKey {
            case tabID = "tab_id"
            case workspaceID = "workspace_id"
            case number, label, zoomed, focused
            case agentStatus = "agent_status"
        }
    }

    struct Pane: Decodable {
        let paneID: String
        let tabID: String
        let label: String?
        let cwd: String?
        let focused: Bool

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case tabID = "tab_id"
            case label, cwd, focused
        }
    }

    struct Agent: Decodable {
        let paneID: String
        let workspaceID: String
        let tabID: String
        let name: String?
        /// What kind of agent it is — "claude", "codex" — as herdr detected it.
        ///
        /// Not `display_agent`, which the server leaves out for an agent it
        /// merely detected, and which is therefore nil for nearly all of them.
        let agent: String?
        let displayAgent: String?
        let title: String?
        let agentStatus: AgentStatus
        /// Bumped whenever the agent's state changes.
        ///
        /// herdr orders a priority list by attention and breaks ties with
        /// this, newest first, so the thing that just started needing you is
        /// above the thing that has needed you for an hour.
        let stateChangeSeq: UInt64
        let focused: Bool

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case workspaceID = "workspace_id"
            case tabID = "tab_id"
            case name, agent
            case displayAgent = "display_agent"
            case title
            case agentStatus = "agent_status"
            case stateChangeSeq = "state_change_seq"
            case focused
        }
    }
}
