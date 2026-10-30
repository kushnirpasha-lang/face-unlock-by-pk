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
import AVFoundation

@Observable
@MainActor
final class FaceUnlockCoordinator {
    private let pocController: POCController
    let lockMonitor = LockMonitor()
    let camera = CameraManager()
    let pipeline = FaceRecognitionPipeline()
    let input = InputActivityMonitor()
    let unlockSignal = UnlockSignal()

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

    /// Per-scan numbers (no images, no embeddings) — shown after a self-test and written to the journal, so a failing
    /// scan says WHY: never matched, matched but liveness never confirmed, frames thrown away, …
    struct ScanStats {
        var frames = 0, noFace = 0, tooFar = 0, partial = 0, turned = 0, lowQuality = 0, multiFace = 0
        var used = 0, matchedFrames = 0, denyCues = 0
        var bestSimilarity: Float = -1
        var livenessConfirmed = false

        var summary: String {
            let sim = bestSimilarity < 0 ? "—" : String(format: "%.2f", bestSimilarity)
            return "кадров \(frames): годных \(used), без лица \(noFace), далеко \(tooFar), неполное \(partial), повёрнуто \(turned), темно/смазано \(lowQuality), 2+ лица \(multiFace); совпадений \(matchedFrames), лучшее сходство \(sim); живое лицо: \(livenessConfirmed ? "да" : "нет"), признаков подделки \(denyCues)"
        }
    }
    private(set) var lastScanStats = ScanStats()

    private(set) var statusMessage = "Ожидание"
    /// Self-test from the settings window: the camera looks, the result is shown — nothing is typed, the Mac isn't touched.
    private(set) var selfTestRunning = false
    private(set) var selfTestResult: String?
    private(set) var selfTestPassed: Bool?
    private(set) var lastOutcome: String?

    // MARK: Policy state
    private(set) var policy: UnlockPolicy
    private static let stickyURL = SecretVault.directory.appendingPathComponent("state.json")
    static let killSwitchURL = SecretVault.directory.appendingPathComponent("OFF")

