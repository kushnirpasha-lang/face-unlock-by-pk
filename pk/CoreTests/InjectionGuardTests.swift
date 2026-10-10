import XCTest
@testable import FaceIDCore

final class InjectionGuardTests: XCTestCase {
    let wake = Date(timeIntervalSince1970: 2_000_000)
    var scanStart: Date { wake.addingTimeInterval(0.6) }

    func clean() -> GuardSnapshot {
        GuardSnapshot(cgSessionLocked: true, unlockNotifiedSinceLock: false, sessionOnConsole: true,
                      consoleUserIsMe: true, inputMonitorAlive: true, accessibilityTrusted: true,
                      killSwitchPresent: false, paused: false, lastKeyDown: nil, lastPointerDown: nil,
                      wakeAt: wake, scanStartedAt: scanStart, typingStartedAt: nil)
    }

    func testCleanSnapshotAllowsText() {
        XCTAssertNil(InjectionGuard.evaluate(clean(), phase: .beforeText))
    }

    func testEverySystemConditionDeniesOnItsOwn() {
        var s = clean(); s.cgSessionLocked = false
        XCTAssertEqual(InjectionGuard.evaluate(s, phase: .beforeText), .notLocked)
        s = clean(); s.unlockNotifiedSinceLock = true
        XCTAssertEqual(InjectionGuard.evaluate(s, phase: .beforeText), .unlockNotified)
        s = clean(); s.sessionOnConsole = false
        XCTAssertEqual(InjectionGuard.evaluate(s, phase: .beforeText), .notOnConsole)
        s = clean(); s.consoleUserIsMe = false
        XCTAssertEqual(InjectionGuard.evaluate(s, phase: .beforeText), .otherUserOnConsole)
        s = clean(); s.killSwitchPresent = true
        XCTAssertEqual(InjectionGuard.evaluate(s, phase: .beforeText), .killSwitch)
        s = clean(); s.paused = true
        XCTAssertEqual(InjectionGuard.evaluate(s, phase: .beforeText), .paused)
        s = clean(); s.accessibilityTrusted = false
        XCTAssertEqual(InjectionGuard.evaluate(s, phase: .beforeText), .noAccessibility)
        s = clean(); s.inputMonitorAlive = false
        XCTAssertEqual(InjectionGuard.evaluate(s, phase: .beforeText), .inputMonitorDead)
    }

    func testWakingTapDoesNotBlock() {
        var s = clean()
        s.lastPointerDown = wake            // the tap that woke the screen
        s.lastKeyDown = wake.addingTimeInterval(0.3)   // or a key, within the wake grace
        XCTAssertNil(InjectionGuard.evaluate(s, phase: .beforeText))
    }

    func testOwnerTypingAfterScanStartBlocks() {
        var s = clean()
        s.lastKeyDown = scanStart.addingTimeInterval(1)
        XCTAssertEqual(InjectionGuard.evaluate(s, phase: .beforeText), .recentKeyboard)
    }

    func testClickAfterScanStartBlocks() {
        var s = clean()
        s.lastPointerDown = scanStart.addingTimeInterval(0.2)
        XCTAssertEqual(InjectionGuard.evaluate(s, phase: .beforeText), .recentPointer)
    }

    func testKeyJustAfterWakeGraceBlocks() {
        var s = clean()
        s.scanStartedAt = wake            // scan started instantly; the wake grace is now the later cutoff
        s.lastKeyDown = wake.addingTimeInterval(0.7)
        XCTAssertEqual(InjectionGuard.evaluate(s, phase: .beforeText), .recentKeyboard)
    }

    func testReturnNeedsTypingStartAndNoInputSince() {
        var s = clean()
        XCTAssertEqual(InjectionGuard.evaluate(s, phase: .beforeReturn), .recentKeyboard)
        let typing = scanStart.addingTimeInterval(2)
        s.typingStartedAt = typing
        XCTAssertNil(InjectionGuard.evaluate(s, phase: .beforeReturn))
        s.lastKeyDown = typing.addingTimeInterval(0.005)
        XCTAssertEqual(InjectionGuard.evaluate(s, phase: .beforeReturn), .recentKeyboard)
        s.lastKeyDown = nil; s.lastPointerDown = typing.addingTimeInterval(0.005)
        XCTAssertEqual(InjectionGuard.evaluate(s, phase: .beforeReturn), .recentPointer)
    }

    func testTouchIDUnlockMidTypingStopsReturn() {
        var s = clean()
        s.typingStartedAt = scanStart.addingTimeInterval(2)
        s.unlockNotifiedSinceLock = true   // CGSession may still say locked for a few hundred ms
        XCTAssertEqual(InjectionGuard.evaluate(s, phase: .beforeReturn), .unlockNotified)
    }
}
