import AppKit

struct TargetAppContext {
    let name: String
    let bundleIdentifier: String
    let processIdentifier: pid_t

    init?(app: NSRunningApplication) {
        let ownBundleID = Bundle.main.bundleIdentifier
        let bundleID = app.bundleIdentifier ?? ""
        if !bundleID.isEmpty, bundleID == ownBundleID {
            return nil
        }

        name = app.localizedName ?? "Unknown App"
        bundleIdentifier = bundleID
        processIdentifier = app.processIdentifier
    }

    static func current() -> TargetAppContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        return TargetAppContext(app: app)
    }
}

@MainActor
final class TargetAppTracker {
    private var lastExternalApp: TargetAppContext?
    private var observer: NSObjectProtocol?

    func start() {
        update(with: NSWorkspace.shared.frontmostApplication)

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                self?.update(with: app)
            }
        }
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
    }

    func currentTarget() -> TargetAppContext? {
        TargetAppContext.current() ?? lastExternalApp
    }

    private func update(with app: NSRunningApplication?) {
        guard let app, let context = TargetAppContext(app: app) else {
            return
        }
        lastExternalApp = context
    }
}
