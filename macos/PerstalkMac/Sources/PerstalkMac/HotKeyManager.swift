import Carbon
import AppKit
@preconcurrency import ApplicationServices
import Foundation

struct HotKeyRegistrationStatus {
    let shortcut: ShortcutPreference
    let isRegistered: Bool
    let message: String
}

@MainActor
final class HotKeyManager {
    private static let functionDoubleTapWindow: TimeInterval = 0.45

    var onPressed: (() -> Void)?
    var onReleased: (() -> Void)?
    private(set) var registrationStatus = HotKeyRegistrationStatus(
        shortcut: ShortcutPreference.current,
        isRegistered: false,
        message: "Not registered yet."
    )

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var functionEventTap: CFMachPort?
    private var functionRunLoopSource: CFRunLoopSource?
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var shortcut = ShortcutPreference.current
    private var isFunctionFlagDown = false
    private var isFunctionDictating = false
    private var lastFunctionTapAt: Date?

    @discardableResult
    func register() -> HotKeyRegistrationStatus {
        unregister()

        if shortcut.isFunctionDoubleTap {
            return registerFunctionDoubleTap()
        }

        var eventSpecs = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]

        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let handlerStatus = eventSpecs.withUnsafeMutableBufferPointer { buffer in
            InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, userData in
                    guard let event, let userData else {
                        return noErr
                    }
                    let manager = Unmanaged<HotKeyManager>
                        .fromOpaque(userData)
                        .takeUnretainedValue()
                    let eventKind = GetEventKind(event)
                    Task { @MainActor in
                        if eventKind == UInt32(kEventHotKeyReleased) {
                            manager.onReleased?()
                        } else {
                            manager.onPressed?()
                        }
                    }
                    return noErr
                },
                buffer.count,
                buffer.baseAddress,
                selfPointer,
                &handlerRef
            )
        }
        guard handlerStatus == noErr else {
            return setRegistrationStatus(
                isRegistered: false,
                message: "Could not install shortcut handler (\(handlerStatus))."
            )
        }

        let hotKeyID = EventHotKeyID(signature: fourCharCode("PSTK"), id: 1)

        let registerStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard registerStatus == noErr, hotKeyRef != nil else {
            unregister()
            return setRegistrationStatus(
                isRegistered: false,
                message: hotKeyFailureMessage(registerStatus)
            )
        }

        return setRegistrationStatus(
            isRegistered: true,
            message: "\(shortcut.label) is ready."
        )
    }

    @discardableResult
    func updateShortcut(_ newShortcut: ShortcutPreference) -> HotKeyRegistrationStatus {
        let previousShortcut = shortcut
        shortcut = newShortcut
        let result = register()
        if result.isRegistered {
            ShortcutPreference.current = newShortcut
            return result
        }

        shortcut = previousShortcut
        let fallback = register()
        if fallback.isRegistered {
            return HotKeyRegistrationStatus(
                shortcut: newShortcut,
                isRegistered: false,
                message: "\(result.message) Keeping \(previousShortcut.label)."
            )
        }
        return result
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        if let functionEventTap {
            CGEvent.tapEnable(tap: functionEventTap, enable: false)
            self.functionEventTap = nil
        }
        if let functionRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), functionRunLoopSource, .commonModes)
            self.functionRunLoopSource = nil
        }
        if let globalFlagsMonitor {
            NSEvent.removeMonitor(globalFlagsMonitor)
            self.globalFlagsMonitor = nil
        }
        if let localFlagsMonitor {
            NSEvent.removeMonitor(localFlagsMonitor)
            self.localFlagsMonitor = nil
        }
        isFunctionFlagDown = false
        isFunctionDictating = false
        lastFunctionTapAt = nil
    }

    private func setRegistrationStatus(
        isRegistered: Bool,
        message: String
    ) -> HotKeyRegistrationStatus {
        let status = HotKeyRegistrationStatus(
            shortcut: shortcut,
            isRegistered: isRegistered,
            message: message
        )
        registrationStatus = status
        return status
    }

    private func hotKeyFailureMessage(_ status: OSStatus) -> String {
        if status == eventHotKeyExistsErr {
            return "\(shortcut.label) is already used by another app."
        }
        return "Could not register \(shortcut.label) (\(status))."
    }

    private func registerFunctionDoubleTap() -> HotKeyRegistrationStatus {
        let hasEventTap = installFunctionEventTap()
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            Task { @MainActor in
                self?.handleFunctionFlagsChanged(isDown: event.modifierFlags.contains(.function))
            }
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            Task { @MainActor in
                self?.handleFunctionFlagsChanged(isDown: event.modifierFlags.contains(.function))
            }
            return event
        }

        guard hasEventTap || globalFlagsMonitor != nil || localFlagsMonitor != nil else {
            return setRegistrationStatus(
                isRegistered: false,
                message: "Could not listen for Fn/Globe key events."
            )
        }

        return setRegistrationStatus(
            isRegistered: true,
            message: "Double-tap Fn to dictate; tap Fn again to insert."
        )
    }

    private func installFunctionEventTap() -> Bool {
        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: functionEventTapCallback,
            userInfo: selfPointer
        ) else {
            return false
        }

        guard let runLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            eventTap,
            0
        ) else {
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        functionEventTap = eventTap
        functionRunLoopSource = runLoopSource
        return true
    }

    fileprivate func handleFunctionFlagsChanged(isDown: Bool) {
        guard isDown != isFunctionFlagDown else {
            return
        }
        isFunctionFlagDown = isDown

        guard isDown else {
            return
        }

        if isFunctionDictating {
            isFunctionDictating = false
            lastFunctionTapAt = nil
            onReleased?()
            return
        }

        let now = Date()
        if let lastFunctionTapAt,
           now.timeIntervalSince(lastFunctionTapAt) <= Self.functionDoubleTapWindow {
            self.lastFunctionTapAt = nil
            isFunctionDictating = true
            onPressed?()
        } else {
            lastFunctionTapAt = now
        }
    }
}

private let functionEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard type == .flagsChanged, let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let manager = Unmanaged<HotKeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    let isFunctionDown = event.flags.contains(.maskSecondaryFn)
    Task { @MainActor in
        manager.handleFunctionFlagsChanged(isDown: isFunctionDown)
    }

    return Unmanaged.passUnretained(event)
}

private func fourCharCode(_ string: String) -> OSType {
    var result: OSType = 0
    for scalar in string.unicodeScalars.prefix(4) {
        result = (result << 8) + OSType(scalar.value)
    }
    return result
}
