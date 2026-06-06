import AppKit
import AVFoundation

@MainActor
final class SettingsWindowController: NSWindowController {
    private let backendClient: BackendClient
    private let shortcutStatus: () -> HotKeyRegistrationStatus?
    private let onShortcutChanged: (ShortcutPreference) -> HotKeyRegistrationStatus
    private let onModelSettingsChanged: () -> Void
    private let onPasteTest: () -> Void

    private let microphonePopup = NSPopUpButton()
    private let transcribeModelPopup = NSPopUpButton()
    private let rewriteEnabledCheckbox = NSButton(checkboxWithTitle: "Clean up grammar with Qwen", target: nil, action: nil)
    private let rewriteModelPopup = NSPopUpButton()
    private let promptTextView = NSTextView()
    private let promptStatusLabel = NSTextField(labelWithString: "Loading prompt...")
    private let shortcutPopup = NSPopUpButton()
    private let shortcutStatusLabel = NSTextField(labelWithString: "")
    private let micStatusLabel = NSTextField(labelWithString: "")
    private let pasteStatusLabel = NSTextField(labelWithString: "")
    private let backendStatusLabel = NSTextField(labelWithString: "")
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Open at login", target: nil, action: nil)

    private var microphoneOptions = MicrophonePreference.available

    init(
        backendClient: BackendClient,
        shortcutStatus: @escaping () -> HotKeyRegistrationStatus?,
        onShortcutChanged: @escaping (ShortcutPreference) -> HotKeyRegistrationStatus,
        onModelSettingsChanged: @escaping () -> Void,
        onPasteTest: @escaping () -> Void
    ) {
        self.backendClient = backendClient
        self.shortcutStatus = shortcutStatus
        self.onShortcutChanged = onShortcutChanged
        self.onModelSettingsChanged = onModelSettingsChanged
        self.onPasteTest = onPasteTest

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 660),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Perstalk Flow"
        window.isReleasedWhenClosed = false

