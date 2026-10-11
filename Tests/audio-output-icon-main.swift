import AppKit
import CoreAudio

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fatalError(message) }
}

func bitmap(width: Int, height: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
}

func rendered(_ image: NSImage) -> NSBitmapImageRep {
    let result = bitmap(width: 16, height: 16)
    let context = NSGraphicsContext(bitmapImageRep: result)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16), from: .zero,
               operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return result
}

func hasVisiblePixels(_ image: NSImage) -> Bool {
    let pixels = rendered(image)
    for y in 0..<16 { for x in 0..<16 {
        var channels = [Int](repeating: 0, count: 4)
        pixels.getPixel(&channels, atX: x, y: y)
        if channels[3] > 64 { return true }
    } }
    return false
}

func archivedCopy(_ image: NSImage) throws -> NSImage {
    let data = try NSKeyedArchiver.archivedData(withRootObject: image, requiringSecureCoding: true)
    return try NSKeyedUnarchiver.unarchivedObject(ofClass: NSImage.self, from: data)!
}

let fixtures = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
let wide = bitmap(width: 48, height: 24)
var redPixel = [255, 0, 0, 255]
for y in 0..<24 { for x in 0..<48 { wide.setPixel(&redPixel, atX: x, y: y) } }
let icon = fixtures.appendingPathComponent("wide.png")
try wide.representation(using: .png, properties: [:])!.write(to: icon)
let native = AudioOutputIcon.menuImage(for: AudioOutputDevice(id: 1, name: "Test output",
                                      transport: kAudioDeviceTransportTypeBuiltIn, iconURL: icon))
expect(native.size == NSSize(width: 16, height: 16), "menu icon uses 16-point canvas")
expect(!native.isTemplate, "provided color icon keeps native colors")
expect(native.representations.count == 2 && native.representations.allSatisfy { $0 is NSBitmapImageRep },
       "menu icon carries explicit 1x/2x bitmap representations")
expect(Set(native.representations.map(\.pixelsWide)) == [16, 32], "menu icon carries both display scales")
let restoredNative = try archivedCopy(native)
expect(hasVisiblePixels(restoredNative), "native icon pixels survive menu image serialization")
let renderedNative = rendered(native)
func channel(_ channel: Int, x: Int, y: Int) -> Int {
    var pixel = [Int](repeating: 0, count: 4)
    renderedNative.getPixel(&pixel, atX: x, y: y)
    return pixel[channel]
}
expect(channel(0, x: 8, y: 8) > 230,
       "local native icon is preferred over transport fallback")
expect(channel(3, x: 8, y: 1) == 0,
       "wide native icon keeps aspect ratio with top padding")
expect(channel(3, x: 8, y: 14) == 0,
       "wide native icon keeps aspect ratio with bottom padding")
expect(channel(3, x: 1, y: 8) > 230,
       "wide native icon spans the horizontal canvas")

let cases: [(UInt32?, String)] = [
    (kAudioDeviceTransportTypeBuiltIn, "hifispeaker.fill"),
    (kAudioDeviceTransportTypeHDMI, "display"),
    (kAudioDeviceTransportTypeDisplayPort, "display"),
    (kAudioDeviceTransportTypeBluetooth, "headphones"),
    (kAudioDeviceTransportTypeBluetoothLE, "headphones"),
    (kAudioDeviceTransportTypeUSB, "cable.connector"),
    (kAudioDeviceTransportTypeAirPlay, "airplayaudio"),
    (kAudioDeviceTransportTypeVirtual, "waveform"),
    (kAudioDeviceTransportTypeAggregate, "waveform"),
    (kAudioDeviceTransportTypeUnknown, "speaker.wave.2.fill"),
    (nil, "speaker.wave.2.fill")
]
for (transport, expectedSymbol) in cases {
    expect(AudioOutputIcon.fallbackSymbol(for: transport) == expectedSymbol, "transport fallback")
    expect(NSImage(systemSymbolName: expectedSymbol, accessibilityDescription: nil) != nil,
           "fallback symbol is available on this system: \(expectedSymbol)")
    let fallback = AudioOutputIcon.menuImage(for: AudioOutputDevice(id: 2, name: "Test", transport: transport))
    expect(fallback.isTemplate && fallback.size == NSSize(width: 16, height: 16),
           "fallback retains menu template behavior and size")
    expect(hasVisiblePixels(fallback), "fallback symbol has rendered pixels: \(expectedSymbol)")
    let restored = try archivedCopy(fallback)
    expect(restored.isTemplate && hasVisiblePixels(restored), "template pixels survive menu image serialization")
}
let corrupt = fixtures.appendingPathComponent("invalid.png")
try Data("invalid image".utf8).write(to: corrupt)
for url in [fixtures.appendingPathComponent("missing.png"), corrupt,
            URL(string: "https://example.invalid/device.png")!,
            URL(string: "file://example.invalid/device.png")!] {
    let fallback = AudioOutputIcon.menuImage(for: AudioOutputDevice(id: 3, name: "Test",
                                             transport: kAudioDeviceTransportTypeUSB, iconURL: url))
    expect(fallback.isTemplate, "missing, invalid, and nonlocal icon URLs safely use a transport symbol")
}
let bluetooth = AudioOutputIcon.menuImage(for: AudioOutputDevice(id: 4, name: "AirPods unknown model",
                                          transport: kAudioDeviceTransportTypeBluetooth))
expect(bluetooth.isTemplate, "Bluetooth with no system icon uses a generic transport fallback")

if CommandLine.arguments.contains("--read-only-metadata") {
    let devices = try AudioOutputs.available()
    for device in devices {
        expect(device.iconURL == nil || device.iconURL!.isFileURL, "CoreAudio icon is local")
        let image = AudioOutputIcon.menuImage(for: device)
        expect(image.size == NSSize(width: 16, height: 16), "real metadata produces a menu icon")
        print("READ ONLY: \(device.name), transport=\(device.transport.map(String.init) ?? "unknown"), systemIcon=\(device.iconURL != nil), template=\(image.isTemplate)")
    }
    print("Read-only metadata inspected for \(devices.count) current output devices")
}
print("PASS \(checks) output icon checks; no connections, routing, playback, or permissions changed")
