import AppKit

guard CommandLine.arguments.count > 1, let app = Bundle(path: CommandLine.arguments[1]) else {
    fputs("Build the candidate first, then pass its .app path.\n", stderr)
    exit(2)
}
var count = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) { precondition(value(), label); count += 1 }
let en = Bundle(path: app.path(forResource: "en", ofType: "lproj")!)!
let zh = Bundle(path: app.path(forResource: "zh-Hans", ofType: "lproj")!)!
for (bundle, expected) in [(en,"Settings"), (zh,"设置")] {
    check(L("设置", bundle: bundle) == expected, "localized settings")
    check(!L("目标音量 \("27%")，等待设备确认", bundle: bundle).contains("%@"), "interpolation")
    let keys = NSDictionary(contentsOfFile: bundle.path(forResource: "Localizable", ofType: "strings")!) as! [String:String]
    check(keys.count >= 115, "catalog coverage")
    for (key, value) in keys {
        check(key.components(separatedBy: "%@").count == value.components(separatedBy: "%@").count, "placeholder count")
        check(!value.isEmpty, "empty translation")
    }
}
check(Bundle.preferredLocalizations(from: ["en","zh-Hans"], forPreferences: ["fr"])[0] == "en", "unsupported fallback")
check(Bundle.preferredLocalizations(from: ["en","zh-Hans"], forPreferences: ["zh-Hans"])[0] == "zh-Hans", "Chinese negotiation")
check(Sponsorship.load(app) == nil, "unconfigured entry hidden")
check(AboutContent.makeAlert(app).buttons.count == 3, "about without sponsorship")
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("bundle")
try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents/Resources/Sponsorship"), withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let info: [String: Any] = ["CFBundleIdentifier":"test.sac.sponsorship", "CFBundlePackageType":"BNDL"]
try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: root.appendingPathComponent("Contents/Info.plist"))
let fixture = Bundle(url: root)!
let config = root.appendingPathComponent("Contents/Resources/Sponsorship.json")
func configure(_ object: [String:Any]) throws { try JSONSerialization.data(withJSONObject: object).write(to: config) }
for url in ["http://invalid.test", "javascript:alert(1)", "file:///tmp", "https://user:pass@invalid.test", "https://"] {
    try configure(["url":url]); check(Sponsorship.load(fixture) == nil, "reject unsafe destination")
}
try configure(["url":"https://support.invalid.test/developer"])
let support = Sponsorship.load(fixture)!
var opens = 0
check(support.openWebsite(using: { _ in opens += 1; return true }), "injected opener")
check(opens == 1, "one user action opens one URL; no actual browser used")
check(AboutContent.makeAlert(fixture).buttons.count == 4, "configured entry visible")
try configure(["wechat":"../outside.png", "alipay":"missing.png"])
check(Sponsorship.load(fixture) == nil, "reject traversal and missing QR")
let pixel = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
try pixel.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("Contents/Resources/Sponsorship/fixture.png"))
try configure(["wechat":"fixture.png", "alipay":"fixture.png"])
check(Sponsorship.load(fixture)?.codes.count == 2, "local image loading; fixture is not a payment QR")
check(Sponsorship.load(fixture)!.makeAlert().accessoryView is NSScrollView, "small-screen scroll view")
check(!Sponsorship.load(fixture)!.openWebsite(using: { _ in fatalError("QR-only must not open browser") }), "QR only")
for name in ["m1ddc", "MonitorControl"] {
    let text = try String(contentsOf: app.url(forResource: name, withExtension: "txt", subdirectory: "Licenses")!, encoding: .utf8)
    check(AboutContent.licenseText(app).contains(text), "full unchanged MIT license")
}
for text in ["Muted", "100%", "System", "静音"] {
    check((text as NSString).size(withAttributes: [.font:NSFont.monospacedDigitSystemFont(ofSize:11,weight:.medium)]).width <= (text == "System" ? 46 : 36), "compact label width")
}
print("PASS \(count) localization/sponsorship assertions; no audio, browser or visible UI actions")
