//
//  UnlockPolicy.swift
//  Face ID for Mac (by PK)
//
//  The single source of truth for "may the camera start?" and "what happens after a scan?". Pure logic: no camera,
//  no screen, no keyboard, no clocks of its own — every input is passed in, so every rule is unit-tested
//  (`swift test`, see Package.swift at the repo root).
//
//  Rules (memory/face-unlock/ARCHITECTURE.md):
//  - A scan never starts because the screen just locked (A1) — only wake, space or hover.
//  - Lock epochs are derived from *observed* lock state on any event, not from a notification that can be lost (A2/A5).
//  - At most `maxAttempts` failed attempts per lock; then silence until the Mac is unlocked by any means.
//  - "No face in view" is not an attempt.
//  - A failed password injection is sticky: it survives unlocks and restarts until the password is saved again (A4).
//  - An app launched while the screen is already locked stays quiet until the next unlock (it can't know the count).
//

import Foundation

nonisolated enum ScanTrigger: String, Sendable, Codable {
    case wake, space, hover
}

nonisolated enum ScanResult: String, Sendable, Codable {
    case matched
    /// A detected face that isn't the owner, sustained.
    case wrongFace
    /// A liveness deny cue that held long enough to be a real rejection.
    case spoof
    /// A face was in view but couldn't be confirmed before the window closed.
    case unconfirmed
    /// No face at all during the window — the owner simply wasn't looking. Not an attempt.
    case noFace
    /// Cancelled from outside (sleep, unlock, superseded). Not an attempt.
    case cancelled

    var countsAsAttempt: Bool {
        switch self {
        case .wrongFace, .spoof, .unconfirmed: return true
        case .matched, .noFace, .cancelled: return false
        }
    }
}

nonisolated enum InjectionResult: String, Sendable, Codable {
    /// The screen unlocked after Return.
    case unlocked
    /// Return was sent but the screen stayed locked — almost certainly a wrong (changed) password.
    case notUnlocked
    /// The guard stopped the injection part-way (someone touched the keyboard, the screen unlocked by itself, …).
    case aborted
}

nonisolated enum PauseReason: String, Sendable, Codable {
    // Cleared by the next unlock:
    case attemptsExhausted
    case startedWhileLocked
    case injectionAborted
    // Sticky — cleared only by saving the password again:
    case injectionFailed

    var isSticky: Bool { self == .injectionFailed }
}

nonisolated enum ScanRefusal: String, Sendable, Codable {
    case notLocked, sleeping, disabled, killSwitch, paused, vaultClosed, noPassword, noFaceEnrolled
    case scanInProgress, wakeBurst
}

/// Everything outside the policy that decides whether a scan may start. Gathered fresh by the caller each time.
nonisolated struct ScanEnvironment: Sendable {
    var isEnabled: Bool
    var killSwitchPresent: Bool
    var isSleeping: Bool
    var vaultOpen: Bool
    var hasStoredPassword: Bool
    var hasEnrolledFace: Bool
}

nonisolated enum ScanDecision: Equatable, Sendable {
    case start(generation: Int)
    case refuse(ScanRefusal)
}

nonisolated enum AfterScan: Equatable, Sendable {
    /// Matched — go ahead and ask the injection guard.
    case inject
    /// Nothing to do (failure counted or not, stale result ignored).
    case none
}

nonisolated struct UnlockPolicy: Sendable {
    var maxAttempts: Int
    /// Several wake signals arrive from one lid-open; anything this close to the last scan start is the same wake.
    var wakeBurst: TimeInterval = 2

    private(set) var isLocked = false
    private(set) var lockEpoch = 0
    private(set) var failedAttempts = 0
    private(set) var transientPause: PauseReason?
    private(set) var stickyPause: PauseReason?
    private(set) var activeScan: Int?
    private var generation = 0
    private var lastScanStartedAt: Date?

    init(maxAttempts: Int = 3, stickyPause: PauseReason? = nil) {
        self.maxAttempts = max(1, min(5, maxAttempts))
        self.stickyPause = (stickyPause?.isSticky == true) ? stickyPause : nil
    }

    var pause: PauseReason? { stickyPause ?? transientPause }
    var attemptsLeft: Int { max(0, maxAttempts - failedAttempts) }

    // MARK: - Lifecycle

    /// Call once at launch with the observed lock state.
    mutating func launched(screenLocked: Bool) {
        isLocked = screenLocked
        if screenLocked {
            transientPause = .startedWhileLocked
        }
    }

    /// Call on EVERY event (wake, lock, unlock notification, space, hover, timer) with the authoritative lock state.
    /// Transitions are derived here, so a lost notification can't wedge the machine.
    mutating func observe(screenLocked: Bool) {
        guard screenLocked != isLocked else { return }
        isLocked = screenLocked
        // Both directions start a clean slate: a new lock gets fresh attempts, an unlock ends the old lock.
        failedAttempts = 0
        transientPause = nil
        activeScan = nil
        if screenLocked { lockEpoch &+= 1 }
    }

    // MARK: - Scanning

    mutating func requestScan(_ trigger: ScanTrigger, env: ScanEnvironment, now: Date) -> ScanDecision {
        guard isLocked else { return .refuse(.notLocked) }
        guard !env.isSleeping else { return .refuse(.sleeping) }
        guard !env.killSwitchPresent else { return .refuse(.killSwitch) }
        guard env.isEnabled else { return .refuse(.disabled) }
        guard pause == nil, failedAttempts < maxAttempts else { return .refuse(.paused) }
        guard env.vaultOpen else { return .refuse(.vaultClosed) }
        guard env.hasStoredPassword else { return .refuse(.noPassword) }
        guard env.hasEnrolledFace else { return .refuse(.noFaceEnrolled) }
        guard activeScan == nil else { return .refuse(.scanInProgress) }
        if trigger == .wake, let last = lastScanStartedAt, now.timeIntervalSince(last) < wakeBurst {
            return .refuse(.wakeBurst)
        }
        generation &+= 1
        activeScan = generation
        lastScanStartedAt = now
        return .start(generation: generation)
    }

    /// Sleep, unlock or the kill switch: drop the current scan without counting it.
    mutating func cancelScan() {
        activeScan = nil
    }

    mutating func finishScan(generation: Int, result: ScanResult) -> AfterScan {
        // A result from a scan that was cancelled or superseded is ignored entirely.
        guard activeScan == generation else { return .none }
        activeScan = nil
        guard isLocked else { return .none }
        if result.countsAsAttempt {
            failedAttempts += 1
            if failedAttempts >= maxAttempts { transientPause = .attemptsExhausted }
            return .none
        }
        if result == .matched, pause == nil { return .inject }
        return .none
    }

    // MARK: - Injection outcome

    mutating func injectionFinished(_ result: InjectionResult) {
        switch result {
        case .unlocked: break
        case .notUnlocked: stickyPause = .injectionFailed
        case .aborted: transientPause = .injectionAborted
        }
    }

    /// The owner typed the password into Settings again — the only thing that lifts a sticky pause.
    mutating func passwordSaved() {
        stickyPause = nil
    }
}
