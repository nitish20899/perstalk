import Foundation

struct StatusResponse: Decodable {
    struct Stage: Decodable {
        let status: String
        let message: String
        let error: String?
    }

    let asr: Stage
    let llm: Stage
}

struct TranscribeResponse: Decodable {
    let text: String
}

struct RewriteResponse: Decodable {
    let text: String
}

struct BackendSettingsResponse: Decodable {
    let rewritePrompt: String
    let defaultRewritePrompt: String
    let isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case rewritePrompt = "rewrite_prompt"
        case defaultRewritePrompt = "default_rewrite_prompt"
        case isDefault = "is_default"
    }
}

struct DictateResponse: Decodable {
    let text: String
    let transcript: String
    let formattedTranscript: String?
    let elapsedMs: Int
    let transcribeElapsedMs: Int
    let rewriteElapsedMs: Int
    let asrModel: String?
    let llmModel: String?
    let maxTokens: Int?

    enum CodingKeys: String, CodingKey {
        case text
        case transcript
        case formattedTranscript = "formatted_transcript"
        case elapsedMs = "elapsed_ms"
        case transcribeElapsedMs = "transcribe_elapsed_ms"
        case rewriteElapsedMs = "rewrite_elapsed_ms"
        case asrModel = "asr_model"
        case llmModel = "llm_model"
        case maxTokens = "max_tokens"
    }
}

final class BackendClient: @unchecked Sendable {
    private let baseURL = URL(string: "http://127.0.0.1:5050")!
    private let session = URLSession.shared

    func health() async -> Bool {
        do {
            let url = baseURL.appendingPathComponent("healthz")
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func status() async throws -> StatusResponse {
        let url = baseURL.appendingPathComponent("status")
        let (data, response) = try await session.data(from: url)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(StatusResponse.self, from: data)
    }

    func transcribe(audioURL: URL) async throws -> String {
        let (request, body) = try multipartAudioRequest(path: "transcribe", audioURL: audioURL)
        let (data, response) = try await session.upload(for: request, from: body)
        try validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(TranscribeResponse.self, from: data)
        return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func rewrite(text: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("rewrite"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = ["text": text]
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        let decoded = try JSONDecoder().decode(RewriteResponse.self, from: data)
        return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func settings() async throws -> BackendSettingsResponse {
        let url = baseURL.appendingPathComponent("settings")
        let (data, response) = try await session.data(from: url)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(BackendSettingsResponse.self, from: data)
    }

    func updateRewritePrompt(_ prompt: String) async throws -> BackendSettingsResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("settings"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["rewrite_prompt": prompt])

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(BackendSettingsResponse.self, from: data)
    }

    func resetRewritePrompt() async throws -> BackendSettingsResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("settings"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["reset": true])

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(BackendSettingsResponse.self, from: data)
    }

    func dictate(audioURL: URL, context: TargetAppContext?) async throws -> DictateResponse {
        let fields = context.map {
            [
                "app_name": $0.name,
                "bundle_id": $0.bundleIdentifier,
            ]
        } ?? [:]
        let (request, body) = try multipartAudioRequest(
            path: "dictate",
            audioURL: audioURL,
            fields: fields
        )
        let (data, response) = try await session.upload(for: request, from: body)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(DictateResponse.self, from: data)
    }

    private func multipartAudioRequest(
        path: String,
        audioURL: URL,
        fields: [String: String] = [:]
    ) throws -> (URLRequest, Data) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        for (name, value) in fields where !value.isEmpty {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append(value)
            body.append("\r\n")
        }
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"speech.wav\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(try Data(contentsOf: audioURL))
        body.append("\r\n--\(boundary)--\r\n")

        return (request, body)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            if let apiError = try? JSONDecoder().decode(APIError.self, from: data) {
                throw BackendError.requestFailed(apiError.detail)
            }
            throw BackendError.requestFailed("Backend returned HTTP \(http.statusCode).")
        }
    }
}

struct APIError: Decodable {
    let detail: String
}

enum BackendError: LocalizedError {
    case requestFailed(String)
    case serverMissing

    var errorDescription: String? {
        switch self {
        case .requestFailed(let message):
            return message
        case .serverMissing:
            return "Could not find bundled backend files. Rebuild the app or set PERSTALK_ROOT."
        }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
