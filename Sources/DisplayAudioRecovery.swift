import Foundation

struct DisplaySleepState {
    private var system = false, screens = false
    var sleeping: Bool { system || screens }
    var diagnostics: String { "system=\(system) screens=\(screens)" }
    mutating func sleep(system isSystem: Bool) {
        if isSystem { system = true } else { screens = true }
    }
    mutating func wake(system isSystem: Bool) {
        if isSystem {
            // A real system wake starts a new epoch; its preceding screen sleep
            // need not have a matching screen-wake notification. A duplicate
            // system wake must not erase a later, independent screen sleep.
            guard system else { return }
            system = false; screens = false
        } else { screens = false }
    }
}

// Display/wake and real availability edges can arm a fresh recovery window.
// Runtime faults use a separate rolling budget so briefly reaching active
// between faults cannot become an endless automatic restart loop.
struct DisplayAudioRecovery {
    private(set) var pending = false
    private(set) var permitsStart = false
    private(set) var attempts = 0
    private var deadline: TimeInterval = 0, nextAttempt: TimeInterval = 0
    private var candidate: String?, stableSince: TimeInterval = 0
    private var runtimeRequests: [TimeInterval] = []
    @discardableResult mutating func request(now: TimeInterval) -> Bool {
        guard !pending else { return false }
        pending = true; permitsStart = false; attempts = 0
        deadline = now + 60; nextAttempt = now + 0.5; candidate = nil
        return true
    }
    @discardableResult mutating func requestRuntime(now: TimeInterval) -> Bool {
        guard !pending else { return false }
        runtimeRequests.removeAll { now - $0 >= 300 }
        guard runtimeRequests.count < 3 else { return false }
        guard request(now: now) else { return false }
        runtimeRequests.append(now)
        return true
    }
    mutating func takeAttempt(now: TimeInterval, outputUID: String?, available: Bool, busy: Bool) -> Bool {
        guard pending, !permitsStart else { return false }
        guard now <= deadline, attempts < 3 else { cancel(); return false }
        guard available, let outputUID, !outputUID.isEmpty else { candidate = nil; return false }
        if candidate != outputUID { candidate = outputUID; stableSince = now; return false }
        guard !busy, now >= nextAttempt, now - stableSince >= 0.5 else { return false }
        attempts += 1; permitsStart = true
        return true
    }
    mutating func failed(retryable: Bool, now: TimeInterval) {
        guard pending else { return }
        permitsStart = false
        guard retryable, attempts < 3, now < deadline else { cancel(); return }
        nextAttempt = now + pow(2, Double(attempts))
        candidate = nil
    }
    // Finishing or cancelling one window does not forgive recent runtime faults.
    mutating func cancel() { pending = false; permitsStart = false; candidate = nil }
}