    private var scanTask: Task<Void, Never>?
    private var wakeAt: Date?
    private var scanStartedAt: Date?

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
        // Owner 13.10: the screen often wakes by itself (a notification), the camera finds nobody, and when he walks up
        // later and taps the trackpad nothing happens — the screen is already awake, so there is no new wake event.
        // A click or a finger on the trackpad on the lock screen now starts a scan too (no attempt is spent if no face).
        input.onPointerDown = { [weak self] in
            Task { @MainActor [weak self] in self?.handlePointerTrigger() }
        }
        input.start()
        if !input.isAlive {
            EventLog.shared.add("мониторинг ввода", "нет разрешения — ввод пароля запрещён, пока его не дадут")
        }
        observeLockAndWakeEvents()
        startStatusFile()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)   // let login settle before the Touch ID sheet
            self?.promptVaultIfNeeded(reason: "после запуска")
            // The camera prompt can't appear on the lock screen — ask now, while the owner is at the desktop (18.10).
            if GlanceSettings.shared.hasCompletedOnboarding,
               AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                EventLog.shared.add("камера", granted ? "доступ разрешён" : "доступ не дан")
                self?.writeStatusFile()
            }
        }
        NotificationCenter.default.addObserver(forName: .secureCredentialPasswordSaved, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.passwordWasSaved() }
        }
    }

    // MARK: - Status file (for remote support: one glance says what's missing)

    private var statusTimer: Timer?
    private var vaultPromptInFlight = false

    private func startStatusFile() {
        writeStatusFile()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeStatusFile() }
        }
    }

    func writeStatusFile() {
        let camera: String
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: camera = "granted"
        case .denied: camera = "denied"
        case .restricted: camera = "restricted"
        case .notDetermined: camera = "not-asked"
        @unknown default: camera = "unknown"
        }
        let status: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "version": AppVersion.display,
            "enabled": isEnabled,
            "killSwitch": killSwitchPresent,
            "vaultOpen": SecureCredentialManager.isSessionUnlocked,
            "vaultBackend": SecureCredentialManager.vaultBackend?.rawValue ?? "none",
            "passwordStored": SecureCredentialManager.hasStoredPassword(),
            "facesEnrolled": FaceEnrollmentStore.shared.activeIdentities.count,
            "camera": camera,
            "accessibility": AXIsProcessTrusted(),
            "inputMonitoring": input.isAlive,
            "screenLocked": policy.isLocked,
            "pause": policy.pause?.rawValue ?? "none",
            "attemptsLeft": policy.attemptsLeft,
            "liveness": GlanceSettings.shared.livenessMode.rawValue,
            "scanSeconds": GlanceSettings.shared.faceDetectionSeconds,
        ]
        let url = SecretVault.directory.appendingPathComponent("status.json")
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// After a reboot the vault is closed until Touch ID; without it face unlock is silently dead (owner, 18.10).
    /// Ask once — right after launch and after every unlock while it's still closed — with the system Touch ID sheet.
    func promptVaultIfNeeded(reason: String) {
        guard !vaultPromptInFlight, !SecureCredentialManager.isSessionUnlocked,
              SecureCredentialManager.hasStoredPassword(), GlanceSettings.shared.hasCompletedOnboarding,
              !(SessionFacts.currentOrNil()?.screenLocked ?? true) else { return }
        vaultPromptInFlight = true
        EventLog.shared.add("хранилище", "прошу Touch ID: \(reason)")
        Task { [weak self] in
            let ok: Bool = await Task.detached(priority: .userInitiated) {
                (try? SecureCredentialManager.unlockSession(reason: "включить вход лицом (\(reason))")) != nil
            }.value
            guard let self else { return }
            self.vaultPromptInFlight = false
            EventLog.shared.add("хранилище", ok ? "открыто — вход лицом готов" : "Touch ID не подтверждён — вход лицом выключен до подтверждения")
            self.writeStatusFile()
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
                if event == .willSleep { self.cancelScan() }
                if event == .wake { self.wakeAt = Date() }
                // Brief settle: CGSession can lag the true state right after wake — wait up to 2 s for "locked"
                // instead of a fixed 300 ms, or the wake is refused as notLocked without a trace (30.10 audit).
                try? await Task.sleep(nanoseconds: 300_000_000)
                if event == .wake {
                    for _ in 0..<9 where !(SessionFacts.currentOrNil()?.screenLocked ?? false) {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                }
                self.syncLockState()
                // Only a wake starts a scan by itself. A lock never does (A1).
                if event == .wake { self.handle(trigger: .wake) }
            }
        }
    }

    /// Every event re-derives the lock state from CGSession (A2): a lost notification can't wedge the policy.
    private func syncLockState() {
        // No CGSession dictionary → observe nothing (don't fake an unlock that would reset the attempt counter).
        guard let locked = SessionFacts.currentOrNil()?.screenLocked else { return }
        let wasLocked = policy.isLocked
        policy.observe(screenLocked: locked)
        if locked, !wasLocked {
            unlockSignal.lockObserved()
            EventLog.shared.add("блокировка", "попыток: \(policy.attemptsLeft)")
        } else if !locked, wasLocked {
            cancelScan()
            EventLog.shared.add("разблокировано", "")
            promptVaultIfNeeded(reason: "после входа")
        }
    }

    private var lastScanEndedAt: Date?
    private var lastPointerTriggerAt: Date?

    private func handlePointerTrigger() {
        let now = Date()
        // A resting or moving finger fires many events: at most one try per 2 s, and not right after a scan ended.
        if let last = lastPointerTriggerAt, now.timeIntervalSince(last) < 2 { return }
        lastPointerTriggerAt = now
        if let ended = lastScanEndedAt, now.timeIntervalSince(ended) < 2 { return }
        guard policy.isLocked || (SessionFacts.currentOrNil()?.screenLocked ?? false) else { return }
        handle(trigger: .hover)
    }

    private func handle(trigger: ScanTrigger) {
        syncLockState()
        guard !selfTestRunning else { return }   // the camera is busy with the self-test
        let env = ScanEnvironment(
            isEnabled: isEnabled,
            killSwitchPresent: killSwitchPresent,
            isSleeping: lockMonitor.isSleeping,
            vaultOpen: SecureCredentialManager.isSessionUnlocked,
            hasStoredPassword: SecureCredentialManager.hasStoredPassword(),
            hasEnrolledFace: !FaceEnrollmentStore.shared.activeIdentities.isEmpty
        )
        switch policy.requestScan(trigger, env: env, now: Date()) {
        case .refuse(let reason) where trigger == .wake && policy.isLocked:
            EventLog.shared.add("пробуждение", "скан не запущен: \(reason.rawValue)")
            statusMessage = "Скан не запущен: \(reason.rawValue)"
        case .refuse(let reason) where trigger == .wake:
            EventLog.shared.add("пробуждение", "скан не запущен: \(reason.rawValue)")
            statusMessage = "Скан не запущен: \(reason.rawValue)"
        case .refuse(let reason):
            if reason != .notLocked, reason != .wakeBurst, reason != .scanInProgress {
                EventLog.shared.add("скан не запущен", "\(trigger.rawValue): \(reason.rawValue)")
            }
            statusMessage = "Скан не запущен: \(reason.rawValue)"
        case .start(let generation):
            scanStartedAt = Date()
            EventLog.shared.add("скан", "\(trigger.rawValue), попыток осталось \(policy.attemptsLeft), камера: \(CameraDeviceCatalog.resolvedDevice()?.localizedName ?? "нет")")
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

        let result = await observeScanWindow(deadline: Date().addingTimeInterval(scanWindowDuration), requireLocked: true)
        camera.stop()
        lastScanEndedAt = Date()
        let elapsed = String(format: "%.1f с", Date().timeIntervalSince(started))

        let next = policy.finishScan(generation: generation, result: result)
        if showsUI { NotchOverlayController.shared.finish(success: result == .matched) }
        if result != .cancelled {
            EventLog.shared.add("итог скана", "\(result.rawValue) за \(elapsed); попыток осталось \(policy.attemptsLeft); \(lastScanStats.summary)")
        }
        if policy.pause == .attemptsExhausted, result.countsAsAttempt {
            EventLog.shared.add("пауза", "\(policy.maxAttempts) неудачи — только палец или пароль до разблокировки")
            PauseNotifier.pauseStarted(.attemptsExhausted)
        }
        if next == .inject { await injectPassword() }
    }

    /// Recognition and liveness run concurrently; the unlock fires only when both agree.
    private func observeScanWindow(deadline: Date, requireLocked: Bool) async -> ScanResult {
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
        var stats = ScanStats()
        defer { lastScanStats = stats }

        while Date() < deadline, !Task.isCancelled {
            if requireLocked, !SessionFacts.current().screenLocked { return .cancelled }

            guard let frame = camera.currentFrame, frame.id != lastProcessedFrameID else {
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            lastProcessedFrameID = frame.id

            let pipeline = self.pipeline
            let previousBoundingBox = lastFaceBoundingBox
            let attempt = await Task.detached(priority: .userInitiated) { () -> (FaceRecognitionResult, LivenessFrame)?? in
                do {
                    let result = try pipeline.recognize(in: frame.image, preferNear: previousBoundingBox)
                    let faceCrop = CameraManager.renderCrop(from: frame, imageRect: result.face.boundingBox)
                    return .some((result, LivenessFeatureExtractor.extract(from: result, frame: frame.image, faceCrop: faceCrop)))
                } catch FaceRecognitionPipelineError.faceTooSmall {
                    return .some(nil)          // a face, but too far
                } catch {
                    return nil                 // no face at all
                }
            }.value

            stats.frames += 1
            let outcome: (FaceRecognitionResult, LivenessFrame)? = attempt ?? nil
            guard let (result, livenessFrame) = outcome else {
                if case .some(.none) = attempt { stats.tooFar += 1 } else { stats.noFace += 1 }
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
                stats.used += 1
            case .refuseMultipleFaces:
                sawUsableFace = true
                stats.multiFace += 1
                readyMatch = nil
                lastOutcome = "В кадре больше одного лица"
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            case .skip(let why):
                switch why {
                case .noFace: stats.noFace += 1
                case .partialFace: stats.partial += 1
                case .turnedAway: stats.turned += 1
                case .lowQuality: stats.lowQuality += 1
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }

            if livenessEnabled {
                let snapshot = liveness.observe(livenessFrame)
                switch snapshot.decision {
                case .denied:
                    stats.denyCues += 1
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
                    stats.livenessConfirmed = true
                    livenessConfirmed = true
                    if let since = denySince, Date().timeIntervalSince(since) >= spoofSustain { denySince = nil }
                case .pending:
                    if let since = denySince, Date().timeIntervalSince(since) >= spoofSustain { denySince = nil }
                }
            }

            let scored = pipeline.score(result.embedding, against: FaceEnrollmentStore.shared.activeIdentities)
            if let top = scored.map({ min($0.centroidSimilarity, $0.maxSampleSimilarity) }).max() {
                stats.bestSimilarity = max(stats.bestSimilarity, top)
            }
            if let matched = pipeline.bestMatch(in: scored, threshold: matchThreshold) {
                stats.matchedFrames += 1
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

    // MARK: - Self-test

    /// «Проверить сканер»: the same recognition + liveness + frame-quality path as a real unlock, but only while the
    /// Mac is unlocked, and it never types anything.
    func runSelfTest() async {
        guard !selfTestRunning, scanTask == nil else { return }
        guard !(SessionFacts.currentOrNil()?.screenLocked ?? true) else { return }
        guard SecureCredentialManager.isSessionUnlocked else {
            selfTestPassed = false
            selfTestResult = "Сначала подтвердите Touch ID: вкладка «Пароль» → разблокировать."
            return
        }
        guard !FaceEnrollmentStore.shared.activeIdentities.isEmpty else {
            selfTestPassed = false
            selfTestResult = "Лицо ещё не записано — вкладка «Лицо»."
            return
        }
        selfTestRunning = true
        selfTestPassed = nil
        selfTestResult = "Смотрите в камеру…"
        lastOutcome = nil
        let started = Date()
        await camera.start()
        if let error = camera.errorMessage {
            camera.stop()
            selfTestRunning = false
            selfTestPassed = false
            selfTestResult = "Камера: \(error)"
            return
        }
        let result = await observeScanWindow(deadline: Date().addingTimeInterval(scanWindowDuration), requireLocked: false)
        camera.stop()
        selfTestRunning = false
        let secs = String(format: "%.1f", Date().timeIntervalSince(started))
        switch result {
        case .matched:
            selfTestPassed = true
            selfTestResult = "✅ Узнал вас за \(secs) с. \(lastOutcome ?? "")"
        case .wrongFace:
            selfTestPassed = false
            selfTestResult = "❌ Лицо в кадре не совпало с записанным. Попробуйте при лучшем свете или перезапишите лицо."
        case .spoof:
            selfTestPassed = false
            selfTestResult = "❌ Не подтвердил, что лицо живое (\(lastOutcome ?? "блик/экран")). Уберите блики, попробуйте ещё раз."
        case .unconfirmed:
            selfTestPassed = false
            selfTestResult = "⚠️ Лицо видно, но подтвердить не успел за \(secs) с. В строгом режиме моргните или слегка поверните голову."
        case .noFace:
            selfTestPassed = false
            selfTestResult = "⚠️ Не увидел лица. Сядьте прямо перед камерой, 30–70 см."
        case .cancelled:
            selfTestPassed = nil
            selfTestResult = "Проверка прервана."
        }
        selfTestResult = (selfTestResult ?? "") + "\n\(lastScanStats.summary). Порог сходства \(String(format: "%.2f", matchThreshold))."
        EventLog.shared.add("проверка сканера", "\(result.rawValue) за \(secs) с; \(lastScanStats.summary)")
    }

    // MARK: - Injection

    private func injectPassword() async {
        guard let scanStartedAt else { policy.injectionFinished(.refused); return }
        statusMessage = "Узнал — ввожу пароль…"
        let wakeAt = self.wakeAt
        let input = self.input
        let paused = policy.pause != nil
        let unlockSignal = self.unlockSignal
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
                    unlockNotifiedSinceLock: unlockSignal.unlockedSinceLock,   // fresh on every call
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
            } else if unlockSignal.unlockedSinceLock {
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
            policy.injectionFinished(.refused)
            EventLog.shared.add("ввод отменён", "до текста: \(d.rawValue)")
        case .stoppedBeforeReturn(let d):
            policy.injectionFinished(.aborted)
            EventLog.shared.add("ввод остановлен", "перед Return: \(d.rawValue) — пароль остался в поле")
        case .failed(let m):
            policy.injectionFinished(.refused)
            EventLog.shared.add("ввод не удался", m)
        }
        syncLockState()
    }

    private func persistSticky() {
        try? StickyState(stickyPause: policy.stickyPause).save(to: Self.stickyURL)
    }
}
