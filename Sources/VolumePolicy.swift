import Foundation

struct VolumePolicy {
    static func raw(percent: Double, maximum: Int) -> Int {
        guard maximum > 0, percent.isFinite else { return 0 }
        return Int((min(100, max(0, percent)) * Double(maximum) / 100).rounded())
    }
    static func percent(raw: Int, maximum: Int) -> Double {
        maximum > 0 ? Double(raw) * 100 / Double(maximum) : 0
    }
    static func step(current: Int, maximum: Int, direction: Int, percent: Int = 2) -> Int {
        guard maximum > 0 else { return 0 }
        return min(maximum, max(0, current + direction * max(1, Int((Double(maximum) * Double(min(4, max(1, percent))) / 100).rounded()))))
    }
}

// This fence cancels queued operations on target changes, sleep and failures.
// A hardware transaction already in progress may finish on its original display.
final class GenerationFence {
    private let lock = NSLock()
    private var value = 0
    @discardableResult func advance() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1; return value
    }
    func matches(_ generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == value
    }
}

struct MediaKey {
    let code: Int
    let down: Bool
    let repeated: Bool
    static func decode(data1: Int, subtype: Int) -> MediaKey? {
        guard subtype == 8 else { return nil }
        let code = (data1 >> 16) & 0xffff
        guard [0, 1, 7].contains(code) else { return nil }
        let flags = data1 & 0xffff
        let state = (flags >> 8) & 0xff
        guard state == 0xa || state == 0xb else { return nil }
        return MediaKey(code: code, down: state == 0xa, repeated: flags & 1 != 0)
    }
}

struct VolumeEventDeduplicator {
    private struct Event: Hashable { let timestamp: UInt64; let source: Int64; let data1: Int }
    private var events: Set<Event> = []
    private var order: [Event] = []
    func wasHandled(timestamp: UInt64, source: Int64, data1: Int) -> Bool {
        timestamp != 0 && events.contains(Event(timestamp: timestamp, source: source, data1: data1))
    }
    mutating func markHandled(timestamp: UInt64, source: Int64, data1: Int) {
        guard timestamp != 0 else { return }
        let event = Event(timestamp: timestamp, source: source, data1: data1)
        guard events.insert(event).inserted else { return }
        order.append(event)
        if order.count > 64 { events.remove(order.removeFirst()) }
    }
}

// System volume commands don't identify a physical wheel. Apply bounded
// cadence acceleration to discrete same-direction commands, independent of brand.
struct VolumeCadence {
    private var previousTime: TimeInterval?
    private var previousDirection = 0
    private var streak = 0
    mutating func reset() { previousTime = nil; previousDirection = 0; streak = 0 }
    mutating func step(direction: Int, repeated: Bool, time: TimeInterval) -> Int {
        defer { previousTime = time; previousDirection = direction }
        guard time.isFinite else { reset(); return 1 }
        if repeated { streak = 0; return 2 }
        guard let last = previousTime, direction == previousDirection,
              time > last, time - last < 0.30 else { streak = 0; return 1 }
        streak = min(3, streak + 1)
        let interval = time - last
        let speed = interval < 0.055 ? 4 : interval < 0.11 ? 3 : interval < 0.20 ? 2 : 1
        return min(speed, 1 + streak)
    }
}
