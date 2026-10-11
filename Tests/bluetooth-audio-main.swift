import Foundation
import CoreBluetooth
import IOBluetooth

var checks = 0
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !value() { fatalError(message) }
}
let headset = BluetoothAudioDevice(address: "00:11:22:33:44:55", name: "Headset", isConnected: false)
let other = BluetoothAudioDevice(address: "AA:BB:CC:DD:EE:FF", name: "Other", isConnected: false)
func output(_ id: UInt32 = 20, name: String = "Headset", uid: String? = "00-11-22-33-44-55:output", bluetooth: Bool = true) -> BluetoothAudioOutput {
    BluetoothAudioOutput(id: id, name: name, uid: uid, isBluetooth: bluetooth)
}
expect(BluetoothAudioPolicy.normalizedAddress("00-11-22-33-44-55") == "001122334455", "address separators normalize")
expect(BluetoothAudioPolicy.normalizedAddress("not a MAC") == nil, "malformed address rejected")
expect(BluetoothAudioPolicy.outputID(for: headset, among: [output(name: "Renamed")]) == 20, "explicit UID address wins over a changed name")
expect(BluetoothAudioPolicy.outputID(for: headset, among: [output(uid: "Bluetooth_001122334455:output")]) == 20, "complete compact UID address token matches")
expect(BluetoothAudioPolicy.outputID(for: headset, among: [output(bluetooth: false)]) == nil, "non Bluetooth output never matches")
expect(BluetoothAudioPolicy.outputID(for: headset, among: [output(uid: nil)]) == 20, "one exact name with no address can match")
expect(BluetoothAudioPolicy.outputID(for: headset, among: [output(uid: "opaque-token")]) == 20, "opaque UID permits unique exact-name fallback")
expect(BluetoothAudioPolicy.outputID(for: headset, among: [output(name: "headset", uid: nil)]) == nil, "fallback requires exact name")
expect(BluetoothAudioPolicy.outputID(for: headset, among: [output(uid: "AA-BB-CC-DD-EE-FF:output")]) == nil, "conflicting address cannot fall back to name")
expect(BluetoothAudioPolicy.outputID(for: headset, among: [output(), output(21)]) == nil, "duplicate matching HAL endpoints are ambiguous")
expect(BluetoothAudioPolicy.outputID(for: headset, among: [output(uid: nil), output(21, uid: nil)]) == nil, "duplicate output names are ambiguous")
expect(BluetoothAudioPolicy.outputID(for: headset, among: [output(uid: "00-11-22-33-44-55_AA-BB-CC-DD-EE-FF")]) == nil, "multiple UID addresses are ambiguous")
let duplicate = BluetoothAudioDevice(address: "00-11-22-33-44-55", name: "Headset", isConnected: false)
expect(BluetoothAudioPolicy.uniqueDevices([headset, duplicate]).count == 1, "paired devices deduplicate by normalized address")
let names = BluetoothAudioPolicy.uniqueDevices([headset, BluetoothAudioDevice(address: other.address, name: headset.name, isConnected: false)])
expect(names.allSatisfy { !$0.allowsNameFallback }, "same-name paired devices disable fallback")
expect(BluetoothAudioPolicy.outputID(for: names[0], among: [output(uid: nil)]) == nil, "paired name collision remains ambiguous with one HAL output")
expect(BluetoothAudioPolicy.outputID(for: names[0], among: [output()]) == 20, "explicit address still resolves a paired name collision")
for minor in [UInt32(1), 2, 5, 6, 7, 8, 10, 15, 18] {
    expect(BluetoothAudioPolicy.isAudioOutput(major: 4, minor: minor, cachedServices: []), "playback device class included")
}
for (major, minor) in [(UInt32(4), UInt32(4)), (4, 12), (4, 13), (4, 14), (5, 1), (1, 0)] {
    expect(!BluetoothAudioPolicy.isAudioOutput(major: major, minor: minor, cachedServices: []), "input-only, video-only, HID and computer excluded")
}
expect(BluetoothAudioPolicy.isAudioOutput(major: 0, minor: 0, cachedServices: [0x110B]), "cached Audio Sink identifies unclassified speaker")
expect(!BluetoothAudioPolicy.isAudioOutput(major: 0, minor: 0, cachedServices: [0x110A, 0x110D, 0x111F]), "source, A2DP marker and audio gateway do not establish playback destination")

