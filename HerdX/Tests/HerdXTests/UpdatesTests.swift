import XCTest

@testable import HerdX

/// Two decisions, both of which are wrong in a way nobody would notice: a
/// comparison that reads versions as text announces nothing for the whole of a
/// series past its ninth release, and a "once a day" that is really "every
/// launch" only looks like enthusiasm.
final class UpdatesTests: XCTestCase {

    // MARK: - Which one is newer

    func testALaterVersionIsNewer() {
        XCTAssertTrue(Updates.isNewer("1.3.0", than: "1.2.0"))
        XCTAssertTrue(Updates.isNewer("2.0.0", than: "1.9.9"))
        XCTAssertTrue(Updates.isNewer("1.2.1", than: "1.2.0"))
    }

    func testTheSameVersionIsNotNewer() {
        XCTAssertFalse(Updates.isNewer("1.2.0", than: "1.2.0"))
        // The tag carries a v and the bundle does not, which is the only shape
        // this comparison ever actually sees.
        XCTAssertFalse(Updates.isNewer("v1.2.0", than: "1.2.0"))
    }

    func testAnOlderVersionIsNotNewer() {
        XCTAssertFalse(Updates.isNewer("1.1.9", than: "1.2.0"))
        XCTAssertFalse(Updates.isNewer("v0.9.0", than: "1.2.0"))
    }

    func testTenSortsAfterNine() {
        // As text "1.10.0" < "1.9.0", so a string comparison would go quiet for
        // every release from the tenth of a series onwards — and stay quiet.
        XCTAssertTrue(Updates.isNewer("1.10.0", than: "1.9.0"))
        XCTAssertFalse(Updates.isNewer("1.9.0", than: "1.10.0"))
    }

    func testMissingComponentsCountAsZero() {
        XCTAssertTrue(Updates.isNewer("1.3", than: "1.2.9"))
        XCTAssertFalse(Updates.isNewer("1.2", than: "1.2.0"))
        XCTAssertTrue(Updates.isNewer("1.2.1", than: "1.2"))
    }

    func testSomethingThatIsNotAVersionIsNotNewer() {
        // A tag nobody can parse is not grounds for telling someone to go and
        // download something.
        XCTAssertFalse(Updates.isNewer("nightly", than: "1.2.0"))
        XCTAssertFalse(Updates.isNewer("", than: "1.2.0"))
        XCTAssertFalse(Updates.isNewer("1.3.0", than: "unbundled"))
    }

    func testAPrereleaseCompesAsItsNumbers() {
        // GitHub's latest release is never a prerelease, so this is only about
        // not throwing the whole comparison away when a tag has a suffix.
        XCTAssertTrue(Updates.isNewer("1.3.0-rc.1", than: "1.2.0"))
    }

    // MARK: - Whether to ask at all

    func testTheFirstLaunchEverAsks() {
        XCTAssertTrue(Updates.isDue(lastChecked: nil))
    }

    func testASecondLaunchTheSameDayDoesNotAsk() {
        let now = Date()
        XCTAssertFalse(Updates.isDue(lastChecked: now.addingTimeInterval(-60), now: now))
        XCTAssertFalse(Updates.isDue(lastChecked: now.addingTimeInterval(-23 * 3600), now: now))
    }

    func testALaunchADayLaterAsks() {
        let now = Date()
        XCTAssertTrue(Updates.isDue(lastChecked: now.addingTimeInterval(-24 * 3600), now: now))
        XCTAssertTrue(Updates.isDue(lastChecked: now.addingTimeInterval(-40 * 3600), now: now))
    }

    func testAClockPutBackDoesNotSilenceItForMonths() {
        // A check stamped in the future would otherwise have to be waited out.
        let now = Date()
        XCTAssertTrue(Updates.isDue(lastChecked: now.addingTimeInterval(60 * 86400), now: now))
    }
}
