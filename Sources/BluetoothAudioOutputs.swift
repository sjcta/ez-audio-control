import Foundation
import AppKit
import CoreAudio
import CoreBluetooth
import IOBluetooth

// Tests supply every operation; no production Bluetooth object is constructed
// or permission requested by the fake environment.
struct BluetoothAudioEnvironment {
    var authorization: () -> CBManagerAuthorization
    var pairedDevices: () -> [BluetoothAudioDevice]
    var requestAccess: () -> Void
    var connect: (String, @escaping (IOReturn) -> Void) -> IOReturn
    var outputs: () -> [BluetoothAudioOutput]
    var currentOutput: () -> AudioDeviceID?
    var now: () -> TimeInterval
}

private final class BluetoothConnectionCallback: NSObject {
    let completion: (IOReturn) -> Void
    init(_ completion: @escaping (IOReturn) -> Void) { self.completion = completion }
    @objc(connectionComplete:status:)
    func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) { completion(status) }
}

final class BluetoothAudioOutputs: NSObject, CBCentralManagerDelegate {
    var onChange: (() -> Void)?
    var onOutputReady: ((AudioDeviceID) -> Void)?
    var onFailure: ((String) -> Void)?
    var connectingAddress: String? { intent?.device.address }
    var authorization: CBManagerAuthorization { environment?.authorization() ?? CBManager.authorization }
    private struct Intent {
        let token: UInt64
        let device: BluetoothAudioDevice
        let initial: AudioDeviceID?
        let deadline: TimeInterval
    }
    private let environment: BluetoothAudioEnvironment?
    private let schedulesPolling: Bool
    private var manager: CBCentralManager?
    private var intent: Intent?
    private var generation: UInt64 = 0
    private var timer: Timer?
    // Keep cancelled attempts' delegates alive until their own completion.
    // Their token prevents a late callback from completing a newer attempt.
    private var callbacks: [UInt64: BluetoothConnectionCallback] = [:]
    init(environment: BluetoothAudioEnvironment? = nil, schedulesPolling: Bool = true) {
        self.environment = environment; self.schedulesPolling = schedulesPolling
        super.init()
    }
    deinit { timer?.invalidate() }

