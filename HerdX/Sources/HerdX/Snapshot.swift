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

    struct Workspace: Decodable {
        let workspaceID: String
        let number: Int
        let label: String
        let branch: String?
        let focused: Bool
        let agentStatus: AgentStatus

        enum CodingKeys: String, CodingKey {
            case workspaceID = "workspace_id"
            case number, label, branch, focused
            case agentStatus = "agent_status"
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
        let displayAgent: String?
        let title: String?
        let agentStatus: AgentStatus
        let focused: Bool

        enum CodingKeys: String, CodingKey {
            case paneID = "pane_id"
            case displayAgent = "display_agent"
            case title
            case agentStatus = "agent_status"
            case focused
        }
    }
}
