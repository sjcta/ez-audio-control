import AppKit
import QuartzCore
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var checks = 0
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
let row = CompactControls()
expect(row.frame.size == NSSize(width: 190, height: 36), "compact left-click size")
expect(row.subviews.count == 3, "left click contains only volume indicator, slider and value")
let rowFrames = row.subviews.map(\.frame)
let originalSpeakerFrame = row.speaker.frame
let originalValueFrame = row.value.frame
let originalSliderFrame = row.slider.frame
row.setFrameSize(NSSize(width: 280, height: 36))
row.layoutSubtreeIfNeeded()
expect(row.speaker.frame == originalSpeakerFrame, "long compact row keeps the speaker fixed")
expect(row.slider.frame.width > originalSliderFrame.width, "long compact row grows only the slider")
let wideValueAlignment = row.value.alignmentRect(forFrame: row.value.frame)
expect(wideValueAlignment.maxX <= row.bounds.maxX - 9 && wideValueAlignment.maxX >= row.bounds.maxX - 11,
       "long compact row keeps ten point right padding in the label alignment rect")
expect(row.value.frame.minX > row.slider.frame.maxX, "long compact row keeps a gap before the value")
row.setFrameSize(NSSize(width: 190, height: 36))
row.layoutSubtreeIfNeeded()
expect(row.speaker.frame == originalSpeakerFrame && row.value.frame == originalValueFrame && row.slider.frame == originalSliderFrame,
       "compact row returns to the original layout")
let compactStableSliderFrame = row.slider.frame
for (raw, text) in [(0, "0%"), (1, "1%"), (99, "99%"), (100, "100%")] {
    row.slider.doubleValue = Double(raw)
    row.value.stringValue = text
    row.value.invalidateIntrinsicContentSize()
    row.layoutSubtreeIfNeeded()
    expect(row.slider.frame == compactStableSliderFrame, "compact numeric label \(text) does not move the slider")
    expect(abs(row.value.frame.midY - 18) <= 0.5, "compact numeric label \(text) is vertically centered")
    expect(row.value.frame.height + 0.5 >= row.value.fittingSize.height, "compact numeric label \(text) is not clipped vertically")
    expect(row.value.frame.width + 0.5 >= row.value.fittingSize.width, "compact numeric label \(text) is not clipped horizontally")
}
row.setFrameSize(NSSize(width: 360, height: 36))
row.value.stringValue = "System volume 100%"
row.value.invalidateIntrinsicContentSize()
row.layoutSubtreeIfNeeded()
expect(row.value.frame.width + 0.5 >= row.value.fittingSize.width, "long System label fits without truncation")
expect(abs(row.value.frame.midY - 18) <= 0.5, "long System label is vertically centered")
let longValueAlignment = row.value.alignmentRect(forFrame: row.value.frame)
expect(longValueAlignment.maxX <= row.bounds.maxX - 9 && longValueAlignment.maxX >= row.bounds.maxX - 11,
       "long System label keeps the trailing inset in the label alignment rect")
