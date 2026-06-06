import AppKit
@preconcurrency import ApplicationServices

@MainActor
enum PasteboardInserter {
    private static let activationTimeout: TimeInterval = 0.18
    private static let activationPollInterval: TimeInterval = 0.01
    private static let pasteRestoreDelay: TimeInterval = 0.8
    private static let lastInsertionMethodKey = "LastInsertionMethod"

    enum InsertionResult {
        case directAccessibility
        case clipboardPasteFallback(ClipboardFallbackMode)
        case copiedOnly(CopyOnlyReason)

        var label: String {
            switch self {
            case .directAccessibility:
                return "Direct Accessibility insertion"
            case .clipboardPasteFallback:
                return "Clipboard paste fallback"
            case .copiedOnly:
                return "Copied only"
            }
        }

        var detail: String {
            switch self {
            case .directAccessibility:
                return "Direct Accessibility insertion"
            case .clipboardPasteFallback(let mode):
                return "Clipboard paste fallback (\(mode.label))"
            case .copiedOnly(let reason):
                return "Copied only (\(reason.label))"
            }
        }
    }

    enum ClipboardFallbackMode {
        case trusted
        case untrusted

        var label: String {
            switch self {
            case .trusted:
                return "restored clipboard"
            case .untrusted:
                return "text left on clipboard"
            }
        }
    }

    enum CopyOnlyReason {
        case noTarget

        var label: String {
            switch self {
            case .noTarget:
                return "no target app"
            }
        }
    }

    static var lastInsertionMethod: String {
        UserDefaults.standard.string(forKey: lastInsertionMethodKey) ?? "Not used yet"
    }

    static var isAccessibilityTrusted: Bool {
        isAccessibilityTrusted(prompt: false)
    }

    static func insert(_ text: String, target: TargetAppContext?) async throws -> InsertionResult {
        guard let target else {
            copyToClipboard(text)
            let result = InsertionResult.copiedOnly(.noTarget)
            setLastInsertionMethod(result, target: nil)
            return result
        }

        let isTrusted = isAccessibilityTrusted(prompt: false)

        activate(target: target)
        try await waitForTargetActivation(target)

        if isTrusted, insertUsingAccessibility(text, target: target) {
            setLastInsertionMethod(.directAccessibility, target: target)
            return .directAccessibility
        }

        pasteUsingClipboard(text, restoresClipboard: isTrusted)
        let result = InsertionResult.clipboardPasteFallback(isTrusted ? .trusted : .untrusted)
        setLastInsertionMethod(result, target: target)
        return result
    }

    static func requestAccessibilityPermission() {
        _ = isAccessibilityTrusted(prompt: true)
    }

    private static func setLastInsertionMethod(
        _ result: InsertionResult,
        target: TargetAppContext?
    ) {
        let destination = target?.name ?? "No target"
        UserDefaults.standard.set("\(result.detail) - \(destination)", forKey: lastInsertionMethodKey)
    }

    private static func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let options = [
            accessibilityPromptOptionKey(): prompt
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private static func insertUsingAccessibility(_ text: String, target: TargetAppContext) -> Bool {
        guard let focusedElement = focusedElement(target: target) else {
            return false
        }

        if AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ) == .success {
            return true
        }

        var selectedRangeObject: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeObject
        ) == .success,
            let selectedRangeObject,
            let selectedRange = rangeValue(selectedRangeObject) {
            return replaceValueText(in: focusedElement, range: selectedRange, with: text)
        }

        return false
    }

    private static func replaceValueText(
        in element: AXUIElement,
        range: CFRange,
        with text: String
    ) -> Bool {
        var valueObject: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueObject
        ) == .success,
            let currentValue = valueObject as? String
        else {
            return false
        }

        let utf16Count = (currentValue as NSString).length
        let start = max(0, min(range.location, utf16Count))
        let length = max(0, min(range.length, utf16Count - start))
        let nsRange = NSRange(location: start, length: length)
        guard let stringRange = Range(nsRange, in: currentValue) else {
            return false
        }

        var replacement = currentValue
        replacement.replaceSubrange(stringRange, with: text)
        guard AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            replacement as CFTypeRef
        ) == .success else {
            return false
        }

        var newRange = CFRange(location: start + (text as NSString).length, length: 0)
        if let rangeValue = AXValueCreate(.cfRange, &newRange) {
            _ = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
            )
        }

        return true
    }

    private static func focusedElement(target: TargetAppContext) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(target.processIdentifier)
        var focusedObject: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        ) == .success,
            let focusedObject
        else {
            return nil
        }

        return (focusedObject as! AXUIElement)
    }

    private static func rangeValue(_ value: CFTypeRef) -> CFRange? {
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else {
            return nil
        }
        return range
    }

    private static func pasteUsingClipboard(_ text: String, restoresClipboard: Bool) {
        let pasteboard = NSPasteboard.general
        let previousString = pasteboard.string(forType: .string)

        copyToClipboard(text)
        sendPasteKeystroke()
        if restoresClipboard {
            restoreClipboard(
                previousString: previousString,
                unlessChangedFrom: text,
                after: pasteRestoreDelay
            )
        }
    }

    private static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func restoreClipboard(
        previousString: String?,
        unlessChangedFrom insertedText: String,
        after delay: TimeInterval
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let pasteboard = NSPasteboard.general
            guard pasteboard.string(forType: .string) == insertedText else {
                return
            }

            pasteboard.clearContents()
            if let previousString {
                pasteboard.setString(previousString, forType: .string)
            }
        }
    }

    private static func activate(target: TargetAppContext) {
        guard let app = NSRunningApplication(processIdentifier: target.processIdentifier)
        else {
            return
        }
        app.activate(options: [.activateIgnoringOtherApps])
    }

    private static func waitForTargetActivation(_ target: TargetAppContext) async throws {
        let deadline = Date().addingTimeInterval(activationTimeout)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                return
            }
            try await Task.sleep(nanoseconds: UInt64(activationPollInterval * 1_000_000_000))
        }
    }

    private static func sendPasteKeystroke() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}

private func accessibilityPromptOptionKey() -> String {
    kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
}
