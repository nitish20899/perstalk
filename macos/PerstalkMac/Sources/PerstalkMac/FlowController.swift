import AppKit
import Foundation

@MainActor
final class FlowController {
    private static let minimumRecordingDurationMs = 350
    private static let modelReadinessTimeoutSeconds: TimeInterval = 180
    private static let modelReadinessPollNanoseconds: UInt64 = 500_000_000

    private enum State {
        case idle
        case preparing
        case recording
        case processing
    }

    private let panel = FloatingPanel()
    private let recorder = AudioRecorder()
    let backendClient = BackendClient()
    private let targetAppTracker: TargetAppTracker
    private lazy var backendProcess = BackendProcess(client: backendClient)

    private var state: State = .idle
    private var stopRequestedDuringPreparation = false
    private var targetAppContext: TargetAppContext?
    private var popupAnchor: NSPoint?
    private var activeTask: Task<Void, Never>?

    var primaryMenuActionTitle: String {
        switch state {
        case .idle:
            return "Start dictation"
        case .recording:
            return "Stop and insert"
        case .preparing, .processing:
            return "Cancel dictation"
        }
    }

    var canCancelDictation: Bool {
        state != .idle
    }

    init(targetAppTracker: TargetAppTracker) {
        self.targetAppTracker = targetAppTracker

        panel.onAction = { [weak self] in
            self?.toggleDictation()
        }
        panel.onCancel = { [weak self] in
            self?.cancelDictation()
        }
        recorder.onLevel = { [weak self] level in
            self?.panel.updateLevel(level)
        }
    }

    func prepareBackend() async {
        do {
            panel.update(
                title: "Starting local MLX backend",
                detail: "First launch may install the app runtime.",
                isRecording: false
            )
            try await backendProcess.ensureRunning()
        } catch {
            showMessage("Backend needs attention", detail: error.localizedDescription)
        }
    }

    func restartBackendForCurrentProfile() async {
        do {
            panel.update(
                title: "Restarting local MLX",
                detail: "Applying model settings.",
                isRecording: false
            )
            panel.show(anchor: popupAnchor)
            try await backendProcess.restart()
            panel.update(
                title: "Backend restarted",
                detail: "\(ModelSettings.summary) is active.",
                isRecording: false
            )
            panel.hide(after: 1.2)
        } catch {
            showMessage("Backend restart failed", detail: error.localizedDescription)
        }
    }

    func toggleDictation() {
        switch state {
        case .idle:
            beginDictation()
        case .recording:
            finishDictation()
        case .preparing, .processing:
            cancelDictation()
        }
    }

    func beginDictation() {
        guard state == .idle else {
            return
        }
        state = .preparing
        stopRequestedDuringPreparation = false
        targetAppContext = targetAppTracker.currentTarget()
        popupAnchor = PopupAnchor.current(for: targetAppContext)
        panel.update(title: "Preparing microphone", detail: "Starting local capture.", isRecording: false, actionTitle: "Cancel")
        panel.show(anchor: popupAnchor)

        activeTask = Task { [weak self] in
            await self?.startDictation()
            self?.clearActiveTask()
        }
    }

    func finishDictation() {
        switch state {
        case .recording:
            state = .processing
            panel.update(title: "Finishing", detail: "Preparing audio.", isRecording: false, actionTitle: "Cancel")
            activeTask = Task { [weak self] in
                await self?.stopAndInsert()
                self?.clearActiveTask()
            }
        case .preparing:
            stopRequestedDuringPreparation = true
            panel.update(title: "Finishing", detail: "Starting capture, then polishing.", isRecording: false, actionTitle: "Cancel")
        case .idle, .processing:
            break
        }
    }

    func cancelDictation() {
        guard state != .idle else {
            showMessage("Nothing to cancel", detail: "Perstalk is idle.", hideAfter: 1.0)
            return
        }

        activeTask?.cancel()
        activeTask = nil
        recorder.cancel()
        resetDictationState()
        panel.update(title: "Canceled", detail: "Dictation stopped.", isRecording: false)
        panel.hide(after: 1.0)
    }

    func showIdlePopup() {
        popupAnchor = PopupAnchor.current(for: targetAppTracker.currentTarget())
        panel.update(
            title: "Perstalk",
            detail: ShortcutPreference.current.idleInstruction,
            isRecording: false
        )
        panel.show(anchor: popupAnchor)
    }

