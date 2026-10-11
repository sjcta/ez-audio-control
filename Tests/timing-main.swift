import Foundation
var checks = 0
func expect(_ ok: @autoclosure () -> Bool, _ text: String) {
    checks += 1; if !ok() { fatalError(text) }
}
final class TimedDevice: AudioDDCDevice {
    let readDelay: Double, writeDelay: Double, maximum: Int
    let start = ProcessInfo.processInfo.systemUptime
    var value: Int
    var writes: [(Double,Int)] = []
    init(native: Bool) { readDelay = native ? 0.001 : 0.070; writeDelay = native ? 0.001 : 0.015; maximum = native ? 10000 : 100; value = maximum / 4 }
    func readVolume() throws -> AudioState {
        Thread.sleep(forTimeInterval: readDelay)
        return AudioState(current: value, maximum: maximum)
    }
    func readMute() throws -> Int { Thread.sleep(forTimeInterval: readDelay); return 2 }
    func writeVolume(_ v: Int) throws {
        Thread.sleep(forTimeInterval: writeDelay); value = v
        writes.append((ProcessInfo.processInfo.systemUptime - start, v))
    }
    func writeMute(_ value: Int) throws { fatalError("No mute in timing benchmark") }
}
func run(native: Bool, streaming: Bool) -> (first: Double, final: Double, count: Int) {
    let queue = DispatchQueue(label: "fake-volume")
    let old = LatestVolumeWriter(queue: queue)
    let new = StreamingVolumeWriter(queue: queue)
    let device = TimedDevice(native: native)
    let done = DispatchSemaphore(value: 0)
    var finalTime = 0.0
    let last = native ? 3000 : 30
    for index in 0..<40 {
        // Reverse halfway; a pause after the last intent must still flush the tail.
        let step = index < 20 ? 26 + index : 49 - index / 2
        let target = index == 39 ? last : (native ? step * 100 : step)
        let completion: (Int,Result<AudioSnapshot,Error>) -> Void = { revision, result in
            if case .success(let snapshot) = result,
               (streaming ? new.isLatest(revision) : old.isLatest(revision)), snapshot.volume.current == last {
                finalTime = ProcessInfo.processInfo.systemUptime - device.start; done.signal()
            }
        }
        if streaming {
            new.submit(target: target, operation: { resolver in
                if native { return try NativeAudioOperations.volume(device: device, target: target, valid: { true }, resolveTarget: resolver) }
                return try DDCOperations.volume(device: device, target: target, expectedMaximum: 100, valid: { true }, resolveTarget: resolver)
            }, completion: completion)
        } else {
            old.submit(target: target, operation: { valid in
                if native { return try NativeAudioOperations.volume(device: device, target: target, valid: valid) }
                return try DDCOperations.volume(device: device, target: target, expectedMaximum: 100, valid: valid)
            }, completion: completion)
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    expect(done.wait(timeout: .now() + 4) == .success, "tail confirmed")
    let values = queue.sync { device.writes }
    expect(queue.sync { device.value } == last, "reversal final target retained")
    expect(values.allSatisfy { $0.1 >= 0 && $0.1 <= device.maximum }, "bounded actual writes")
    return (values.first!.0, finalTime, values.count)
}
for native in [false,true] {
    let before = run(native: native, streaming: false), after = run(native: native, streaming: true)
    expect(after.first < before.first, "first write earlier")
    if !native { expect(after.count > before.count, "DDC continuous input no longer starves writes") }
    print(String(format: "%@ fake timed backend: old first-write %.0fms final-confirm %.0fms writes %d; new first-write %.0fms final-confirm %.0fms writes %d",native ? "CoreAudio" : "DDC",before.first*1000,before.final*1000,before.count,after.first*1000,after.final*1000,after.count))
}
let queue = DispatchQueue(label: "cancel-test")
let writer = StreamingVolumeWriter(queue: queue)
let entered = DispatchSemaphore(value:0), release = DispatchSemaphore(value:0), finished = DispatchSemaphore(value:0)
var writes = 0
writer.submit(target: 80, operation: { resolver in
    entered.signal(); release.wait()
    guard let value = resolver() else { throw DDCOperationError.cancelled }
    writes += 1; return AudioSnapshot(volume: AudioState(current:value,maximum:100),mute:2)
}, completion: { _,_ in fatalError("Old route completion delivered") })
expect(entered.wait(timeout:.now()+1) == .success, "fresh read started")
writer.cancel(); release.signal(); queue.sync {}
expect(writes == 0, "output switch cancels before write")
writer.submit(target: 20, operation: { resolver in
    guard let value = resolver() else { throw DDCOperationError.cancelled }
    writes += 1; return AudioSnapshot(volume: AudioState(current:value,maximum:100),mute:2)
}, completion: { _,result in
    if case .success(let snapshot) = result { expect(snapshot.volume.current == 20, "new route value") }
    finished.signal()
})
expect(finished.wait(timeout:.now()+1) == .success && writes == 1, "new route resumes")
print("PASS \(checks) stream timing/cancellation checks; synthetic latency only, no hardware/audio")
