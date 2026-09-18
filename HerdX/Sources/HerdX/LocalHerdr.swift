import AppKit

/// Whether herdr itself is on this Mac.
///
/// HerdX is a client: it renders what a herdr server composes and has nothing
/// to show without one. Someone who installs the app first — which is the
/// ordinary way round for a Mac app — gets an empty window and "Local is
/// offline", which names the symptom and not the cause.
enum LocalHerdr {
    enum State {
        /// herdr is installed and its server answered.
        case running
        /// herdr is here but no server is listening.
        case installed(at: String)
        /// No herdr on this machine at all.
        case missing
    }

    /// Where herdr would be.
    ///
    /// Known locations rather than a PATH search alone: an app launched from
    /// the Finder inherits a minimal PATH that does not include `~/.local/bin`,
    /// which is where herdr's own installer puts it, so a PATH miss says
    /// nothing about whether herdr is installed.
    static func binaryPath() -> String? {
        let manager = FileManager.default
        var candidates: [String] = []

        if let named = ProcessInfo.processInfo.environment["HERDR_BIN_PATH"] {
            candidates.append(named)
        }
        candidates.append(
            (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/herdr"))
        candidates += ["/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"]

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map {
                ($0 as NSString).appendingPathComponent("herdr")
            }
        }
        return candidates.first { manager.isExecutableFile(atPath: $0) }
    }

    /// What to tell someone, given whether the local server answered.
    static func state(serverIsUp: Bool) -> State {
        if serverIsUp { return .running }
        guard let path = binaryPath() else { return .missing }
        return .installed(at: path)
    }

    /// The install line herdr's own README gives.
    static let installCommand = "curl -fsSL https://herdr.dev/install.sh | sh"
}
