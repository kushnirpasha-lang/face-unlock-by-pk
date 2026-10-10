//
//  FaceIDHomePage.swift
//  Face ID for Mac (by PK)
//
//  The one page the owner actually needs (V5): status (there is no menu-bar icon, so this IS the status), the main
//  switch, attempts, scan time, strictness, the last events, version and the "by PK" mark. Face re-enrollment and
//  the stored password keep their own tabs.
//

import SwiftUI
import AppKit

struct FaceIDHomePage: View {
    @Bindable var coordinator: FaceUnlockCoordinator
    @Bindable var settings = GlanceSettings.shared
    var log = EventLog.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusCard

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Вход лицом", isOn: $coordinator.isEnabled)
                        .toggleStyle(.switch)
                    Stepper(value: $settings.maxFailedAttempts, in: 1...5) {
                        Text("Попыток до паузы: \(settings.maxFailedAttempts)")
                    }
                    .onChange(of: settings.maxFailedAttempts) { _, value in coordinator.applyMaxAttempts(value) }
                    Stepper(value: $settings.faceDetectionSeconds, in: GlanceSettings.faceDetectionRange) {
                        Text("Время одного скана: \(settings.faceDetectionSeconds) с")
                    }
                    Picker("Строгость", selection: $settings.livenessMode) {
                        Text("Обычная").tag(LivenessMode.light)
                        Text("Строгая (живое лицо: моргнуть или повернуть голову)").tag(LivenessMode.heavy)
                    }
                    Toggle("Уведомлять, когда вход лицом на паузе", isOn: $settings.notifyOnPause)
                }
                .padding(6)
            }

            GroupBox("Последние события") {
                VStack(alignment: .leading, spacing: 4) {
                    if log.recent.isEmpty {
                        Text("Пока пусто").foregroundStyle(.secondary)
                    }
                    ForEach(log.recent) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.at.formatted(date: .omitted, time: .shortened))
                                .monospacedDigit().foregroundStyle(.secondary)
                            Text(entry.event).bold()
                            Text(entry.detail).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            HStack(spacing: 10) {
                Button("Закрыть окно") { NSApp.keyWindow?.close() }
                Button("Завершить программу", role: .destructive) { NSApp.terminate(nil) }
                Spacer()
            }
            Text("«Закрыть окно» — программа продолжит работать в фоне. «Завершить программу» (или ⌘Q) — выключит её до следующего входа в систему или до запуска из «Программ». Для временной паузы — переключатель «Вход лицом». Touch ID и пароль работают всегда.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            footer
        }
    }

    private var statusCard: some View {
        let (title, detail, color) = status
        return HStack(spacing: 12) {
            Circle().fill(color).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.12)))
    }

    private var status: (String, String, Color) {
        if coordinator.killSwitchPresent {
            return ("Выключено файлом OFF", "Удалите ~/Library/Application Support/FaceIDforMac/OFF, чтобы включить.", .gray)
        }
        if !coordinator.isEnabled {
            return ("Выключено", "Включите «Вход лицом» ниже.", .gray)
        }
        if !coordinator.inputMonitorAlive {
            return ("Нужно разрешение «Мониторинг ввода»",
                    "Системные настройки → Конфиденциальность → Мониторинг ввода → Face ID for Mac. Без него пароль не вводится (защита).", .orange)
        }
        switch coordinator.pauseReason {
        case .injectionFailed:
            return ("Пауза: сохранённый пароль не подошёл", "Откройте вкладку «Пароль» и сохраните пароль заново.", .red)
        case .attemptsExhausted:
            return ("Пауза до следующей блокировки", "Лицо не узнано \(settings.maxFailedAttempts) раза подряд.", .orange)
        case .startedWhileLocked:
            return ("Ждёт входа", "Программа запустилась на заблокированном экране — после входа пальцем или паролем заработает.", .orange)
        case .injectionAborted:
            return ("Пауза до следующей блокировки", "Ввод пароля был остановлен ради безопасности.", .orange)
        case nil:
            break
        }
        if !SecureCredentialManager.hasStoredPassword() {
            return ("Нет пароля", "Сохраните пароль Мака на вкладке «Пароль».", .orange)
        }
        if !SecureCredentialManager.isSessionUnlocked {
            return ("Нужен Touch ID", "После перезапуска откройте вкладку «Пароль» и подтвердите Touch ID один раз.", .orange)
        }
        let vault = SecureCredentialManager.vaultBackend?.title ?? "—"
        return ("Работает", "Хранилище: \(vault)", .green)
    }

    private var footer: some View {
        HStack {
            Text("Версия \(AppVersion.display)")
            Spacer()
            Text("by PK").fontWeight(.semibold)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}

enum AppVersion {
    /// "10.10.2026 17:34 · a1b2c3d" — the commit time in Kyiv, baked in by CI (V6).
    static var display: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let human = (info["PKBuildDisplayVersion"] as? String).flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
        let commit = (info["PKBuildCommit"] as? String).flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        return [human ?? short, commit].compactMap { $0 }.joined(separator: " · ")
    }
}
