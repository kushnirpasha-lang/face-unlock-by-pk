//
//  InjectionGuard.swift
//  Face ID for Mac (by PK)
//
//  "May the password be typed RIGHT NOW?" Asked immediately before the text and again immediately before Return.
//  Every condition must hold; any doubt is a "no" (R7). Pure logic over a snapshot the caller takes.
//
//  Real-input rule (A3): the tap/keypress that woke the screen must not block the unlock, but any keypress the owner
//  makes after the scan has started (they began typing the password themselves) must.
//  - keys:    deny if a key went down after max(scanStartedAt, wakeAt + 0.5 s)
//  - pointer: deny if a click/trackpad press went down after scanStartedAt (cursor movement is not tracked at all)
//  - while typing (before Return): deny if anything went down after typing started
//

import Foundation

nonisolated enum InjectionPhase: String, Sendable {
    case beforeText, beforeReturn
}

nonisolated enum GuardDenial: String, Sendable, Codable, Equatable {
    case notLocked            // CGSession says unlocked
    case unlockNotified       // the unlock notification already arrived (CGSession may lag after Touch ID, A8)
    case notOnConsole         // our session isn't the one on screen (fast user switching, K4)
    case otherUserOnConsole
    case inputMonitorDead     // without it we can't see the owner typing — fail closed (K6/A10)
    case noAccessibility
    case killSwitch
    case paused
    case recentKeyboard
    case recentPointer
}

nonisolated struct GuardSnapshot: Sendable {
    var cgSessionLocked: Bool
    var unlockNotifiedSinceLock: Bool
    var sessionOnConsole: Bool
    var consoleUserIsMe: Bool
    var inputMonitorAlive: Bool
    var accessibilityTrusted: Bool
    var killSwitchPresent: Bool
    var paused: Bool
    var lastKeyDown: Date?
    var lastPointerDown: Date?
    var wakeAt: Date?
    var scanStartedAt: Date
    var typingStartedAt: Date?
}

nonisolated enum InjectionGuard {
    static let wakeGrace: TimeInterval = 0.5

    static func evaluate(_ s: GuardSnapshot, phase: InjectionPhase) -> GuardDenial? {
        guard s.cgSessionLocked else { return .notLocked }
        guard !s.unlockNotifiedSinceLock else { return .unlockNotified }
        guard s.sessionOnConsole else { return .notOnConsole }
        guard s.consoleUserIsMe else { return .otherUserOnConsole }
        guard !s.killSwitchPresent else { return .killSwitch }
        guard !s.paused else { return .paused }
        guard s.accessibilityTrusted else { return .noAccessibility }
        guard s.inputMonitorAlive else { return .inputMonitorDead }

        let keyCutoff: Date
        let pointerCutoff: Date
        switch phase {
        case .beforeText:
            let wakeCutoff = s.wakeAt.map { $0.addingTimeInterval(wakeGrace) } ?? .distantPast
            keyCutoff = max(s.scanStartedAt, wakeCutoff)
            pointerCutoff = s.scanStartedAt
        case .beforeReturn:
            // No typing start recorded means we can't prove the window is clean.
            guard let typing = s.typingStartedAt else { return .recentKeyboard }
            keyCutoff = typing
            pointerCutoff = typing
        }
        if let k = s.lastKeyDown, k > keyCutoff { return .recentKeyboard }
        if let p = s.lastPointerDown, p > pointerCutoff { return .recentPointer }
        return nil
    }
}
