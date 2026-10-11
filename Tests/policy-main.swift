import Foundation
var checkCount = 0
func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    checkCount += 1
    if !condition() { fputs("FAIL: \(name)\n", stderr); exit(1) }
}
expect(VolumePolicy.raw(percent: 25, maximum: 300) == 75, "non-100 maximum")
expect(VolumePolicy.raw(percent: 120, maximum: 300) == 300, "upper clamp")
expect(VolumePolicy.raw(percent: -10, maximum: 300) == 0, "lower clamp")
expect(VolumePolicy.raw(percent: .nan, maximum: 300) == 0, "invalid slider")
expect(VolumePolicy.percent(raw: 75, maximum: 300) == 25, "scaling")
expect(VolumePolicy.step(current: 298, maximum: 300, direction: 1) == 300, "key upper clamp")
expect(VolumePolicy.step(current: 1, maximum: 300, direction: -1) == 0, "key lower clamp")
let fence = GenerationFence(), first = fence.advance()
expect(fence.matches(first), "active generation")
let second = fence.advance()
expect(!fence.matches(first) && fence.matches(second), "drop work after target/sleep invalidation")
let group = DispatchGroup()
for _ in 0..<100 { group.enter(); DispatchQueue.global().async { fence.advance(); group.leave() } }
group.wait();expect(!fence.matches(second), "thread-safe invalidation")
expect(MediaKey.decode(data1: 0x00000a00, subtype: 8)?.down == true, "volume up keydown")
expect(MediaKey.decode(data1: 0x00010b00, subtype: 8)?.down == false, "volume down keyup")
expect(MediaKey.decode(data1: 0x00070a01, subtype: 8)?.repeated == true, "mute repeat")
expect(MediaKey.decode(data1: 0x00020a00, subtype: 8) == nil, "ignore brightness")
expect(MediaKey.decode(data1: 0x00000a00, subtype: 7) == nil, "ignore other subtype")
print("\(checkCount) volume safety, generation concurrency and media key decoding checks passed")

