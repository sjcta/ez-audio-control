import AppKit

// AppKit owns neighbouring items; only this item's length changes.
final class StatusItemExpansion: NSObject {
    private let item: NSStatusItem
    private let label: NSView
    private let glyph: NSView
    private var timer: Timer?
    private var animationTarget: CGFloat?
    private var dismissal: DispatchWorkItem?
    private var expanded = false
    private var hovered = false
    private var menuOpen = false
    private var lastInput: TimeInterval = 0
    private var textWidth: CGFloat = 20
    private var emphasis: CGFloat = 1
    var numbersEnabled = true {
        didSet {
            guard !numbersEnabled else { return }
            dismissal?.cancel(); timer?.invalidate(); timer = nil
            expanded = false; animationTarget = nil
            label.isHidden = true; label.alphaValue = 0
            item.length = compactWidth; layoutViews()
        }
    }
    var didLayout: (() -> Void)?
    var compactWidth: CGFloat { max(24, NSStatusBar.system.thickness) }
    private var side: CGFloat { (compactWidth - 22) / 2 }
    private var expandedWidth: CGFloat { side + 22 + 2 + textWidth + side }
    init(item: NSStatusItem, label: NSView, glyph: NSView) {
        self.item = item; self.label = label; self.glyph = glyph
        super.init()
        item.button?.wantsLayer = true; item.button?.layer?.masksToBounds = true
        item.button?.addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        item.length = compactWidth; label.isHidden = true; label.alphaValue = 0
        layoutViews()
    }
    func textChanged(width: CGFloat, pending: Bool) {
        textWidth = ceil(width); emphasis = pending ? 0.8 : 1
        layoutViews()
        if expanded { animate(to: expandedWidth) }
    }
    func activity() {
        guard numbersEnabled else { return }
        lastInput = ProcessInfo.processInfo.systemUptime
        expanded = true; animate(to: expandedWidth); armDismissal()
    }
    func setMenuOpen(_ value: Bool) {
        menuOpen = value
        if value { dismissal?.cancel() } else { armDismissal() }
    }
    // NSObject does not inherit NSResponder's Objective-C selector mapping.
    // NSTrackingArea sends mouseEntered:/mouseExited:, not ...With:.
    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) { hovered = true; dismissal?.cancel() }
    @objc(mouseExited:) func mouseExited(with event: NSEvent) { hovered = false; armDismissal() }
    func reset() {
        dismissal?.cancel()
        guard !menuOpen && !hovered else { return }
        expanded = false; animate(to: compactWidth)
    }
    private func armDismissal() {
        dismissal?.cancel()
        guard expanded, !menuOpen, !hovered else { return }
        let delay = max(0.15, 1.5 - (ProcessInfo.processInfo.systemUptime - lastInput))
        let job = DispatchWorkItem { [weak self] in
            guard let self, !self.menuOpen, !self.hovered else { return }
            self.expanded = false; self.animate(to: self.compactWidth)
        }
        dismissal = job; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: job)
    }
    private func layoutViews() {
        guard let button = item.button else { return }
        glyph.frame = NSRect(x: side, y: (button.bounds.height - 22) / 2, width: 22, height: 22)
        label.frame = NSRect(x: side + 24, y: 0, width: textWidth, height: button.bounds.height)
        didLayout?()
    }
    private func animate(to target: CGFloat) {
        if timer != nil, let animationTarget, abs(animationTarget - target) < 0.5 { return }
        timer?.invalidate(); timer = nil; animationTarget = target
        let start = item.length
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduced || abs(start - target) < 0.5 {
            item.length = target; label.isHidden = !expanded; label.alphaValue = expanded ? emphasis : 0
            layoutViews(); return
        }
        let opening = target > start
        // Hide text before reducing its available space; keep the symbol fixed-size.
        label.isHidden = false
        let began = ProcessInfo.processInfo.systemUptime
        let initialAlpha = label.alphaValue
        let animation = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            let widthProgress = min(1, max(0, (elapsed - (opening ? 0 : 0.06)) / 0.12))
            let eased = widthProgress * widthProgress * (3 - 2 * widthProgress)
            self.item.length = start + (target - start) * eased
            if opening {
                self.label.alphaValue = elapsed < 0.12 ? 0 : self.emphasis * min(1, (elapsed - 0.12) / 0.06)
            } else { self.label.alphaValue = initialAlpha * max(0, 1 - elapsed / 0.06) }
            self.layoutViews()
            if elapsed >= 0.18 {
                timer.invalidate(); self.timer = nil
                self.item.length = target; self.label.isHidden = !self.expanded
                self.label.alphaValue = self.expanded ? self.emphasis : 0
                self.layoutViews()
                AudioDiagnostics.shared.record("status layout expanded=\(self.expanded) requested=\(Int(target)) actual=\(Int(self.item.button?.bounds.width ?? 0))")
            }
        }
        timer = animation; RunLoop.main.add(animation, forMode: .common)
    }
    deinit { timer?.invalidate(); dismissal?.cancel() }
}
