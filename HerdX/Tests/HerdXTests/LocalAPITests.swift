import Darwin
import XCTest

@testable import HerdX

/// Which socket a run talks to is the one thing a dev run must never get
/// wrong: the real session holds live agents and unsaved terminals, and these
/// requests close workspaces.
final class LocalAPITests: XCTestCase {
    private let sessions = {
        [
            SessionEntry(
                name: "default", isDefault: true, running: true,
                apiSocket: "/config/herdr/herdr.sock"),
            SessionEntry(
                name: "hxtest", isDefault: false, running: true,
                apiSocket: "/config/herdr/sessions/hxtest/herdr.sock"),
        ]
    }

    /// A write to a peer that has closed raises SIGPIPE, and the default
    /// disposition for it ends the process — before the send loop's own
    /// failure path can run. Measured: the process exits on signal 13 with no
    /// result, so every careful failure message below it is unreachable.
    ///
    /// Asserted by reading the option back rather than by provoking the
    /// signal, which would take the test runner down with it.
    func testARequestSocketRefusesSigpipe() throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer {
            Darwin.close(pair[0])
            Darwin.close(pair[1])
        }

        LocalAPI.configure(pair[0], timeout: 2)

        var set: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        XCTAssertEqual(getsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &set, &size), 0)
        XCTAssertNotEqual(set, 0, "a write to a closed peer would kill the app")
    }

    /// The timeouts go on with it: a server that accepts and then says nothing
    /// must not hold a thread for the life of the process.
    func testARequestSocketStillGetsItsTimeouts() throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer {
            Darwin.close(pair[0])
            Darwin.close(pair[1])
        }

        LocalAPI.configure(pair[0], timeout: 3)

        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
            var limit = timeval()
            var size = socklen_t(MemoryLayout<timeval>.size)
            XCTAssertEqual(getsockopt(pair[0], SOL_SOCKET, option, &limit, &size), 0)
            XCTAssertEqual(limit.tv_sec, 3, "option \(option) was left unset")
        }
    }

    /// The mismatch that could close a workspace on the wrong server.
    ///
    /// The window resolved its session with `HERDX_SESSION` first; hibernation
    /// asked again from the *saved* name. Aimed at a throwaway session, the
    /// window showed the throwaway one and hibernation addressed the saved
    /// one — and since workspace ids are only unique within a server, a
    /// matching id closed a live workspace on the developer's own session.
    ///
    /// The cure is that there is now one fact: whatever client socket the
    /// session attached to, with the API socket derived from it. This asserts
    /// the two directions are exact inverses, which is what makes deriving
    /// safe for every variable the core honours.
    func testTheDerivationIsTheInverseOfTheCores() {
        // herdr-core's `default_socket_path` turns an API socket into a client
        // socket by this same stem rule, in the other direction.
        let api = "/Users/me/.config/herdr/sessions/hxtest/herdr.sock"
        let client = "/Users/me/.config/herdr/sessions/hxtest/herdr-client.sock"
        XCTAssertEqual(LocalAPI.apiSocket(besideClientSocket: client), api)
        // And a run aimed at one session can no longer derive another's.
        XCTAssertNotEqual(
            LocalAPI.apiSocket(besideClientSocket: client),
            "/Users/me/.config/herdr/herdr.sock")
    }

    func testTheAPISocketSitsBesideTheClientSocket() {
        XCTAssertEqual(
            LocalAPI.apiSocket(
                besideClientSocket: "/config/herdr/sessions/hxtest/herdr-client.sock"),
            "/config/herdr/sessions/hxtest/herdr.sock")
    }

    func testAPathThatIsAlreadyAnAPISocketIsLeftAlone() {
        XCTAssertEqual(
            LocalAPI.apiSocket(besideClientSocket: "/config/herdr/herdr.sock"),
            "/config/herdr/herdr.sock",
            "deriving twice must not eat part of the name")
    }






}
