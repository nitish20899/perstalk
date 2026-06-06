import AppKit

@MainActor
final class FloatingPanel: NSPanel {
    private let pillView = FlowPillView()
    private var hideTask: Task<Void, Never>?

    var onAction: (() -> Void)? {
        didSet {
            pillView.onAction = onAction
        }
    }

    var onCancel: (() -> Void)? {
        didSet {
            pillView.onCancel = onCancel
        }
    }

    init() {
        let frame = NSRect(x: 0, y: 0, width: 186, height: 60)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false

        pillView.frame = NSRect(origin: .zero, size: frame.size)
        pillView.autoresizingMask = [.width, .height]
        contentView = pillView
    }

    func showIdle() {
        update(
            title: "Perstalk",
            detail: ShortcutPreference.current.idleInstruction,
            isRecording: false
        )
        show(anchor: PopupAnchor.current(for: nil))
    }

    func show(anchor: NSPoint? = nil) {
        hideTask?.cancel()
        positionNearBottomCenter()
        orderFrontRegardless()
    }

    func update(title: String, detail: String, isRecording: Bool, actionTitle: String? = nil) {
        hideTask?.cancel()
        pillView.toolTip = "\(title). \(detail)"
        pillView.mode = isRecording ? .recording : .idle
        if isRecording {
            pillView.level = max(pillView.level, 12)
        } else if title == "Processing" || title == "Polishing" || title.contains("MLX") {
            pillView.mode = .processing
        } else {
            pillView.level = 0
        }
    }

    func hide(after seconds: TimeInterval) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            let nanoseconds = UInt64(seconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                self?.orderOut(nil)
            }
        }
    }

    func updateLevel(_ level: Double) {
        pillView.level = min(100, max(0, level))
    }

    private func positionNearBottomCenter() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screenFrame = screen?.visibleFrame else {
            center()
            return
        }
        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.minY + 28
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private final class FlowPillView: NSView {
    enum Mode {
        case idle
        case recording
        case processing
    }

    var mode: Mode = .idle {
        didSet {
            needsDisplay = true
        }
    }

    var level: Double = 0 {
        didSet {
            recordLevel(level)
            needsDisplay = true
        }
    }

    var onAction: (() -> Void)?
    var onCancel: (() -> Void)?
    private var recentLevels = Array(repeating: CGFloat(0.08), count: 13)
    private var lastHistorySampleAt = Date.distantPast

    override var isOpaque: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.clear.setFill()
        bounds.fill()

        let pillRect = bounds.insetBy(dx: 2, dy: 2)
        drawShadow(around: pillRect)
        drawPill(in: pillRect)
        drawCancel(in: cancelRect(in: pillRect))
        drawCheck(in: actionRect(in: pillRect))
        drawWaveform(in: waveRect(in: pillRect))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let pillRect = bounds.insetBy(dx: 2, dy: 2)

        if cancelRect(in: pillRect).contains(point) {
            onCancel?()
            return
        }
        if actionRect(in: pillRect).contains(point) {
            onAction?()
            return
        }

        window?.performDrag(with: event)
    }

    private func cancelRect(in pillRect: NSRect) -> NSRect {
        NSRect(x: pillRect.minX + 12, y: pillRect.midY - 21, width: 42, height: 42)
    }

    private func actionRect(in pillRect: NSRect) -> NSRect {
        NSRect(x: pillRect.maxX - 54, y: pillRect.midY - 21, width: 42, height: 42)
    }

    private func waveRect(in pillRect: NSRect) -> NSRect {
        NSRect(x: pillRect.midX - 34, y: pillRect.midY - 15, width: 68, height: 30)
    }

    private func drawShadow(around rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawPill(in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.black.setFill()
        path.fill()
        NSColor(calibratedRed: 0.25, green: 0.24, blue: 0.27, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawCancel(in rect: NSRect) {
        let circle = NSBezierPath(ovalIn: rect)
        NSColor(calibratedWhite: 0.24, alpha: 1).setFill()
        circle.fill()

        let inset = rect.insetBy(dx: 13.5, dy: 13.5)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: inset.minX, y: inset.minY))
        path.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
        path.move(to: NSPoint(x: inset.maxX, y: inset.minY))
        path.line(to: NSPoint(x: inset.minX, y: inset.maxY))
        NSColor.white.setStroke()
        path.lineWidth = 2.2
        path.lineCapStyle = .round
        path.stroke()
    }

    private func drawCheck(in rect: NSRect) {
        let circle = NSBezierPath(ovalIn: rect)
        NSColor(calibratedWhite: 0.24, alpha: 1).setFill()
        circle.fill()

        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + 12, y: rect.midY - 1))
        path.line(to: NSPoint(x: rect.midX - 2, y: rect.minY + 12))
        path.line(to: NSPoint(x: rect.maxX - 11.5, y: rect.maxY - 12))
        NSColor.white.setStroke()
        path.lineWidth = 2.35
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private func drawWaveform(in rect: NSRect) {
        let bars = recentLevels.count
        let barWidth: CGFloat = 3.8
        let gap: CGFloat = 2.2
        let totalWidth = CGFloat(bars) * barWidth + CGFloat(bars - 1) * gap
        let startX = rect.midX - totalWidth / 2
        let centerY = rect.midY
        let active = mode == .recording

        NSColor.white.setFill()
        for index in 0..<bars {
            let x = startX + CGFloat(index) * (barWidth + gap)
            let height: CGFloat
            if active {
                let sample = recentLevels[index]
                height = sample < 0.12 ? 4 : max(6, 4 + rect.height * sample * 0.9)
            } else if mode == .processing {
                height = 4
            } else {
                height = 4
            }
            let bar = NSRect(x: x, y: centerY - height / 2, width: barWidth, height: height)
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }

    private func recordLevel(_ level: Double) {
        guard mode == .recording else {
            if level <= 0 {
                recentLevels = Array(repeating: CGFloat(0.08), count: recentLevels.count)
                lastHistorySampleAt = .distantPast
            }
            return
        }

        let now = Date()
        let normalized = CGFloat(max(0.04, min(1, sqrt(level / 100))))
        let previous = recentLevels.last ?? normalized
        let visual = min(1, max(0.04, previous * 0.25 + normalized * 0.75))

        if now.timeIntervalSince(lastHistorySampleAt) >= 0.035 {
            recentLevels.removeFirst()
            recentLevels.append(visual)
            lastHistorySampleAt = now
        } else {
            recentLevels[recentLevels.count - 1] = visual
        }
    }
}
