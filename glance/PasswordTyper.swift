//
//  PasswordTyper.swift
//  Face ID for Mac (by PK)
//
//  Types the stored password into the lock screen — and nothing else. Replaces Glance's KeystrokeInjector call path:
//  - never clears the field first (Glance sent ⌘→ ⌘⌫, wiping whatever the owner was typing) (R4);
//  - asks InjectionGuard immediately before the text and again immediately before Return (R3, K5);
//  - stops before Return if anything changed, and reports exactly where it stopped.
//
//  Residual risk (documented): a few milliseconds between the last guard check and the Return key-down.
//

import Foundation
import CoreGraphics

nonisolated enum TyperOutcome: Equatable, Sendable {
    case sent
    case refusedBeforeText(GuardDenial)
    case stoppedBeforeReturn(GuardDenial)
    case failed(String)
}

nonisolated enum PasswordTyper {
    /// `snapshot` must take a FRESH reading every time it is called — it is called twice.
    static func type(_ password: Data,
                     snapshot: (_ typingStartedAt: Date?) -> GuardSnapshot) -> TyperOutcome {
        if let denial = InjectionGuard.evaluate(snapshot(nil), phase: .beforeText) {
            return .refusedBeforeText(denial)
        }
        guard let text = String(data: password, encoding: .utf8), !text.isEmpty else { return .failed("empty") }
        let source = CGEventSource(stateID: .hidSystemState)
        let typingStartedAt = Date()
        // Same chunking as Glance (CGEvent carries at most 20 UTF-16 units per event).
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            var end = min(index + 20, units.count)
            // Don't split a surrogate pair across events.
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            let chunk = Array(units[index..<end])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                return .failed("CGEvent")
            }
            chunk.withUnsafeBufferPointer { buf in
                down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            index = end
        }
        if let denial = InjectionGuard.evaluate(snapshot(typingStartedAt), phase: .beforeReturn) {
            return .stoppedBeforeReturn(denial)
        }
        let returnKey: CGKeyCode = 0x24
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false) else {
            return .failed("CGEvent")
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return .sent
    }
}

/// Reads the facts the guard needs, straight from the system, at the moment it's called.
nonisolated enum SessionFacts {
    struct Session {
        var screenLocked: Bool
        var onConsole: Bool
        var userIsMe: Bool
    }

    /// For the guard: fails closed — no dictionary → "not locked, not on console" → never type.
    static func current() -> Session {
        currentOrNil() ?? Session(screenLocked: false, onConsole: false, userIsMe: false)
    }

    /// For state tracking: nil when CGSession can't be read, so callers don't mistake "unknown" for "unlocked".
    static func currentOrNil() -> Session? {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        let locked = (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
        let onConsole = (dict[kCGSessionOnConsoleKey as String] as? Bool) ?? false
        let user = dict[kCGSessionUserNameKey as String] as? String
        return Session(screenLocked: locked, onConsole: onConsole, userIsMe: user == NSUserName())
    }

    /// After Return: poll for up to `timeout` until the screen reports unlocked (A-verifier).
    static func waitForUnlock(timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !current().screenLocked { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return !current().screenLocked
    }
}
