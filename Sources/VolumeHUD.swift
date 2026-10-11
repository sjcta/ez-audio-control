import AppKit

private final class VolumeHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
private final class HUDSurface: NSView {
    var hover: ((Bool) -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hover?(true) }
    override func mouseExited(with event: NSEvent) { hover?(false) }
}
private final class HUDLevel: NSSlider {
    var isAdjustable: Bool {
        get { isEnabled }
        set { isEnabled = newValue; if !newValue { cancelTracking() } }
    }
    var percent: Double {
        get { doubleValue }
        set { doubleValue = newValue.isFinite ? min(100, max(0, newValue)) : 0 }
    }
    var onAdjust: ((Double) -> Void)?
    var onTracking: ((Bool) -> Void)?
    private var tracking = false
    private var trackingCancelled = false
    var muted = false { didSet { trackFillColor = muted ? .secondaryLabelColor : nil } }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        minValue = 0; maxValue = 100; isContinuous = true
        controlSize = .small; focusRingType = .none
        target = self; action = #selector(adjust)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isEnabled }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        tracking = true; trackingCancelled = false; onTracking?(true)
        defer { tracking = false; trackingCancelled = false; onTracking?(false) }
        super.mouseDown(with: event)
    }
    // A route change can hide the HUD during AppKit's tracking loop. Do not
    // forward the remainder of that gesture after a different output is ready.
    func cancelTracking() { if tracking { trackingCancelled = true } }
    @objc private func adjust() {
        guard isEnabled, !trackingCancelled else { return }
        onAdjust?(doubleValue)
    }
}
final class VolumeHUD {
    private let panel = VolumeHUDPanel(contentRect: NSRect(x: 0, y: 0, width: 190, height: 36),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let label = VolumeValueLabel("")
    private let image = AudioGlyphView(size: 20)
    private var hasVerifiedState = false
    private var waitingForOutput = false
    private var lastDisplayID: UInt32?
    private let level = HUDLevel(frame: .zero)
    private var dismissal: DispatchWorkItem?
    private var fadeTimer: Timer?
    private var hovering = false
    private var tracking = false
    private var presentation = 0
    var isEnabled = true { didSet { if !isEnabled { hide() } } }
    var isSoftwareAttenuation = false {
        didSet { level.setAccessibilityLabel(isSoftwareAttenuation ? L("软件衰减；100% 原始电平，0% 静音") : L("音量")) }
    }
    var anchor: (() -> NSRect?)?
    var onAdjust: ((Double) -> Void)? {
        didSet { level.onAdjust = onAdjust }
    }
    private let presentationEnabled: Bool
    init(presentationEnabled: Bool = true) {
        self.presentationEnabled = presentationEnabled
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.hidesOnDeactivate = false
        // The compact HUD keeps hover-to-stay without taking keyboard focus.
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let view = HUDSurface(frame: NSRect(x: 0, y: 0, width: 190, height: 36))
        view.hover = { [weak self] entered in
            guard let self else { return }
            self.hovering = entered
            if entered { self.holdPresentation() }
            else { self.scheduleDismissal(after: 1.2) }
        }
        level.onTracking = { [weak self] active in
            guard let self else { return }
            self.tracking = active
            if active { self.holdPresentation() }
            else if self.panel.isVisible {
                self.hovering = self.panel.frame.contains(NSEvent.mouseLocation)
                self.scheduleDismissal(after: 1.2)
            }
        }
        image.frame = NSRect(x: 8, y: 8, width: 20, height: 20)
        level.translatesAutoresizingMaskIntoConstraints = false
        level.setAccessibilityLabel(L("音量"))
        label.wantsLayer = true
        for item in [image, level, label] { view.addSubview(item) }
        NSLayoutConstraint.activate([
            level.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 38),
            level.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -8),
            level.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            level.heightAnchor.constraint(equalToConstant: 20),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: view.frame)
            glass.style = .regular; glass.cornerRadius = 18; glass.contentView = view
            if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
            panel.contentView = glass
        } else {
            let effect = NSVisualEffectView(frame: view.frame)
            effect.material = .popover; effect.blendingMode = .behindWindow; effect.state = .active
            effect.wantsLayer = true; effect.layer?.cornerRadius = 18; effect.layer?.masksToBounds = true
            effect.addSubview(view); panel.contentView = effect
        }
        panel.contentView?.layoutSubtreeIfNeeded()
    }
    private func setLabel(_ text: String) {
        guard label.stringValue != text else { return }
        label.stringValue = text
        label.setAccessibilityLabel(text)
    }
    func pending(displayID: UInt32, requested: AudioState? = nil, muted: Bool = false) {
        waitingForOutput = false
        if lastDisplayID != displayID { hasVerifiedState = false }
        if lastDisplayID != displayID && requested == nil {
            setLabel(volumePercent(0)); level.percent = 0
            image.setLevel(0, muted: false, animated: false)
        }
        if let requested {
            level.isAdjustable = true
            level.percent = VolumePolicy.percent(raw: requested.current, maximum: requested.maximum)
            setLabel(volumePercent(level.percent))
            image.setLevel(level.percent, muted: muted)
            level.muted = muted
        }
        label.alphaValue = 0.8; level.alphaValue = 1
        label.toolTip = isSoftwareAttenuation ? L("软件衰减 \(label.stringValue)，100% 原始电平，0% 静音") : L("目标音量 \(label.stringValue)，等待设备确认")
        lastDisplayID = displayID
        present(displayID: displayID, duration: 2)
    }
    func verified(_ snapshot: AudioSnapshot, displayID: UInt32) {
        waitingForOutput = false
        level.isAdjustable = true
        let percent = VolumePolicy.percent(raw: snapshot.volume.current, maximum: snapshot.volume.maximum)
        let muted = snapshot.effectiveSilent
        setLabel(snapshot.mute == 1 ? L("静音") : volumePercent(percent))
        label.setAccessibilityLabel(label.stringValue)
        image.setLevel(percent, muted: muted)
        hasVerifiedState = true; lastDisplayID = displayID
        label.alphaValue = 1; level.alphaValue = 1
        label.toolTip = isSoftwareAttenuation ? L("100% 原始电平 · 0% 静音 · 不改变硬件音量") : nil
        level.percent = percent; level.muted = muted; level.isHidden = false
        level.setAccessibilityValue(muted ? L("静音") : volumePercent(percent))
        present(displayID: displayID, duration: 1.5)
    }
    func failure(displayID: UInt32) {
        waitingForOutput = false
        level.isAdjustable = false
        // Keep every frame in place even on failure; details remain in Settings.
        label.stringValue = "!"; label.toolTip = L("调节失败；请在设置中查看详情")
        label.setAccessibilityLabel(L("调节失败"))
        label.alphaValue = 1; level.alphaValue = 0.4
        present(displayID: displayID, duration: 2)
    }
    func unavailable(displayID: UInt32, reason: String) {
        waitingForOutput = true
        hasVerifiedState = false; lastDisplayID = displayID
        setLabel("—"); label.toolTip = reason; label.alphaValue = 1
        level.percent = 0; level.muted = false; level.alphaValue = 0.4
        level.isAdjustable = false; level.setAccessibilityValue(reason)
        image.setLevel(0, muted: false, animated: false)
        present(displayID: displayID, duration: 2)
    }
    func resolveWaiting(_ snapshot: AudioSnapshot, displayID: UInt32) {
        guard waitingForOutput, panel.isVisible, lastDisplayID == displayID else { return }
        verified(snapshot, displayID: displayID)
    }
    private func present(displayID: UInt32, duration: Double) {
        guard isEnabled else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        dismissal?.cancel(); fadeTimer?.invalidate(); fadeTimer = nil; presentation += 1
        // A hidden/unavailable status item must never fall back to the bottom.
        guard let anchorRect = anchor?() else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchorRect.midX, y: anchorRect.midY)) }
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrameOrigin(Self.origin(anchor: anchorRect, visible: visible, size: panel.frame.size))
        panel.alphaValue = 1
        // Neither display nor a button click can make this panel key.
        guard presentationEnabled else { return }
        if !panel.isVisible { panel.orderFront(nil) }
        scheduleDismissal(after: duration)
    }
    func reposition() {
        guard panel.isVisible, let rect = anchor?(),
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) }) else { return }
        panel.setFrameOrigin(Self.origin(anchor: rect, visible: screen.visibleFrame, size: panel.frame.size))
    }
    static func origin(anchor: NSRect, visible: NSRect, size: NSSize) -> NSPoint {
        NSPoint(x: max(visible.minX + 4, min(anchor.midX - size.width / 2, visible.maxX - size.width - 4)),
                y: max(visible.minY, min(anchor.minY - size.height - 4, visible.maxY - size.height)))
    }
    private func holdPresentation() {
        dismissal?.cancel(); fadeTimer?.invalidate(); fadeTimer = nil
        presentation += 1; panel.alphaValue = 1
    }
    private func scheduleDismissal(after delay: Double) {
        dismissal?.cancel()
        guard !hovering, !tracking else { return }
        let token = presentation
        let job = DispatchWorkItem { [weak self] in
            guard let self, self.presentation == token, !self.hovering, !self.tracking else { return }
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                self.panel.orderOut(nil); return
            }
            let start = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
                guard let self, self.presentation == token, !self.hovering, !self.tracking else { timer.invalidate(); return }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - start) / 0.18)
                self.panel.alphaValue = 1 - progress
                if progress >= 1 { timer.invalidate(); self.fadeTimer = nil; self.panel.orderOut(nil) }
            }
            self.fadeTimer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        dismissal = job; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: job)
    }
    func hide() { level.cancelTracking(); fadeTimer?.invalidate(); fadeTimer = nil; presentation += 1; dismissal?.cancel(); dismissal = nil; hovering = false; panel.orderOut(nil) }
}
