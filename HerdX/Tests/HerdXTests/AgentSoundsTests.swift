import XCTest

@testable import HerdX

/// A sound that plays to a locked screen is heard by whoever is in the room
/// and by nobody who wanted it. The reading is the part worth pinning down:
/// unlocked, macOS does not set the key at all, so a wrong guess about what
/// absence means silences the app permanently or never silences it at all.
@MainActor
final class AgentSoundsTests: XCTestCase {

    // MARK: - Reading the session

    func testAnAbsentKeyMeansUnlocked() {
        // What this machine actually returns with somebody sitting at it: the
        // session dictionary is full of other flags and this key is not in it.
        let session: [String: Any] = [
            "kCGSSessionOnConsoleKey": NSNumber(value: true),
            "kCGSSessionUserNameKey": "dizzyd",
        ]
        XCTAssertFalse(AgentSounds.isLocked(session: session))
    }

    func testALockedScreenReadsLocked() {
        // Locked, it arrives as a CFBoolean, which bridges to NSNumber.
        XCTAssertTrue(
            AgentSounds.isLocked(session: ["CGSSessionScreenIsLocked": NSNumber(value: true)]))
        // And the same key written as a number, which is how every example of
        // this call in the wild reads it.
        XCTAssertTrue(
            AgentSounds.isLocked(session: ["CGSSessionScreenIsLocked": NSNumber(value: 1)]))
    }

    func testAnExplicitFalseIsNotLocked() {
        XCTAssertFalse(
            AgentSounds.isLocked(session: ["CGSSessionScreenIsLocked": NSNumber(value: false)]))
        XCTAssertFalse(
            AgentSounds.isLocked(session: ["CGSSessionScreenIsLocked": NSNumber(value: 0)]))
    }

    func testNoSessionIsNotLocked() {
        // Nothing to read is not evidence of a locked screen, and guessing
        // otherwise would take the sounds away for good.
        XCTAssertFalse(AgentSounds.isLocked(session: nil))
    }

    // MARK: - Whether anything is worth playing

    func testALockedScreenSilencesEnabledSounds() {
        let sounds = AgentSounds()
        sounds.isEnabled = true
        sounds.screenIsLocked = { true }
        XCTAssertFalse(sounds.isAudible)
    }

    func testAnUnlockedScreenLeavesEnabledSoundsAlone() {
        let sounds = AgentSounds()
        sounds.isEnabled = true
        sounds.screenIsLocked = { false }
        XCTAssertTrue(sounds.isAudible)
    }

    func testUnlockingDoesNotOverrideTheSetting() {
        let sounds = AgentSounds()
        sounds.isEnabled = false
        sounds.screenIsLocked = { false }
        XCTAssertFalse(sounds.isAudible)
    }

    func testTheScreenIsAskedEveryTime() {
        // Not cached: the answer changes while the app is running, and the
        // whole point is to notice that it has.
        let sounds = AgentSounds()
        var locked = false
        sounds.screenIsLocked = { locked }
        XCTAssertTrue(sounds.isAudible)
        locked = true
        XCTAssertFalse(sounds.isAudible)
        locked = false
        XCTAssertTrue(sounds.isAudible)
    }
}
