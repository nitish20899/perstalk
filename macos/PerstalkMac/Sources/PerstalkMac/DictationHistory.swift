import Foundation

struct DictationHistoryEntry: Codable {
    let createdAt: Date
    let text: String
    let transcript: String
    let formattedTranscript: String?
    let targetAppName: String?
    let elapsedMs: Int
    let transcribeElapsedMs: Int?
    let rewriteElapsedMs: Int?
    let modelProfile: String?
    let asrModel: String?
    let llmModel: String?
    let maxTokens: Int?
}

@MainActor
enum DictationHistory {
    private static let maxEntries = 50
    private static let isEnabledKey = "SaveDictationHistory"

    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: isEnabledKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: isEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: isEnabledKey)
            if !newValue {
                clear()
            }
        }
    }

    static func append(
        text: String,
        transcript: String,
        formattedTranscript: String?,
        target: TargetAppContext?,
        elapsedMs: Int,
        transcribeElapsedMs: Int?,
        rewriteElapsedMs: Int?,
        modelProfile: String,
        asrModel: String?,
        llmModel: String?,
        maxTokens: Int?
    ) {
        guard isEnabled else {
            return
        }

        let entry = DictationHistoryEntry(
            createdAt: Date(),
            text: text,
            transcript: transcript,
            formattedTranscript: formattedTranscript,
            targetAppName: target?.name,
            elapsedMs: elapsedMs,
            transcribeElapsedMs: transcribeElapsedMs,
            rewriteElapsedMs: rewriteElapsedMs,
            modelProfile: modelProfile,
            asrModel: asrModel,
            llmModel: llmModel,
            maxTokens: maxTokens
        )

        var entries = load()
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save(entries)
    }

    static func lastText() -> String? {
        load().first?.text
    }

    static func lastEntry() -> DictationHistoryEntry? {
        load().first
    }

    static func clear() {
        save([])
    }

    static func ensureFileExists() {
        let url = AppSupport.historyURL()
        if !FileManager.default.fileExists(atPath: url.path) {
            save([])
        }
    }

    private static func load() -> [DictationHistoryEntry] {
        let url = AppSupport.historyURL()
        guard let data = try? Data(contentsOf: url) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([DictationHistoryEntry].self, from: data)) ?? []
    }

    private static func save(_ entries: [DictationHistoryEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else {
            return
        }
        guard (try? AppSupport.directory()) != nil else {
            return
        }
        try? data.write(to: AppSupport.historyURL(), options: .atomic)
    }
}
