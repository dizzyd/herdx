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

    /// Every session herdr knows about, running or not.
    ///
    /// An empty list is what a missing herdr, a herdr too old for `--json` and
    /// a genuinely empty machine all look like. That is deliberate: none of the
    /// three is a reason to refuse to open a window, and the menu says there is
    /// nothing to switch to either way.
    static func list() -> [SessionEntry] {
        guard let herdr = LocalHerdr.binaryPath() else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: herdr)
        process.arguments = ["session", "list", "--json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
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
