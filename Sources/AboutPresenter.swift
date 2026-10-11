import AppKit

// Menu tracking must end before an accessory app activates an ordinary window.
// Own both alerts for their entire visible lifetime; never nest runModal loops.
final class AboutPresenter: NSObject, NSWindowDelegate {
    private let makeAbout: () -> NSAlert
    private let makeLicenses: () -> NSAlert
    private let copySupport: () -> Void
    private let makeCopied: () -> NSAlert
    private let makeSupport: (() -> NSAlert?)?
    private let openSupport: (() -> Bool)?
    private let makeSupportError: (() -> NSAlert)?
    private var about: NSAlert?
    private var child: NSAlert?
    private var scheduled = false
    var window: NSWindow? { about?.window }
    var childWindow: NSWindow? { child?.window }
    init(makeAbout: @escaping () -> NSAlert, makeLicenses: @escaping () -> NSAlert,
         copySupport: @escaping () -> Void, makeCopied: @escaping () -> NSAlert,
         makeSupport: (() -> NSAlert?)? = nil, openSupport: (() -> Bool)? = nil,
         makeSupportError: (() -> NSAlert)? = nil) {
        self.makeAbout = makeAbout; self.makeLicenses = makeLicenses
        self.copySupport = copySupport; self.makeCopied = makeCopied
        self.makeSupport = makeSupport; self.openSupport = openSupport
        self.makeSupportError = makeSupportError
    }
    func show() {
        guard !scheduled else { return }
        scheduled = true
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            guard let self else { return }; self.scheduled = false
            self.present()
        }
    }
    private func present() {
        if let about {
            NSApp.activate(ignoringOtherApps: true)
            (child?.window ?? about.window).makeKeyAndOrderFront(nil)
            return
        }
        let alert = makeAbout(); about = alert
        alert.layout()
        let window = alert.window
        window.isReleasedWhenClosed = false; window.delegate = self
        window.title = alert.messageText; window.styleMask.insert(.closable)
        window.collectionBehavior.insert(.moveToActiveSpace)
        for (index, button) in alert.buttons.enumerated() {
            button.tag = index; button.target = self; button.action = #selector(aboutAction(_:))
        }
        alert.buttons.first?.keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        window.center(); window.makeKeyAndOrderFront(nil)
    }
    @objc private func aboutAction(_ sender: NSButton) {
        switch sender.tag {
        case 0: close()
        case 1: showChild(makeLicenses())
        case 2: copySupport(); showChild(makeCopied())
        case 3: if let support = makeSupport?() { showChild(support, support: true) }
        default: break
        }
    }
    private func showChild(_ alert: NSAlert, support: Bool = false) {
        guard let parent = about?.window else { return }
        if let child { child.window.makeKeyAndOrderFront(nil); return }
        child = alert; alert.layout()
        alert.window.isReleasedWhenClosed = false
        for (index, button) in alert.buttons.enumerated() {
            button.tag = support && index == 1 ? 1 : 0
            button.target = self; button.action = #selector(childAction(_:))
        }
        alert.buttons.first?.keyEquivalent = "\u{1b}"
        parent.beginSheet(alert.window)
    }
    @objc private func childAction(_ sender: NSButton) {
        let opensWebsite = sender.tag == 1
        dismissChild()
        if opensWebsite && openSupport?() == false, let error = makeSupportError?() { showChild(error) }
    }
    private func dismissChild() {
        guard let child else { return }
        about?.window.endSheet(child.window)
        child.window.orderOut(nil); self.child = nil
        about?.window.makeKeyAndOrderFront(nil)
    }
    func close() { dismissChild(); about?.window.close(); about = nil }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === about?.window else { return }
        dismissChild(); about = nil
    }
}
