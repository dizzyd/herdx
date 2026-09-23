import XCTest

@testable import HerdX

/// A request herdr rejects does nothing and says nothing, so the ones that
/// were never requests must not be built as though they were.
final class CommandRequestTests: XCTestCase {
    /// Handled in the client, or resolved by `invoke` into something else.
    private let notRequests: [Command] = [
        .copyMode, .help, .settings, .detach, .toggleSidebar,
        .newLocalWorkspace, .hibernateWorkspace,
    ]

    func testTheClientsOwnCommandsBuildNoRequest() {
        for command in notRequests {
            XCTAssertFalse(command.hasRequest, "\(command) claims a method")
            XCTAssertNil(
                command.requestJSON(id: "1"),
                "\(command) would go out as a request with an empty method")
        }
    }

    func testAnOrdinaryCommandStillBuildsOne() throws {
        let json = try XCTUnwrap(Command.focusTab("w1:t2").requestJSON(id: "1"))
        XCTAssertTrue(json.contains("\"method\":\"tab.focus\""))
        XCTAssertTrue(json.contains("\"tab_id\":\"w1:t2\""))
    }
}
