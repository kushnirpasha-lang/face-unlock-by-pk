//
//  InputActivityMonitor.swift
//  Face ID for Mac (by PK)
//
//  Listens — never seizes, never blocks — to the keyboard and pointing devices at the HID level, which still works on
//  the lock screen where Secure Event Input hides normal event taps. Records only *when* the last key / button went
//  down (never which key), so InjectionGuard can tell "the owner started typing" from "the tap that woke the screen".
//  Also reports the space bar for the "press space to scan" trigger.
//
//  `kIOHIDOptionsTypeNone` = shared listen-only access. There is deliberately no CGEventTap anywhere in this app: it
//  cannot swallow, delay or alter a single keystroke or click.
//

import Foundation
import IOKit.hid

nonisolated final class InputActivityMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var _lastKeyDown: Date?
    private var _lastPointerDown: Date?
    private var _alive = false
    private var manager: IOHIDManager?

    /// Called on the main run loop for a space-bar key-down.
    var onSpace: (@Sendable () -> Void)?

    var lastKeyDown: Date? { lock.lock(); defer { lock.unlock() }; return _lastKeyDown }
    var lastPointerDown: Date? { lock.lock(); defer { lock.unlock() }; return _lastPointerDown }
    /// True only while the HID manager is open — without it the guard is blind, so injection is refused (fail closed).
    var isAlive: Bool { lock.lock(); defer { lock.unlock() }; return _alive }

    @MainActor
    func start() {
        guard manager == nil else { return }
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keypad],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer],
            [kIOHIDDeviceUsagePageKey: kHIDPage_Digitizer],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matches as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(mgr, { context, _, _, value in
            guard let context else { return }
            let monitor = Unmanaged<InputActivityMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.handle(value)
        }, context)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        if result == kIOReturnSuccess {
            manager = mgr
            lock.lock(); _alive = true; lock.unlock()
        } else {
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            lock.lock(); _alive = false; lock.unlock()
        }
    }

    @MainActor
    func stop() {
        guard let mgr = manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
        lock.lock(); _alive = false; lock.unlock()
    }

    private func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        guard IOHIDValueGetIntegerValue(value) != 0 else { return }   // only "went down"
        let now = Date()
        switch page {
        case UInt32(kHIDPage_KeyboardOrKeypad):
            // Usages 0x04…0xE7 are real keys; lower values are error/rollover reports.
            guard usage >= 0x04, usage <= 0xE7 else { return }
            lock.lock(); _lastKeyDown = now; lock.unlock()
            if usage == UInt32(kHIDUsage_KeyboardSpacebar) { onSpace?() }
        case UInt32(kHIDPage_Button):
            lock.lock(); _lastPointerDown = now; lock.unlock()
        case UInt32(kHIDPage_Digitizer):
            // Tap-to-click on the trackpad never becomes a HID button press; a finger landing (tip switch / touch)
            // does. The tap that woke the screen happens before the scan starts and is ignored by the guard.
            guard usage == 0x42 || usage == 0x33 else { return }
            lock.lock(); _lastPointerDown = now; lock.unlock()
        default:
            return   // movement, touches without a click, scroll — not "the owner is doing something"
        }
    }
}
