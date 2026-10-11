import AppKit

// Presents the explanation for the system volume-control permission without
// entering a nested modal loop.  The caller owns the actual permission state;
// this presenter only shows the next-step UI and opens the injected settings
// action when the user asks for it.
final class ControlPermissionPresenter: NSObject, NSWindowDelegate {
    private let message: String
    private let openSettings: () -> Void
    private var alert: NSAlert?
    private var scheduled = false
    private var deniedPhaseShown = false
    private var settingsActionConsumed = false

    var window: NSWindow? { alert?.window }

    init(message: String, openSettings: @escaping () -> Void) {
        self.message = message
        self.openSettings = openSettings
        super.init()
    }

    // A false update represents one denied phase.  Repeated false updates do
    // not steal focus; a true update closes the window and arms the next phase.
    func update(trusted: Bool) {
        if trusted {
            deniedPhaseShown = false
            dismiss()
            return
        }
        guard !deniedPhaseShown else { return }
        deniedPhaseShown = true
        show()
    }

    // Explicit diagnostic entry may reopen a dismissed explanation even when
    // the current denied phase has already been shown automatically.
    func show() {
        if let alert {
            NSApp.activate(ignoringOtherApps: true)
            alert.window.makeKeyAndOrderFront(nil)
            return
        }
        guard !scheduled else { return }
        scheduled = true
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            guard let self, self.scheduled else { return }
            self.scheduled = false
            self.present()
        }
    }

    func dismiss() {
        scheduled = false
        guard let alert else { return }
        alert.window.close()
        self.alert = nil
    }

    private func present() {
        guard alert == nil else {
            show()
            return
        }
        let next = NSAlert()
        next.messageText = L("允许系统音量指令控制")
        next.informativeText = message
        next.addButton(withTitle: L("打开系统设置"))
        next.addButton(withTitle: L("稍后"))
        next.layout()

        let window = next.window
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = next.messageText
        window.styleMask.insert(.closable)
        window.collectionBehavior.insert(.moveToActiveSpace)
        for (index, button) in next.buttons.enumerated() {
            button.tag = index
            button.target = self
            button.action = #selector(buttonAction(_:))
        }
        next.buttons.last?.keyEquivalent = "\u{1b}"
        settingsActionConsumed = false
        alert = next
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func buttonAction(_ sender: NSButton) {
        switch sender.tag {
        case 0:
            guard !settingsActionConsumed else { return }
            settingsActionConsumed = true
            dismiss()
            openSettings()
        case 1:
            dismiss()
        default:
            break
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === alert?.window else { return }
        alert = nil
    }

    deinit { dismiss() }
}
