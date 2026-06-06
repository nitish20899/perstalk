import Carbon
import Foundation

struct ShortcutPreference: Equatable {
    let id: String
    let label: String
    let keyCode: UInt32
    let modifiers: UInt32
    let isFunctionDoubleTap: Bool

    var idleInstruction: String {
        isFunctionDoubleTap ? "Double-tap Fn to dictate." : "Hold \(label) to dictate."
    }

    var recordingInstruction: String {
        isFunctionDoubleTap ? "Tap Fn to insert." : "Release \(label) to insert."
    }

    static let all: [ShortcutPreference] = [
        ShortcutPreference(
            id: "fn-double-tap",
            label: "Fn Fn",
            keyCode: 0,
            modifiers: 0,
            isFunctionDoubleTap: true
        ),
        ShortcutPreference(
            id: "option-space",
            label: "Option-Space",
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(optionKey),
            isFunctionDoubleTap: false
        ),
        ShortcutPreference(
            id: "control-space",
            label: "Control-Space",
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(controlKey),
            isFunctionDoubleTap: false
        ),
        ShortcutPreference(
            id: "option-d",
            label: "Option-D",
            keyCode: UInt32(kVK_ANSI_D),
            modifiers: UInt32(optionKey),
            isFunctionDoubleTap: false
        ),
        ShortcutPreference(
            id: "control-option-space",
            label: "Control-Option-Space",
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(controlKey | optionKey),
            isFunctionDoubleTap: false
        ),
    ]

    static let fallback = all[0]

    static var current: ShortcutPreference {
        get {
            let id = UserDefaults.standard.string(forKey: userDefaultsKey) ?? fallback.id
            return all.first { $0.id == id } ?? fallback
        }
        set {
            UserDefaults.standard.set(newValue.id, forKey: userDefaultsKey)
        }
    }

    private static let userDefaultsKey = "dictationShortcut"
}
