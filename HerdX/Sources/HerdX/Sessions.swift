import Foundation

/// The herdr sessions on this Mac.
///
/// Read from `herdr session list --json` rather than by scanning
/// `~/.config/herdr`: where a session's directory lives, what counts as running
/// and which one is the default are herdr's rules, and a second copy of them
/// here would drift the first time one of them changed. herdr grew the `--json`
/// form for exactly this, so it is a contract rather than a scraped table.
struct SessionEntry {
    let name: String
    let isDefault: Bool
    let running: Bool
    /// The API socket, which is what herdr lists.
    let apiSocket: String

    /// What a *client* connects to.
    ///
    /// Not what herdr lists: the API socket and the client socket sit side by
    /// side under the same stem, and `default_socket_path` in herdr-core
    /// derives one from the other the same way.
    var clientSocket: String {
        let url = URL(fileURLWithPath: apiSocket)
        let stem = url.deletingPathExtension().lastPathComponent
        return
            url
            .deletingLastPathComponent()
            .appendingPathComponent("\(stem)-client.sock")
            .path
    }
}

enum SessionCatalog {
    private struct Listing: Decodable {
        struct Entry: Decodable {
            let name: String
            let running: Bool
            let isDefault: Bool
            let apiSocket: String

            private enum CodingKeys: String, CodingKey {
                case name
                case running
                case isDefault = "default"
                case apiSocket = "socket_path"
            }
        }
        let sessions: [Entry]
    }

    /// herdr, with the environment a session command can safely inherit.
    ///
    /// `HERDR_SOCKET_PATH` and `HERDR_CLIENT_SOCKET_PATH` name a socket, and
    /// the first is set inside every herdr pane. A server started with either
    /// of them inherited would listen on another session's socket, which is the
    /// one thing starting a new session must not do. `HERDR_CONFIG_DIR` is kept
    /// deliberately: it says where sessions live, which is exactly the question
    /// being asked.
    private static func command(_ arguments: [String]) -> Process? {
        guard let herdr = LocalHerdr.binaryPath() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: herdr)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        for key in ["HERDR_SOCKET_PATH", "HERDR_CLIENT_SOCKET_PATH", "HERDR_ENV"] {
            environment.removeValue(forKey: key)
        }
        process.environment = environment
        return process
    }

    /// Runs a herdr command to completion and hands back its output.
    private static func output(_ arguments: [String]) -> Data? {
        guard let process = command(arguments) else { return nil }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    /// Starts a server for a session, creating it if it is a new name.
    ///
    /// herdr has no "create": a session exists as soon as something names one,
    /// so this is the same command for a name never used before and for a
    /// session that has been stopped. It returns as soon as the process is
    /// launched — the server is not listening yet, so the caller waits.
    ///
    /// `server` rather than a bare `herdr --session <name>`: that would be a
    /// TUI, which wants a terminal and refuses to nest inside another herdr.
    static func start(_ name: String) -> Bool {
        guard let process = command(["--session", name, "server"]) else { return false }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        return true
    }

    /// How many workspaces a session has, or nil if it could not be asked.
    static func workspaceCount(_ name: String) -> Int? {
        struct Reply: Decodable {
            struct Result: Decodable { let workspaces: [Workspace] }
            struct Workspace: Decodable {}
            let result: Result
        }
        guard let data = output(["--session", name, "workspace", "list"]),
            let reply = try? JSONDecoder().decode(Reply.self, from: data)
        else { return nil }
        return reply.result.workspaces.count
    }

    /// Puts the first workspace in a session.
    ///
    /// No `--cwd`: where a workspace starts with none given is herdr's default,
    /// and it already has one — the home directory, labelled `~`.
    @discardableResult
    static func createWorkspace(in name: String) -> Bool {
        output(["--session", name, "workspace", "create", "--focus"]) != nil
    }

    /// Every session herdr knows about, running or not.
    ///
    /// An empty list is what a missing herdr, a herdr too old for `--json` and
    /// a genuinely empty machine all look like. That is deliberate: none of the
    /// three is a reason to refuse to open a window, and the menu says there is
    /// nothing to switch to either way.
    static func list() -> [SessionEntry] {
        guard let data = output(["session", "list", "--json"]),
            let listing = try? JSONDecoder().decode(Listing.self, from: data)
        else { return [] }
        return listing.sessions.map {
            SessionEntry(
                name: $0.name, isDefault: $0.isDefault, running: $0.running,
                apiSocket: $0.apiSocket)
        }
    }

    /// Whether the environment names a socket for this run.
    ///
    /// `HERDR_SOCKET_PATH` is set inside every herdr pane and points at the
    /// server that owns it, and `HERDR_CLIENT_SOCKET_PATH` is how a test run is
    /// pointed at a throwaway session. Either one has to outrank the session
    /// remembered in settings, or a saved choice would quietly drag a test run
    /// back to the real session.
    static var environmentPicksSocket: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["HERDR_SOCKET_PATH"]?.isEmpty == false
            || environment["HERDR_CLIENT_SOCKET_PATH"]?.isEmpty == false
    }
}
