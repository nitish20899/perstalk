import AppKit

enum PrivacySettings {
    static let bundleIdentifier = "ai.perstalk.flow"

    static func openMicrophone() {
        open(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        )
    }

    static func openAccessibility() {
        open(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }

    @discardableResult
    static func resetAccessibilityPermission() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleIdentifier]

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString),
              NSWorkspace.shared.open(url)
        else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
            return
        }
    }
}
