//
//  UnlockSignal.swift
//  Face ID for Mac (by PK)
//
//  "Has the screen been unlocked since it was last locked?" — answered from the system's own lock/unlock
//  notifications, delivered on a private queue (NOT the main actor) straight into a lock-protected flag.
//
//  Why not the main actor: when Touch ID wins the race against a face match, the main actor is busy starting the
//  password injection; an unlock notification queued behind it would arrive too late. CGSession itself can lag the
//  real state by hundreds of ms after Touch ID (A8), so this flag is the second, faster source the guard reads
//  before the text AND before Return (review finding 2).
//

import Foundation

nonisolated final class UnlockSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var _unlockedSinceLock = false
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "com.pavel.faceidformac.unlocksignal"
        return q
    }()
    private var observers: [NSObjectProtocol] = []

    var unlockedSinceLock: Bool { lock.lock(); defer { lock.unlock() }; return _unlockedSinceLock }

    init() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                                            object: nil, queue: queue) { [weak self] _ in self?.set(true) })
        observers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                                            object: nil, queue: queue) { [weak self] _ in self?.set(false) })
    }

    deinit {
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
    }

    /// Called when a new lock is observed through CGSession (the notification may have been missed).
    func lockObserved() { set(false) }

    private func set(_ value: Bool) { lock.lock(); _unlockedSinceLock = value; lock.unlock() }
}
