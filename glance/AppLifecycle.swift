//
//  AppLifecycle.swift
//  Face ID for Mac (by PK)
//
//  Three small things that keep exactly one copy of the app doing exactly one thing:
//
//  1. Single instance (W1). A second copy (Launchpad after ⌘Q, a copy on the DMG, launchd starting the agent while
//     the owner already opened the app) would mean two cameras and the password typed twice → a failed login.
//     An exclusive `flock` on a file decides; the loser asks the winner to show its window and exits(0).
//  2. Must live in /Applications. Started from the DMG or Downloads, it explains and quits instead of installing
//     background pieces that point at a file that will disappear.
//  3. LaunchAgent (V3). Written by the app itself on first launch from /Applications, so a manual drag-install is
//     complete. KeepAlive only on a crash. If the app is deleted without uninstall.sh, launchd fails once per login
//     to start a missing file — harmless; uninstall.sh removes the plist.
//

import AppKit
import Darwin

@MainActor
enum AppLifecycle {
    static let label = "com.pavel.faceidformac"
    static let showSettingsNotification = Notification.Name("com.pavel.faceidformac.showSettings")
    private static var lockFD: Int32 = -1

    /// Returns false if another instance is already running (this one should exit).
    static func acquireSingleInstance() -> Bool {
        let url = SecretVault.directory.appendingPathComponent(".instance.lock")
        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true }   // can't even create the file: don't block the app on that
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        lockFD = fd   // held (and the lock with it) for the life of the process
        return true
    }

    static var launchedByLaunchd: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label
    }

    static var isInApplications: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    static func explainWrongLocationAndQuit() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Перетащите Face ID for Mac в «Программы»"
        alert.informativeText = "Программа работает только из папки «Программы». Перетащите её туда из этого окна и откройте оттуда.\n\nby PK"
        alert.addButton(withTitle: "Понятно")
        alert.runModal()
        exit(0)
    }

    // MARK: LaunchAgent

    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func ensureLaunchAgent() {
        guard isInApplications, let executable = Bundle.main.executablePath else { return }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            // Only a crash brings it back. A clean exit (⌘Q, or a second copy stepping aside) stays exited —
            // PathState/SuccessfulExit would make launchd respawn the loser every 10 s (review finding 3).
            "KeepAlive": ["Crashed": true],
            "ThrottleInterval": 10,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
        if let existing = try? Data(contentsOf: agentURL), existing == data { return }
        try? FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: agentURL, options: .atomic)) != nil else { return }
        // Started by launchd itself: never boot out our own label (that would SIGTERM this very process). The new
        // plist takes effect at the next login (review finding 4).
        guard !launchedByLaunchd else { return }
        // Load it for this login session too. launchd will start a second copy (RunAtLoad); the single-instance lock
        // makes that copy exit(0) quietly, and from the next login on launchd is the one that starts the app.
        let uid = getuid()
        run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        run("/bin/launchctl", ["bootstrap", "gui/\(uid)", agentURL.path])
        EventLog.shared.add("автозапуск", "LaunchAgent установлен")
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }
}
