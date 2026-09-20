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

    func testAnEnvironmentSocketOutranksEverything() {
        XCTAssertEqual(
            LocalAPI.socketPath(
                environment: ["HERDR_SOCKET_PATH": "/tmp/named.sock"],
                sessionName: "default", sessions: sessions),
            "/tmp/named.sock")
    }

    func testAClientSocketInTheEnvironmentPicksItsOwnMachine() {
        // This is how a throwaway session is pointed at, and the API calls have
        // to follow it rather than going to the session settings remember.
        XCTAssertEqual(
            LocalAPI.socketPath(
                environment: [
                    "HERDR_CLIENT_SOCKET_PATH": "/config/herdr/sessions/hxtest/herdr-client.sock"
                ],
                sessionName: "default", sessions: sessions),
            "/config/herdr/sessions/hxtest/herdr.sock",
            "a test run would otherwise close workspaces in the real session")
    }

    func testTheRememberedSessionIsUsedWhenTheEnvironmentSaysNothing() {
        XCTAssertEqual(
            LocalAPI.socketPath(environment: [:], sessionName: "hxtest", sessions: sessions),
            "/config/herdr/sessions/hxtest/herdr.sock")
    }

    func testWithoutAnythingElseTheDefaultSessionIsUsed() {
        XCTAssertEqual(
            LocalAPI.socketPath(environment: [:], sessionName: nil, sessions: sessions),
            "/config/herdr/herdr.sock")
    }

    func testNoSessionsMeansNoSocketRatherThanAGuess() {
        XCTAssertNil(LocalAPI.socketPath(environment: [:], sessionName: nil, sessions: { [] }))
    }

    func testAnEmptyEnvironmentValueIsNotASocket() {
        XCTAssertEqual(
            LocalAPI.socketPath(
                environment: ["HERDR_SOCKET_PATH": "", "HERDR_CLIENT_SOCKET_PATH": ""],
                sessionName: nil, sessions: sessions),
            "/config/herdr/herdr.sock",
            "an unset variable arrives as empty and must not win")
    }
}
