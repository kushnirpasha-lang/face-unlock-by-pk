//
//  RecognitionSettingsPage.swift
//  glance
//

import SwiftUI

struct RecognitionSettingsPage: View {
    @Bindable var coordinator: FaceUnlockCoordinator
    @Bindable var pocController: POCController
    @Bindable private var settings = GlanceSettings.shared

    @State private var isUnlocking = false
    @State private var sessionError: String?

    /// Read from `POCController`, not a local copy — same reasoning as
    /// `PasswordSettingsPage`.
    private var isSessionUnlocked: Bool { pocController.isSessionUnlocked }

    var body: some View {
        ZStack(alignment: .top) {
            lockedState
                .opacity(isSessionUnlocked ? 0 : 1)
                .allowsHitTesting(!isSessionUnlocked)
                .accessibilityHidden(isSessionUnlocked)

            unlockedState
                .opacity(isSessionUnlocked ? 1 : 0)
                .allowsHitTesting(isSessionUnlocked)
                .accessibilityHidden(!isSessionUnlocked)
        }
        .animation(SettingsMetrics.stateTransitionAnimation, value: isSessionUnlocked)
        .onAppear { pocController.refreshCredentialStatus() }
        // Password/name/enrollment flows run in the notch, outside this
        // window, so nothing else prompts a re-check once one closes.
        .onChange(of: NotchOverlayController.shared.phase) { _, newPhase in
            guard newPhase == .closed else { return }
            pocController.refreshCredentialStatus()
        }
    }

    // MARK: - Locked

    private var lockedState: some View {
        SettingsEmptyStateView(
            icon: "lock.fill",
            message: "Сеанс заблокирован",
            buttonTitle: isUnlocking ? "Проверка…" : "Разблокировать сеанс",
            isButtonEnabled: !isUnlocking,
            caption: sessionError,
            action: unlock
        )
    }

    // MARK: - Unlocked

    private var unlockedState: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup {
                SettingsOptionSliderRowContent(
                    title: "Точность совпадения",
                    stepLabels: MatchConfidenceLevel.allCases.map(\.title),
                    index: matchConfidenceIndex,
                    stopCount: MatchConfidenceLevel.allCases.count
                )

                SettingsGroupDivider()

                SettingsOptionSliderRowContent(
                    title: "Дистанция распознавания",
                    stepLabels: DetectionDistanceLevel.allCases.map(\.title),
                    index: detectionDistanceIndex,
                    stopCount: DetectionDistanceLevel.allCases.count
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionTitle(text: "Проверка живости")
                SettingsGroup {
                    SettingsRowContent(
                        title: "Проверка живого лица",
                        subtitle: "Проверяет, что перед камерой живой человек, а не фото. Может замедлить разблокировку.",
                        subtitleMaxWidth: SettingsMetrics.rowSubtitleMaxWidth
                    ) {
                        GlanceToggle(isOn: $settings.livenessChecksEnabled)
                    }
                    SettingsGroupDivider()
                    LivenessModePicker(
                        selection: $settings.livenessMode,
                        isEnabled: settings.livenessChecksEnabled
                    )
                }
            }
        }
    }

    // MARK: - Match confidence

    /// Nearest of the three snap points to whatever's stored, in case the
    /// value doesn't land exactly on one of the stops.
    private var matchConfidenceLevel: MatchConfidenceLevel {
        .nearest(to: coordinator.matchThreshold)
    }

    private var matchConfidenceIndex: Binding<Double> {
        Binding(
            get: { matchConfidenceLevel.sliderIndex },
            set: { coordinator.matchThreshold = MatchConfidenceLevel.from(sliderIndex: $0).threshold }
        )
    }

    // MARK: - Detection distance

    private var detectionDistanceLevel: DetectionDistanceLevel {
        .nearest(to: settings.minimumFaceWidth)
    }

    private var detectionDistanceIndex: Binding<Double> {
        Binding(
            get: { detectionDistanceLevel.sliderIndex },
            set: { settings.minimumFaceWidth = DetectionDistanceLevel.from(sliderIndex: $0).minimumFaceWidth }
        )
    }

    // MARK: - Actions

    private func unlock() {
        isUnlocking = true
        sessionError = nil
        Task {
            await pocController.unlockSession()
            sessionError = pocController.sessionError
            isUnlocking = false
        }
    }
}

/// The three selectable points on the "Match confidence" slider — named
/// rather than exposing the raw cosine-similarity threshold directly.
private enum MatchConfidenceLevel: Int, CaseIterable {
    case lessStrict, standard, moreStrict

    var title: String {
        switch self {
        case .lessStrict: return "Мягче"
        case .standard: return "По умолчанию"
        case .moreStrict: return "Строже"
        }
    }

    var threshold: Float {
        switch self {
        case .lessStrict: return 0.58
        case .standard: return 0.66   // Face ID for Mac: matches the stored default (Glance showed 0.63 here)
        case .moreStrict: return 0.68
        }
    }

    /// Position in `allCases` — same role as `AutoLockInterval.sliderIndex`.
    var sliderIndex: Double {
        Double(Self.allCases.firstIndex(of: self) ?? 0)
    }

    static func from(sliderIndex: Double) -> Self {
        let clamped = Int(sliderIndex.rounded())
        return allCases.indices.contains(clamped) ? allCases[clamped] : .standard
    }

    static func nearest(to threshold: Float) -> Self {
        allCases.min { abs($0.threshold - threshold) < abs($1.threshold - threshold) } ?? .standard
    }
}

/// The three selectable points on the "Detection distance" slider.
private enum DetectionDistanceLevel: Int, CaseIterable {
    case close, standard, far

    var title: String {
        switch self {
        case .close: return "Близко"
        case .standard: return "По умолчанию"
        case .far: return "Далеко"
        }
    }

    var minimumFaceWidth: Float {
        switch self {
        case .close: return 0.23
        case .standard: return 0.19
        case .far: return 0.15
        }
    }

    var sliderIndex: Double {
        Double(Self.allCases.firstIndex(of: self) ?? 0)
    }

    static func from(sliderIndex: Double) -> Self {
        let clamped = Int(sliderIndex.rounded())
        return allCases.indices.contains(clamped) ? allCases[clamped] : .standard
    }

    static func nearest(to width: Float) -> Self {
        allCases.min { abs($0.minimumFaceWidth - width) < abs($1.minimumFaceWidth - width) } ?? .standard
    }
}
