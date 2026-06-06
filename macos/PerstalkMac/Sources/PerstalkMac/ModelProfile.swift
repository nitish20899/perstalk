import Foundation

enum ModelProfile: String, CaseIterable {
    case fast
    case balanced
    case quality

    private static let key = "ModelProfile"

    static var current: ModelProfile {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key),
                  let profile = ModelProfile(rawValue: raw)
            else {
                return .fast
            }
            return profile
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }

    var label: String {
        switch self {
        case .fast:
            return "Fast"
        case .balanced:
            return "Balanced"
        case .quality:
            return "Quality"
        }
    }

    var detail: String {
        switch self {
        case .fast:
            return "Whisper Turbo + Qwen 1.5B for lowest rewrite latency."
        case .balanced:
            return "Whisper Turbo + Qwen 3B for balanced quality."
        case .quality:
            return "Whisper large-v3 + Qwen 7B for higher quality."
        }
    }

    var environment: [String: String] {
        ModelSettings.environment
    }
}