    func pairedAudioDevices() -> [BluetoothAudioDevice] {
        guard authorization == .allowedAlways else { return [] }
        if let environment { return BluetoothAudioPolicy.uniqueDevices(environment.pairedDevices()) }
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return BluetoothAudioPolicy.uniqueDevices(devices.compactMap { device in
            let services: Set<UInt16> = Set([UInt16(0x110B), 0x1108, 0x111E, 0x1131].filter {
                device.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: $0)) != nil
            })
            guard BluetoothAudioPolicy.isAudioOutput(major: device.deviceClassMajor, minor: device.deviceClassMinor,
                                                     cachedServices: services),
                  let address = device.addressString, let name = device.name else { return nil }
            return BluetoothAudioDevice(address: address, name: name, isConnected: device.isConnected())
        })
    }

    // Called only by the explicit permission menu action. No scan is started.
    func requestAccess() {
        guard authorization == .notDetermined else { onChange?(); return }
        if let environment { environment.requestAccess(); return }
        guard manager == nil else { return }
        manager = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if authorization != .allowedAlways { cancel() }
        onChange?()
    }

    static func outputID(for device: BluetoothAudioDevice, among outputs: [AudioOutputDevice]) -> AudioDeviceID? {
        BluetoothAudioPolicy.outputID(for: device, among: outputSnapshots(outputs))
    }
    private static func outputSnapshots(_ outputs: [AudioOutputDevice]) -> [BluetoothAudioOutput] {
        outputs.map {
            BluetoothAudioOutput(id: $0.id, name: $0.name, uid: AudioOutputs.uid($0.id),
                isBluetooth: $0.transport == kAudioDeviceTransportTypeBluetooth || $0.transport == kAudioDeviceTransportTypeBluetoothLE)
        }
    }
    private var now: TimeInterval { environment?.now() ?? ProcessInfo.processInfo.systemUptime }
    private var currentOutput: AudioDeviceID? {
        if let environment { return environment.currentOutput() }
        return AudioOutputs.currentID()
    }
    private func outputs() -> [BluetoothAudioOutput] {
        if let environment { return environment.outputs() }
        return Self.outputSnapshots((try? AudioOutputs.available()) ?? [])
    }

    func connect(_ address: String) {
        cancel()
        guard authorization == .allowedAlways else { onFailure?(L("请允许蓝牙访问后再连接音频设备")); return }
        guard let normalized = BluetoothAudioPolicy.normalizedAddress(address),
              let device = pairedAudioDevices().first(where: { BluetoothAudioPolicy.normalizedAddress($0.address) == normalized }) else {
            onFailure?(L("这个蓝牙音频设备已不在配对列表中")); return
        }
        generation &+= 1
        let token = generation
        intent = Intent(token: token, device: device, initial: currentOutput, deadline: now + 15)
        onChange?()
        poll()
        guard intent?.token == token else { return }
        if schedulesPolling {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .eventTracking)
        }
        guard !device.isConnected else { return }
        let completion: (IOReturn) -> Void = { [weak self] status in
            let receive: () -> Void = { [weak self] in self?.connectionFinished(token: token, status: status) }
            if Thread.isMainThread { receive() } else { DispatchQueue.main.async(execute: receive) }
        }
        let result: IOReturn
        if let environment {
            result = environment.connect(device.address, completion)
        } else if let remote = IOBluetoothDevice(addressString: device.address), remote.isPaired() {
            let callback = BluetoothConnectionCallback(completion)
            callbacks[token] = callback
            result = remote.openConnection(callback)
        } else {
            fail(token: token, message: L("这个蓝牙音频设备已不在配对列表中")); return
        }
        if result != kIOReturnSuccess { connectionFinished(token: token, status: result) }
    }

    private func connectionFinished(token: UInt64, status: IOReturn) {
        callbacks.removeValue(forKey: token)
        guard let intent, intent.token == token else { return }
        // A baseband connection can succeed without the audio profile being
        // ready. CoreAudio discovery, not this callback, completes the request.
        poll()
        guard self.intent?.token == token, status != kIOReturnSuccess else { return }
        let connected = pairedAudioDevices().contains {
            BluetoothAudioPolicy.normalizedAddress($0.address) == BluetoothAudioPolicy.normalizedAddress(intent.device.address) && $0.isConnected
        }
        if !connected { fail(token: token, message: L("无法连接蓝牙音频设备（\(status)）")) }
    }
    func routeChanged() { poll() }
    func cancel() {
        generation &+= 1
        let wasConnecting = intent != nil
        clearIntent()
        if wasConnecting { onChange?() }
    }
    private func clearIntent() { timer?.invalidate(); timer = nil; intent = nil }
    private func fail(token: UInt64, message: String) {
        guard intent?.token == token else { return }
        clearIntent(); onChange?()
        if generation == token { onFailure?(message) }
    }
    // Internal entry point also lets fake-clock tests exercise deadlines without
    // a runloop, real Bluetooth access, or any CoreAudio route write.
    func poll() {
        guard let intent else { return }
        guard authorization == .allowedAlways else {
            fail(token: intent.token, message: L("请允许蓝牙访问后再连接音频设备")); return
        }
        guard now < intent.deadline else {
            fail(token: intent.token, message: L("蓝牙设备未能及时成为音频输出，请检查设备后重试")); return
        }
        // HAL can briefly have no default while a route is changing. It is not
        // evidence of another selection, and is not ready for our hand-off.
        guard let current = currentOutput else { return }
        let target = BluetoothAudioPolicy.outputID(for: intent.device, among: outputs())
        guard current == intent.initial || (target != nil && current == target) else { cancel(); return }
        guard let target else { return }
        clearIntent(); onChange?()
        if generation == intent.token { onOutputReady?(target) }
    }
}
