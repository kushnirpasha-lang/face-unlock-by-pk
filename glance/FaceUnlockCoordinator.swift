//
//  FaceUnlockCoordinator.swift
//  Face ID for Mac (by PK) — based on Glance
//
//  Connects the camera and face recognition to the unlock path. In this fork the coordinator DECIDES NOTHING on its
//  own: every "may the camera start?", "does this count as a failed attempt?" and "may the password be typed now?"
//  goes to the pure, unit-tested core (glance/Core: UnlockPolicy, InjectionGuard, FrameQualityGate).
//
//  Hard rule from the owner: Touch ID and the keyboard keep working at every moment. Nothing here touches the system
//  login path or intercepts input; if this object misbehaves or the app dies, the lock screen is exactly macOS's own.
//
//  Known limitation: liveness defeats a printed photo and a phone screen, but not reliably a replayed video.
//

import Foundation
import CoreGraphics
import Observation
import ApplicationServices

@Observable
@MainActor
final class FaceUnlockCoordinator {
    private let pocController: POCController
    let lockMonitor = LockMonitor()
    let camera = CameraManager()
    let pipeline = FaceRecognitionPipeline()
    let input = InputActivityMonitor()

    /// Persisted. Switching off cancels any in-flight scan immediately.
    var isEnabled: Bool {
        didSet {
            GlanceSettings.shared.isFaceUnlockEnabled = isEnabled
            if !isEnabled { cancelScan() }
            EventLog.shared.add(isEnabled ? "включено" : "выключено", "")
        }
    }

    /// Kept independent from Face Lab's own `threshold` so tuning the debug tool never silently changes the real gate.
    var matchThreshold: Float {
        didSet { GlanceSettings.shared.matchThreshold = matchThreshold }
    }

    private var scanWindowDuration: TimeInterval { TimeInterval(GlanceSettings.shared.faceDetectionSeconds) }
    /// A wake often catches the owner still looking away — only a sustained non-match is a failure.
    private let wrongFaceGraceDuration: Duration = .seconds(2)
    /// A single glare frame (glasses) is not a spoof; a deny cue must persist this long to count (A13).
    private let spoofSustain: TimeInterval = 1

    private(set) var statusMessage = "Ожидание"
    private(set) var lastOutcome: String?

    // MARK: Policy state
    private(set) var policy: UnlockPolicy
    private static let stickyURL = SecretVault.directory.appendingPathComponent("state.json")
    static let killSwitchURL = SecretVault.directory.appendingPathComponent("OFF")

    private var scanTask: Task<Void, Never>?
    private var wakeAt: Date?
    private var scanStartedAt: Date?
    /// The unlock notification arrived since the last observed lock — CGSession can lag after Touch ID (A8).
    private var unlockNotifiedSinceLock = false

    private var showsUI: Bool { GlanceSettings.shared.showUnlockAnimation }