expect(BluetoothAudioPolicy.selectionResult(target: 20, initial: 10, current: 10, now: 1, deadline: 3) == .waiting, "route selection waits for notification")
expect(BluetoothAudioPolicy.selectionResult(target: 20, initial: 10, current: 20, now: 1, deadline: 3) == .confirmed, "actual default route confirms selection")
expect(BluetoothAudioPolicy.selectionResult(target: 20, initial: 10, current: 30, now: 1, deadline: 3) == .superseded, "third-party selection supersedes intent")
expect(BluetoothAudioPolicy.selectionResult(target: 20, initial: 10, current: nil, now: 1, deadline: 3) == .waiting, "transient empty route waits")
expect(BluetoothAudioPolicy.selectionResult(target: 20, initial: 10, current: nil, now: 3, deadline: 3) == .timedOut, "empty route still respects deadline")
expect(BluetoothAudioPolicy.selectionResult(target: 20, initial: nil, current: nil, now: 1, deadline: 3) == .waiting, "empty initial route can wait")
expect(BluetoothAudioPolicy.selectionResult(target: 20, initial: 10, current: 10, now: 2.999, deadline: 3) == .waiting, "route deadline not reached")
expect(BluetoothAudioPolicy.selectionResult(target: 20, initial: 10, current: 10, now: 3, deadline: 3) == .timedOut, "route deadline boundary expires")
expect(BluetoothAudioPolicy.selectionResult(target: 20, initial: 10, current: 20, now: 3, deadline: 3) == .confirmed, "observed selected route is confirmed at deadline")

final class FakeBluetooth {
    var authorization: CBManagerAuthorization = .allowedAlways
    var devices = [headset]
    var outputs: [BluetoothAudioOutput] = []
    var current: UInt32? = 10
    var now: TimeInterval = 0
    var pairedReads = 0, accessRequests = 0
    var connections: [String] = []
    var completions: [(IOReturn) -> Void] = []
    var immediateResult: IOReturn = kIOReturnSuccess
    var ready: [UInt32] = [], failures: [String] = []
    func controller() -> BluetoothAudioOutputs {
        let environment = BluetoothAudioEnvironment(
            authorization: { self.authorization },
            pairedDevices: { self.pairedReads += 1; return self.devices },
            requestAccess: { self.accessRequests += 1 },
            connect: { self.connections.append($0); self.completions.append($1); return self.immediateResult },
            outputs: { self.outputs }, currentOutput: { self.current }, now: { self.now })
        let controller = BluetoothAudioOutputs(environment: environment, schedulesPolling: false)
        controller.onOutputReady = { self.ready.append($0) }
        controller.onFailure = { self.failures.append($0) }
        return controller
    }
}

