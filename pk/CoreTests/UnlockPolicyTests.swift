import XCTest
@testable import FaceIDCore

final class UnlockPolicyTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let ready = ScanEnvironment(isEnabled: true, killSwitchPresent: false, isSleeping: false,
                                vaultOpen: true, hasStoredPassword: true, hasEnrolledFace: true)

    func lockedPolicy(_ max: Int = 3) -> UnlockPolicy {
        var p = UnlockPolicy(maxAttempts: max)
        p.launched(screenLocked: false)
        p.observe(screenLocked: true)
        return p
    }

    func gen(_ d: ScanDecision) -> Int {
        guard case .start(let g) = d else { XCTFail("expected start, got \(d)"); return -1 }
        return g
    }

    func testNoScanWhileUnlocked() {
        var p = UnlockPolicy()
        p.launched(screenLocked: false)
        XCTAssertEqual(p.requestScan(.wake, env: ready, now: t0), .refuse(.notLocked))
    }

    func testThreeFailuresThenSilenceUntilUnlock() {
        var p = lockedPolicy()
        for i in 0..<3 {
            let g = gen(p.requestScan(.space, env: ready, now: t0.addingTimeInterval(Double(i) * 10)))
            XCTAssertEqual(p.finishScan(generation: g, result: .wrongFace), .none)
        }
        XCTAssertEqual(p.pause, .attemptsExhausted)
        XCTAssertEqual(p.requestScan(.wake, env: ready, now: t0.addingTimeInterval(100)), .refuse(.paused))
        XCTAssertEqual(p.requestScan(.space, env: ready, now: t0.addingTimeInterval(100)), .refuse(.paused))
        XCTAssertEqual(p.requestScan(.hover, env: ready, now: t0.addingTimeInterval(100)), .refuse(.paused))
        // Unlock by Touch ID or keyboard (observed) → fresh slate next lock.
        p.observe(screenLocked: false)
        p.observe(screenLocked: true)
        XCTAssertNil(p.pause)
        XCTAssertEqual(p.attemptsLeft, 3)
        _ = gen(p.requestScan(.wake, env: ready, now: t0.addingTimeInterval(200)))
    }

    func testNoFaceAndCancelledAreNotAttempts() {
        var p = lockedPolicy()
        for i in 0..<10 {
            let g = gen(p.requestScan(.space, env: ready, now: t0.addingTimeInterval(Double(i) * 10)))
            _ = p.finishScan(generation: g, result: i.isMultiple(of: 2) ? .noFace : .cancelled)
        }
        XCTAssertEqual(p.attemptsLeft, 3)
        XCTAssertNil(p.pause)
    }

    func testSpoofAndUnconfirmedCount() {
        var p = lockedPolicy(2)
        var g = gen(p.requestScan(.space, env: ready, now: t0))
        _ = p.finishScan(generation: g, result: .spoof)
        g = gen(p.requestScan(.space, env: ready, now: t0.addingTimeInterval(5)))
        _ = p.finishScan(generation: g, result: .unconfirmed)
        XCTAssertEqual(p.pause, .attemptsExhausted)
    }

    func testMatchAsksForInjection() {
        var p = lockedPolicy()
        let g = gen(p.requestScan(.wake, env: ready, now: t0))
        XCTAssertEqual(p.finishScan(generation: g, result: .matched), .inject)
    }

    func testStaleScanResultIgnored() {
        var p = lockedPolicy()
        let g = gen(p.requestScan(.wake, env: ready, now: t0))
        p.cancelScan()   // e.g. lid closed
        XCTAssertEqual(p.finishScan(generation: g, result: .matched), .none)
        XCTAssertEqual(p.finishScan(generation: g, result: .wrongFace), .none)
        XCTAssertEqual(p.attemptsLeft, 3)
    }

    func testResultAfterUnlockIgnored() {
        var p = lockedPolicy()
        let g = gen(p.requestScan(.wake, env: ready, now: t0))
        p.observe(screenLocked: false)   // Touch ID won the race
        XCTAssertEqual(p.finishScan(generation: g, result: .matched), .none)
    }

    func testOneScanAtATime() {
        var p = lockedPolicy()
        _ = gen(p.requestScan(.space, env: ready, now: t0))
        XCTAssertEqual(p.requestScan(.space, env: ready, now: t0.addingTimeInterval(1)), .refuse(.scanInProgress))
    }

    func testWakeBurstCollapses() {
        var p = lockedPolicy()
        let g = gen(p.requestScan(.wake, env: ready, now: t0))
        _ = p.finishScan(generation: g, result: .noFace)
        XCTAssertEqual(p.requestScan(.wake, env: ready, now: t0.addingTimeInterval(1)), .refuse(.wakeBurst))
        _ = gen(p.requestScan(.wake, env: ready, now: t0.addingTimeInterval(3)))
    }

    func testLaunchWhileLockedStaysQuietUntilUnlock() {
        var p = UnlockPolicy()
        p.launched(screenLocked: true)
        XCTAssertEqual(p.requestScan(.wake, env: ready, now: t0), .refuse(.paused))
        p.observe(screenLocked: false)
        p.observe(screenLocked: true)
        _ = gen(p.requestScan(.wake, env: ready, now: t0))
    }

    func testLostUnlockNotificationStillResetsOnObservedState() {
        var p = lockedPolicy()
        for i in 0..<3 {
            let g = gen(p.requestScan(.space, env: ready, now: t0.addingTimeInterval(Double(i) * 10)))
            _ = p.finishScan(generation: g, result: .wrongFace)
        }
        // No notification ever arrived — but some later event observed "unlocked".
        p.observe(screenLocked: false)
        XCTAssertNil(p.pause)
    }

    func testFailedInjectionIsStickyAcrossUnlocksUntilPasswordSaved() {
        var p = lockedPolicy()
        let g = gen(p.requestScan(.wake, env: ready, now: t0))
        XCTAssertEqual(p.finishScan(generation: g, result: .matched), .inject)
        p.injectionFinished(.notUnlocked)
        p.observe(screenLocked: false)
        p.observe(screenLocked: true)
        XCTAssertEqual(p.pause, .injectionFailed)
        XCTAssertEqual(p.requestScan(.wake, env: ready, now: t0.addingTimeInterval(60)), .refuse(.paused))
        // Survives a restart via StickyState.
        var restarted = UnlockPolicy(maxAttempts: 3, stickyPause: p.stickyPause)
        restarted.launched(screenLocked: false)
        restarted.observe(screenLocked: true)
        XCTAssertEqual(restarted.pause, .injectionFailed)
        restarted.passwordSaved()
        XCTAssertNil(restarted.pause)
    }

    func testAbortedInjectionPausesOnlyThisLock() {
        var p = lockedPolicy()
        let g = gen(p.requestScan(.wake, env: ready, now: t0))
        _ = p.finishScan(generation: g, result: .matched)
        p.injectionFinished(.aborted)
        XCTAssertEqual(p.pause, .injectionAborted)
        p.observe(screenLocked: false)
        XCTAssertNil(p.pause)
    }

    func testEnvironmentRefusals() {
        var p = lockedPolicy()
        var e = ready; e.killSwitchPresent = true
        XCTAssertEqual(p.requestScan(.wake, env: e, now: t0), .refuse(.killSwitch))
        e = ready; e.isEnabled = false
        XCTAssertEqual(p.requestScan(.wake, env: e, now: t0), .refuse(.disabled))
        e = ready; e.isSleeping = true
        XCTAssertEqual(p.requestScan(.wake, env: e, now: t0), .refuse(.sleeping))
        e = ready; e.vaultOpen = false
        XCTAssertEqual(p.requestScan(.wake, env: e, now: t0), .refuse(.vaultClosed))
        e = ready; e.hasStoredPassword = false
        XCTAssertEqual(p.requestScan(.wake, env: e, now: t0), .refuse(.noPassword))
        e = ready; e.hasEnrolledFace = false
        XCTAssertEqual(p.requestScan(.wake, env: e, now: t0), .refuse(.noFaceEnrolled))
    }

    func testMaxAttemptsClamped() {
        XCTAssertEqual(UnlockPolicy(maxAttempts: 0).maxAttempts, 1)
        XCTAssertEqual(UnlockPolicy(maxAttempts: 99).maxAttempts, 5)
    }

    func testNonStickyPauseNotRestoredFromDisk() {
        XCTAssertNil(UnlockPolicy(maxAttempts: 3, stickyPause: .attemptsExhausted).stickyPause)
    }

    func testStickyStateRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json")
        try StickyState(stickyPause: .injectionFailed).save(to: url)
        XCTAssertEqual(StickyState.load(from: url).stickyPause, .injectionFailed)
        XCTAssertNil(StickyState.load(from: url.appendingPathExtension("missing")).stickyPause)
    }
}