        super.init(window: window)
        buildInterface()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show() {
        refresh()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildInterface() {
        guard let window else {
            return
        }

        configurePopups()
        configureCheckboxes()
        configurePromptEditor()

        let headerTitle = label("Perstalk Flow", size: 28, weight: .semibold)
        let headerDetail = label("Simple local dictation settings.", size: 13, color: .secondaryLabelColor)

        let speechCard = card(
            title: "Speech",
            views: [
                settingRow("Microphone", microphonePopup),
                settingRow("Transcribe model", transcribeModelPopup),
            ]
        )

        let promptButtons = NSStackView(views: [
            button("Save Prompt", action: #selector(savePrompt)),
            button("Reset", action: #selector(resetPrompt)),
        ])
        promptButtons.orientation = .horizontal
        promptButtons.spacing = 8

        let rewriteCard = card(
            title: "Rewrite",
            views: [
                settingRow("Mode", rewriteEnabledCheckbox),
                settingRow("Qwen model", rewriteModelPopup),
                promptScrollView(),
                promptButtons,
                promptStatusLabel,
            ]
        )

        let controlsCard = card(
            title: "Controls",
            views: [
                settingRow("Hotkey", shortcutPopup),
                shortcutStatusLabel,
                launchAtLoginCheckbox,
            ]
        )

        let permissionButtons = NSStackView(views: [
            button("Microphone", action: #selector(requestMicrophone)),
            button("Paste", action: #selector(requestPastePermission)),
            button("Reset Paste", action: #selector(resetPastePermission)),
            button("Test Paste", action: #selector(runPasteTest)),
        ])
        permissionButtons.orientation = .horizontal
        permissionButtons.spacing = 8

        let permissionsCard = card(
            title: "Permissions",
            views: [
                statusLine("Microphone", micStatusLabel),
                statusLine("Paste access", pasteStatusLabel),
                statusLine("Local backend", backendStatusLabel),
                permissionButtons,
            ]
        )

        let stack = NSStackView(views: [
            headerTitle,
            headerDetail,
            speechCard,
            rewriteCard,
            controlsCard,
            permissionsCard,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = documentView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        root.addSubview(scrollView)
        window.contentView = root

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 30),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -30),

            speechCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rewriteCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            controlsCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            permissionsCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func refresh() {
        microphoneOptions = MicrophonePreference.available
        configureMicrophonePopup()
        selectCurrentTranscribeModel()
        selectCurrentRewriteModel()
        rewriteEnabledCheckbox.state = ModelSettings.isRewriteEnabled ? .on : .off
        updateRewriteControls()
        selectCurrentShortcut()
        updateShortcutStatusLabel(shortcutStatus())
        launchAtLoginCheckbox.state = LaunchAtLoginController.isEnabled ? .on : .off
        micStatusLabel.stringValue = microphoneStatusText()
        pasteStatusLabel.stringValue = PasteboardInserter.isAccessibilityTrusted ? "Allowed" : "Needs Accessibility approval"

        Task {
            backendStatusLabel.stringValue = await backendClient.health()
                ? "Running"
                : "Starting or unavailable"
        }

        Task {
            await loadPrompt()
        }
    }

    private func configurePopups() {
        configureMicrophonePopup()

        transcribeModelPopup.removeAllItems()
        transcribeModelPopup.addItems(withTitles: TranscribeModelPreference.all.map(\.label))
        transcribeModelPopup.target = self
        transcribeModelPopup.action = #selector(transcribeModelChanged)
        selectCurrentTranscribeModel()

        rewriteModelPopup.removeAllItems()
        rewriteModelPopup.addItems(withTitles: RewriteModelPreference.all.map(\.label))
        rewriteModelPopup.target = self
        rewriteModelPopup.action = #selector(rewriteModelChanged)
        selectCurrentRewriteModel()

        shortcutPopup.removeAllItems()
        shortcutPopup.addItems(withTitles: ShortcutPreference.all.map(\.label))
        shortcutPopup.target = self
        shortcutPopup.action = #selector(shortcutChanged)
        selectCurrentShortcut()
    }

    private func configureMicrophonePopup() {
        microphonePopup.removeAllItems()
        microphonePopup.addItems(withTitles: microphoneOptions.map(\.label))
        microphonePopup.target = self
        microphonePopup.action = #selector(microphoneChanged)
        let current = MicrophonePreference.current
        let index = microphoneOptions.firstIndex(of: current) ?? 0
        microphonePopup.selectItem(at: index)
    }

    private func configureCheckboxes() {
        rewriteEnabledCheckbox.target = self
        rewriteEnabledCheckbox.action = #selector(rewriteEnabledChanged)

        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(launchAtLoginChanged)
    }

    private func configurePromptEditor() {
        promptTextView.font = .systemFont(ofSize: 13)
        promptTextView.textColor = .labelColor
        promptTextView.backgroundColor = .textBackgroundColor
        promptTextView.isRichText = false
        promptTextView.allowsUndo = true
        promptTextView.textContainerInset = NSSize(width: 10, height: 8)

        promptStatusLabel.font = .systemFont(ofSize: 12)
        promptStatusLabel.textColor = .secondaryLabelColor
    }

    private func updateRewriteControls() {
        let enabled = ModelSettings.isRewriteEnabled
        rewriteModelPopup.isEnabled = enabled
        promptTextView.isEditable = enabled
        promptTextView.textColor = enabled ? .labelColor : .secondaryLabelColor
    }

    private func loadPrompt() async {
        do {
            let settings = try await backendClient.settings()
            promptTextView.string = settings.rewritePrompt
            promptStatusLabel.stringValue = settings.isDefault ? "Using default prompt." : "Using custom prompt."
            promptStatusLabel.textColor = .secondaryLabelColor
        } catch {
            promptStatusLabel.stringValue = "Prompt unavailable until backend is running."
            promptStatusLabel.textColor = .systemOrange
        }
    }

    @objc private func microphoneChanged() {
        let index = microphonePopup.indexOfSelectedItem
        guard microphoneOptions.indices.contains(index) else {
            return
        }
        MicrophonePreference.current = microphoneOptions[index]
    }

    @objc private func transcribeModelChanged() {
        let index = transcribeModelPopup.indexOfSelectedItem
        guard TranscribeModelPreference.all.indices.contains(index) else {
            return
        }
        TranscribeModelPreference.current = TranscribeModelPreference.all[index]
        onModelSettingsChanged()
    }

    @objc private func rewriteEnabledChanged() {
        ModelSettings.isRewriteEnabled = rewriteEnabledCheckbox.state == .on
        updateRewriteControls()
        onModelSettingsChanged()
    }

    @objc private func rewriteModelChanged() {
        let index = rewriteModelPopup.indexOfSelectedItem
        guard RewriteModelPreference.all.indices.contains(index) else {
            return
        }
        RewriteModelPreference.current = RewriteModelPreference.all[index]
        onModelSettingsChanged()
    }

    @objc private func savePrompt() {
        let prompt = promptTextView.string
        promptStatusLabel.stringValue = "Saving..."
        promptStatusLabel.textColor = .secondaryLabelColor
        Task {
            do {
                let settings = try await backendClient.updateRewritePrompt(prompt)
                promptTextView.string = settings.rewritePrompt
                promptStatusLabel.stringValue = "Prompt saved."
                promptStatusLabel.textColor = .secondaryLabelColor
            } catch {
                promptStatusLabel.stringValue = error.localizedDescription
                promptStatusLabel.textColor = .systemRed
            }
        }
    }

    @objc private func resetPrompt() {
        promptStatusLabel.stringValue = "Resetting..."
        promptStatusLabel.textColor = .secondaryLabelColor
        Task {
            do {
                let settings = try await backendClient.resetRewritePrompt()
                promptTextView.string = settings.rewritePrompt
                promptStatusLabel.stringValue = "Default prompt restored."
                promptStatusLabel.textColor = .secondaryLabelColor
            } catch {
                promptStatusLabel.stringValue = error.localizedDescription
                promptStatusLabel.textColor = .systemRed
            }
        }
    }

    @objc private func shortcutChanged() {
        let index = shortcutPopup.indexOfSelectedItem
        guard ShortcutPreference.all.indices.contains(index) else {
            return
        }
        let result = onShortcutChanged(ShortcutPreference.all[index])
        updateShortcutStatusLabel(result)
        if !result.isRegistered {
            selectCurrentShortcut()
        }
    }

    @objc private func launchAtLoginChanged() {
        do {
            try LaunchAtLoginController.setEnabled(launchAtLoginCheckbox.state == .on)
        } catch {
            shortcutStatusLabel.stringValue = error.localizedDescription
            shortcutStatusLabel.textColor = .systemRed
        }
    }

    @objc private func requestMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
        case .denied, .restricted:
            PrivacySettings.openMicrophone()
            refresh()
        case .authorized:
            refresh()
        @unknown default:
            PrivacySettings.openMicrophone()
            refresh()
        }
    }

    @objc private func requestPastePermission() {
        PasteboardInserter.requestAccessibilityPermission()
        if !PasteboardInserter.isAccessibilityTrusted {
            PrivacySettings.openAccessibility()
        }
        refresh()
    }

    @objc private func resetPastePermission() {
        _ = PrivacySettings.resetAccessibilityPermission()
        PrivacySettings.openAccessibility()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.refresh()
        }
    }

    @objc private func runPasteTest() {
        onPasteTest()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.refresh()
        }
    }

    private func selectCurrentTranscribeModel() {
        let index = TranscribeModelPreference.all.firstIndex(of: TranscribeModelPreference.current) ?? 0
        transcribeModelPopup.selectItem(at: index)
    }

    private func selectCurrentRewriteModel() {
        let index = RewriteModelPreference.all.firstIndex(of: RewriteModelPreference.current) ?? 0
        rewriteModelPopup.selectItem(at: index)
    }

    private func selectCurrentShortcut() {
        let index = ShortcutPreference.all.firstIndex(of: ShortcutPreference.current) ?? 0
        shortcutPopup.selectItem(at: index)
    }

    private func updateShortcutStatusLabel(_ status: HotKeyRegistrationStatus?) {
        guard let status else {
            shortcutStatusLabel.stringValue = "Shortcut status unknown."
            shortcutStatusLabel.textColor = .secondaryLabelColor
            return
        }
        shortcutStatusLabel.stringValue = status.message
        shortcutStatusLabel.textColor = status.isRegistered ? .secondaryLabelColor : .systemRed
    }

    private func microphoneStatusText() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return "Allowed"
        case .notDetermined:
            return "Not requested"
        case .denied, .restricted:
            return "Needs microphone approval"
        @unknown default:
            return "Unknown"
        }
    }

    private func settingRow(_ title: String, _ view: NSView) -> NSStackView {
        let titleLabel = label(title, size: 13, weight: .medium, color: .secondaryLabelColor)
        titleLabel.widthAnchor.constraint(equalToConstant: 130).isActive = true

        let row = NSStackView(views: [titleLabel, view])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        return row
    }

    private func statusLine(_ title: String, _ value: NSTextField) -> NSStackView {
        value.font = .systemFont(ofSize: 13)
        value.textColor = .labelColor
        return settingRow(title, value)
    }

    private func promptScrollView() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = promptTextView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(equalToConstant: 150).isActive = true
        return scrollView
    }

    private func card(title: String, views: [NSView]) -> NSView {
        let titleLabel = label(title, size: 16, weight: .semibold)
        let stack = NSStackView(views: [titleLabel] + views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.cornerRadius = 8
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])

        return card
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func label(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor = .labelColor
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}
