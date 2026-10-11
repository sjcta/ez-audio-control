import AppKit
import CoreAudio

enum AudioOutputIcon {
    static let menuSize = NSSize(width: 16, height: 16)

    static func menuImage(for device: AudioOutputDevice) -> NSImage {
        if let url = device.iconURL,
           url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
           let image = NSImage(contentsOf: url), image.isValid,
           validSize(image.size) {
            return fitted(image)
        }
        let symbol = NSImage(systemSymbolName: fallbackSymbol(for: device.transport), accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)
            ?? NSImage(size: menuSize)
        symbol.isTemplate = true
        return fitted(symbol)
    }

    static func fallbackSymbol(for transport: UInt32?) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "hifispeaker.fill"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "display"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeUSB: return "cable.connector"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "waveform"
        default: return "speaker.wave.2.fill"
        }
    }

    private static func validSize(_ size: NSSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    private static func fitted(_ source: NSImage) -> NSImage {
        let result = NSImage(size: menuSize)
        // Native menus can pass image representations out of process. A drawing
        // handler has no persistent pixels for that path, so provide 1x and 2x.
        for pixels in [16, 32] {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
            let scale = min(CGFloat(pixels) / source.size.width, CGFloat(pixels) / source.size.height)
            let size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
            let rect = NSRect(x: (CGFloat(pixels) - size.width) / 2,
                              y: (CGFloat(pixels) - size.height) / 2,
                              width: size.width, height: size.height)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                        respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            bitmap.size = menuSize
            result.addRepresentation(bitmap)
        }
        result.isTemplate = source.isTemplate
        return result
    }
}