// Production DDCOperations and LatestVolumeWriter below use fake devices only.
final class FakeDevice: AudioDDCDevice {
    var volume = AudioState(current: 44, maximum: 100)
    var muted = 2
    var volumeWrites: [Int] = []
    var muteWrites: [Int] = []
    var beforeVolumeRead: (() -> Void)?
    var failVolumeRead = false
    var failMuteRead = false
    var failWrite = false
    var mismatch = false
    var zeroOnMute = false
    var delayedMuteReads = 0
    var pendingMute: Int?
    var beforeMuteRead: (() -> Void)?
    func readVolume() throws -> AudioState {
        beforeVolumeRead?()
        if failVolumeRead { throw DDCOperationError.rangeChanged }
        return volume
    }
    func readMute() throws -> Int {
        beforeMuteRead?()
        if let pending = pendingMute {
            if delayedMuteReads > 0 { delayedMuteReads -= 1 }
            else { muted = pending; pendingMute = nil }
        }
        if failMuteRead { throw DDCOperationError.readbackMismatch }
        return muted
    }
    func writeVolume(_ value: Int) throws {
        if failWrite { throw DDCOperationError.readbackMismatch }
        volumeWrites.append(value)
        volume = AudioState(current: mismatch ? value + 1 : value, maximum: volume.maximum)
    }
    func writeMute(_ value: Int) throws {
        if failWrite { throw DDCOperationError.readbackMismatch }
        muteWrites.append(value)
        if delayedMuteReads > 0 { pendingMute = value } else { muted = value }
        if zeroOnMute && value == 1 { volume = AudioState(current: 0, maximum: volume.maximum) }
    }
}
func expectThrows(_ name: String, _ block: () throws -> Void) {
    do { try block(); expect(false, name) } catch { expect(true, name) }
}
let device = FakeDevice()
let same = try DDCOperations.volume(device: device, target: 44, expectedMaximum: 100, valid: { true })
expect(same.volume.current == 44 && device.volumeWrites.isEmpty, "same value skips unnecessary hardware write")
_ = try DDCOperations.volume(device: device, target: 46, expectedMaximum: 100, valid: { true })
expect(device.volumeWrites == [46], "small change read/write/readback")
_ = try DDCOperations.volume(device: device, target: 90, expectedMaximum: 100, valid: { true })
expect(device.volumeWrites == [46,90], "explicit slider target applies directly without confirmation")
let differentRange = FakeDevice(); differentRange.volume = AudioState(current: 80, maximum: 300)
expectThrows("changed maximum cancels") {
    _ = try DDCOperations.volume(device: differentRange, target: 82, expectedMaximum: 100, valid: { true })
}
expect(differentRange.volumeWrites.isEmpty, "range change did not write")
let unplugged = FakeDevice(); unplugged.failVolumeRead = true
expectThrows("disconnected device read failure") {
    _ = try DDCOperations.volume(device: unplugged, target: 46, expectedMaximum: 100, valid: { true })
}
expect(unplugged.volumeWrites.isEmpty, "disconnected device did not write")
let changing = FakeDevice(), liveFence = GenerationFence(), liveToken = liveFence.advance()
changing.beforeVolumeRead = { liveFence.advance() }
expectThrows("disconnect during fresh read cancels before write") {
    _ = try DDCOperations.volume(device: changing, target: 46, expectedMaximum: 100, valid: { liveFence.matches(liveToken) })
}
expect(changing.volumeWrites.isEmpty, "mid-read invalidation did not write")
let unsupportedMute = FakeDevice(); unsupportedMute.failMuteRead = true
let volumeOnly = try DDCOperations.volume(device: unsupportedMute, target: 46, expectedMaximum: 100, valid: { true })
expect(volumeOnly.mute == nil && volumeOnly.volume.current == 46, "mute unsupported keeps volume available")
let mismatched = FakeDevice(); mismatched.mismatch = true
expectThrows("readback mismatch reported") {
    _ = try DDCOperations.volume(device: mismatched, target: 46, expectedMaximum: 100, valid: { true })
}
let writeFailure = FakeDevice(); writeFailure.failWrite = true
expectThrows("write failure reported") {
    _ = try DDCOperations.volume(device: writeFailure, target: 46, expectedMaximum: 100, valid: { true })
}
let muteDevice = FakeDevice()
let muted = try DDCOperations.mute(device: muteDevice, valid: { true })
expect(muted.mute == 1 && muted.volume.current == 44 && muteDevice.volumeWrites.isEmpty, "mute preserves actual volume")
// Simulate an external OSD update while muted; unmute must adopt it, not restore 44.
muteDevice.volume = AudioState(current: 31, maximum: 100)
let unmuted = try DDCOperations.mute(device: muteDevice, valid: { true })
expect(unmuted.mute == 2 && unmuted.volume.current == 31, "unmute adopts current display volume")
expect(muteDevice.muteWrites == [1, 2] && muteDevice.volumeWrites.isEmpty, "mute/unmute never restores cached volume")
let unreadableMute = FakeDevice(); unreadableMute.failMuteRead = true
expectThrows("mute fails closed when unreadable") { _ = try DDCOperations.mute(device: unreadableMute, valid: { true }) }
expect(unreadableMute.muteWrites.isEmpty, "unreadable mute did not write")
let staleMute = FakeDevice()
expectThrows("stale mute request cancels") { _ = try DDCOperations.mute(device: staleMute, valid: { false }) }
expect(staleMute.muteWrites.isEmpty, "stale mute did not write")

