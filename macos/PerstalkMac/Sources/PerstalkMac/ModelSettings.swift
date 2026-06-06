import Foundation

struct TranscribeModelPreference: Equatable {
    let id: String
    let label: String
    let model: String
    let detail: String

    static let all: [TranscribeModelPreference] = [
        TranscribeModelPreference(
            id: "turbo",
            label: "Whisper large-v3 turbo",
            model: "mlx-community/whisper-large-v3-turbo",
            detail: "Best default for fast local dictation."
        ),
        TranscribeModelPreference(
            id: "base",
            label: "Whisper base",
            model: "mlx-community/whisper-base-mlx",
            detail: "Smallest and fastest, with lower accuracy."
        ),
        TranscribeModelPreference(
            id: "small",
            label: "Whisper small",
            model: "mlx-community/whisper-small-mlx",
            detail: "A compact middle ground for quick notes."
        ),
        TranscribeModelPreference(
            id: "large-v3",
            label: "Whisper large-v3",
            model: "mlx-community/whisper-large-v3-mlx",
            detail: "Higher accuracy, slower warmup and decoding."
        ),
    ]

    static let fallback = all[0]
    private static let key = "TranscribeModelPreference"

    static var current: TranscribeModelPreference {
        get {
            let id = UserDefaults.standard.string(forKey: key) ?? fallback.id
            return all.first { $0.id == id } ?? fallback
        }
        set {
            UserDefaults.standard.set(newValue.id, forKey: key)
        }
    }
}

struct RewriteModelPreference: Equatable {
    let id: String
    let label: String
    let model: String
    let detail: String
    let maxTokens: String
    let minTokens: String
    let tokenBuffer: String

    static let all: [RewriteModelPreference] = [
        RewriteModelPreference(
            id: "qwen-1-5b",
            label: "Qwen 2.5 1.5B",
            model: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
            detail: "Fastest rewrite for everyday dictation.",
            maxTokens: "1024",
            minTokens: "48",
            tokenBuffer: "32"
        ),
        RewriteModelPreference(
            id: "qwen-3b",
            label: "Qwen 2.5 3B",
            model: "mlx-community/Qwen2.5-3B-Instruct-4bit",
            detail: "Balanced cleanup quality and speed.",
            maxTokens: "2048",
            minTokens: "64",
            tokenBuffer: "48"
        ),
        RewriteModelPreference(
            id: "qwen-7b",
            label: "Qwen 2.5 7B",
            model: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            detail: "Best rewrite quality, with heavier warmup.",
            maxTokens: "4096",
            minTokens: "96",
            tokenBuffer: "64"
        ),
    ]

    static let fallback = all[0]
    private static let key = "RewriteModelPreference"

    static var current: RewriteModelPreference {
        get {
            let id = UserDefaults.standard.string(forKey: key) ?? fallback.id
            return all.first { $0.id == id } ?? fallback
        }
        set {
            UserDefaults.standard.set(newValue.id, forKey: key)
        }
    }
}

enum ModelSettings {
    private static let rewriteEnabledKey = "RewriteEnabled"

    static var isRewriteEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: rewriteEnabledKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: rewriteEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: rewriteEnabledKey)
        }
    }

    static var environment: [String: String] {
        var environment = [
            "PERSTALK_MODEL": TranscribeModelPreference.current.model,
            "PERSTALK_REWRITE_ENABLED": isRewriteEnabled ? "1" : "0",
        ]

        if isRewriteEnabled {
            let rewrite = RewriteModelPreference.current
            environment["PERSTALK_LLM"] = rewrite.model
            environment["PERSTALK_REWRITE_MAX_TOKENS"] = rewrite.maxTokens
            environment["PERSTALK_REWRITE_MIN_TOKENS"] = rewrite.minTokens
            environment["PERSTALK_REWRITE_TOKEN_BUFFER"] = rewrite.tokenBuffer
        }

        return environment
    }

    static var summary: String {
        if isRewriteEnabled {
            return "\(TranscribeModelPreference.current.label) + \(RewriteModelPreference.current.label)"
        }
        return "\(TranscribeModelPreference.current.label), no rewrite"
    }
}
