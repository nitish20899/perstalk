import AppKit
import ApplicationServices

@MainActor
enum PopupAnchor {
    static func current(for target: TargetAppContext?) -> NSPoint? {
        focusedElementPoint(for: target) ?? mousePoint()
    }

    private static func focusedElementPoint(for target: TargetAppContext?) -> NSPoint? {
        guard PasteboardInserter.isAccessibilityTrusted,
              let target
        else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(target.processIdentifier)
        var focusedObject: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        )
        guard focusedStatus == .success,
              let focusedElement = focusedObject
        else {
            return nil
        }

        var positionObject: CFTypeRef?
        var sizeObject: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement as! AXUIElement,
            kAXPositionAttribute as CFString,
            &positionObject
        ) == .success,
            AXUIElementCopyAttributeValue(
                focusedElement as! AXUIElement,
                kAXSizeAttribute as CFString,
                &sizeObject
            ) == .success,
            let positionValue = positionObject,
            let sizeValue = sizeObject
        else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              size.width > 0,
              size.height > 0
        else {
            return nil
        }

        return anchorPoint(from: NSRect(origin: position, size: size))
    }

    private static func anchorPoint(from accessibilityRect: NSRect) -> NSPoint? {
        let directPoint = NSPoint(
            x: accessibilityRect.midX,
            y: accessibilityRect.minY
        )
        if contains(directPoint) {
            return directPoint
        }

        for screen in NSScreen.screens {
            let frame = screen.frame
            let flippedY = frame.maxY - accessibilityRect.maxY + frame.minY
            let flippedPoint = NSPoint(
                x: accessibilityRect.midX,
                y: flippedY
            )
            if screen.visibleFrame.contains(flippedPoint) {
                return flippedPoint
            }
        }

        return nil
    }

    private static func contains(_ point: NSPoint) -> Bool {
        NSScreen.screens.contains { screen in
            screen.visibleFrame.contains(point)
        }
    }

    private static func mousePoint() -> NSPoint? {
        let point = NSEvent.mouseLocation
        return contains(point) ? point : nil
    }
}