// Regression: a monitor may publish its new 0x8D state several reads later.
let delayed = FakeDevice(); delayed.delayedMuteReads = 3
var delayedMemory: MuteMemory?
let delayedResult = try DDCOperations.mute(device: delayed, memory: &delayedMemory, valid: { true }, pause: {})
expect(delayedResult.mute == 1 && delayed.muteWrites == [1], "delayed mute readback settles with one write")
let zeroing = FakeDevice(); zeroing.zeroOnMute = true
var zeroMemory: MuteMemory?
let zeroMuted = try DDCOperations.mute(device: zeroing, memory: &zeroMemory, valid: { true }, pause: {})
expect(zeroMuted.volume.current == 0 && zeroMemory?.original.current == 44, "capture only our observed mute-induced zero")
let zeroUnmuted = try DDCOperations.mute(device: zeroing, memory: &zeroMemory, valid: { true }, pause: {})
expect(zeroUnmuted.volume.current == 44 && zeroMemory == nil && zeroing.volumeWrites == [44], "restore this session's mute-induced zero")
_ = try DDCOperations.volume(device: zeroing, target: 46, expectedMaximum: 100, valid: { true })
expect(zeroing.volume.current == 46, "mute unmute then slider remains usable")
let external = FakeDevice(); external.zeroOnMute = true
var externalMemory: MuteMemory?
_ = try DDCOperations.mute(device: external, memory: &externalMemory, valid: { true }, pause: {})
external.volume = AudioState(current: 29, maximum: 100)
let adopted = try DDCOperations.mute(device: external, memory: &externalMemory, valid: { true }, pause: {})
expect(adopted.volume.current == 29 && external.volumeWrites.isEmpty, "external nonzero volume supersedes pre-mute memory")
let racing = FakeDevice(); racing.zeroOnMute = true
var raceMemory: MuteMemory?
_ = try DDCOperations.mute(device: racing, memory: &raceMemory, valid: { true }, pause: {})
var unmuteVolumeReads = 0
racing.beforeVolumeRead = {
    unmuteVolumeReads += 1
    if unmuteVolumeReads == 3 { racing.volume = AudioState(current: 21, maximum: 100) }
}
let race = try DDCOperations.mute(device: racing, memory: &raceMemory, valid: { true }, pause: {})
expect(race.volume.current == 21 && racing.volumeWrites.isEmpty, "external change immediately before restoration wins")
let lastMoment = FakeDevice(); lastMoment.zeroOnMute = true
var lastMemory: MuteMemory?
_ = try DDCOperations.mute(device: lastMoment, memory: &lastMemory, valid: { true }, pause: {})
var lastReads = 0
lastMoment.beforeVolumeRead = {
    lastReads += 1
    if lastReads == 4 { lastMoment.volume = AudioState(current: 19, maximum: 100) }
}
let lastAdopted = try DDCOperations.mute(device: lastMoment, memory: &lastMemory, valid: { true }, pause: {})
expect(lastAdopted.volume.current == 19 && lastMoment.volumeWrites.isEmpty, "final transaction read also respects external nonzero change")
let dragged = FakeDevice(); dragged.zeroOnMute = true
var dragMemory: MuteMemory?
_ = try DDCOperations.mute(device: dragged, memory: &dragMemory, valid: { true }, pause: {})
dragMemory = nil // production explicit volume intent discards memory on the serial queue
_ = try DDCOperations.volume(device: dragged, target: 20, expectedMaximum: 100, valid: { true })
let dragUnmuted = try DDCOperations.mute(device: dragged, memory: &dragMemory, valid: { true }, pause: {})
expect(dragUnmuted.volume.current == 20 && dragged.volumeWrites == [20], "slider while muted replaces prior restore value")
let unstable = FakeDevice(); unstable.delayedMuteReads = 20
var unstableMemory: MuteMemory?
expectThrows("unsupported mute or timeout reports bounded failure") {
    _ = try DDCOperations.mute(device: unstable, memory: &unstableMemory, valid: { true }, pause: {})
}
expect(unstable.muteWrites == [1], "timeout never retries hardware writes")
unstable.pendingMute = nil; unstable.delayedMuteReads = 0
let recovered = try DDCOperations.volume(device: unstable, target: 40, expectedMaximum: 100, valid: { true })
expect(recovered.volume.current == 40, "mute failure does not poison later volume transaction")
let quick = FakeDevice(); var quickMemory: MuteMemory?
for _ in 0..<6 { _ = try DDCOperations.mute(device: quick, memory: &quickMemory, valid: { true }, pause: {}) }
expect(quick.muted == 2 && quick.volume.current == 44 && quick.volumeWrites.isEmpty, "repeated sequential mute toggles preserve volume")

