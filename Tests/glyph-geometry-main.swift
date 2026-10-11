import AppKit
import QuartzCore
let baseline = CommandLine.arguments.contains("--baseline")
var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) { checks += 1; if !value() { fatalError(message) } }
func ink(_ glyph: AudioGlyphView, scale: Int) -> (width: Int, height: Int, area: Int) {
    let width = Int(glyph.bounds.width) * scale, height = Int(glyph.bounds.height) * scale
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes { bytes in
        let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale)); glyph.layer!.render(in: context)
    }
    var xs: [Int] = [], ys: [Int] = []
    for y in 0..<height { for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 64 { xs.append(x); ys.append(y) } }
    return ((xs.max() ?? -1) - (xs.min() ?? 0) + 1, (ys.max() ?? -1) - (ys.min() ?? 0) + 1, xs.count)
}
for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    for size: CGFloat in [20,22,24,32] { for scale in [1,2] {
        let glyph = AudioGlyphView(size: size); glyph.appearance = NSAppearance(named: appearance)
        glyph.setLevel(0, muted: true, animated: false); glyph.layoutSubtreeIfNeeded()
        let frame = glyph.frame
        let layers = glyph.layer!.sublayers!.compactMap { $0 as? CAShapeLayer }
        layers[2].opacity = 0
        let masked = ink(glyph, scale: scale)
        let mask = layers[0].mask; layers[0].mask = nil
        let full = ink(glyph, scale: scale); layers[0].mask = mask
        let ratio = Double(full.width) / Double(full.height)
        let retained = Double(masked.area) / Double(full.area)
        print("\(appearance.rawValue) size=\(Int(size)) @\(scale)x body=\(full.width)x\(full.height) retained=\(String(format:"%.2f",retained))")
        if !baseline {
            check(ratio >= 0.58 && ratio <= 0.85, "speaker silhouette must retain native proportions")
            check(retained >= 0.55, "negative slash must retain a readable majority of speaker ink")
            check(masked.width >= full.width - scale * 2, "negative slash must not collapse silhouette")
        }
        for state in [(100.0,false),(1,false),(0,true),(57,true),(0,true),(100,false)] {
            glyph.setLevel(state.0, muted: state.1, animated: false);glyph.layoutSubtreeIfNeeded()
            check(glyph.frame == frame, "state must not resize fixed glyph")
            check(glyph.layer!.animationKeys()?.isEmpty ?? true, "offscreen state must not leave animation")
        }
    } }
}
print("PASS \(checks) glyph geometry/pixel checks; isolated model-layer render, no device/UI actions")
