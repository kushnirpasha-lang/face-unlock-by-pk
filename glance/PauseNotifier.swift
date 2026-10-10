//
//  PauseNotifier.swift
//  Face ID for Mac (by PK)
//
//  There is no menu-bar icon in this build, so a pause has to be visible somewhere: one system notification. It is
//  delivered after the owner is back in (notifications aren't shown on the lock screen in a useful way anyway), and
//  can be switched off in the settings window.
//

import Foundation
import UserNotifications

@MainActor
enum PauseNotifier {
    static func requestPermissionIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    static func pauseStarted(_ reason: PauseReason) {
        guard GlanceSettings.shared.notifyOnPause else { return }
        let content = UNMutableNotificationContent()
        content.title = "Face ID for Mac — пауза"
        switch reason {
        case .attemptsExhausted:
            content.body = "Лицо не узнано \(GlanceSettings.shared.maxFailedAttempts) раза. До следующей блокировки — только Touch ID или пароль."
        case .injectionFailed:
            content.body = "Сохранённый пароль не подошёл. Откройте Face ID for Mac и обновите пароль — до этого вход лицом выключен."
        case .injectionAborted, .startedWhileLocked:
            return
        }
        let request = UNNotificationRequest(identifier: "pause-\(reason.rawValue)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