let mergeDevice = FakeDevice(), mergeQueue = DispatchQueue(label: "test.coalescing")
let merge = LatestVolumeWriter(queue: mergeQueue, interval: 0.02)
mergeQueue.suspend()
let mergedDone = DispatchSemaphore(value: 0)
for desired in 45...54 {
    merge.submit(target: desired, operation: { latest in
        try DDCOperations.volume(device: mergeDevice, target: desired, expectedMaximum: 100,
                                 valid: latest)
    }, completion: { revision, result in
        if merge.isLatest(revision), case .success = result { mergedDone.signal() }
    })
}
mergeQueue.resume()
expect(mergedDone.wait(timeout: .now() + 2) == .success, "rapid slider latest intent completed")
expect(mergeDevice.volumeWrites == [54], "ten rapid slider requests merged to one write")

let inFlight = FakeDevice(), flightQueue = DispatchQueue(label: "test.inFlight")
let flight = LatestVolumeWriter(queue: flightQueue, interval: 0.01)
let enteredRead = DispatchSemaphore(value: 0), releaseRead = DispatchSemaphore(value: 0), latestDone = DispatchSemaphore(value: 0)
var firstRead = true
inFlight.beforeVolumeRead = {
    if firstRead { firstRead = false; enteredRead.signal(); _ = releaseRead.wait(timeout: .now() + 2) }
}
flight.submit(target: 45, operation: { latest in
    try DDCOperations.volume(device: inFlight, target: 45, expectedMaximum: 100, valid: latest)
}, completion: { _, _ in })
expect(enteredRead.wait(timeout: .now() + 2) == .success, "old request entered read")
flight.submit(target: 48, operation: { latest in
    try DDCOperations.volume(device: inFlight, target: 48, expectedMaximum: 100, valid: latest)
}, completion: { revision, result in
    if flight.isLatest(revision), case .success = result { latestDone.signal() }
})
releaseRead.signal()
expect(latestDone.wait(timeout: .now() + 2) == .success, "replacement intent completed")
expect(inFlight.volumeWrites == [48], "older request superseded during read never writes")

let cancelDevice = FakeDevice(), cancelQueue = DispatchQueue(label: "test.cancel")
let cancelWriter = LatestVolumeWriter(queue: cancelQueue, interval: 0.02)
cancelQueue.suspend()
cancelWriter.submit(target: 46, operation: { latest in
    try DDCOperations.volume(device: cancelDevice, target: 46, expectedMaximum: 100, valid: latest)
}, completion: { _, _ in })
cancelWriter.cancel(); cancelQueue.resume()
let drained = DispatchSemaphore(value: 0)
cancelQueue.asyncAfter(deadline: .now() + 0.04) { drained.signal() }
expect(drained.wait(timeout: .now() + 2) == .success && cancelDevice.volumeWrites.isEmpty, "sleep/disconnect drops pending write")
expect(MediaKeyPolicy.canListen(trusted: true, sleeping: false, measurementOnly: false), "authorized awake app listens without a backend readiness gate")
expect(!MediaKeyPolicy.canListen(trusted: false, sleeping: false, measurementOnly: false), "no permission declines event tap")
expect(!MediaKeyPolicy.canListen(trusted: true, sleeping: true, measurementOnly: false), "sleep declines event tap")
expect(!MediaKeyPolicy.canListen(trusted: true, sleeping: false, measurementOnly: true), "read-only measurement declines event tap")
expect(MediaKeyPolicy.canAdjust(ready: true, refreshing: false, failed: false, controllable: true), "ready controllable native headphones and software backends accept adjustment")
expect(!MediaKeyPolicy.canAdjust(ready: false, refreshing: false, failed: false, controllable: true), "unreadable or switching backend rejects writes")
expect(!MediaKeyPolicy.canAdjust(ready: true, refreshing: true, failed: false, controllable: true), "refreshing backend rejects writes")
expect(!MediaKeyPolicy.canAdjust(ready: true, refreshing: false, failed: true, controllable: true), "failed backend rejects writes")
expect(!MediaKeyPolicy.canAdjust(ready: true, refreshing: false, failed: false, controllable: false), "uncontrollable current output rejects writes")
print("\(checkCount) total checks passed, including production write flow using fake devices; no real DDC writes")