    init(pocController: POCController) {
        self.pocController = pocController
        self.isEnabled = GlanceSettings.shared.isFaceUnlockEnabled
        self.matchThreshold = GlanceSettings.shared.matchThreshold
        let sticky = StickyState.load(from: Self.stickyURL)
        var policy = UnlockPolicy(maxAttempts: GlanceSettings.shared.maxFailedAttempts, stickyPause: sticky.stickyPause)
        policy.launched(screenLocked: SessionFacts.current().screenLocked)
        self.policy = policy
        if policy.pause == .startedWhileLocked {
            EventLog.shared.add("запуск", "экран уже заблокирован — жду входа пальцем или паролем")
        }
        input.onSpace = { [weak self] in
            Task { @MainActor [weak self] in self?.handle(trigger: .space) }
        }
        input.start()
        if !input.isAlive {
            EventLog.shared.add("мониторинг ввода", "нет разрешения — ввод пароля запрещён, пока его не дадут")
        }
        observeLockAndWakeEvents()
        NotificationCenter.default.addObserver(forName: .secureCredentialPasswordSaved, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.passwordWasSaved() }
        }
    }

    // MARK: - Status for the settings window

    var pauseReason: PauseReason? { policy.pause }
    var attemptsLeft: Int { policy.attemptsLeft }
    var killSwitchPresent: Bool { FileManager.default.fileExists(atPath: Self.killSwitchURL.path) }
    var inputMonitorAlive: Bool { input.isAlive }

    /// The owner saved the password again in Settings — lifts a sticky pause (A4).
    func passwordWasSaved() {
        policy.passwordSaved()
        persistSticky()
        EventLog.shared.add("пароль обновлён", "пауза снята")
    }

    func applyMaxAttempts(_ value: Int) {
        policy.maxAttempts = max(1, min(5, value))
    }

    func retryInputMonitor() {
        input.stop()
        input.start()
    }

    // MARK: - Events

    /// Re-subscribes on every change — `withObservationTracking` only fires once per registration.
    private func observeLockAndWakeEvents() {
        withObservationTracking {
            _ = lockMonitor.isScreenLocked
            _ = lockMonitor.wakeEventCount
            _ = lockMonitor.isSleeping
            _ = lockMonitor.eventCount
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeLockAndWakeEvents()
                let event = self.lockMonitor.lastEvent
                if event == .screenUnlocked { self.unlockNotifiedSinceLock = true }
                if event == .willSleep { self.cancelScan() }
                if event == .wake { self.wakeAt = Date() }
                // Brief settle: CGSession can lag the true state right after wake.
                try? await Task.sleep(nanoseconds: 300_000_000)
                self.syncLockState()
                // Only a wake starts a scan by itself. A lock never does (A1).
                if event == .wake { self.handle(trigger: .wake) }
            }
        }
    }

    /// Every event re-derives the lock state from CGSession (A2): a lost notification can't wedge the policy.
    private func syncLockState() {
        let locked = SessionFacts.current().screenLocked
        let wasLocked = policy.isLocked
        policy.observe(screenLocked: locked)
        if locked, !wasLocked {
            unlockNotifiedSinceLock = false
            EventLog.shared.add("блокировка", "попыток: \(policy.attemptsLeft)")
        } else if !locked, wasLocked {
            cancelScan()
            EventLog.shared.add("разблокировано", "")
        }
    }

    private func handle(trigger: ScanTrigger) {
        syncLockState()
        let env = ScanEnvironment(
            isEnabled: isEnabled,
            killSwitchPresent: killSwitchPresent,
            isSleeping: lockMonitor.isSleeping,
            vaultOpen: SecureCredentialManager.isSessionUnlocked,
            hasStoredPassword: SecureCredentialManager.hasStoredPassword(),
            hasEnrolledFace: !FaceEnrollmentStore.shared.activeIdentities.isEmpty
        )
        switch policy.requestScan(trigger, env: env, now: Date()) {
        case .refuse(let reason):
            if reason != .notLocked, reason != .wakeBurst, reason != .scanInProgress {
                EventLog.shared.add("скан не запущен", "\(trigger.rawValue): \(reason.rawValue)")
            }
            statusMessage = "Скан не запущен: \(reason.rawValue)"
        case .start(let generation):
            scanStartedAt = Date()
            EventLog.shared.add("скан", "\(trigger.rawValue), попыток осталось \(policy.attemptsLeft)")
            scanTask = Task { [weak self] in await self?.runScan(generation: generation) }
        }
    }

    private func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        policy.cancelScan()
        camera.stop()
        if showsUI { NotchOverlayController.shared.disarm() }
    }

    // MARK: - Scan

    private func runScan(generation: Int) async {
        let started = Date()
        await camera.start()
        guard policy.activeScan == generation else { camera.stop(); return }
        if let error = camera.errorMessage {
            statusMessage = error
            camera.stop()
            EventLog.shared.add("камера", error)
            _ = policy.finishScan(generation: generation, result: .cancelled)
            return
        }
        if showsUI { NotchOverlayController.shared.beginScanning() }
        statusMessage = "Ищу лицо…"

        let result = await observeScanWindow(deadline: Date().addingTimeInterval(scanWindowDuration))
        camera.stop()
        let elapsed = String(format: "%.1f с", Date().timeIntervalSince(started))

        let next = policy.finishScan(generation: generation, result: result)
        if showsUI { NotchOverlayController.shared.finish(success: result == .matched) }
        if result != .cancelled {
            EventLog.shared.add("итог скана", "\(result.rawValue) за \(elapsed); попыток осталось \(policy.attemptsLeft)")
        }
        if policy.pause == .attemptsExhausted, result.countsAsAttempt {
            EventLog.shared.add("пауза", "\(policy.maxAttempts) неудачи — только палец или пароль до разблокировки")
            PauseNotifier.pauseStarted(.attemptsExhausted)
        }
        if next == .inject { await injectPassword() }
    }

    /// Recognition and liveness run concurrently; the unlock fires only when both agree.
    private func observeScanWindow(deadline: Date) async -> ScanResult {
        let livenessEnabled = GlanceSettings.shared.livenessChecksEnabled
        var liveness = LivenessAnalyzer()
        liveness.modeProvider = { GlanceSettings.shared.livenessMode }
        var wrongFaceStartedAt: ContinuousClock.Instant?
        var denySince: Date?
        var readyMatch: ScoredIdentity?
        var livenessConfirmed = !livenessEnabled
        var lastFaceBoundingBox: CGRect?
        var lastProcessedFrameID: UInt64?
        var sawUsableFace = false

        while Date() < deadline, !Task.isCancelled {
            guard SessionFacts.current().screenLocked else { return .cancelled }

            guard let frame = camera.currentFrame, frame.id != lastProcessedFrameID else {
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            lastProcessedFrameID = frame.id

            let pipeline = self.pipeline
            let previousBoundingBox = lastFaceBoundingBox
            let outcome = await Task.detached(priority: .userInitiated) { () -> (FaceRecognitionResult, LivenessFrame)? in
                guard let result = try? pipeline.recognize(in: frame.image, preferNear: previousBoundingBox) else { return nil }
                let faceCrop = CameraManager.renderCrop(from: frame, imageRect: result.face.boundingBox)
                return (result, LivenessFeatureExtractor.extract(from: result, frame: frame.image, faceCrop: faceCrop))
            }.value

            guard let (result, livenessFrame) = outcome else {
                wrongFaceStartedAt = nil
                lastFaceBoundingBox = nil
                readyMatch = nil
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            lastFaceBoundingBox = result.face.normalizedBoundingBox

            // Frame quality gate (G7): two people → never unlock on this frame; partial / turned / dark → not evaluated.
            let facts = FrameFacts(
                sizableFaceCount: result.prominentFaceCount,
                hasFullLandmarks: result.alignmentTier == .fivePoint,
                yaw: result.face.yaw,
                pitch: result.face.pitch,
                quality: result.face.quality
            )
            switch FrameQualityGate.evaluate(facts) {
            case .use:
                sawUsableFace = true
            case .refuseMultipleFaces:
                sawUsableFace = true
                readyMatch = nil
                lastOutcome = "В кадре больше одного лица"
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            case .skip:
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }

            if livenessEnabled {
                let snapshot = liveness.observe(livenessFrame)
                switch snapshot.decision {
                case .denied:
                    // One glare frame is not a spoof (A13): restart the analyzer and require the deny to persist.
                    let now = Date()
                    if let since = denySince, now.timeIntervalSince(since) >= spoofSustain {
                        lastOutcome = snapshot.decision.denialReason
                        return .spoof
                    }
                    if denySince == nil { denySince = now }
                    liveness = LivenessAnalyzer()
                    liveness.modeProvider = { GlanceSettings.shared.livenessMode }
                    livenessConfirmed = false
                    readyMatch = nil
                case .confirmed:
                    livenessConfirmed = true
                    if let since = denySince, Date().timeIntervalSince(since) >= spoofSustain { denySince = nil }
                case .pending:
                    if let since = denySince, Date().timeIntervalSince(since) >= spoofSustain { denySince = nil }
                }
            }

            let scored = pipeline.score(result.embedding, against: FaceEnrollmentStore.shared.activeIdentities)
            if let matched = pipeline.bestMatch(in: scored, threshold: matchThreshold) {
                wrongFaceStartedAt = nil
                readyMatch = matched
            } else {
                readyMatch = nil
                if wrongFaceStartedAt == nil { wrongFaceStartedAt = .now }
                if ContinuousClock.now - wrongFaceStartedAt! >= wrongFaceGraceDuration {
                    return .wrongFace
                }
            }

            // Never unlock while a recent deny cue is still being watched.
            if let readyMatch, livenessConfirmed, denySince == nil {
                lastOutcome = "Узнал: \(readyMatch.identity.name) (\(String(format: "%.3f", readyMatch.centroidSimilarity)))"
                return .matched
            }

            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if Task.isCancelled { return .cancelled }
        return sawUsableFace ? .unconfirmed : .noFace
    }

    // MARK: - Injection

    private func injectPassword() async {
        guard let scanStartedAt else { return }
        statusMessage = "Узнал — ввожу пароль…"
        let wakeAt = self.wakeAt
        let input = self.input
        let paused = policy.pause != nil
        let unlockFlag = unlockNotifiedSinceLock
        let killURL = Self.killSwitchURL

        let outcome: (TyperOutcome, Bool) = await Task.detached(priority: .userInitiated) {
            guard var password = try? SecureCredentialManager.readPassword() else {
                return (.failed("нет доступа к паролю"), false)
            }
            defer { password.resetBytes(in: 0..<password.count) }
            let typed = PasswordTyper.type(password) { typingStartedAt in
                let session = SessionFacts.current()
                return GuardSnapshot(
                    cgSessionLocked: session.screenLocked,
                    unlockNotifiedSinceLock: unlockFlag,
                    sessionOnConsole: session.onConsole,
                    consoleUserIsMe: session.userIsMe,
                    inputMonitorAlive: input.isAlive,
                    accessibilityTrusted: AXIsProcessTrusted(),
                    killSwitchPresent: FileManager.default.fileExists(atPath: killURL.path),
                    paused: paused,
                    lastKeyDown: input.lastKeyDown,
                    lastPointerDown: input.lastPointerDown,
                    wakeAt: wakeAt,
                    scanStartedAt: scanStartedAt,
                    typingStartedAt: typingStartedAt
                )
            }
            guard typed == .sent else { return (typed, false) }
            return (typed, SessionFacts.waitForUnlock(timeout: 3))
        }.value

        switch outcome.0 {
        case .sent:
            if outcome.1 {
                policy.injectionFinished(.unlocked)
                EventLog.shared.add("вход лицом", "успех")
                statusMessage = "Открыто лицом"
            } else if unlockNotifiedSinceLock {
                // Touch ID / keyboard won the race while we were typing.
                policy.injectionFinished(.unlocked)
                EventLog.shared.add("вход", "открыто другим способом во время ввода")
            } else {
                policy.injectionFinished(.notUnlocked)
                persistSticky()
                EventLog.shared.add("пауза", "пароль не подошёл — обновите пароль в настройках")
                PauseNotifier.pauseStarted(.injectionFailed)
                statusMessage = "Пароль не подошёл"
            }
        case .refusedBeforeText(let d):
            EventLog.shared.add("ввод отменён", "до текста: \(d.rawValue)")
        case .stoppedBeforeReturn(let d):
            policy.injectionFinished(.aborted)
            EventLog.shared.add("ввод остановлен", "перед Return: \(d.rawValue) — пароль остался в поле")
        case .failed(let m):
            EventLog.shared.add("ввод не удался", m)
        }
        syncLockState()
    }

    private func persistSticky() {
        try? StickyState(stickyPause: policy.stickyPause).save(to: Self.stickyURL)
    }
}
