import AppKit
import ApplicationServices
import CoreAudio
import CoreBluetooth
import ServiceManagement
import CoreText

// Prefer native controls; the enabled software-volume option covers unsupported outputs.
func outputDeviceName() -> String? {
    AudioOutputs.currentID().flatMap { AudioOutputs.name($0) }
}

private var controlPermissionName: String {
    ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? L("设备控制和数据访问") : L("辅助功能")
}
private func openControlPermissionSettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
}

extension SACDisplay: AudioDDCDevice {
    func readVolume() throws -> AudioState {
        let reading = try readCode(0x62)
        return AudioState(current: reading.current, maximum: reading.maximum)
    }
    func readMute() throws -> Int { try readCode(0x8d).current }
    func writeVolume(_ value: Int) throws { try writeCode(0x62, value: UInt16(value)) }
    func writeMute(_ value: Int) throws { try writeCode(0x8d, value: UInt16(value)) }
}

final class PassiveVolumeLabel: NSView {
    var stringValue: String { didSet { needsDisplay = true } }
    var font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
    init(labelWithString text: String) { stringValue = text; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    var requiredWidth: CGFloat {
        let text = NSMutableAttributedString(string: stringValue, attributes: [.font: font])
        if let range = stringValue.range(of: "%") {
            text.addAttributes([.font: NSFont.systemFont(ofSize: 7), .baselineOffset: 1], range: NSRange(range, in: stringValue))
        }
        return CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(text), .useGlyphPathBounds).width + 1
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let text = NSMutableAttributedString(string: stringValue, attributes: [
            .font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.labelColor.cgColor])
        if let range = stringValue.range(of: "%") {
            text.addAttributes([.font: NSFont.systemFont(ofSize: 7, weight: .regular), .baselineOffset: 1],
                               range: NSRange(range, in: stringValue))
        }
        let line = CTLineCreateWithAttributedString(text)
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let scale = window?.backingScaleFactor ?? 2
        context.textPosition = CGPoint(x: -ink.minX,
            y: ((bounds.midY - ink.midY) * scale).rounded() / scale)
        CTLineDraw(line, context)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let queue = DispatchQueue(label: "SimpleAudioControl.DDC", qos: .userInitiated)
    private let fence = GenerationFence()
    private var cadence = VolumeCadence()
    private var generation = 0
    private lazy var volumeWriter = StreamingVolumeWriter(queue: queue)
    private var mutatingMute = false
    private var muteMemory: MuteMemory? // accessed only on the serial DDC queue
    private var settingsTracking = false
    private var muteTrace: [String] = []
    private var enumeration: DispatchWorkItem?
    private var displayDiscoveryGeneration = 0
    private var displayDiscoveryPending = false
    private var displays: [SACDisplay] = []
    private var selected: SACDisplay?
    private let software = ProcessTapController()
    private var softwareTimer: Timer?
    private var displaySleep = DisplaySleepState()
    private var audioRecovery = DisplayAudioRecovery()
    private var lastOutputProbe: TimeInterval = 0
    private var unavailableOutputSeen = false
    private var lastSoftwareSnapshot: (uid: String, value: ProcessTapSnapshot)?
    private var softwareMessage: String?
    private var automaticSoftwareOffer = AutomaticSoftwareOffer()
    private var softwareStartScheduled = false
    private var requiresSoftware = false
    private var softwareMode: Bool { software.device != nil }
    private var native: NativeAudioDevice?
    private var nativeListener: AudioObjectPropertyListenerBlock?
    private let feedback = VolumeFeedback()
    private var feedbackItem: NSMenuItem!
    private let bluetooth = BluetoothAudioOutputs()
    private var bluetoothWasConnecting = false
    private var outputMenuTimer: Timer?
    private var outputMenuSignature: [String] = []
    private var pendingOutputSelection: (target: AudioDeviceID, initial: AudioDeviceID?, deadline: TimeInterval)?
    private var controllable: Bool { (!audioRecovery.pending || audioRecovery.permitsStart) && pendingOutputSelection == nil && bluetooth.connectingAddress == nil && (softwareMode || (!software.blocksPhysicalFallback && (outputMatchesDisplay || (native != nil && native?.id == AudioOutputs.currentID())))) }
    private var hudID: UInt32 { software.device?.id ?? native?.id ?? selected?.displayID ?? 0 }
    private var device: AudioDDCDevice? {
        if let device = software.device { return device }
        if software.blocksPhysicalFallback { return nil }
        if let native, native.id == AudioOutputs.currentID() { return native }
        return outputMatchesDisplay ? selected : nil
    }
    private var reading: SACReading?
    private var readingOutputID: AudioDeviceID?
    private var currentReading: Bool { reading != nil && readingOutputID == AudioOutputs.currentID() }
    private var muteReading: SACReading?
    private var sleeping = false
    private var refreshing = false
    private var writing = false
    private var pendingVolume: AudioState?
    private var failed = false
    private let keys = MediaKeys()
    private var controlPermissionTrusted: Bool?
    private var lastPermissionCheck: TimeInterval = 0
    private let hud = VolumeHUD()
    private lazy var controlPermission = ControlPermissionPresenter(
        message: L("系统设置 → \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? L("隐私与安全") : L("隐私与安全性")) → \(controlPermissionName)。请允许 Ez Audio Control 使用音量键。若已允许但仍无法使用，可从“关于”复制支持信息。"),
        openSettings: openControlPermissionSettings)
    private var hudForWrite = false
    private let measurementOnly = CommandLine.arguments.contains("--measure-idle")
    private var observers: [NSObjectProtocol] = []
    private var outputListener: AudioObjectPropertyListenerBlock?
    private let outputSelectors = [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice, kAudioHardwarePropertyDevices]
    private var outputMatchesDisplay: Bool {
        guard !requiresSoftware, !software.blocksPhysicalFallback, let selected else { return false }
        return outputDeviceName()?.localizedCaseInsensitiveContains(selected.name) == true
    }
    private func observeAudioOutput() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] count, properties in
            guard let self else { return }
            if !self.measurementOnly { self.bluetooth.routeChanged() }
            if self.volumeMenuTracking { self.syncAudioOutputs(force: false) }
            let deviceListOnly = count > 0 && (0..<Int(count)).allSatisfy {
                properties[$0].mSelector == kAudioHardwarePropertyDevices
            }
            if deviceListOnly, self.software.state == .paused {
                self.requestAudioRecovery(reason: "device list returned after fault")
            }
            guard self.software.shouldInvalidateForOutputNotification(
                deviceListOnly: deviceListOnly, currentOutput: AudioOutputs.currentID()) else { return }
            let routeNotification = (0..<Int(count)).contains {
                properties[$0].mSelector == kAudioHardwarePropertyDefaultOutputDevice ||
                properties[$0].mSelector == kAudioHardwarePropertyDefaultSystemOutputDevice
            }
            self.audioOutputChanged(routeNotification: routeNotification)
        }
        outputListener = listener
        for selector in outputSelectors {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                      mElement: kAudioObjectPropertyElementMain)
            let result = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
            AudioDiagnostics.shared.record("output observer registration code=\(result)")
        }
    }
    private func clearNativeObserver() {
        if let native, let listener = nativeListener {
            for selector in [native.volumeSelector, kAudioDevicePropertyMute] {
                var address = NativeAudioDevice.address(selector)
                AudioObjectRemovePropertyListenerBlock(native.id, &address, .main, listener)
            }
        }
        nativeListener = nil; native = nil
    }
    private func bindNative() {
        clearNativeObserver()
        guard !software.blocksPhysicalFallback, let id = AudioOutputs.currentID() else { return }
        let discovered = NativeAudioDevice.discover(id)
        requiresSoftware = discovered == nil
        guard let candidate = discovered else { return }
        native = candidate
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.native?.id == id, AudioOutputs.currentID() == id,
                  !self.writing, !self.refreshing, !self.sleeping, !self.failed else { return }
            self.readCurrent(showExternalHUD: true)
        }
        nativeListener = listener
        for selector in [candidate.volumeSelector, kAudioDevicePropertyMute] {
            var address = NativeAudioDevice.address(selector)
            if AudioObjectHasProperty(id, &address) {
                let code = AudioObjectAddPropertyListenerBlock(id, &address, .main, listener)
                AudioDiagnostics.shared.record("native observer registration code=\(code)")
            }
        }
    }
    private func audioOutputChanged(routeNotification: Bool = false) {
        invalidate(); failed = false
        if routeNotification { automaticSoftwareOffer = AutomaticSoftwareOffer() }
        if let request = software.outputChanged(to: AudioOutputs.currentID(), routeNotification: routeNotification) {
            clearNativeObserver()
            softwareMessage = L("正在切换音频输出…")
            render(); updateKeys()
            // Retire the old route after in-flight creation/writes have drained.
            // Until completion, further output changes only update the system's
            // selected output; we bind the latest one, never a captured target.
            queue.async {
                let released = self.software.releaseForOutputChange()
                DispatchQueue.main.async {
                    do {
                        guard try self.software.completeOutputChange(request, released: released) else { return }
                        self.automaticSoftwareOffer = AutomaticSoftwareOffer()
                        self.softwareMessage = nil
                        AudioDiagnostics.shared.record("software route released; reselecting current backend")
                        self.audioOutputChanged()
                    } catch {
                        self.softwareMessage = error.localizedDescription
                        AudioDiagnostics.shared.record("software route cleanup failed \(self.software.cleanupDetail ?? "detail=unavailable")")
                        if self.audioRecovery.pending {
                            self.audioRecovery.failed(retryable: true, now: ProcessInfo.processInfo.systemUptime)
                        } else { self.requestAudioRecovery(reason: "cleanup failure", runtime: true) }
                        self.render(); self.updateKeys()
                    }
                }
            }
            return
        }
        guard software.state != .stopping else { render(); updateKeys(); return }
        bindNative()
        if native != nil { audioRecovery.cancel() }
        offerSoftwareIfNeeded()
        AudioDiagnostics.shared.record("output changed displayMatches=\(outputMatchesDisplay) native=\(native != nil)")
        if controllable { readCurrent() } else { render(); updateKeys() }
    }
    private var statusItem: NSStatusItem!
    private var expansion: StatusItemExpansion!
    private let volumeMenu = NSMenu()
    private var volumeMenuTracking = false
    private let menuBarGlyph = AudioGlyphView(size: 22)
    private let menuBarValue = PassiveVolumeLabel(labelWithString: "—")
    private let controls = CompactControls()
    private var slider: NSSlider { controls.slider }
    private var value: NSTextField { controls.value }
    private let status = NSTextField(wrappingLabelWithString: L("正在读取显示器…"))
    private let contextMenu = NSMenu()
    private let settings = NSMenu()
    private let modeMenu = NSMenu()
    private var displayMode: DisplayMode {
        DisplayMode(savedValue: UserDefaults.standard.string(forKey: "displayMode"))
    }
    private func applyDisplayMode() {
        let mode = displayMode
        hud.isEnabled = mode.showsHUD
        expansion.numbersEnabled = mode.showsNumbers
        for item in modeMenu.items { item.state = (item.representedObject as? String) == mode.rawValue ? .on : .off }
    }
    @objc private func selectDisplayMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = DisplayMode(rawValue: raw) else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: "displayMode")
        applyDisplayMode()
    }
    private let displayMenu = NSMenu()
    private var diagnosticItem: NSMenuItem!
    private var versionItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var refreshItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        AudioDiagnostics.shared.record("startup version=\(AboutContent.version()) logging-self-check")
        UserDefaults.standard.register(defaults: ["volumeFeedbackEnabled": true])
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: max(24, NSStatusBar.system.thickness))
        if let button = statusItem.button {
            menuBarGlyph.frame.origin = NSPoint(x: 3, y: (button.bounds.height - 22) / 2)
            button.addSubview(menuBarGlyph); button.setAccessibilityLabel(L("显示器音量"))
            menuBarValue.frame = NSRect(x: 27, y: 0, width: 25, height: button.bounds.height)
            menuBarValue.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
            menuBarValue.setAccessibilityElement(false)
            button.addSubview(menuBarValue)
        }
        expansion = StatusItemExpansion(item: statusItem, label: menuBarValue, glyph: menuBarGlyph)
        expansion.didLayout = { [weak self] in self?.hud.reposition() }
        statusItem.button?.toolTip = "Ez Audio Control"
        hud.anchor = { [weak self] in
            guard let button = self?.statusItem.button, let window = button.window else { return nil }
            return window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        hud.onAdjust = { [weak self] percent in
            guard let self, let reading = self.reading, self.controllable else { return }
            self.slider.doubleValue = percent
            self.scheduleVolume(VolumePolicy.raw(percent: percent, maximum: reading.maximum), showHUD: true)
        }
        createMenu()
        bluetooth.onChange = { [weak self] in
            guard let self else { return }
            let connecting = self.bluetooth.connectingAddress != nil
            let wasConnecting = self.bluetoothWasConnecting
            self.bluetoothWasConnecting = connecting
            if connecting && !wasConnecting { self.invalidate() }
            if wasConnecting && !connecting && !self.measurementOnly && !self.sleeping {
                self.audioOutputChanged()
            } else { self.render() }
            if self.volumeMenuTracking { self.syncAudioOutputs(force: false) }
        }
        bluetooth.onOutputReady = { [weak self] id in self?.selectOutput(id) }
        bluetooth.onFailure = { [weak self] message in
            self?.audioOutputChanged(); self?.showOutputError(message)
        }
        applyDisplayMode()
        if measurementOnly {
            let optIn = settings.items.contains { $0.action == NSSelectorFromString("toggleKeyboard") || $0.action == NSSelectorFromString("toggleSoftware") }
            AudioDiagnostics.shared.record("settings optInItems=\(optIn) hud=\(hud.isEnabled)")
        }
        observeAudioOutput()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tickSoftware() }
        softwareTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        keys.handler = { [weak self] key in self?.handleKey(key) ?? false }
        updateKeys()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.displaySleep.sleep(system: name == NSWorkspace.willSleepNotification)
                AudioDiagnostics.shared.record("sleep notification=\(name.rawValue) \(self.displaySleep.diagnostics) quarantined=\(self.software.recoveryQuarantined)")
                // Native audio can continue while only the display is dark.
                if name == NSWorkspace.willSleepNotification || self.software.blocksPhysicalFallback || self.outputMatchesDisplay {
                    self.suspend()
                }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.displaySleep.wake(system: name == NSWorkspace.didWakeNotification)
                AudioDiagnostics.shared.record("wake notification=\(name.rawValue) \(self.displaySleep.diagnostics) quarantined=\(self.software.recoveryQuarantined)")
                guard !self.displaySleep.sleeping else { return }
                self.sleeping = false
                if self.requestAudioRecovery(reason: "wake") { self.rediscover(delay: 0.5) }
            })
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.updateKeys() })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.sleeping else { return }
            if self.requestAudioRecovery(reason: "display topology") { self.rediscover(delay: 0.5) }
        })
        rediscover(delay: 0)
        if CommandLine.arguments.contains("--show-controls"), measurementOnly {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showVolumeMenu() }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !volumeMenuTracking { showVolumeMenu() }
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        sleeping = true; audioRecovery.cancel()
        bluetooth.cancel(); outputMenuTimer?.invalidate(); pendingOutputSelection = nil
        softwareTimer?.invalidate(); try? software.shutdown()
        if let listener = outputListener {
            for selector in outputSelectors {
                var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                          mElement: kAudioObjectPropertyElementMain)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
            }
        }
        clearNativeObserver(); invalidate(); keys.stop(); hud.hide()
        controlPermission.dismiss()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
    }
    private func createMenu() {
        slider.target = self; slider.action = #selector(slide)
        let volumeItem = NSMenuItem(); volumeItem.view = controls
        volumeMenu.addItem(volumeItem); volumeMenu.autoenablesItems = false
        statusItem.button?.target = self; statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let settingsItem = NSMenuItem(title: L("设置"), action: nil, keyEquivalent: "")
        settingsItem.submenu = settings; contextMenu.addItem(settingsItem)
        let quitItem = NSMenuItem(title: L("退出"), action: #selector(quit), keyEquivalent: "")
        quitItem.target = self; contextMenu.addItem(quitItem)
        let displayItem = NSMenuItem(title: L("显示器"), action: nil, keyEquivalent: "")
        displayItem.submenu = displayMenu; settings.addItem(displayItem)
        let modeItem = NSMenuItem(title: L("显示模式"), action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu; settings.addItem(modeItem)
        modeMenu.autoenablesItems = false
        for mode in DisplayMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectDisplayMode(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = mode.rawValue; item.toolTip = mode.detail
            modeMenu.addItem(item)
        }
        feedbackItem = NSMenuItem(title: L("音量调节音效"), action: #selector(toggleFeedback), keyEquivalent: "")
        feedbackItem.target = self; settings.addItem(feedbackItem)
        loginItem = NSMenuItem(title: L("开机启动"), action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self; settings.addItem(loginItem)
        refreshItem = NSMenuItem(title: L("重新检测音频设备"), action: #selector(refresh), keyEquivalent: "")
        refreshItem.target = self; settings.addItem(refreshItem)
        settings.addItem(.separator())
        diagnosticItem = NSMenuItem(title: L("音量控制需要检查"), action: #selector(showControlHelp), keyEquivalent: "")
        diagnosticItem.target = self; diagnosticItem.isHidden = true; settings.addItem(diagnosticItem)
        versionItem = NSMenuItem(title: L("关于"), action: #selector(showAbout), keyEquivalent: "")
        versionItem.target = self; settings.addItem(versionItem)
        settings.delegate = self; settings.autoenablesItems = false; displayMenu.autoenablesItems = false
        render()
    }
    @objc private func showVolumeMenu() {
        guard !volumeMenuTracking, let button = statusItem.button else { return }
        if controllable && !writing && !sleeping { readCurrent() }
        syncAudioOutputs()
        hud.hide()
        volumeMenuTracking = true; expansion.setMenuOpen(true)
        // CoreAudio and Bluetooth can appear after the menu opens. Refresh only
        // changed rows, including in AppKit's nested menu tracking run loop.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.syncAudioOutputs(force: false) }
        outputMenuTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer { timer.invalidate(); outputMenuTimer = nil }
        // Let AppKit place and render its own status-item menu, including the
        // current OS glass material and screen-edge handling.
        statusItem.menu = volumeMenu
        button.performClick(nil)
        statusItem.menu = nil
        volumeMenuTracking = false; expansion.setMenuOpen(false)
    }
    private func syncAudioOutputs(force: Bool = true) {
        do {
            let outputs = try AudioOutputs.available()
            let current = AudioOutputs.currentID()
            // Read-only measurement must not enumerate Bluetooth or request TCC.
            let paired = measurementOnly ? [] : bluetooth.pairedAudioDevices()
            let disconnected = paired.filter { BluetoothAudioOutputs.outputID(for: $0, among: outputs) == nil }
            let signature = ["\(current ?? 0)|\(sleeping)|\(bluetooth.authorization.rawValue)|\(bluetooth.connectingAddress ?? "")"]
                + outputs.map { "output:\($0.id):\($0.name):\($0.iconURL?.absoluteString ?? "")" }
                + disconnected.map { "bluetooth:\($0.address):\($0.name):\($0.isConnected)" }
            guard force || signature != outputMenuSignature else { return }
            outputMenuSignature = signature
            while volumeMenu.items.count > 1 { volumeMenu.removeItem(at: 1) }
            volumeMenu.addItem(.separator())
            for output in outputs {
                let item = NSMenuItem(title: output.name, action: #selector(selectAudioOutput(_:)), keyEquivalent: "")
                item.image = AudioOutputIcon.menuImage(for: output)
                if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
                item.target = self; item.representedObject = NSNumber(value: output.id)
                item.state = current == output.id ? .on : .off
                item.isEnabled = !measurementOnly && !sleeping
                volumeMenu.addItem(item)
            }
            if outputs.isEmpty {
                let item = NSMenuItem(title: L("没有可用输出设备"), action: nil, keyEquivalent: "")
                item.isEnabled = false; volumeMenu.addItem(item)
            }
            volumeMenu.addItem(.separator())
            for device in disconnected {
                let connecting = bluetooth.connectingAddress == device.address
                let title = connecting ? L("\(device.name) — 正在连接…") :
                    (device.isConnected ? L("\(device.name) — 音频未就绪") : L("\(device.name) — 未连接"))
                let item = NSMenuItem(title: title, action: #selector(connectBluetoothOutput(_:)), keyEquivalent: "")
                item.image = AudioOutputIcon.menuImage(for: AudioOutputDevice(id: 0, name: device.name, transport: kAudioDeviceTransportTypeBluetooth))
                if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
                item.target = self; item.representedObject = device.address
                item.isEnabled = !measurementOnly && !sleeping && !connecting
                volumeMenu.addItem(item)
            }
            let authorized = bluetooth.authorization == .allowedAlways
            let title = authorized ? L("配对蓝牙设备…") :
                (bluetooth.authorization == .notDetermined ? L("显示蓝牙音频设备…") : L("允许蓝牙访问…"))
            let bluetoothItem = NSMenuItem(title: title, action: #selector(showBluetoothDevices), keyEquivalent: "")
            bluetoothItem.target = self; bluetoothItem.isEnabled = !measurementOnly && !sleeping
            volumeMenu.addItem(bluetoothItem)
            if measurementOnly {
                let iconCount = volumeMenu.items.filter { $0.representedObject is NSNumber && $0.image != nil }.count
                AudioDiagnostics.shared.record("output menu outputs=\(outputs.count) icons=\(iconCount) bluetoothEnumeration=false")
            }
        } catch {
            guard force || outputMenuSignature != ["error"] else { return }
            outputMenuSignature = ["error"]
            while volumeMenu.items.count > 1 { volumeMenu.removeItem(at: 1) }
            volumeMenu.addItem(.separator())
            let item = NSMenuItem(title: L("无法读取输出设备"), action: nil, keyEquivalent: "")
            item.isEnabled = false; volumeMenu.addItem(item)
            AudioDiagnostics.shared.record("output list failed code=\((error as NSError).code)")
        }
        volumeMenu.addItem(.separator())
        let soundSettingsItem = NSMenuItem(title: L("声音设置…"), action: #selector(openSoundSettings), keyEquivalent: "")
        soundSettingsItem.target = self; soundSettingsItem.isEnabled = !measurementOnly
        volumeMenu.addItem(soundSettingsItem)
    }
    @objc private func openSoundSettings() {
        guard !measurementOnly else { return }
        DispatchQueue.main.async {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
        }
    }
    @objc private func selectAudioOutput(_ sender: NSMenuItem) {
        guard !measurementOnly, !sleeping else { return }
        guard let id = (sender.representedObject as? NSNumber)?.uint32Value else { return }
        bluetooth.cancel()
        selectOutput(id)
    }
    private func selectOutput(_ id: AudioDeviceID) {
        guard !measurementOnly, !sleeping else { return }
        let replacingPending = pendingOutputSelection != nil
        pendingOutputSelection = nil
        let initial = AudioOutputs.currentID()
        guard initial != id || replacingPending else { return }
        invalidate(); hud.hide()
        do {
            try AudioOutputs.select(id, verifyImmediately: false)
            pendingOutputSelection = (id, initial, ProcessInfo.processInfo.systemUptime + 3)
            render()
            if initial != id { pollOutputSelection() }
        } catch {
            audioOutputChanged(); showOutputError(error.localizedDescription)
        }
    }
    private func pollOutputSelection() {
        guard let pending = pendingOutputSelection else { return }
        let result = BluetoothAudioPolicy.selectionResult(target: pending.target, initial: pending.initial,
            current: AudioOutputs.currentID(), now: ProcessInfo.processInfo.systemUptime, deadline: pending.deadline)
        guard result != .waiting else { return }
        pendingOutputSelection = nil
        audioOutputChanged(routeNotification: true)
        if result == .timedOut { showOutputError(L("系统未确认输出切换，请重试")) }
    }
    @objc private func connectBluetoothOutput(_ sender: NSMenuItem) {
        guard !measurementOnly, !sleeping, let address = sender.representedObject as? String else { return }
        pendingOutputSelection = nil
        bluetooth.connect(address)
    }
    @objc private func showBluetoothDevices() {
        guard !measurementOnly, !sleeping else { return }
        DispatchQueue.main.async {
            switch self.bluetooth.authorization {
            case .notDetermined: self.bluetooth.requestAccess()
            case .allowedAlways:
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
            default:
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
            }
        }
    }
    private func showOutputError(_ message: String) {
        volumeMenu.cancelTracking()
        DispatchQueue.main.async {
            let alert = NSAlert(); alert.messageText = L("未能切换音频输出")
            alert.informativeText = message; alert.addButton(withTitle: L("关闭"))
            NSApp.activate(ignoringOtherApps: true); alert.runModal()
        }
    }
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showContextMenu(sender)
        } else {
            showVolumeMenu()
        }
    }
    private func showContextMenu(_ button: NSStatusBarButton) {
        hud.hide()
        volumeMenu.cancelTracking()
        updateKeys(); updateDiagnostics(); syncDisplayMenu()
        feedbackItem.state = UserDefaults.standard.bool(forKey: "volumeFeedbackEnabled") ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        settingsTracking = true; expansion.setMenuOpen(true)
        statusItem.menu = contextMenu
        button.performClick(nil)
        statusItem.menu = nil
        settingsTracking = false; expansion.setMenuOpen(false)
        render()
    }

    private func rememberSoftwareSnapshot() {
        guard let id = software.device?.id, let uid = AudioOutputs.uid(id) else { return }
        if currentReading, let reading, let mute = muteReading?.current {
            lastSoftwareSnapshot = (uid, .init(gain: Float(reading.current) / Float(reading.maximum), muted: mute == 1 ? 1 : 0))
        } else if let value = software.latestStatus { lastSoftwareSnapshot = (uid, value) }
    }
    private func recoveryCanRetry(_ error: Error) -> Bool {
        (error as? ProcessTapError)?.runtimeRecoverable == true
    }
    @discardableResult private func recoverSoftwareFault(_ error: Error, wasActive: Bool) -> Bool {
        if audioRecovery.pending {
            audioRecovery.failed(retryable: recoveryCanRetry(error), now: ProcessInfo.processInfo.systemUptime)
            return audioRecovery.pending
        }
        guard wasActive, recoveryCanRetry(error) else { return false }
        if requestAudioRecovery(reason: "runtime fault", runtime: true) { return true }
        AudioDiagnostics.shared.record("audio runtime recovery blocked by budget or cleanup")
        return false
    }
    @discardableResult private func requestAudioRecovery(reason: String, runtime: Bool = false) -> Bool {
        guard !measurementOnly, !sleeping else {
            if !measurementOnly { AudioDiagnostics.shared.record("audio recovery deferred reason=\(reason) sleeping=\(sleeping)") }
            return false
        }
        let wasPending = audioRecovery.pending
        guard ((runtime || software.recoveryQuarantined) ? audioRecovery.requestRuntime(now: ProcessInfo.processInfo.systemUptime)
                                                        : audioRecovery.request(now: ProcessInfo.processInfo.systemUptime)) else {
            if !wasPending { AudioDiagnostics.shared.record("audio recovery rejected reason=\(reason) budget exhausted quarantined=\(software.recoveryQuarantined)") }
            return false
        }
        rememberSoftwareSnapshot(); software.pause()
        enumeration?.cancel(); displayDiscoveryGeneration &+= 1; displayDiscoveryPending = false
        clearNativeObserver(); invalidate(); failed = false
        softwareMessage = L("正在准备系统音频处理")
        AudioDiagnostics.shared.record("audio recovery requested reason=\(reason)")
        render(); updateKeys()
        return true
    }
    private func retryQuarantinedCleanup() {
        guard let request = software.beginCleanupRecovery() else { return }
        AudioDiagnostics.shared.record("software cleanup retry attempt=\(audioRecovery.attempts)")
        queue.async {
            let released = self.software.retryCleanup()
            DispatchQueue.main.async {
                do {
                    guard try self.software.completeOutputChange(request, released: released) else { return }
                    AudioDiagnostics.shared.record("software cleanup recovered; reselecting current backend")
                    self.automaticSoftwareOffer = AutomaticSoftwareOffer()
                    self.softwareMessage = nil
                    self.audioOutputChanged()
                } catch {
                    AudioDiagnostics.shared.record("software cleanup retry failed \(self.software.cleanupDetail ?? "detail=unavailable")")
                    self.audioRecovery.failed(retryable: true, now: ProcessInfo.processInfo.systemUptime)
                    self.softwareMessage = error.localizedDescription
                    self.render(); self.updateKeys()
                }
            }
        }
    }
    private func pollAudioRecovery(now: TimeInterval) {
        guard now - lastOutputProbe >= 0.5 else { return }
        lastOutputProbe = now
        let output = AudioOutputs.currentID()
        let available = output.map { AudioOutputs.isAvailable($0) } ?? false
        if !available { unavailableOutputSeen = true }
        else if unavailableOutputSeen {
            unavailableOutputSeen = false
            requestAudioRecovery(reason: "output reappeared")
        }
        let uid = output.flatMap { AudioOutputs.uid($0) }
        if audioRecovery.takeAttempt(now: now, outputUID: uid, available: available,
                                     busy: displayDiscoveryPending || software.state == .stopping || software.state == .preparing || bluetooth.connectingAddress != nil || pendingOutputSelection != nil) {
            AudioDiagnostics.shared.record("audio recovery attempt=\(audioRecovery.attempts)")
            if software.recoveryQuarantined { retryQuarantinedCleanup(); return }
            automaticSoftwareOffer = AutomaticSoftwareOffer()
            audioOutputChanged(routeNotification: true)
        }
    }
    private func tickSoftware() {
        guard !measurementOnly, !sleeping else { return }
        pollOutputSelection()
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPermissionCheck >= 1 {
            lastPermissionCheck = now
            if AXIsProcessTrusted() != controlPermissionTrusted { updateKeys() }
        }
        pollAudioRecovery(now: now)
        let previous = software.state
        do {
            try software.tick()
            if software.state == .active { rememberSoftwareSnapshot(); audioRecovery.cancel() }
            if software.state != previous {
                AudioDiagnostics.shared.record("software state=\(software.state) callbacks=\(software.progress?.callbacks ?? 0) frames=\(software.progress?.validFrames ?? 0)")
                if let device = software.device, let packet = software.latestStatus, let uid = AudioOutputs.uid(device.id) {
                    UserDefaults.standard.set(packet.gain, forKey: "softwareGain." + uid)
                }
                softwareMessage = nil; audioOutputChanged()
            }
            else if softwareMode && !writing && !refreshing && !mutatingMute,
                    let packet = software.latestStatus, currentReading {
                let snapshot = AudioSnapshot(volume: AudioState(current: Int((packet.gain * 10000).rounded()), maximum: 10000), mute: packet.muted == 1 ? 1 : 2)
                if snapshot.volume.current != reading?.current || snapshot.mute != muteReading?.current {
                    apply(snapshot); renderVolumePresentation()
                }
            }
        } catch {
            softwareMessage = error.localizedDescription
            AudioDiagnostics.shared.record("software poll failed: \(error.localizedDescription)")
            recoverSoftwareFault(error, wasActive: previous == .active)
            invalidate(); render(); updateKeys()
        }
    }
    private func offerSoftwareIfNeeded() {
        guard !measurementOnly, !sleeping, !softwareStartScheduled,
              !audioRecovery.pending || audioRecovery.permitsStart else { return }
        if automaticSoftwareOffer.shouldOffer(output: AudioOutputs.currentID(), nativeWritable: native != nil,
                                               available: software.available, idle: software.state == .off) {
            scheduleSoftwareStart()
        }
    }
    private func scheduleSoftwareStart() {
        guard !measurementOnly, !sleeping, !softwareStartScheduled,
              !audioRecovery.pending || audioRecovery.permitsStart else { return }
        softwareStartScheduled = true
        let output = AudioOutputs.currentID()
        // Wait for native menu tracking to finish; coalesce automatic/manual entry.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            guard let self else { return }
            self.softwareStartScheduled = false
            guard AudioOutputs.currentID() == output else {
                self.offerSoftwareIfNeeded(); return
            }
            self.prepareSoftware()
        }
    }
    private func prepareSoftware() {
        guard !measurementOnly, !sleeping,
              !audioRecovery.pending || audioRecovery.permitsStart,
              software.state == .off, let output = AudioOutputs.currentID() else { return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "local.SimpleAudioControl").allSatisfy({ $0.processIdentifier == getpid() || $0.isTerminated }) else {
            softwareMessage = L("请先退出其它 Ez Audio Control 实例，再启用软件衰减")
            render(); return
        }
        let consent = ProcessTapConsent.confirmed(output: output)
        let reference = NativeAudioDevice.volumeReference(output)
        let saved = AudioOutputs.uid(output).flatMap {
            UserDefaults.standard.object(forKey: "softwareGain." + $0) as? NSNumber
        }?.floatValue
        let uid = AudioOutputs.uid(output)
        let resumed = audioRecovery.pending && lastSoftwareSnapshot?.uid == uid ? lastSoftwareSnapshot?.value : nil
        let initial = resumed ?? ProcessTapSnapshot.initial(systemGain: reference.gain, systemMuted: reference.muted, savedGain: saved)
        do {
            let request = try software.beginPreparation(output: output, consent: consent)
            AudioDiagnostics.shared.record("software preparation started")
            invalidate(); clearNativeObserver()
            softwareMessage = L("正在准备系统音频处理")
            render()
            let token = generation
            // Drain native/DDC requests first. Creating CoreAudio objects and its
            // possible permission dialog must not block the main thread.
            queue.async {
                let result = Result<UInt64, Error> {
                    guard self.fence.matches(token), AudioOutputs.currentID() == output else { throw ProcessTapError.interrupted }
                    return try self.software.establish(output: output, consent: consent, initial: initial)
                }
                DispatchQueue.main.async {
                    guard self.software.isPreparing(request) else { return }
                    do {
                        let created = try result.get()
                        guard self.fence.matches(token), !self.sleeping, AudioOutputs.currentID() == output else { throw ProcessTapError.interrupted }
                        try self.software.didEstablish(output: output, token: created, request: request)
                        AudioDiagnostics.shared.record("software established; waiting for PCM")
                        self.softwareMessage = L("等待有效音频帧")
                        self.render()
                    } catch {
                        AudioDiagnostics.shared.record("software preparation failed: \(error.localizedDescription)")
                        if self.software.preparationFailed(request, error: error) {
                            self.audioRecovery.failed(retryable: self.recoveryCanRetry(error), now: ProcessInfo.processInfo.systemUptime)
                            self.softwareMessage = error.localizedDescription; self.render()
                        }
                    }
                }
            }
        } catch { softwareMessage = error.localizedDescription; render() }
    }
    private func confirmSoftwareExit() -> Bool {
        guard software.blocksPhysicalFallback else { return true }
        let alert = NSAlert(); alert.messageText = L("先暂停所有音频播放")
        alert.informativeText = L("退出软件衰减后，原始音频可能恢复播放。请先暂停播放；退出不会调低硬件音量。")
        alert.addButton(withTitle: L("取消")); alert.addButton(withTitle: L("已暂停，退出软件模式"))
        return alert.runModal() == .alertSecondButtonReturn
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        confirmSoftwareExit() ? .terminateNow : .terminateCancel
    }
    private func syncDisplayMenu() {
        guard !settingsTracking else { return }
        displayMenu.removeAllItems()
        if displays.isEmpty {
            let item = NSMenuItem(title: L("没有可访问的显示器"), action: nil, keyEquivalent: "")
            item.isEnabled = false; displayMenu.addItem(item)
        }
        for display in displays {
            let item = NSMenuItem(title: display.name, action: #selector(selectTarget(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = display.identifier
            item.state = selected?.identifier == display.identifier ? .on : .off
            item.isEnabled = !sleeping && !measurementOnly
            displayMenu.addItem(item)
        }
    }
    private func updateDiagnostics() {
        guard !settingsTracking else { return }
        let reason: String
        if let message = softwareMessage { reason = message }
        else if software.state == .paused { reason = L("软件衰减已暂停；请先暂停播放，再退出软件模式") }
        else if sleeping { reason = L("音量控制已暂停，等待唤醒") }
        else if failed { reason = L("暂时无法调节音量") }
        else if !controllable { reason = L("当前输出暂不支持调节") }
        else if reading == nil { reason = L("正在连接音频设备") }
        else if !AXIsProcessTrusted() {
            reason = L("允许音量键控制…")
        } else if keys.activeTapCount == 0 {
            reason = L("音量键暂不可用")
        } else { reason = "" }
        diagnosticItem?.title = reason
        diagnosticItem?.isHidden = reason.isEmpty
        statusItem?.button?.toolTip = reason.isEmpty ? "Ez Audio Control" : reason
    }
    private func copySupportInfo() {
        let backend = softwareMode ? L("软件音量模式") : native != nil ? L("系统音频") : (outputMatchesDisplay ? L("显示器") : L("未连接"))
        let text = L("Ez Audio Control \(AboutContent.version())\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n控制方式：\(backend)\n控制许可：\(AXIsProcessTrusted() ? L("已允许") : L("未允许"))\n音量键：\(keys.activeTapCount > 0 ? L("已连接") : L("未连接"))\n设备状态：\(failed ? L("操作失败") : L("可用或正在连接"))")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    private lazy var aboutPresenter = AboutPresenter(
        makeAbout: { AboutContent.makeAlert() }, makeLicenses: { AboutContent.makeLicenseAlert() },
        copySupport: { [weak self] in self?.copySupportInfo() },
        makeCopied: {
            let alert = NSAlert(); alert.messageText = L("支持信息已复制")
            alert.informativeText = L("仅复制到剪贴板，未发送。内容不含设备名称、文件路径或日志。")
            alert.addButton(withTitle: L("完成")); return alert
        },
        makeSupport: { Sponsorship.load()?.makeAlert() },
        openSupport: { Sponsorship.load()?.openWebsite() ?? false },
        makeSupportError: {
            let alert = NSAlert(); alert.messageText = L("无法打开赞助网站")
            alert.addButton(withTitle: L("关闭")); return alert
        })
    @objc private func showAbout() {
        hud.hide(); settings.cancelTracking(); contextMenu.cancelTracking()
        aboutPresenter.show()
    }
    @objc private func showControlHelp() {
        if !AXIsProcessTrusted() { controlPermission.show(); return }
        let alert = NSAlert(); alert.messageText = L("音量控制")
        if failed {
            alert.informativeText = L("请检查音频设备连接。使用显示器时，请确认已开启 DDC/CI，然后在设置中重新检测。")
        } else {
            alert.informativeText = L("请确认已选择可用输出设备。部分设备不支持软件音量控制；你仍可使用设备自身的音量按钮。")
        }
        alert.addButton(withTitle: L("关闭"))
        alert.addButton(withTitle: L("重新检测"))
        alert.addButton(withTitle: L("复制支持信息"))
        let result = alert.runModal()
        if result == .alertSecondButtonReturn {
            refresh()
        } else if result == .alertThirdButtonReturn { copySupportInfo() }
    }
    private func invalidate() {
        feedback.stop(); pendingVolume = nil; expansion?.reset()
        cadence.reset()
        generation = fence.advance(); volumeWriter.cancel(); mutatingMute = false
        queue.async { self.muteMemory = nil }
        writing = false; refreshing = false; readingOutputID = nil; reading = nil; muteReading = nil; hudForWrite = false; hud.hide()
    }
    private func suspend() {
        rememberSoftwareSnapshot()
        sleeping = true; audioRecovery.cancel()
        displayDiscoveryGeneration &+= 1; displayDiscoveryPending = false
        bluetooth.cancel(); pendingOutputSelection = nil
        software.pause()
        enumeration?.cancel(); clearNativeObserver(); invalidate(); keys.stop()
        status.stringValue = L("显示器休眠；唤醒后重新读取"); render()
    }
    private func rediscover(delay: Double) {
        enumeration?.cancel(); displayDiscoveryGeneration &+= 1; displayDiscoveryPending = true
        clearNativeObserver(); invalidate(); selected = nil; displays = []
        failed = false
        status.stringValue = L("正在检测显示器…"); render()
        let token = displayDiscoveryGeneration
        let job = DispatchWorkItem { [weak self] in
            guard let self, self.displayDiscoveryGeneration == token, !self.sleeping else { return }
            self.queue.async {
                let found = SACDisplay.discover()
                DispatchQueue.main.async {
                    guard self.displayDiscoveryGeneration == token, !self.sleeping else { return }
                    self.displayDiscoveryPending = false
                    self.displays = found
                    let saved = UserDefaults.standard.string(forKey: "targetUUID")
                    self.selected = found.first { $0.identifier == saved }
                    // If a previously chosen target disappears, never silently switch
                    // the keyboard to a different monitor. Explicit selection is needed.
                    if saved == nil && found.count == 1 {
                        self.selected = found.first
                        if !self.measurementOnly { UserDefaults.standard.set(found[0].identifier, forKey: "targetUUID") }
                    }
                    self.syncDisplayMenu()
                    self.bindNative()
                    self.offerSoftwareIfNeeded()
                    if self.controllable {
                        self.readCurrent()
                    } else {
                        self.status.stringValue = found.isEmpty ? L("没有可访问的 DDC 显示器") : L("请选择目标，读取成功后才可调节")
                        self.render()
                    }
                }
            }
        }
        enumeration = job; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: job)
    }
    @objc private func refresh() {
        guard !measurementOnly else { return }
        if software.recoveryQuarantined { requestAudioRecovery(reason: "manual refresh", runtime: true) }
        audioOutputChanged(routeNotification: true)
        rediscover(delay: 0)
    }
    @objc private func selectTarget(_ sender: NSMenuItem) {
        guard !measurementOnly, let identifier = sender.representedObject as? String,
              let display = displays.first(where: { $0.identifier == identifier }) else { return }
        invalidate(); failed = false; selected = display
        UserDefaults.standard.set(display.identifier, forKey: "targetUUID")
        syncDisplayMenu(); bindNative(); readCurrent()
    }
    private func readCurrent(recoveringFrom error: Error? = nil, showExternalHUD: Bool = false) {
        guard let device = device, !sleeping, !writing, !refreshing else { return }
        let token = generation
        let outputID = AudioOutputs.currentID()
        let allowRecovery = error == nil
        let previous = reading.map { AudioState(current: $0.current, maximum: $0.maximum) }
        let previousMute = muteReading?.current
        refreshing = true; status.stringValue = L("正在读取当前音量…"); render()
        queue.async {
            guard self.fence.matches(token) else { return }
            do {
                let volume = try device.readVolume()
                let mute: Int?
                if device is ProcessTapVolumeDevice { mute = try device.readMute() }
                else { mute = try? device.readMute() }
                DispatchQueue.main.async {
                    guard self.fence.matches(token) else { return }
                    guard AudioOutputs.currentID() == outputID else { return }
                    self.readingOutputID = outputID
                    self.apply(AudioSnapshot(volume: volume, mute: mute)); self.failed = false; self.refreshing = false
                    self.status.stringValue = error.map { L("操作失败：\($0.localizedDescription)；已重新读取，可重试") } ?? (mute == nil ? L("音量可调；显示器未提供静音状态") : "")
                    if showExternalHUD, !self.volumeMenuTracking, previous != volume || previousMute != mute {
                        self.expansion.activity()
                        self.hud.verified(AudioSnapshot(volume: volume, mute: mute), displayID: self.hudID)
                    }
                    self.hud.resolveWaiting(AudioSnapshot(volume: volume, mute: mute), displayID: self.hudID)
                    self.render(); self.updateKeys()
                }
            } catch { DispatchQueue.main.async { self.fail(error, token: token, recover: allowRecovery) } }
        }
    }
    private func fail(_ error: Error, token: Int, recover: Bool = true) {
        guard fence.matches(token) else { return }
        AudioDiagnostics.shared.record("operation failed code=\((error as NSError).code)")
        let hadHUD = hudForWrite, failedHUDID = hudID
        if softwareMode {
            rememberSoftwareSnapshot()
            software.pause(); softwareMessage = error.localizedDescription
            AudioDiagnostics.shared.record("software operation failed: \(error.localizedDescription)")
            if recoverSoftwareFault(error, wasActive: true) {
                if hadHUD { hud.unavailable(displayID: failedHUDID, reason: L("正在准备系统音频处理")) }
                render(); updateKeys(); return
            }
        }
        let lastConfirmed = reading.map { AudioSnapshot(volume: AudioState(current: $0.current, maximum: $0.maximum), mute: muteReading?.current) }
        invalidate(); failed = true
        if let lastConfirmed {
            let percent = VolumePolicy.percent(raw: lastConfirmed.volume.current, maximum: lastConfirmed.volume.maximum)
            menuBarGlyph.setLevel(percent, muted: lastConfirmed.effectiveSilent)
            controls.speaker.setLevel(percent, muted: lastConfirmed.effectiveSilent)
        }
        if hadHUD { hud.failure(displayID: hudID) }
        status.stringValue = error.localizedDescription + L("；请重新检测")
        status.toolTip = status.stringValue
        render()
        // A failed transaction must not leave the controls permanently locked.
        // Recovery reads only; no cached value is written or restored here.
        if recover && native == nil && !software.blocksPhysicalFallback { readCurrent(recoveringFrom: error) }
    }
    private func render() {
        let ready = !measurementOnly && currentReading && controllable && !sleeping && !failed && !refreshing
        slider.isEnabled = ready && !mutatingMute
        syncDisplayMenu()
        refreshItem?.isEnabled = !sleeping
        renderVolumePresentation()
        if !controllable {
            value.stringValue = L("系统")
            slider.toolTip = softwareMessage ?? (software.blocksPhysicalFallback ? L("软件衰减已暂停；请先暂停播放，再退出软件模式") : L("当前输出暂不支持调节"))
            menuBarValue.stringValue = "—"
        } else { slider.toolTip = softwareMode ? L("100% 原始电平 · 0% 静音 · 不改变硬件音量") : nil }
        menuBarGlyph.alphaValue = controllable ? 1 : 0.55
        if refreshing { value.alphaValue = 0.6 }
        updateDiagnostics()
    }

    // Both visible numbers and glyphs use one state in the same main-thread turn.
    // A pending target is explicitly labelled; confirmed hardware values stay separate.
    private func renderVolumePresentation(showHUD: Bool = false) {
        hud.isSoftwareAttenuation = softwareMode
        guard currentReading, controllable, let reading else {
            value.stringValue = "—"; menuBarValue.stringValue = "—"; return
        }
        let state = pendingVolume ?? AudioState(current: reading.current, maximum: reading.maximum)
        let percent = VolumePolicy.percent(raw: state.current, maximum: state.maximum)
        let text = volumePercent(percent)
        let pending = pendingVolume != nil
        let muted = AudioSnapshot(volume: state, mute: muteReading?.current).effectiveSilent
        slider.doubleValue = percent
        value.stringValue = text; menuBarValue.stringValue = text
        value.alphaValue = pending ? 0.8 : 1; expansion.textChanged(width: menuBarValue.requiredWidth, pending: pending)
        let description = softwareMode ? L("软件衰减 \(text)，100% 原始电平，0% 静音") : (pending ? L("目标音量 \(text)，等待设备确认") : L("音量 \(text)"))
        slider.setAccessibilityLabel(softwareMode ? L("软件衰减；100% 原始电平，0% 静音") : L("音量"))
        slider.setAccessibilityValueDescription(description)
        menuBarValue.toolTip = description; statusItem.button?.setAccessibilityLabel(description)
        controls.speaker.setLevel(percent, muted: muted)
        menuBarGlyph.setLevel(percent, muted: muted)
        if showHUD {
            if pending { hud.pending(displayID: hudID, requested: state, muted: muted) }
            else { hud.verified(AudioSnapshot(volume: state, mute: muteReading?.current), displayID: hudID) }
        }
    }

    @objc private func slide() {
        guard let volume = reading, !mutatingMute, !refreshing else { return }
        cadence.reset()
        let requested = VolumePolicy.raw(percent: slider.doubleValue, maximum: volume.maximum)
        value.stringValue = "\(Int(slider.doubleValue.rounded()))%"
        scheduleVolume(requested)
    }
    private func scheduleVolume(_ requested: Int, showHUD: Bool = false) {
        guard !measurementOnly, controllable, currentReading, let device = device, let initial = reading, !sleeping, !failed, !mutatingMute, !refreshing else { return }
        guard !softwareMode || (0...10000).contains(requested) else { return }
        feedback.stop() // No old feedback tail during a new volume intent.
        let token = generation
        let nativeMode = native != nil || softwareMode, outputID = AudioOutputs.currentID()
        writing = true
        hudForWrite = hudForWrite || (showHUD && !volumeMenuTracking)
        pendingVolume = AudioState(current: requested, maximum: initial.maximum)
        expansion.activity()
        renderVolumePresentation(showHUD: hudForWrite)
        let started = ProcessInfo.processInfo.systemUptime
        volumeWriter.submit(target: requested, operation: { resolveTarget in
            self.muteMemory = nil // an explicit slider/key intent supersedes any mute memory
            let valid = { self.fence.matches(token) && AudioOutputs.currentID() == outputID }
            if nativeMode { return try NativeAudioOperations.volume(device: device, target: requested, valid: valid, resolveTarget: resolveTarget) }
            return try DDCOperations.volume(device: TracedAudioDevice(device), target: requested,
                expectedMaximum: initial.maximum, valid: valid, resolveTarget: resolveTarget)
        }, completion: { revision, result in
            DispatchQueue.main.async {
                guard self.fence.matches(token), AudioOutputs.currentID() == outputID else { return }
                switch result {
                case .success(let snapshot):
                    let changed = snapshot.volume.current != self.reading?.current || self.muteReading?.current == 1
                    self.apply(snapshot)
                    if self.softwareMode, let outputID, let uid = AudioOutputs.uid(outputID) {
                        UserDefaults.standard.set(Double(snapshot.volume.current) / Double(snapshot.volume.maximum), forKey: "softwareGain." + uid)
                    }
                    self.writing = !self.volumeWriter.isLatest(revision)
                    if !self.writing { self.pendingVolume = nil }
                    self.renderVolumePresentation(showHUD: self.hudForWrite)
                    if !self.writing { self.hudForWrite = false }
                    self.feedback.confirmed(snapshot, changed: changed,
                        enabled: (self.softwareMode || !self.software.blocksPhysicalFallback) && UserDefaults.standard.bool(forKey: "volumeFeedbackEnabled"),
                        software: self.softwareMode, outputUID: outputID.flatMap { AudioOutputs.uid($0) })
                    AudioDiagnostics.shared.record("volume confirmed backend=\(nativeMode ? "native" : "ddc") elapsed_ms=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) pending=\(self.writing)")
                    self.status.stringValue = snapshot.mute == nil ? L("音量可调；静音状态不可读") : ""
                    self.render(); self.updateKeys()
                case .failure(let error): self.fail(error, token: token)
                }
            }
        })
    }
    private func apply(_ snapshot: AudioSnapshot) {
        reading = SACReading(current: snapshot.volume.current, maximum: snapshot.volume.maximum)
        muteReading = snapshot.mute.map { SACReading(current: $0, maximum: 0) }
        if softwareMode, let mute = snapshot.mute, mute == 1 || mute == 2,
           let id = software.device?.id, let uid = AudioOutputs.uid(id) {
            lastSoftwareSnapshot = (uid, .init(gain: Float(snapshot.volume.current) / Float(snapshot.volume.maximum), muted: snapshot.mute == 1 ? 1 : 0))
        }
    }
    @objc private func toggleMute() { performMute() }
    private func performMute(showHUD: Bool = false) {
        AudioDiagnostics.shared.record("mute intent ready=\(reading != nil) muteReadable=\(muteReading != nil) busy=\(mutatingMute) refreshing=\(refreshing) failed=\(failed) sleeping=\(sleeping)")
        guard !measurementOnly, controllable, currentReading, let device = device, reading != nil, muteReading != nil, !mutatingMute, !sleeping, !failed, !refreshing else { return }
        feedback.stop(); pendingVolume = nil; expansion.activity()
        let contextID = hudID, nativeMode = native != nil || softwareMode, outputID = AudioOutputs.currentID()
        volumeWriter.cancel(); writing = true; mutatingMute = true
        hudForWrite = showHUD && !volumeMenuTracking
        if hudForWrite { hud.pending(displayID: contextID, requested: reading.map { AudioState(current: $0.current, maximum: $0.maximum) }) }
        slider.isEnabled = false
        let token = generation
        muteTrace = []
        queue.async {
            guard self.fence.matches(token) else { return }
            do {
                let valid = { self.fence.matches(token) && AudioOutputs.currentID() == outputID }
                let snapshot = try nativeMode ? NativeAudioOperations.mute(device: device, valid: valid) : DDCOperations.mute(device: TracedAudioDevice(device), memory: &self.muteMemory, valid: valid, trace: { stage in
                    AudioDiagnostics.shared.record(stage)
                    NSLog("SAC mute transaction: %@", stage)
                    DispatchQueue.main.async {
                        if self.fence.matches(token) { self.muteTrace.append(stage); self.muteTrace = Array(self.muteTrace.suffix(14)) }
                    }
                })
                DispatchQueue.main.async {
                    guard self.fence.matches(token) else { return }
                    guard AudioOutputs.currentID() == outputID else { return }
                    self.apply(snapshot); self.writing = false; self.mutatingMute = false
                    if self.hudForWrite { self.hud.verified(snapshot, displayID: contextID) }
                    self.hudForWrite = false
                    self.status.stringValue = ""; self.render(); self.updateKeys()
                }
            } catch { DispatchQueue.main.async { self.fail(error, token: token) } }
        }
    }
    private func conflictingApp() -> String? {
        NSWorkspace.shared.runningApplications.first {
            ["pro.betterdisplay.BetterDisplay", "me.guillaumeb.MonitorControl", "app.monitorcontrol.MonitorControl"].contains($0.bundleIdentifier ?? "") || ["BetterDisplay", "MonitorControl"].contains($0.localizedName ?? "")
        }?.localizedName
    }
    private func updateKeys() {
        defer { updateDiagnostics() }
        guard !measurementOnly, !sleeping else { keys.stop(); return }
        let trusted = AXIsProcessTrusted()
        controlPermissionTrusted = trusted
        controlPermission.update(trusted: trusted)
        guard MediaKeyPolicy.canListen(trusted: trusted, sleeping: sleeping, measurementOnly: measurementOnly) else {
            keys.stop(); status.stringValue = L("请在系统设置中允许音量键控制；音量滑杆仍可使用"); return
        }
        if !keys.start() { status.stringValue = L("音量事件监听未能启动；滑杆仍可用") }
        else if !writing && currentReading {
            status.stringValue = conflictingApp().map { L("\($0) 运行中；Ez Audio Control 优先接管可到达的音量指令") } ?? (muteReading == nil ? L("音量可调；静音状态不可读") : "")
        }
    }
    private func handleKey(_ key: MediaKey) -> Bool {
        guard MediaKeyPolicy.canListen(trusted: AXIsProcessTrusted(), sleeping: sleeping, measurementOnly: measurementOnly) else { return false }
        // Keep ownership of volume commands while a route is changing. Never
        // replay a command against a different device once that route is ready.
        guard key.down else { return true }
        if mutatingMute { return true }
        guard MediaKeyPolicy.canAdjust(ready: currentReading, refreshing: refreshing, failed: failed, controllable: controllable),
              let volume = reading else {
            hud.unavailable(displayID: AudioOutputs.currentID() ?? 0,
                reason: softwareMessage ?? (failed ? L("暂时无法调节音量") : L("正在连接音频设备")))
            return true
        }
        if key.code == 7 {
            if muteReading == nil { hud.unavailable(displayID: hudID, reason: L("音量可调；静音状态不可读")) }
            else if !key.repeated { performMute(showHUD: true) }
            return true
        }
        // While a write is pending, keep only the latest bounded key intent.
        // Repeats do not accumulate an unbounded queue.
        let base = writing ? VolumePolicy.raw(percent: slider.doubleValue, maximum: volume.maximum) : volume.current
        let direction = key.code == 0 ? 1 : -1
        let step = cadence.step(direction: direction, repeated: key.repeated, time: ProcessInfo.processInfo.systemUptime)
        let desired = VolumePolicy.step(current: base, maximum: volume.maximum, direction: direction, percent: step)
        slider.doubleValue = VolumePolicy.percent(raw: desired, maximum: volume.maximum)
        value.stringValue = "\(Int(slider.doubleValue.rounded()))%"
        scheduleVolume(desired, showHUD: true)
        return true
    }
    @objc private func toggleFeedback() {
        let enabled = !UserDefaults.standard.bool(forKey: "volumeFeedbackEnabled")
        UserDefaults.standard.set(enabled, forKey: "volumeFeedbackEnabled")
        feedbackItem.state = enabled ? .on : .off
        if !enabled { feedback.stop() }
    }
    @objc private func toggleLogin() {
        guard !measurementOnly else { return }
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
            if SMAppService.mainApp.status == .requiresApproval { status.stringValue = L("请在系统设置中批准登录项") }
        } catch { status.stringValue = L("开机启动设置失败：\(error.localizedDescription)") }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

if CommandLine.arguments.contains("--software-self-check") {
    var result = EZProcessTapFailure()
    let denied = EZProcessTapCreate(0, 0, 0, 1, &result)
    guard denied == nil, result.stage == Int32(EZTapConsent.rawValue) else { fatalError("Missing-consent gate failed") }
    print("PASS packaged runtime: tap API available=\(EZProcessTapAvailable() != 0); missing consent rejected before CoreAudio; no audio/UI/preferences")
} else if CommandLine.arguments.contains("--native-capabilities") {
    for output in (try? AudioOutputs.available()) ?? [] {
        if let device = NativeAudioDevice.discover(output.id), let volume = try? device.readVolume() {
            print("\(output.name): native volume=\(volume.current)/\(volume.maximum) mute=\((try? device.readMute()).map(String.init) ?? "unsupported") selector=\(device.volumeSelector)")
        } else { print("\(output.name): no writable native main volume") }
    }
} else if CommandLine.arguments.contains("--list-outputs") {
    do {
        let current = AudioOutputs.currentID()
        for output in try AudioOutputs.available() { print("\(current == output.id ? "*" : " ") \(output.name)") }
    } catch { print(error.localizedDescription); exit(1) }
} else if CommandLine.arguments.contains("--diagnostic-self-test") {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SAC-diagnostic-self-test-" + UUID().uuidString)
    let log = AudioDiagnostics(directory: directory)
    NSLog("SAC diagnostic self-test: no device accessed")
    log.record("self-test no-device no-events no-permissions")
    log.flush()
    guard log.failure == nil, (try? String(contentsOf: log.file, encoding: .utf8))?.contains("self-test no-device") == true else { exit(1) }
    print("PASS file and memory logger: \(log.file.path)")
    print(log.snapshot())
} else if CommandLine.arguments.contains("--diagnose") {
    print("App path: \(Bundle.main.bundlePath)")
    print("Version: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown")")
    print("Output device: \(outputDeviceName() ?? "unavailable")")
    print("Permission scope: this diagnostic process only; Finder runtime may differ")
    print("Accessibility trusted: \(AXIsProcessTrusted())")
    let displays = SACDisplay.discover()
    if displays.isEmpty { print("No accessible DDC displays"); exit(2) }
    for display in displays {
        do {
            let volume = try display.readCode(0x62)
            print("\(display.name) uuid=\(display.identifier) volume=\(volume.current)/\(volume.maximum)")
            if let mute = try? display.readCode(0x8d) { print("mute=\(mute.current)") }
        } catch { print(error.localizedDescription); exit(3) }
    }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