for permission in [CBManagerAuthorization.notDetermined, .denied, .restricted] {
    let fake = FakeBluetooth(); fake.authorization = permission
    let controller = fake.controller()
    expect(fake.pairedReads == 0 && fake.accessRequests == 0 && fake.connections.isEmpty, "construction has no discovery, permission or connection side effects")
    expect(controller.pairedAudioDevices().isEmpty && fake.pairedReads == 0, "permission gate prevents paired enumeration")
    controller.connect(headset.address)
    expect(fake.pairedReads == 0 && fake.connections.isEmpty && fake.failures.count == 1, "unauthorized connection fails without Bluetooth calls")
    controller.requestAccess()
    expect(fake.accessRequests == (permission == .notDetermined ? 1 : 0), "only explicit not-determined permission action requests access")
}
do {
    let fake = FakeBluetooth(); let controller = fake.controller()
    controller.requestAccess()
    expect(fake.accessRequests == 0, "already granted access does not request again")
    controller.connect(other.address)
    expect(fake.connections.isEmpty && controller.connectingAddress == nil, "unpaired address cannot connect")
}
do {
    let fake = FakeBluetooth(); let controller = fake.controller()
    controller.connect(headset.address)
    expect(fake.connections == [headset.address] && fake.ready.isEmpty, "explicit click starts one asynchronous connection")
    fake.completions[0](kIOReturnSuccess)
    expect(fake.ready.isEmpty && controller.connectingAddress == headset.address, "baseband success is not audio readiness")
    fake.outputs = [output()]; controller.poll()
    expect(fake.ready == [20] && controller.connectingAddress == nil, "HAL audio output completes intent once")
    controller.poll(); fake.completions[0](-99)
    expect(fake.ready == [20] && fake.failures.isEmpty, "late completion cannot repeat or fail a finished intent")
}
do {
    let fake = FakeBluetooth(); let controller = fake.controller()
    controller.connect(headset.address)
    fake.now = 14.999; controller.poll()
    expect(controller.connectingAddress != nil, "connection waits before fifteen second deadline")
    fake.now = 15; fake.outputs = [output()]; controller.poll()
    expect(controller.connectingAddress == nil && fake.ready.isEmpty && fake.failures.count == 1, "audio discovery at expired connection deadline cannot switch output")
    fake.completions[0](kIOReturnSuccess); controller.poll()
    expect(fake.ready.isEmpty && fake.failures.count == 1, "late completion after timeout is inert")
}
do {
    let fake = FakeBluetooth(); let controller = fake.controller()
    controller.connect(headset.address); controller.cancel()
    fake.outputs = [output()]; fake.completions[0](kIOReturnSuccess); controller.poll()
    expect(fake.ready.isEmpty && fake.failures.isEmpty && controller.connectingAddress == nil, "cancelled intent never selects or emits a late failure")
}
do {
    let fake = FakeBluetooth(); let controller = fake.controller()
    controller.connect(headset.address); controller.cancel(); controller.connect(headset.address)
    fake.completions[0](-99)
    expect(controller.connectingAddress == headset.address && fake.failures.isEmpty, "old same-address callback cannot fail a new request")
    fake.outputs = [output()]; fake.completions[1](kIOReturnSuccess)
    expect(fake.ready == [20] && fake.failures.isEmpty, "new request completes through its own callback")
}
do {
    let fake = FakeBluetooth(); let controller = fake.controller()
    controller.connect(headset.address); fake.current = 30; controller.routeChanged()
    fake.outputs = [output()]; fake.completions[0](kIOReturnSuccess)
    expect(controller.connectingAddress == nil && fake.ready.isEmpty && fake.failures.isEmpty, "different user route cancels pending Bluetooth selection")
}
do {
    let fake = FakeBluetooth(); let controller = fake.controller()
    controller.connect(headset.address); fake.outputs = [output()]; fake.current = 20; controller.routeChanged()
    expect(fake.ready == [20], "system selection of the intended target is accepted")
}
do {
    let fake = FakeBluetooth(); let controller = fake.controller()
    controller.connect(headset.address); fake.outputs = [output()]; fake.current = nil; controller.routeChanged()
    expect(fake.ready.isEmpty && controller.connectingAddress != nil, "temporary empty default is neither cancellation nor readiness")
    fake.current = 10; controller.routeChanged()
    expect(fake.ready == [20], "readiness resumes after initial default returns")
}
do {
    let fake = FakeBluetooth(); let controller = fake.controller()
    controller.connect(headset.address); fake.current = nil; fake.now = 15; controller.poll()
    expect(fake.ready.isEmpty && fake.failures.count == 1 && controller.connectingAddress == nil, "empty default cannot extend connection deadline")
}
do {
    let fake = FakeBluetooth(); fake.devices = [BluetoothAudioDevice(address: headset.address, name: headset.name, isConnected: true)]
    let controller = fake.controller(); controller.connect(headset.address)
    expect(fake.connections.isEmpty && controller.connectingAddress != nil, "existing baseband connection is not reopened")
    fake.outputs = [output()]; controller.poll()
    expect(fake.ready == [20], "already connected device still waits for HAL readiness")
}
for permission in [CBManagerAuthorization.denied, .notDetermined] {
    let fake = FakeBluetooth(); let controller = fake.controller()
    controller.connect(headset.address)
    let reads = fake.pairedReads
    fake.authorization = permission; fake.outputs = [output()]; controller.poll()
    expect(fake.ready.isEmpty && controller.connectingAddress == nil && fake.failures.count == 1, "permission loss cancels pending output readiness")
    expect(fake.pairedReads == reads && fake.accessRequests == 0, "permission loss does not enumerate or request access")
}
do {
    let fake = FakeBluetooth(); fake.immediateResult = -99
    let controller = fake.controller(); controller.connect(headset.address)
    expect(controller.connectingAddress == nil && fake.failures.count == 1, "immediate connection error terminates request")
    fake.outputs = [output()]; fake.completions[0](kIOReturnSuccess)
    expect(fake.ready.isEmpty, "callback after immediate failure cannot select output")
}
do {
    let fake = FakeBluetooth(); let controller = fake.controller()
    controller.connect(headset.address)
    fake.devices = [BluetoothAudioDevice(address: headset.address, name: headset.name, isConnected: true)]
    fake.completions[0](-99)
    expect(fake.failures.isEmpty && controller.connectingAddress != nil, "connection-exists result can continue waiting for audio")
    fake.outputs = [output()]; controller.poll()
    expect(fake.ready == [20], "connection-exists path needs HAL confirmation")
}
do {
    let fake = FakeBluetooth(); let controller = fake.controller()
    controller.connect(headset.address)
    controller.onChange = { if controller.connectingAddress == nil { controller.cancel() } }
    fake.outputs = [output()]; controller.poll()
    expect(fake.ready.isEmpty, "cancellation reentered from completion notification suppresses hand-off")
    controller.onChange = nil
}
do {
    let fake = FakeBluetooth(); fake.devices.append(other)
    let controller = fake.controller(); controller.connect(headset.address)
    var restarted = false
    controller.onChange = {
        if controller.connectingAddress == nil && !restarted {
            restarted = true; fake.outputs = []; controller.connect(other.address)
        }
    }
    fake.outputs = [output()]; controller.poll()
    expect(fake.ready.isEmpty && controller.connectingAddress == other.address, "new request reentered from completion notification replaces old hand-off")
    fake.completions[0](-99)
    expect(fake.failures.isEmpty && controller.connectingAddress == other.address, "old completion stays inert after reentrant replacement")
    fake.outputs = [output(21, name: other.name, uid: "AA-BB-CC-DD-EE-FF:output")]; controller.poll()
    expect(fake.ready == [21], "only replacement target is handed off")
    controller.onChange = nil
}
print("PASS \(checks) Bluetooth audio policy and fake-environment checks; no real paired-device enumeration, permission request, connection, output writes or playback")
