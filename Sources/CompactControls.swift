import AppKit

final class VolumeValueLabel: NSTextField {
    private let minimumSize: NSSize
    init(_ text: String) {
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let measure = NSTextField(labelWithString: volumePercent(100))
        measure.font = valueFont
        let percentSize = measure.fittingSize
        measure.stringValue = L("静音")
        let mutedSize = measure.fittingSize
        minimumSize = NSSize(width: ceil(max(percentSize.width, mutedSize.width)),
                             height: max(percentSize.height, mutedSize.height))
        super.init(frame: .zero)
        isEditable = false; isSelectable = false; isBezeled = false; isBordered = false; drawsBackground = false
        cell?.usesSingleLineMode = true
        font = valueFont; alignment = .right; stringValue = text
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override var intrinsicContentSize: NSSize {
        NSSize(width: max(minimumSize.width, super.intrinsicContentSize.width), height: minimumSize.height)
    }
}

// Left click exposes only the everyday volume controls.
final class CompactControls: NSView {
    let slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    let value = VolumeValueLabel("—")
    let speaker = AudioGlyphView(size: 20)
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 190, height: 36))
        // AppKit widens this row to match output names in the same menu.
        // Keep the icon and trailing value fixed, giving that space to the slider.
        autoresizingMask = [.width]
        speaker.frame = NSRect(x: 8, y: 8, width: 20, height: 20)
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.controlSize = .small; slider.isContinuous = true; slider.setAccessibilityLabel(L("显示器音量百分比"))
        for view in [speaker, slider, value] { addSubview(view) }
        NSLayoutConstraint.activate([
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 34),
            slider.trailingAnchor.constraint(equalTo: value.leadingAnchor, constant: -4),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
            slider.heightAnchor.constraint(equalToConstant: 22),
            value.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            value.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        layoutSubtreeIfNeeded()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
}
