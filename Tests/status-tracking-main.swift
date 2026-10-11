import AppKit
import ObjectiveC

// Validate the selectors AppKit dispatches, rather than calling Swift directly.
// No NSApplication, status item, audio device or permission is opened.
var failures = 0
for name in ["mouseEntered:", "mouseExited:"] {
    let found = class_getInstanceMethod(StatusItemExpansion.self, NSSelectorFromString(name)) != nil
    print("\(found ? "PASS" : "FAIL") AppKit tracking selector \(name)")
    if !found { failures += 1 }
}
if failures == 0 && CommandLine.arguments.contains("--show-window") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let item = NSStatusBar.system.statusItem(withLength: 24)
    let expansion = StatusItemExpansion(item: item, label: NSView(), glyph: NSView())
    let alert = NSAlert()
    alert.messageText = "EzAc tracking regression — no audio"
    alert.addButton(withTitle: "Close")
    var dispatched = false
    let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
        let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            subtype: 0, data1: 0, data2: 0)!
        for name in ["mouseEntered:", "mouseExited:"] {
            expansion.perform(NSSelectorFromString(name), with: event)
        }
        dispatched = true
        app.stopModal()
    }
    RunLoop.main.add(timer, forMode: .modalPanel)
    alert.runModal()
    alert.window.orderOut(nil)
    NSStatusBar.system.removeStatusItem(item)
    print("\(dispatched ? "PASS" : "FAIL") Objective-C tracking dispatch inside NSAlert modal loop")
    if !dispatched { failures += 1 }
}
exit(failures == 0 ? 0 : 1)
