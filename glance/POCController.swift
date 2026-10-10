//
//  POCController.swift
//  glance
//
//  Orchestration for credential storage: wires SecureCredentialManager to
//  KeystrokeInjector and exposes session/password status for Settings.
//

import Foundation
import Observation

@Observable
@MainActor
final class POCController {
    var accessibilityGranted: Bool = KeystrokeInjector.isAccessibilityTrusted()

    var hasStoredPassword: Bool = SecureCredentialManager.hasStoredPassword()
    var isSessionUnlocked: Bool = SecureCredentialManager.isSessionUnlocked
    var sessionError: String? = nil

    /// Bound to the setup SecureField. Cleared immediately after a successful save.
    var passwordInput: String = ""

    var statusMessage: String = "Ожидание"

    func refreshAccessibilityStatus() {
        accessibilityGranted = KeystrokeInjector.isAccessibilityTrusted()
    }

    func requestAccessibility() {
        KeystrokeInjector.promptForAccessibility()
    }

    func refreshCredentialStatus() {
        hasStoredPassword = SecureCredentialManager.hasStoredPassword()
        isSessionUnlocked = SecureCredentialManager.isSessionUnlocked
    }

    // MARK: - Session (Touch ID gate)

    /// Must succeed before `savePassword()` will do anything.
    func unlockSession() async {
        sessionError = nil
        do {
            try await Task.detached(priority: .userInitiated) {
                try SecureCredentialManager.unlockSession(reason: "настроить или использовать Face ID for Mac")
            }.value
            isSessionUnlocked = true
        } catch {
            isSessionUnlocked = false
            sessionError = error.localizedDescription
        }
    }

    func lockSession() {
        SecureCredentialManager.lockSession()
        isSessionUnlocked = false
    }

    // MARK: - Setup flow

    /// Encrypts and stores `passwordInput`. Requires the session to already
    /// be unlocked (Touch ID happens in `unlockSession()`, not here).
    func savePassword() async {
        guard !passwordInput.isEmpty else {
            statusMessage = "Сначала введите пароль."
            return
        }
        let plaintext = passwordInput
        passwordInput = ""

        do {
            try await Task.detached(priority: .userInitiated) {
                guard var bytes = plaintext.data(using: .utf8) else {
                    throw SecureCredentialError.emptyPassword
                }
                defer { bytes.resetBytes(in: 0..<bytes.count) }
                try SecureCredentialManager.savePassword(bytes)
            }.value
            statusMessage = "Пароль сохранён и зашифрован."
            hasStoredPassword = true
        } catch {
            statusMessage = "Не удалось сохранить: \(error.localizedDescription)"
        }
    }

    // Injection lives in FaceUnlockCoordinator + PasswordTyper (Face ID for Mac): there is no other code path that can
    // type the password, so nothing outside the guarded lock-screen flow can ever send it anywhere.
}
