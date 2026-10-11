import AppKit
import QuartzCore

// One fixed coordinate space for every level and mute state. Only the wave
// opacity and slash animate; the body centers on mute inside a fixed hit target.
final class AudioGlyphView: NSView {
    private let body = CAShapeLayer()
    private let cutout = CAShapeLayer()
    private let normal = CAShapeLayer()
    private let slash = CAShapeLayer()
    private var hasAudioState = false
    private(set) var percent = 0.0
    private(set) var muted = false
    init(size: CGFloat = 24) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        setAccessibilityElement(false)
        for shape in [body, normal, slash] {
            shape.lineCap = .round; shape.lineJoin = .round
            layer?.addSublayer(shape)
        }
        normal.fillColor = nil; body.opacity = 0
        cutout.fillRule = .evenOdd; cutout.fillColor = NSColor.white.cgColor
        body.mask = cutout
        slash.fillColor = nil; slash.strokeEnd = 0
        updateGeometry(); updateColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); updateGeometry(); updateColors() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateColors() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            body.fillColor = nil
            let canvas = NSImage(size: bounds.size)
            canvas.lockFocus()
            let scale = min(bounds.width, bounds.height) / 24
            let symbol = NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: nil)!
            // SF speaker.fill has a square alignment canvas. Forcing it into 9×16
            // squeezed the body horizontally before the slash mask removed most of it.
            // Preserve its aspect ratio; the five-point translation centers this body.
            let fit = min(16 * scale / symbol.size.width, 16 * scale / symbol.size.height)
            let size = NSSize(width: symbol.size.width * fit, height: symbol.size.height * fit)
            symbol.draw(in: NSRect(x: bounds.midX - 5 * scale - size.width / 2,
                                  y: bounds.midY - size.height / 2,
                                  width: size.width, height: size.height))
            NSColor.labelColor.setFill()
            let context = NSGraphicsContext.current!.cgContext
            context.saveGState(); context.setBlendMode(.sourceIn)
            context.setFillColor(NSColor.labelColor.cgColor); context.fill(NSRect(origin: .zero, size: bounds.size))
            context.restoreGState()
            canvas.unlockFocus()
            body.contents = canvas.cgImage(forProposedRect: nil, context: nil, hints: nil)
            body.contentsGravity = .resizeAspect
            body.contentsScale = window?.backingScaleFactor ?? 2
            slash.strokeColor = NSColor.labelColor.cgColor
            normal.contents = nativeVolumeImage()
            CATransaction.commit()
        }
    }
    private func updateGeometry() {
        let scale = min(bounds.width, bounds.height) / 24
        var transform = CGAffineTransform(translationX: (bounds.width - 24 * scale) / 2,
                                         y: (bounds.height - 24 * scale) / 2).scaledBy(x: scale, y: scale)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        body.frame = bounds
        normal.frame = bounds
        let line = CGMutablePath(); line.move(to: CGPoint(x: 7, y: 19)); line.addLine(to: CGPoint(x: 17, y: 5))
        slash.path = line.copy(using: &transform); slash.lineWidth = 1.8 * scale
        cutout.path = maskPath(muted: muted)
        body.setValue(muted ? 5 * scale : 0, forKeyPath: "transform.translation.x")
        CATransaction.commit()
    }
    private func maskPath(muted: Bool) -> CGPath {
        let scale = min(bounds.width, bounds.height) / 24
        var transform = CGAffineTransform(translationX: (bounds.width - 24 * scale) / 2,
                                         y: (bounds.height - 24 * scale) / 2).scaledBy(x: scale, y: scale)
        let path = CGMutablePath(); path.addRect(CGRect(x: -24, y: -24, width: 72, height: 72))
        // The body's five-point translation places this cut directly under the
        // centered slash. Actual alpha is removed, so any background shows through.
        let gap = CGMutablePath(); gap.move(to: CGPoint(x: 2, y: 19)); gap.addLine(to: CGPoint(x: 12, y: 5))
        path.addPath(gap.copy(strokingWithWidth: muted ? 3.0 : 0.001, lineCap: .round, lineJoin: .round, miterLimit: 1))
        return path.copy(using: &transform)!
    }
    func setLevel(_ level: Double, muted: Bool, animated: Bool = true) {
        let next = level.isFinite ? min(100, max(0, level)) : 0
        guard !hasAudioState || next != percent || muted != self.muted else { return }
        hasAudioState = true; percent = next
        self.muted = muted
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let visible = animated && window?.isVisible == true
        transition(body, key: "transform.translation.x", to: muted ? Double(5 * min(bounds.width, bounds.height) / 24) : 0,
                   animated: visible && !reduceMotion, duration: 0.20)
        let targetMask = maskPath(muted: muted)
        let oldMask = cutout.presentation()?.path ?? cutout.path
        CATransaction.begin(); CATransaction.setDisableActions(true); cutout.path = targetMask; CATransaction.commit()
        cutout.removeAnimation(forKey: "path")
        if visible && !reduceMotion, let oldMask {
            let animation = CABasicAnimation(keyPath: "path")
            animation.fromValue = oldMask; animation.toValue = targetMask; animation.duration = 0.20
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            cutout.add(animation, forKey: "path")
        }
        let oldImage = normal.presentation()?.contents ?? normal.contents
        CATransaction.begin(); CATransaction.setDisableActions(true)
        normal.contents = nativeVolumeImage()
        CATransaction.commit()
        if visible, let oldImage {
            let fade = CABasicAnimation(keyPath: "contents")
            fade.fromValue = oldImage; fade.toValue = normal.contents
            fade.duration = reduceMotion ? 0.10 : 0.16
            normal.add(fade, forKey: "contents")
        }
        transition(normal, key: "opacity", to: muted ? 0 : 1, animated: visible)
        transition(body, key: "opacity", to: muted ? 1 : 0, animated: visible)
        if reduceMotion {
            transition(slash, key: "strokeEnd", to: 1, animated: false)
            transition(slash, key: "opacity", to: muted ? 1 : 0, animated: visible, duration: 0.10)
        } else {
            transition(slash, key: "opacity", to: 1, animated: false)
            transition(slash, key: "strokeEnd", to: muted ? 1 : 0, animated: visible, duration: 0.20)
        }
    }
    private func nativeVolumeImage() -> CGImage? {
        let canvas = NSImage(size: bounds.size)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            canvas.lockFocus()
            let symbol = NSImage(systemSymbolName: "speaker.wave.3.fill", variableValue: percent / 100,
                                 accessibilityDescription: nil)!
            let scale = min(bounds.width / 24, bounds.height / 24)
            let box = NSRect(x: (bounds.width - 24 * scale) / 2,
                             y: (bounds.height - 20 * scale) / 2, width: 24 * scale, height: 20 * scale)
            let ratio = min(box.width / symbol.size.width, box.height / symbol.size.height)
            let size = NSSize(width: symbol.size.width * ratio, height: symbol.size.height * ratio)
            symbol.draw(in: NSRect(x: box.midX-size.width/2, y: box.midY-size.height/2, width: size.width, height: size.height))
            NSColor.labelColor.setFill()
            let context = NSGraphicsContext.current!.cgContext
            context.saveGState(); context.setBlendMode(.sourceIn)
            context.setFillColor(NSColor.labelColor.cgColor); context.fill(NSRect(origin: .zero, size: bounds.size))
            context.restoreGState()
            canvas.unlockFocus()
        }
        return canvas.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
    private func transition(_ shape: CAShapeLayer, key: String, to target: Double,
                            animated: Bool, duration: Double = 0.18) {
        let old = (shape.value(forKeyPath: key) as? NSNumber)?.doubleValue ?? target
        guard abs(old - target) > 0.0001 else { return }
        let displayed = (shape.presentation()?.value(forKeyPath: key) as? NSNumber)?.doubleValue ?? old
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shape.setValue(target, forKeyPath: key); CATransaction.commit()
        shape.removeAnimation(forKey: key)
        guard animated else { return }
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = displayed; animation.toValue = target; animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        shape.add(animation, forKey: key)
    }
}

class MuteIconButton: NSButton {
    private let glyph = AudioGlyphView()
    init() {
        super.init(frame: .zero)
        title = ""; image = nil; isBordered = false
        addSubview(glyph)
        setAudioState(percent: 0, muted: false, animated: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func layout() {
        super.layout()
        glyph.frame = NSRect(x: (bounds.width - 24) / 2, y: (bounds.height - 24) / 2, width: 24, height: 24)
    }
    func setAudioState(percent: Double, muted: Bool, animated: Bool = true) {
        glyph.setLevel(percent, muted: muted, animated: animated)
        toolTip = muted ? L("解除静音") : L("静音")
        setAccessibilityLabel(toolTip!)
        setAccessibilityValue(muted ? L("已静音") : L("未静音"))
    }
}
