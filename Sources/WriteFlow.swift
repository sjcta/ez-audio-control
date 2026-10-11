import Foundation

struct AudioState: Equatable {
    let current: Int
    let maximum: Int
}
struct AudioSnapshot {
    let volume: AudioState
    let mute: Int?
    var effectiveSilent: Bool { mute == 1 || volume.current == 0 }
}
protocol AudioDDCDevice {
    func readVolume() throws -> AudioState
    func readMute() throws -> Int
    func writeVolume(_ value: Int) throws
    func writeMute(_ value: Int) throws
}
enum DDCOperationError: LocalizedError {
    case cancelled, rangeChanged, readbackMismatch
    var errorDescription: String? {
        switch self {
        case .cancelled: return L("目标或音量意图已改变，已取消写入")
        case .rangeChanged: return L("音量范围改变，已取消写入")
        case .readbackMismatch: return L("写入后读回不一致，可能有其他控制器同时操作")
        }
    }
}
// Only remembers a volume drop observed immediately after our own mute, within
// this connection. Explicit volume intents, external nonzero changes, or a new
// connection discard it. Displays that preserve volume need no restoration.
struct MuteMemory {
    let original: AudioState
}
enum DDCOperations {
    private static func verifiedMute(device: AudioDDCDevice, desired: Int,
                                     valid: () -> Bool, pause: () -> Void) throws -> Int {
        for attempt in 0..<6 {
            guard valid() else { throw DDCOperationError.cancelled }
            if let value = try? device.readMute(), value == desired { return value }
            if attempt < 5 { pause() }
        }
        throw DDCOperationError.readbackMismatch
    }
    static func volume(device: AudioDDCDevice, target: Int, expectedMaximum: Int,
                       valid: () -> Bool, expectedCurrent: Int? = nil,
                       resolveTarget: (() -> Int?)? = nil) throws -> AudioSnapshot {
        guard valid() else { throw DDCOperationError.cancelled }
        let fresh = try device.readVolume()
        guard valid() else { throw DDCOperationError.cancelled }
        guard fresh.maximum > 0, fresh.current >= 0, fresh.current <= fresh.maximum,
              fresh.maximum == expectedMaximum else { throw DDCOperationError.rangeChanged }
        if let expected = expectedCurrent, fresh.current != expected {
            return AudioSnapshot(volume: fresh, mute: try? device.readMute())
        }
        guard let target = resolveTarget.map({ $0() }) ?? target else { throw DDCOperationError.cancelled }
        let desired = min(fresh.maximum, max(0, target))
        guard valid() else { throw DDCOperationError.cancelled }
        if desired != fresh.current { try device.writeVolume(desired) }
        let verified = try device.readVolume()
        guard verified.current == desired && verified.maximum == fresh.maximum else { throw DDCOperationError.readbackMismatch }
        return AudioSnapshot(volume: verified, mute: try? device.readMute())
    }
    static func mute(device: AudioDDCDevice, valid: () -> Bool) throws -> AudioSnapshot {
        var memory: MuteMemory?
        return try mute(device: device, memory: &memory, valid: valid)
    }
    static func mute(device: AudioDDCDevice, memory: inout MuteMemory?,
                     valid: () -> Bool,
                     pause: () -> Void = { Thread.sleep(forTimeInterval: 0.05) },
                     trace: (String) -> Void = { _ in }) throws -> AudioSnapshot {
        guard valid() else { throw DDCOperationError.cancelled }
        let volumeBefore = try device.readVolume()
        let before = try device.readMute()
        guard before == 1 || before == 2 else { throw DDCOperationError.readbackMismatch }
        trace("before volume=\(volumeBefore.current)/\(volumeBefore.maximum) mute=\(before) saved=\(memory?.original.current.description ?? "none")")
        let desired = before == 1 ? 2 : 1
        if before == 2 || volumeBefore.current != 0 || memory?.original.maximum != volumeBefore.maximum {
            memory = nil
        }
        guard valid() else { throw DDCOperationError.cancelled }
        trace("write mute=\(desired)")
        try device.writeMute(desired)
        let after = try verifiedMute(device: device, desired: desired, valid: valid, pause: pause)
        var volumeAfter = try device.readVolume()
        trace("verified mute=\(after) volume=\(volumeAfter.current)/\(volumeAfter.maximum)")
        guard valid() else { throw DDCOperationError.cancelled }
        if desired == 1, volumeBefore.current > 0, volumeAfter.current == 0,
           volumeBefore.maximum == volumeAfter.maximum {
            memory = MuteMemory(original: volumeBefore)
            trace("observed mute-induced zero; saved=\(volumeBefore.current)")
        } else if desired == 2 {
            // Restore only the zero produced by our own preceding mute. Recheck
            // immediately before writing; adopt any external nonzero change.
            if let saved = memory, volumeBefore.current == 0, volumeAfter.current == 0,
               saved.original.maximum == volumeAfter.maximum {
                let fresh = try device.readVolume()
                guard valid() else { throw DDCOperationError.cancelled }
                if fresh.current == 0, fresh.maximum == saved.original.maximum {
                    volumeAfter = try volume(device: device, target: saved.original.current,
                        expectedMaximum: saved.original.maximum, valid: valid, expectedCurrent: 0).volume
                } else { volumeAfter = fresh }
            }
            memory = nil
        }
        trace("result volume=\(volumeAfter.current)/\(volumeAfter.maximum) mute=\(after)")
        return AudioSnapshot(volume: volumeAfter, mute: after)
    }
}