row.value.stringValue = "100%"
row.value.invalidateIntrinsicContentSize()
row.setFrameSize(NSSize(width: 190, height: 36))
row.layoutSubtreeIfNeeded()
let button = MuteIconButton()
button.frame = NSRect(x: 0, y: 0, width: 26, height: 28)
button.layoutSubtreeIfNeeded()
let icon = button.subviews.compactMap { $0 as? AudioGlyphView }.first!
let window = NSPanel(contentRect: row.frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = row
row.layoutSubtreeIfNeeded()
let iconFrame = icon.frame
for percent in [100.0, 75, 40, 15, 0] {
    button.setAudioState(percent: percent, muted: false)
    row.speaker.setLevel(percent, muted: false)
    row.layoutSubtreeIfNeeded()
    expect(row.subviews.map(\.frame) == rowFrames && icon.frame == iconFrame, "volume must not move or resize controls")
    expect(button.toolTip == "静音", "unmuted icon describes mute action")
}
button.setAudioState(percent: 40, muted: true)
expect(button.toolTip == "解除静音", "muted icon describes unmute action")
expect(icon.frame == iconFrame, "slash does not resize the icon")
let layers = icon.layer!.sublayers!.compactMap { $0 as? CAShapeLayer }
expect(layers[1].opacity == 0, "mute hides native sound waves")
expect(layers[2].strokeEnd == 1 && layers[2].opacity == 1, "mute completes slash")
expect((layers[0].value(forKeyPath: "transform.translation.x") as! NSNumber).doubleValue == 5, "muted speaker is centered")
expect(layers[2].path!.boundingBoxOfPath.width == 10, "slash is sized to speaker, not waves")
expect((layers[0].mask as? CAShapeLayer)?.fillRule == .evenOdd, "slash cuts transparent negative space")
button.setAudioState(percent: 100, muted: false)
expect(layers[1].contents != nil && layers[1].opacity == 1, "native variable-volume symbol rendered")
let position = VolumeHUD.origin(anchor: NSRect(x: 980, y: 776, width: 62, height: 24),
                                visible: NSRect(x: 0, y: 0, width: 1024, height: 776), size: NSSize(width: 190, height: 36))
expect(position.y == 736, "automatic HUD appears below status item, not bottom")
expect(position.x + 190 <= 1020, "HUD stays inside display edge")
let hud = VolumeHUD(presentationEnabled: false)
let panel = Mirror(reflecting: hud).children.first { $0.label == "panel" }!.value as! NSPanel
expect(panel.frame.size == NSSize(width: 190, height: 36), "compact top HUD size")
if #available(macOS 26.0, *) {
    expect(panel.contentView is NSGlassEffectView, "real native glass")
    expect((panel.contentView as? NSGlassEffectView)?.style == .regular, "HUD uses regular native glass")
}
if #available(macOS 27.0, *) {
    expect((panel.contentView as? NSGlassEffectView)?.effectIsInteractive == true, "HUD glass is interactive on macOS 27")
}
hud.pending(displayID: 3, requested: AudioState(current: 47, maximum: 100))
let label = Mirror(reflecting: hud).children.first { $0.label == "label" }!.value as! VolumeValueLabel
expect(label.stringValue == "47%", "pending HUD keeps a number, never ellipsis")
hud.verified(AudioSnapshot(volume: AudioState(current: 46, maximum: 100), mute: 2), displayID: 3)
expect(label.stringValue == "46%", "hardware result replaces requested number")
panel.contentView?.layoutSubtreeIfNeeded()
let hudStableSliderFrame = (Mirror(reflecting: hud).children.first { $0.label == "level" }!.value as! NSSlider).frame
for (raw, text) in [(0, "0%"), (1, "1%"), (99, "99%"), (100, "100%")] {
    hud.verified(AudioSnapshot(volume: AudioState(current: raw, maximum: 100), mute: 2), displayID: 3)
    panel.contentView?.layoutSubtreeIfNeeded()
    expect(label.stringValue == text, "HUD numeric label \(text) is displayed")
    expect(abs(label.frame.midY - 18) <= 0.5, "HUD numeric label \(text) is vertically centered")
    expect(label.frame.height + 0.5 >= label.fittingSize.height, "HUD numeric label \(text) is not clipped vertically")
    expect(label.frame.width + 0.5 >= label.fittingSize.width, "HUD numeric label \(text) is not clipped horizontally")
    let currentSlider = Mirror(reflecting: hud).children.first { $0.label == "level" }!.value as! NSSlider
    expect(currentSlider.frame == hudStableSliderFrame, "HUD numeric label \(text) does not move the slider")
}
hud.verified(AudioSnapshot(volume: AudioState(current: 100, maximum: 100), mute: 1), displayID: 3)
panel.contentView?.layoutSubtreeIfNeeded()
let mutedFrame = label.frame
expect(label.stringValue == "静音", "HUD muted label is localized")
expect(mutedFrame.width + 0.5 >= label.fittingSize.width, "HUD muted label is not clipped")
expect(abs(mutedFrame.midY - 18) <= 0.5, "HUD muted label is vertically centered")
let longHUDText = "System volume 100%"
label.stringValue = longHUDText
label.invalidateIntrinsicContentSize()
panel.contentView?.layoutSubtreeIfNeeded()
expect(label.frame.width + 0.5 >= label.fittingSize.width, "HUD long System label fits without truncation")
expect(abs(label.frame.midY - 18) <= 0.5, "HUD long System label is vertically centered")
label.stringValue = "100%"
label.invalidateIntrinsicContentSize()
panel.contentView?.layoutSubtreeIfNeeded()
expect(!panel.canBecomeKey && !panel.canBecomeMain && !panel.hidesOnDeactivate, "HUD never takes focus or hide on app deactivation")
expect(!window.isVisible, "offscreen validation must not display UI")
let track = Mirror(reflecting: hud).children.first { $0.label == "level" }!.value as! NSSlider
expect(track.frame.height == 20, "HUD has a 20 point slider target without larger panel")
expect(track.minValue == 0 && track.maxValue == 100 && track.isContinuous, "HUD slider uses a continuous 0-100 range")
var adjusted: Double?
hud.onAdjust = { adjusted = $0 }
expect(track.target != nil && track.action != nil, "HUD slider has a local target/action")
for (value, expected) in [(50.0, 50.0), (0.0, 0.0), (100.0, 100.0)] {
    adjusted = nil
    track.doubleValue = value
    _ = track.sendAction(track.action, to: track.target)
    expect(adjusted == expected, "HUD NSSlider target/action sends bounded adjustment without event posting")
}

