import Foundation

enum AppSupport {
    static func directory() throws -> URL {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw BackendError.requestFailed("Could not locate Application Support.")
        }

        let directory = base.appendingPathComponent("Perstalk Flow", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    static func backendDirectory() throws -> URL {
        try directory().appendingPathComponent("backend", isDirectory: true)
    }

    static func backendLogURL() -> URL {
        let fallback = URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = (try? directory()) ?? fallback
        return directory.appendingPathComponent("backend.log")
    }

    static func historyURL() -> URL {
        let fallback = URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = (try? directory()) ?? fallback
        return directory.appendingPathComponent("dictation-history.json")
    }
}