    func showMessage(_ title: String, detail: String, hideAfter: TimeInterval? = nil) {
        popupAnchor = PopupAnchor.current(for: targetAppTracker.currentTarget())
        panel.update(title: title, detail: detail, isRecording: false)
        panel.show(anchor: popupAnchor)
        if let hideAfter {
            panel.hide(after: hideAfter)
        }
    }

    func runPasteTest() {
        guard state == .idle else {
            showMessage("Dictation active", detail: "Finish or cancel before testing paste.")
            return
        }

        let target = targetAppTracker.currentTarget()
        let anchor = PopupAnchor.current(for: target)
        let sample = pasteTestText()
        let destination = target?.name ?? "clipboard"

        panel.update(
            title: "Testing paste",
            detail: "Inserting a sample into \(destination).",
            isRecording: false
        )
        panel.show(anchor: anchor)

        activeTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let result = try await PasteboardInserter.insert(sample, target: target)
                switch result {
                case .directAccessibility:
                    panel.update(
                        title: "Paste test inserted",
                        detail: "Direct insertion worked in \(destination).",
                        isRecording: false
                    )
                    panel.hide(after: 1.4)
                case .clipboardPasteFallback(let mode):
                    panel.update(
                        title: clipboardFallbackTitle(mode),
                        detail: clipboardFallbackDetail(mode, destination: destination),
                        isRecording: false
                    )
                    if mode == .trusted {
                        panel.hide(after: 1.4)
                    }
                case .copiedOnly(let reason):
                    panel.update(
                        title: "Paste test copied",
                        detail: copyOnlyDetail(reason),
                        isRecording: false
                    )
                }
            } catch is CancellationError {
                panel.update(title: "Paste test canceled", detail: "No sample inserted.", isRecording: false)
                panel.hide(after: 1.0)
            } catch {
                panel.update(title: "Paste test failed", detail: error.localizedDescription, isRecording: false)
            }
            clearActiveTask()
        }
    }

    func shutdown() {
        if recorder.isRecording {
            recorder.cancel()
        }
        popupAnchor = nil
        backendProcess.stop()
    }

    private func startDictation() async {
        do {
            guard await recorder.requestPermission() else {
                resetDictationState()
                panel.update(
                    title: "Microphone permission needed",
                    detail: "Allow Perstalk in System Settings, then try again.",
                    isRecording: false
                )
                return
            }

            try Task.checkCancellation()
            try recorder.start()
            state = .recording
            panel.update(
                title: "Listening",
                detail: ShortcutPreference.current.recordingInstruction,
                isRecording: true
            )

            if stopRequestedDuringPreparation {
                await stopAndInsert()
            }
        } catch is CancellationError {
            resetDictationState()
        } catch {
            resetDictationState()
            panel.update(title: "Could not start", detail: error.localizedDescription, isRecording: false)
        }
    }

    private func stopAndInsert() async {
        guard let recording = recorder.stop() else {
            resetDictationState()
            panel.update(title: "No audio captured", detail: "Try again.", isRecording: false)
            panel.hide(after: 1.2)
            return
        }

        let audioURL = recording.url
        defer {
            try? FileManager.default.removeItem(at: audioURL)
        }

        guard recording.durationMs >= Self.minimumRecordingDurationMs else {
            resetDictationState()
            panel.update(title: "Too short", detail: "Hold a little longer to dictate.", isRecording: false)
            panel.hide(after: 1.1)
            return
        }

        panel.update(title: "Preparing local MLX", detail: "Checking transcription and rewrite models.", isRecording: false, actionTitle: "Cancel")

        do {
            try await waitForReadyModels()
            panel.update(title: "Polishing", detail: "Local MLX is transcribing and cleaning up.", isRecording: false, actionTitle: "Cancel")
            let result = try await backendClient.dictate(
                audioURL: audioURL,
                context: targetAppContext
            )
            let finalText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let transcript = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            let formattedTranscript = result.formattedTranscript?.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !finalText.isEmpty || !transcript.isEmpty else {
                resetDictationState()
                panel.update(title: "No speech detected", detail: "Try speaking a little longer.", isRecording: false)
                panel.hide(after: 1.2)
                return
            }

            let insertText = finalText.isEmpty ? transcript : finalText
            DictationHistory.append(
                text: insertText,
                transcript: transcript,
                formattedTranscript: formattedTranscript,
                target: targetAppContext,
                elapsedMs: result.elapsedMs,
                transcribeElapsedMs: result.transcribeElapsedMs,
                rewriteElapsedMs: result.rewriteElapsedMs,
                modelProfile: ModelSettings.summary,
                asrModel: result.asrModel,
                llmModel: result.llmModel,
                maxTokens: result.maxTokens
            )

            let insertionResult = try await PasteboardInserter.insert(
                insertText,
                target: targetAppContext
            )
            let destination = targetAppContext?.name ?? "active app"

            resetDictationState()
            switch insertionResult {
            case .directAccessibility:
                panel.update(
                    title: "Inserted",
                    detail: "Cleaned text inserted into \(destination).",
                    isRecording: false
                )
                panel.hide(after: 1.2)
            case .clipboardPasteFallback(let mode):
                panel.update(
                    title: clipboardFallbackTitle(mode),
                    detail: clipboardFallbackDetail(mode, destination: destination),
                    isRecording: false
                )
                if mode == .trusted {
                    panel.hide(after: 1.2)
                }
            case .copiedOnly(let reason):
                panel.update(
                    title: "Copied",
                    detail: copyOnlyDetail(reason),
                    isRecording: false
                )
            }
        } catch is CancellationError {
            resetDictationState()
            panel.update(title: "Canceled", detail: "Dictation stopped.", isRecording: false)
            panel.hide(after: 1.0)
        } catch {
            resetDictationState()
            panel.update(title: "Dictation failed", detail: error.localizedDescription, isRecording: false)
        }
    }

    private func waitForReadyModels() async throws {
        try await backendProcess.ensureRunning()

        var lastStatus: StatusResponse?
        let deadline = Date().addingTimeInterval(Self.modelReadinessTimeoutSeconds)
        var hasShownQueuedState = false

        while Date() < deadline {
            let status = try await backendClient.status()
            lastStatus = status

            if status.asr.status == "ready",
               (!ModelSettings.isRewriteEnabled || status.llm.status == "ready" || status.llm.status == "disabled") {
                return
            }

            if status.asr.status == "error" {
                throw BackendError.requestFailed(status.asr.error ?? "Speech model failed to load.")
            }
            if ModelSettings.isRewriteEnabled, status.llm.status == "error" {
                throw BackendError.requestFailed(status.llm.error ?? "Rewrite model failed to load.")
            }

            panel.update(
                title: hasShownQueuedState ? "Still warming local MLX" : "Warming local MLX",
                detail: modelWaitDetail(status),
                isRecording: false,
                actionTitle: "Cancel"
            )
            hasShownQueuedState = true

            try await Task.sleep(nanoseconds: Self.modelReadinessPollNanoseconds)
        }

        if let status = lastStatus {
            throw BackendError.requestFailed(
                "Models are still warming. \(modelWaitDetail(status))"
            )
        }
        throw BackendError.requestFailed("Models did not report readiness.")
    }

    private func modelWaitDetail(_ status: StatusResponse) -> String {
        if !ModelSettings.isRewriteEnabled {
            return status.asr.message
        }
        if status.asr.status != "ready", status.llm.status != "ready" {
            return "Waiting for speech and rewrite models."
        }
        if status.asr.status != "ready" {
            return status.asr.message
        }
        if status.llm.status != "ready" {
            return status.llm.message
        }
        return "Ready."
    }

    private func pasteTestText() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return "Perstalk paste test \(formatter.string(from: Date()))"
    }

    private func copyOnlyDetail(_ reason: PasteboardInserter.CopyOnlyReason) -> String {
        switch reason {
        case .noTarget:
            return "Copied because no target app was focused."
        }
    }

    private func clipboardFallbackTitle(
        _ mode: PasteboardInserter.ClipboardFallbackMode
    ) -> String {
        switch mode {
        case .trusted:
            return "Pasted"
        case .untrusted:
            return "Copied"
        }
    }

    private func clipboardFallbackDetail(
        _ mode: PasteboardInserter.ClipboardFallbackMode,
        destination: String
    ) -> String {
        switch mode {
        case .trusted:
            return "Used clipboard fallback for \(destination)."
        case .untrusted:
            return "Text is on the clipboard. Press Command-V if it did not appear."
        }
    }

    private func resetDictationState() {
        state = .idle
        targetAppContext = nil
        popupAnchor = nil
    }

    private func clearActiveTask() {
        activeTask = nil
    }
}