// Render the actual CAShapeLayers at six endpoint states, without UI or DDC.
let image = NSImage(size: NSSize(width: 480, height: 100))
image.lockFocus()
NSColor.windowBackgroundColor.setFill(); NSRect(x: 0, y: 0, width: 480, height: 100).fill()
for (index,state) in [(100.0,false),(70,false),(40,false),(15,false),(0,false),(53,true)].enumerated() {
    let glyph = AudioGlyphView(size: 32)
    glyph.appearance = NSAppearance(named: .darkAqua)
    glyph.setLevel(state.0, muted: state.1, animated: false)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState(); ctx.translateBy(x: CGFloat(index)*80+24,y: 46)
    glyph.layer!.render(in: ctx); ctx.restoreGState()
    let title = state.1 ? "静音" : "\(Int(state.0))%"
    (title as NSString).draw(at: NSPoint(x: CGFloat(index)*80+23,y: 18),
        withAttributes: [.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.labelColor])
}
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath:"/tmp/sac-audio-glyph-states.png"))
print("PASS: \(checks) fixed-layout/wave/mute-state checks; offscreen only, no DDC and no event posting. Native animation timing still requires visual observation.")

let hudImage = Mirror(reflecting: hud).children.first { $0.label == "image" }!.value as! AudioGlyphView
for raw in [49, 48, 0, 1, 60, 10] {
    hud.pending(displayID: 3, requested: AudioState(current: raw, maximum: 100), muted: raw == 0)
    expect(label.stringValue == "\(raw)%" && hudImage.percent == Double(raw), "pending number and wave share latest state")
    expect(track.alphaValue == 1, "pending progress never dims between writes")
    expect(hudImage.muted == (raw == 0), "zero silent, positive restored")
}
hud.failure(displayID: 3)
hud.verified(AudioSnapshot(volume: AudioState(current: 1, maximum: 100), mute: 2), displayID: 3)
expect(label.stringValue == "1%" && !hudImage.muted, "error recovery uses confirmed positive level")
hud.verified(AudioSnapshot(volume: AudioState(current: 0, maximum: 100), mute: 2), displayID: 3)
expect(label.stringValue == "0%" && hudImage.muted, "external zero is silent, keeps numeric value")
print("PASS \(checks) visual checks including continuous progress/zero/error recovery")

hud.isEnabled = false
hud.pending(displayID: 3, requested: AudioState(current: 42, maximum: 100))
hud.verified(AudioSnapshot(volume: AudioState(current: 42, maximum: 100), mute: 2), displayID: 3)
hud.failure(displayID: 3)
expect(!panel.isVisible, "disabled HUD stays hidden for pending/confirmed/failure")
expect(DisplayMode(savedValue: nil) == .full && DisplayMode(savedValue: "unknown") == .full, "default and invalid preference preserve full mode")
for mode in DisplayMode.allCases {
    expect(DisplayMode(savedValue: mode.rawValue) == mode, "saved mode roundtrip")
}
expect(DisplayMode.hud.showsHUD && !DisplayMode.hud.showsNumbers, "HUD only")
expect(DisplayMode(savedValue: "numbers") == .full, "legacy numbers-only mode restores the always-on HUD")
expect(DisplayMode.allCases.allSatisfy { $0.showsHUD }, "every current presentation mode keeps the HUD")
expect(DisplayMode.full.showsHUD && DisplayMode.full.showsNumbers, "full mode")
hud.unavailable(displayID: 4, reason: "Waiting for output")
expect(label.stringValue == "—" && label.toolTip == "Waiting for output", "waiting never shows stale or fabricated volume")
expect(!track.isEnabled, "waiting HUD disables the native slider")
adjusted = nil
track.doubleValue = 50
_ = track.sendAction(track.action, to: track.target)
expect(adjusted == nil, "waiting HUD cannot send a volume adjustment")
hud.resolveWaiting(AudioSnapshot(volume: AudioState(current: 42, maximum: 100), mute: 2), displayID: 4)
expect(!panel.isVisible && label.stringValue == "—", "background readiness cannot reopen a hidden HUD")
hud.verified(AudioSnapshot(volume: AudioState(current: 42, maximum: 100), mute: 2), displayID: 4)
expect(track.isEnabled, "verified output re-enables the native slider")
track.doubleValue = 50
_ = track.sendAction(track.action, to: track.target)
expect(adjusted == 50 && label.stringValue == "42%", "verified output restores HUD adjustment")
print("PASS \(checks) visual/mode checks")
