import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let targetAppTracker = TargetAppTracker()
    private lazy var flowController = FlowController(targetAppTracker: targetAppTracker)
    private lazy var settingsWindowController = SettingsWindowController(
        backendClient: flowController.backendClient,
        shortcutStatus: { [weak self] in
            self?.hotKeyManager.registrationStatus
        },
        onShortcutChanged: { [weak self] shortcut in
            self?.hotKeyManager.updateShortcut(shortcut)
                ?? HotKeyRegistrationStatus(
                    shortcut: shortcut,
                    isRegistered: false,
                    message: "Shortcut manager is unavailable."
                )
        },
        onModelSettingsChanged: { [weak self] in
            guard let flowController = self?.flowController else {
                return
            }
            Task { @MainActor in
                await flowController.restartBackendForCurrentProfile()
            }
        },
        onPasteTest: { [weak self] in
            self?.flowController.runPasteTest()
        }
    )
    private let hotKeyManager = HotKeyManager()
    private var primaryDictationItem: NSMenuItem?
    private var cancelDictationItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        targetAppTracker.start()
        configureStatusItem()

        hotKeyManager.onPressed = { [weak self] in
            self?.flowController.beginDictation()
        }
        hotKeyManager.onReleased = { [weak self] in
            self?.flowController.finishDictation()
        }
        let hotKeyStatus = hotKeyManager.register()
        if !hotKeyStatus.isRegistered {
            flowController.showMessage("Shortcut unavailable", detail: hotKeyStatus.message)
        }

        Task {
            await flowController.prepareBackend()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyManager.unregister()
        targetAppTracker.stop()
        flowController.shutdown()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handle(url: url)
        }
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Perstalk")
            button.imagePosition = .imageOnly
            button.toolTip = "Perstalk Flow"
        }

        let menu = NSMenu()
        menu.delegate = self

        let primaryItem = NSMenuItem(
            title: flowController.primaryMenuActionTitle,
            action: #selector(toggleDictation),
            keyEquivalent: ""
        )
        primaryDictationItem = primaryItem
        menu.addItem(primaryItem)

        let cancelItem = NSMenuItem(
            title: "Cancel active dictation",
            action: #selector(cancelDictation),
            keyEquivalent: ""
        )
        cancelDictationItem = cancelItem
        menu.addItem(cancelItem)

        menu.addItem(
            NSMenuItem(
                title: "Show popup",
                action: #selector(showPopup),
                keyEquivalent: ""
            )
        )
        menu.addItem(
            NSMenuItem(
                title: "Copy last dictation",
                action: #selector(copyLastDictation),
                keyEquivalent: ""
            )
        )
        menu.addItem(
            NSMenuItem(
                title: "Copy last transcript",
                action: #selector(copyLastTranscript),
                keyEquivalent: ""
            )
        )
        menu.addItem(
            NSMenuItem(
                title: "Copy last formatted transcript",
                action: #selector(copyLastFormattedTranscript),
                keyEquivalent: ""
            )
        )
        menu.addItem(
            NSMenuItem(
                title: "Clear dictation history",
                action: #selector(clearDictationHistory),
                keyEquivalent: ""
            )
        )
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(
                title: "Settings...",
                action: #selector(showSettings),
                keyEquivalent: ","
            )
        )
        menu.addItem(
            NSMenuItem(
                title: "Open web app",
                action: #selector(openWebApp),
                keyEquivalent: ""
            )
        )
        menu.addItem(
            NSMenuItem(
                title: "Request paste permission",
                action: #selector(requestAccessibilityPermission),
                keyEquivalent: ""
            )
        )
        menu.addItem(
            NSMenuItem(
                title: "Reset paste permission",
                action: #selector(resetAccessibilityPermission),
                keyEquivalent: ""
            )
        )
        menu.addItem(
            NSMenuItem(
                title: "Run paste test",
                action: #selector(runPasteTest),
                keyEquivalent: ""
            )
        )
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit Perstalk",
                action: #selector(quit),
                keyEquivalent: "q"
            )
        )

        for item in menu.items {
            item.target = self
        }
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        primaryDictationItem?.title = flowController.primaryMenuActionTitle
        cancelDictationItem?.isEnabled = flowController.canCancelDictation
    }

    @objc private func toggleDictation() {
        flowController.toggleDictation()
    }

    @objc private func cancelDictation() {
        flowController.cancelDictation()
    }

    @objc private func showPopup() {
        flowController.showIdlePopup()
    }

    @objc private func copyLastDictation() {
        guard DictationHistory.isEnabled else {
            flowController.showMessage("History disabled", detail: "Enable local history in Settings first.")
            return
        }
        guard let text = DictationHistory.lastText(), !text.isEmpty else {
            flowController.showMessage("No dictation history", detail: "Dictate something first.")
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        flowController.showMessage("Copied", detail: "Last cleaned dictation copied.", hideAfter: 1.2)
    }

    @objc private func copyLastTranscript() {
        guard DictationHistory.isEnabled else {
            flowController.showMessage("History disabled", detail: "Enable local history in Settings first.")
            return
        }
        guard let transcript = DictationHistory.lastEntry()?.transcript, !transcript.isEmpty else {
            flowController.showMessage("No transcript history", detail: "Dictate something first.")
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcript, forType: .string)
        flowController.showMessage("Copied", detail: "Last raw transcript copied.", hideAfter: 1.2)
    }

    @objc private func copyLastFormattedTranscript() {
        guard DictationHistory.isEnabled else {
            flowController.showMessage("History disabled", detail: "Enable local history in Settings first.")
            return
        }
        guard let entry = DictationHistory.lastEntry() else {
            flowController.showMessage("No transcript history", detail: "Dictate something first.")
            return
        }
        let formattedTranscript = entry.formattedTranscript ?? entry.transcript
        guard !formattedTranscript.isEmpty else {
            flowController.showMessage("No formatted transcript", detail: "Dictate something first.")
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(formattedTranscript, forType: .string)
        flowController.showMessage("Copied", detail: "Last formatted transcript copied.", hideAfter: 1.2)
    }

    @objc private func clearDictationHistory() {
        DictationHistory.clear()
        let detail = DictationHistory.isEnabled
            ? "Local dictation history removed."
            : "Local history is disabled."
        flowController.showMessage("History cleared", detail: detail, hideAfter: 1.2)
    }

    @objc private func showSettings() {
        settingsWindowController.show()
    }

    @objc private func openWebApp() {
        NSWorkspace.shared.open(URL(string: "http://127.0.0.1:5050")!)
    }

    @objc private func requestAccessibilityPermission() {
        PasteboardInserter.requestAccessibilityPermission()
        if !PasteboardInserter.isAccessibilityTrusted {
            PrivacySettings.openAccessibility()
        }
        flowController.showMessage(
            "Paste permission",
            detail: "Approve Perstalk in System Settings so it can paste into the active app."
        )
    }

    @objc private func resetAccessibilityPermission() {
        let didReset = PrivacySettings.resetAccessibilityPermission()
        PrivacySettings.openAccessibility()
        flowController.showMessage(
            didReset ? "Paste permission reset" : "Paste reset failed",
            detail: didReset
                ? "Approve the current Perstalk Flow build in Accessibility."
                : "Remove Perstalk Flow manually, then approve the current build."
        )
    }

    @objc private func runPasteTest() {
        flowController.runPasteTest()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func handle(url: URL) {
        guard url.scheme == "perstalk-flow" else {
            return
        }

        let command = url.host ?? url.pathComponents.dropFirst().first ?? ""
        switch command {
        case "paste-test":
            flowController.runPasteTest()
        case "show":
            flowController.showIdlePopup()
        case "settings":
            settingsWindowController.show()
        default:
            flowController.showMessage(
                "Unknown Perstalk command",
                detail: url.absoluteString,
                hideAfter: 1.6
            )
        }
    }
}