// One timer and at most one in-flight operation; the pending slot contains only
// the latest intent. The same coordinator is exercised with fake devices in tests.
final class LatestVolumeWriter {
    struct Request {
        let revision: Int
        let operation: (_ isLatest: @escaping () -> Bool) throws -> AudioSnapshot
        let completion: (Int, Result<AudioSnapshot, Error>) -> Void
    }
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let interval: TimeInterval
    private struct IntentKey: Equatable { let target: Int }
    private var lastKey: IntentKey?
    private var revision = 0
    private var pending: Request?
    private var scheduled: DispatchWorkItem?
    private var running = false
    init(queue: DispatchQueue, interval: TimeInterval = 0.04) {
        self.queue = queue; self.interval = interval
    }
    @discardableResult func submit(target: Int, operation: @escaping (_ isLatest: @escaping () -> Bool) throws -> AudioSnapshot,
                                   completion: @escaping (Int, Result<AudioSnapshot, Error>) -> Void) -> Int {
        lock.lock()
        let key = IntentKey(target: target)
        // Repeated identical key/slider intents must not keep invalidating a
        // read already in progress and starve the eventual hardware write.
        if lastKey == key && (running || pending != nil || scheduled != nil) {
            let id = revision; lock.unlock(); return id
        }
        lastKey = key
        revision += 1
        let id = revision
        pending = Request(revision: id, operation: operation, completion: completion)
        scheduleLocked()
        lock.unlock()
        return id
    }
    func isLatest(_ id: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return revision == id
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        revision += 1; pending = nil; scheduled?.cancel(); scheduled = nil; lastKey = nil
    }
    private func scheduleLocked() {
        guard pending != nil, !running, scheduled == nil else { return }
        let job = DispatchWorkItem { [weak self] in self?.drain() }
        scheduled = job
        queue.asyncAfter(deadline: .now() + interval, execute: job)
    }
    private func drain() {
        lock.lock()
        scheduled = nil
        guard let request = pending else { lock.unlock(); return }
        pending = nil; running = true
        lock.unlock()
        let result: Result<AudioSnapshot, Error>
        do { result = .success(try request.operation { [weak self] in self?.isLatest(request.revision) == true }) }
        catch { result = .failure(error) }
        lock.lock()
        running = false
        if pending == nil { lastKey = nil }
        scheduleLocked()
        lock.unlock()
        request.completion(request.revision, result)
    }
}

struct MediaKeyPolicy {
    static func canListen(trusted: Bool, sleeping: Bool, measurementOnly: Bool) -> Bool {
        trusted && !sleeping && !measurementOnly
    }
    static func canAdjust(ready: Bool, refreshing: Bool, failed: Bool, controllable: Bool) -> Bool {
        ready && !refreshing && !failed && controllable
    }
}

// A bounded stream: retain one newest intent and adopt it AFTER the fresh read,
// immediately before writing. New input cannot starve the read by cancelling it.
// A route/mute/sleep cancellation invalidates the entire stream epoch.
final class StreamingVolumeWriter {
    typealias Operation = (_ resolveTarget: @escaping () -> Int?) throws -> AudioSnapshot
    private struct Request {
        let revision: Int
        let target: Int
        let operation: Operation
        let completion: (Int, Result<AudioSnapshot, Error>) -> Void
    }
    private let lock = NSLock()
    private let queue: DispatchQueue
    private var epoch = 0, revision = 0
    private var pending: Request?
    private var running = false
    private var scheduled: DispatchWorkItem?
    init(queue: DispatchQueue) { self.queue = queue }
    @discardableResult func submit(target: Int, operation: @escaping Operation,
        completion: @escaping (Int, Result<AudioSnapshot, Error>) -> Void) -> Int {
        lock.lock(); defer { lock.unlock() }
        revision += 1
        pending = Request(revision: revision, target: target, operation: operation, completion: completion)
        scheduleLocked(delay: 0.008)
        return revision
    }
    func isLatest(_ value: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }; return value == revision
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        epoch += 1; revision += 1; pending = nil; scheduled?.cancel(); scheduled = nil
    }
    private func scheduleLocked(delay: TimeInterval) {
        guard pending != nil, !running, scheduled == nil else { return }
        let token = epoch
        let job = DispatchWorkItem { [weak self] in self?.drain(token) }
        scheduled = job
        queue.asyncAfter(deadline: .now() + delay, execute: job)
    }
    private func drain(_ token: Int) {
        lock.lock()
        guard token == epoch else { lock.unlock(); return }
        scheduled = nil
        guard let first = pending else { lock.unlock(); return }
        running = true
        lock.unlock()
        var committed = first
        let result = Result { try first.operation {
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.epoch == token, let newest = self.pending else { return nil }
            committed = newest
            self.pending = nil
            return newest.target
        } }
        lock.lock()
        let currentEpoch = epoch == token
        running = false
        // A pre-read failure may occur before an intent was claimed.
        if pending?.revision == first.revision { pending = nil }
        scheduleLocked(delay: 0)
        lock.unlock()
        if currentEpoch { committed.completion(committed.revision, result) }
    }
}
