import Foundation

@MainActor
final class BackendProcess {
    private static let bundledBackendFiles = [
        "server.py",
        "text_formatting.py",
        "index.html",
        "requirements.txt",
    ]

    private struct Runtime {
        let backendRoot: URL
        let python: URL
        let arguments: [String]
        let environment: [String: String]
    }

    private let client: BackendClient
    private var process: Process?

    init(client: BackendClient) {
        self.client = client
    }

    func ensureRunning() async throws {
        if await client.health() {
            return
        }

        try launch()
        try await waitForHealth()
    }

    func restart() async throws {
        if process == nil, await client.health() {
            throw BackendError.requestFailed(
                "An external backend is already running on 127.0.0.1:5050. Stop it, then restart from Perstalk to apply this profile."
            )
        }

        try await stopAndWaitForExit()
        try launch()
        try await waitForHealth()
    }

    private func waitForHealth() async throws {
        for _ in 0..<90 {
            if await client.health() {
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        throw BackendError.requestFailed("Backend did not become ready.")
    }

    func stop() {
        guard let process else {
            return
        }

        if process.isRunning {
            process.terminate()

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if process.isRunning {
                    process.interrupt()
                }
            }
        }

        self.process = nil
    }

    private func stopAndWaitForExit() async throws {
        guard let process else {
            return
        }

        if process.isRunning {
            process.terminate()
            for _ in 0..<20 {
                if !process.isRunning {
                    break
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if process.isRunning {
                process.interrupt()
            }
        }

        self.process = nil
    }

    private func launch() throws {
        let runtime = try bootstrapRuntime()
        let process = Process()
        process.currentDirectoryURL = runtime.backendRoot
        process.executableURL = runtime.python
        process.arguments = runtime.arguments
        process.environment = runtime.environment
        process.standardOutput = backendLogHandle()
        process.standardError = backendLogHandle()

        try process.run()
        self.process = process
    }

    private func bootstrapRuntime() throws -> Runtime {
        if let developmentRoot = findDevelopmentRoot() {
            return Runtime(
                backendRoot: developmentRoot,
                python: pythonForDevelopmentRoot(developmentRoot),
                arguments: argumentsForDevelopmentRoot(developmentRoot),
                environment: backendEnvironment()
            )
        }

        let backendRoot = try prepareBundledBackend()
        let venvPython = backendRoot.appendingPathComponent(".venv/bin/python")
        if !FileManager.default.isExecutableFile(atPath: venvPython.path) {
            try runSetupCommand(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["python3", "-m", "venv", backendRoot.appendingPathComponent(".venv").path],
                currentDirectory: backendRoot
            )
            try runSetupCommand(
                executable: venvPython,
                arguments: ["-m", "pip", "install", "--upgrade", "pip"],
                currentDirectory: backendRoot
            )
            try runSetupCommand(
                executable: venvPython,
                arguments: ["-m", "pip", "install", "-r", "requirements.txt"],
                currentDirectory: backendRoot
            )
        }

        return Runtime(
            backendRoot: backendRoot,
            python: venvPython,
            arguments: ["server.py"],
            environment: backendEnvironment()
        )
    }

    private func findDevelopmentRoot() -> URL? {
        if let configured = ProcessInfo.processInfo.environment["PERSTALK_ROOT"] {
            let root = URL(fileURLWithPath: configured)
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("server.py").path) {
                return root
            }
        }

        var candidates: [URL] = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            Bundle.main.bundleURL,
        ]

        if let executable = Bundle.main.executableURL {
            candidates.append(executable)
        }

        for start in candidates {
            var current = start.hasDirectoryPath ? start : start.deletingLastPathComponent()
            for _ in 0..<8 {
                if FileManager.default.fileExists(atPath: current.appendingPathComponent("server.py").path) {
                    return current
                }
                current.deleteLastPathComponent()
            }
        }

        return nil
    }

    private func pythonForDevelopmentRoot(_ root: URL) -> URL {
        let venvPython = root.appendingPathComponent(".venv/bin/python")
        if FileManager.default.isExecutableFile(atPath: venvPython.path) {
            return venvPython
        }
        return URL(fileURLWithPath: "/usr/bin/env")
    }

    private func argumentsForDevelopmentRoot(_ root: URL) -> [String] {
        let venvPython = root.appendingPathComponent(".venv/bin/python")
        return FileManager.default.isExecutableFile(atPath: venvPython.path)
            ? ["server.py"]
            : ["python3", "server.py"]
    }

    private func prepareBundledBackend() throws -> URL {
        guard let bundledBackend = Bundle.main.resourceURL?.appendingPathComponent("backend"),
              FileManager.default.fileExists(atPath: bundledBackend.appendingPathComponent("server.py").path)
        else {
            throw BackendError.serverMissing
        }

        let backendRoot = try AppSupport.backendDirectory()
        try FileManager.default.createDirectory(
            at: backendRoot,
            withIntermediateDirectories: true
        )

        for fileName in Self.bundledBackendFiles {
            let source = bundledBackend.appendingPathComponent(fileName)
            let destination = backendRoot.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        }

        return backendRoot
    }

    private func backendEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PERSTALK_HOST"] = "127.0.0.1"
        environment["PERSTALK_PORT"] = "5050"
        for (key, value) in ModelSettings.environment {
            environment[key] = value
        }
        return environment
    }

    private func runSetupCommand(
        executable: URL,
        arguments: [String],
        currentDirectory: URL
    ) throws {
        let process = Process()
        process.currentDirectoryURL = currentDirectory
        process.executableURL = executable
        process.arguments = arguments
        process.environment = backendEnvironment()
        process.standardOutput = backendLogHandle()
        process.standardError = backendLogHandle()

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw BackendError.requestFailed(
                "Backend setup failed. See \(backendLogURL().path) for details."
            )
        }
    }

    private func backendLogURL() -> URL {
        AppSupport.backendLogURL()
    }

    private func backendLogHandle() -> FileHandle? {
        let url = backendLogURL()
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            return nil
        }
        _ = try? handle.seekToEnd()
        return handle
    }
}