let repeatDevice = FakeDevice(), repeatQueue = DispatchQueue(label: "test.repeat")
let repeats = LatestVolumeWriter(queue: repeatQueue, interval: 0.01)
let repeatRead = DispatchSemaphore(value: 0), releaseRepeat = DispatchSemaphore(value: 0), repeatDone = DispatchSemaphore(value: 0)
var firstRepeatRead = true
repeatDevice.beforeVolumeRead = {
    if firstRepeatRead { firstRepeatRead = false; repeatRead.signal(); _ = releaseRepeat.wait(timeout: .now() + 2) }
}
let repeatID = repeats.submit(target: 46, operation: { latest in
    try DDCOperations.volume(device: repeatDevice, target: 46, expectedMaximum: 100, valid: latest)
}, completion: { _, result in if case .success = result { repeatDone.signal() } })
expect(repeatRead.wait(timeout: .now() + 2) == .success, "repeat test entered read")
var duplicateIDs: [Int] = []
for _ in 0..<100 {
    duplicateIDs.append(repeats.submit(target: 46, operation: { _ in fatalError("duplicate intent ran") }, completion: { _, _ in }))
}
expect(duplicateIDs.allSatisfy { $0 == repeatID }, "identical intents preserve in-flight revision")
releaseRepeat.signal()
expect(repeatDone.wait(timeout: .now() + 2) == .success && repeatDevice.volumeWrites == [46], "100 key repeats do not starve or duplicate write")
print("\(checkCount) final checks passed; all write-flow tests used fake devices")

var dedupe = VolumeEventDeduplicator()
expect(!dedupe.wasHandled(timestamp: 100, source: 2853, data1: 0x00000a00), "injected media event is new")
dedupe.markHandled(timestamp: 100, source: 2853, data1: 0x00000a00)
expect(dedupe.wasHandled(timestamp: 100, source: 2853, data1: 0x00000a00), "same event across tap stages deduplicated")
expect(!dedupe.wasHandled(timestamp: 101, source: 2853, data1: 0x00000a00), "distinct rapid volume event retained")
expect(!dedupe.wasHandled(timestamp: 100, source: 2853, data1: 0x00000b00), "keyup is separate event")
expect(!dedupe.wasHandled(timestamp: 0, source: 2853, data1: 0x00000a00), "zero timestamps not dropped")
print("\(checkCount) final no-confirmation and source-independent system-volume checks passed")

var cadence = VolumeCadence()
expect(cadence.step(direction: 1, repeated: false, time: 1) == 1, "first action fine")
expect(cadence.step(direction: 1, repeated: false, time: 1.04) == 2, "fast second ramps gradually")
expect(cadence.step(direction: 1, repeated: false, time: 1.08) == 3, "fast third ramps")
expect(cadence.step(direction: 1, repeated: false, time: 1.12) == 4, "fast capped at four")
expect(cadence.step(direction: -1, repeated: false, time: 1.16) == 1, "reversal resets fine")
expect(cadence.step(direction: -1, repeated: false, time: 2) == 1, "pause resets fine")
expect(cadence.step(direction: -1, repeated: true, time: 2.04) == 2, "keyboard hold stays bounded")
expect(VolumePolicy.step(current: 99, maximum: 100, direction: 1, percent: 4) == 100, "accelerated range clamp")
expect(VolumePolicy.step(current: 100, maximum: 200, direction: -1, percent: 1) == 98, "fine step respects actual maximum")
print("\(checkCount) checks including bounded cadence acceleration passed; no real DDC writes")

expect(MediaKeyPolicy.canListen(trusted: true, sleeping: false, measurementOnly: false) &&
       !MediaKeyPolicy.canAdjust(ready: false, refreshing: true, failed: false, controllable: false),
       "output transition keeps command listening while blocking backend writes")
print("\(checkCount) control-policy checks passed")
