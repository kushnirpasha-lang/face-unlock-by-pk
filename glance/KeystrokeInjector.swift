//
//  KeystrokeInjector.swift
//  glance
//
//  Synthesizes keystrokes via CGEvent, posted at the HID tap so they reach the lock screen's secure text field.
//

import Foundation
import ApplicationServices
import CoreGraphics

enum KeystrokeError: LocalizedError {
    case accessibilityNotGranted
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            return "Нужно разрешение Универсального доступа. Откройте Системные настройки → Конфиденциальность и безопасность → Универсальный доступ и включите Face ID for Mac."
        case .eventCreationFailed:
            return "Не удалось создать CGEvent для нажатия клавиши."
        }
    }
}

enum KeystrokeInjector {
    /// Returns true if the app has Accessibility permission (no prompt).
    nonisolated static func isAccessibilityTrusted() -> Bool {
        return AXIsProcessTrusted()
    }

    /// Triggers the system prompt to grant Accessibility (deep links to System Settings).
    @discardableResult
    nonisolated static func promptForAccessibility() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // typeAndReturn / clearFocusedField removed in Face ID for Mac: the only code that types the password is
    // PasswordTyper, which never clears the field and asks InjectionGuard before the text and before Return.
}
