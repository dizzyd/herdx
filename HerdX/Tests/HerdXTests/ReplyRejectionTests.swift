import XCTest

@testable import HerdX

/// A rejected request does nothing and says nothing unless the client reads
/// the reply, so what counts as a rejection has to be exact.
final class ReplyRejectionTests: XCTestCase {
    func testARejectionIsReportedWithWhatTheServerSaid() {
        let rejected = #"{"id":"1","error":{"code":"bad_params","message":"unknown field 'focus'"}}"#
        XCTAssertEqual(Reply.rejection(in: rejected)?.text, "unknown field 'focus'")
    }

    func testACodeWithoutAMessageStillReads() {
        XCTAssertEqual(
            Reply.rejection(in: #"{"id":"1","error":{"code":"unsupported_method"}}"#)?.text,
            "unsupported_method")
    }

    /// The reply is JSON, and only its error field says it failed.
    func testOutputContainingTheWordErrorIsNotAFailure() {
        let success = """
            {"id":"1","result":{"text":"npm ERR! error Missing script: \\"build\\"\\nsee \\"error\\" above"}}
            """
        XCTAssertNil(Reply.rejection(in: success))
    }

    /// Searching the text for `"error"` called this reply a failure and then
    /// reported `{` as the reason, because there was no message to find.
    func testAWorkspaceNamedErrorIsNotAFailure() {
        XCTAssertNil(Reply.rejection(in: #"{"id":"1","result":{"label":"error"}}"#))
    }

    /// Splitting the text on `"message":"` stopped at the first quote, so this
    /// one used to be reported as `pane \`.
    func testAMessageWithQuotesInItSurvivesWhole() {
        let rejected = """
            {"id":"1","error":{"code":"no_pane","message":"pane \\"w1:p9\\" is not in this tab"}}
            """
        XCTAssertEqual(Reply.rejection(in: rejected)?.text, #"pane "w1:p9" is not in this tab"#)
    }

    func testAnUnreadableReplyIsNotCalledARejection() {
        XCTAssertNil(Reply.rejection(in: "not json"))
        XCTAssertNil(Reply.rejection(in: ""))
    }
}
