import Foundation

var checks = 0
func check(_ value: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(value(), "Check failed", file: file, line: line); checks += 1
}

// Screen sleep and whole-system sleep can arrive in either order. Screen wake
// cannot end system sleep; a real system wake also ends the old screen epoch.
for systemFirst in [false, true] {
    var state = DisplaySleepState()
    check(!state.sleeping)
    state.sleep(system: systemFirst); state.sleep(system: systemFirst)
    state.wake(system: !systemFirst); check(state.sleeping)
    state.sleep(system: !systemFirst)
    state.wake(system: systemFirst); state.wake(system: systemFirst)
    check(state.sleeping == !systemFirst)
    state.wake(system: !systemFirst); check(!state.sleeping)
}

// Overnight: native audio may continue after screen sleep, then the system
// sleeps. didWake alone must resume the app without a paired screensDidWake.
var overnight = DisplaySleepState()
overnight.sleep(system: false); check(overnight.sleeping)
overnight.sleep(system: true); check(overnight.sleeping)
overnight.wake(system: true); check(!overnight.sleeping)
overnight.wake(system: true); check(!overnight.sleeping)

// A new screen sleep after a completed system wake belongs to the new epoch.
// Duplicate didWake events from the preceding epoch must leave it in place.
overnight.sleep(system: false); check(overnight.sleeping)
overnight.wake(system: true); check(overnight.sleeping)
overnight.wake(system: true); check(overnight.sleeping)
overnight.wake(system: false); check(!overnight.sleeping)

// A whole-system cycle also works without either screen notification.
var systemOnly = DisplaySleepState()
systemOnly.sleep(system: true); check(systemOnly.sleeping)
systemOnly.wake(system: true); check(!systemOnly.sleeping)
systemOnly.sleep(system: false)
systemOnly.wake(system: true); check(systemOnly.sleeping)
systemOnly.wake(system: false); check(!systemOnly.sleeping)

// Reverse ordering and repeated screen wake cannot bypass outstanding system
// sleep. A later actual system wake clears both flags, even after screen sleep
// arrives again before it.
var reverse = DisplaySleepState()
reverse.sleep(system: true); reverse.sleep(system: false)
reverse.wake(system: false); check(reverse.sleeping)
reverse.wake(system: false); check(reverse.sleeping)
reverse.sleep(system: false); check(reverse.sleeping)
reverse.wake(system: true); check(!reverse.sleeping)
reverse.wake(system: false); check(!reverse.sleeping)
reverse.sleep(system: false); check(reverse.sleeping)
reverse.wake(system: true); check(reverse.sleeping)
reverse.sleep(system: true); reverse.wake(system: true)
check(!reverse.sleeping)

var recovery = DisplayAudioRecovery()
check(!recovery.pending && !recovery.permitsStart && recovery.attempts == 0)
check(!recovery.takeAttempt(now: 0, outputUID: "A", available: true, busy: false))
check(recovery.request(now: 0))
check(!recovery.request(now: 0.3))
check(!recovery.takeAttempt(now: 0, outputUID: "A", available: true, busy: false))
check(!recovery.takeAttempt(now: 0.499, outputUID: "A", available: true, busy: false))
check(recovery.takeAttempt(now: 0.5, outputUID: "A", available: true, busy: false))
check(recovery.permitsStart && recovery.attempts == 1)
check(!recovery.takeAttempt(now: 1, outputUID: "A", available: true, busy: false))
check(!recovery.request(now: 1) && recovery.attempts == 1)
recovery.cancel()
check(!recovery.pending && !recovery.permitsStart)

// A missing/unavailable output resets stability without consuming an attempt.
var unavailable = DisplayAudioRecovery()
unavailable.request(now: 0)
check(!unavailable.takeAttempt(now: 1, outputUID: nil, available: true, busy: false))
check(!unavailable.takeAttempt(now: 2, outputUID: "", available: true, busy: false))
check(!unavailable.takeAttempt(now: 3, outputUID: "A", available: true, busy: false))
check(!unavailable.takeAttempt(now: 3.5, outputUID: "A", available: false, busy: false))
check(!unavailable.takeAttempt(now: 4, outputUID: "A", available: true, busy: false))
check(!unavailable.takeAttempt(now: 4.4, outputUID: "A", available: true, busy: false))
check(unavailable.attempts == 0)
check(unavailable.takeAttempt(now: 4.5, outputUID: "A", available: true, busy: false))

// Route changes restart stability; an old screen cannot borrow another
// output's half-second observation window.
var changed = DisplayAudioRecovery()
changed.request(now: 0)
check(!changed.takeAttempt(now: 0, outputUID: "A", available: true, busy: false))
check(!changed.takeAttempt(now: 0.5, outputUID: "B", available: true, busy: false))
check(!changed.takeAttempt(now: 0.75, outputUID: "A", available: true, busy: false))
check(!changed.takeAttempt(now: 1.24, outputUID: "A", available: true, busy: false))
check(changed.takeAttempt(now: 1.25, outputUID: "A", available: true, busy: false))

// Cleanup/menu/output selection may be busy for a while. The recovery budget
// belongs to actual creation attempts, not timer ticks while work drains.
var busy = DisplayAudioRecovery()
busy.request(now: 0)
check(!busy.takeAttempt(now: 0, outputUID: "A", available: true, busy: true))
for now in [0.5, 1.0, 2.0, 10.0] {
    check(!busy.takeAttempt(now: now, outputUID: "A", available: true, busy: true))
    check(busy.pending && busy.attempts == 0)
}
check(busy.takeAttempt(now: 10.1, outputUID: "A", available: true, busy: false))

// Retryable initialization failure has bounded backoff and a three-attempt
// ceiling even when repeated display notifications arrive during recovery.
var retries = DisplayAudioRecovery()
retries.request(now: 0)
check(!retries.takeAttempt(now: 0, outputUID: "A", available: true, busy: false))
check(retries.takeAttempt(now: 0.5, outputUID: "A", available: true, busy: false))
retries.failed(retryable: true, now: 1)
check(retries.pending && !retries.permitsStart && retries.attempts == 1)
check(!retries.request(now: 2))
check(!retries.takeAttempt(now: 1.5, outputUID: "A", available: true, busy: false))
check(!retries.takeAttempt(now: 2.9, outputUID: "A", available: true, busy: false))
check(retries.takeAttempt(now: 3, outputUID: "A", available: true, busy: false))
retries.failed(retryable: true, now: 3.1)
check(!retries.takeAttempt(now: 4, outputUID: "B", available: true, busy: false))
check(!retries.takeAttempt(now: 7, outputUID: "B", available: true, busy: false))
check(retries.takeAttempt(now: 7.1, outputUID: "B", available: true, busy: false))
check(retries.attempts == 3)
retries.failed(retryable: true, now: 8)
check(!retries.pending && !retries.permitsStart)
check(!retries.takeAttempt(now: 30, outputUID: "B", available: true, busy: false))

// A late output may recover within the original minute, but duplicate wake
// notifications cannot silently extend that minute.
var late = DisplayAudioRecovery()
late.request(now: 0)
check(!late.takeAttempt(now: 58, outputUID: nil, available: false, busy: false))
check(!late.request(now: 59))
check(!late.takeAttempt(now: 59, outputUID: "A", available: true, busy: false))
check(late.takeAttempt(now: 59.5, outputUID: "A", available: true, busy: false))
late.failed(retryable: true, now: 60)
check(!late.pending && !late.permitsStart)
var expired = DisplayAudioRecovery()
expired.request(now: 10)
check(!expired.takeAttempt(now: 69.75, outputUID: "A", available: true, busy: false))
check(!expired.request(now: 70))
check(!expired.takeAttempt(now: 70.01, outputUID: "A", available: true, busy: false))
check(!expired.pending && expired.attempts == 0)

var refused = DisplayAudioRecovery()
refused.request(now: 0)
check(!refused.takeAttempt(now: 0, outputUID: "A", available: true, busy: false))
check(refused.takeAttempt(now: 0.5, outputUID: "A", available: true, busy: false))
refused.failed(retryable: false, now: 1)
check(!refused.pending && !refused.permitsStart)
check(!refused.takeAttempt(now: 10, outputUID: "A", available: true, busy: false))
check(refused.request(now: 20) && refused.attempts == 0)
refused.cancel(); refused.failed(retryable: true, now: 21)
check(!refused.pending && !refused.permitsStart)

// A successful restart may be short-lived. Cancelling each completed window
// must retain the rolling budget across repeated active -> fault transitions.
var runtime = DisplayAudioRecovery()
for now: TimeInterval in [0, 30, 60] {
    check(runtime.requestRuntime(now: now))
    check(!runtime.takeAttempt(now: now, outputUID: "A", available: true, busy: false))
    check(runtime.takeAttempt(now: now + 0.5, outputUID: "A", available: true, busy: false))
    runtime.cancel() // The caller observed active again.
    check(!runtime.pending && !runtime.permitsStart)
}
for now: TimeInterval in [61, 90, 200, 299.5] {
    check(!runtime.requestRuntime(now: now))
    check(!runtime.pending && !runtime.permitsStart)
}
// Expiration is rolling, not a fixed five-minute bucket or an all-at-once reset.
check(runtime.requestRuntime(now: 300))
runtime.cancel()
check(!runtime.requestRuntime(now: 329))
check(runtime.requestRuntime(now: 330))
runtime.cancel()
check(!runtime.requestRuntime(now: 359))
check(runtime.requestRuntime(now: 360))
runtime.cancel()
check(!runtime.requestRuntime(now: 361))

// Duplicate fault reports while a window is pending neither reset its attempts
// nor consume another window. Three retries within it still count as one.
var runtimeRetries = DisplayAudioRecovery()
check(runtimeRetries.requestRuntime(now: 0))
check(!runtimeRetries.requestRuntime(now: 0.25))
check(!runtimeRetries.takeAttempt(now: 0, outputUID: "A", available: true, busy: false))
check(runtimeRetries.takeAttempt(now: 0.5, outputUID: "A", available: true, busy: false))
runtimeRetries.failed(retryable: true, now: 1)
check(!runtimeRetries.requestRuntime(now: 2) && runtimeRetries.attempts == 1)
check(!runtimeRetries.takeAttempt(now: 2, outputUID: "A", available: true, busy: false))
check(runtimeRetries.takeAttempt(now: 3, outputUID: "A", available: true, busy: false))
runtimeRetries.failed(retryable: true, now: 3)
check(!runtimeRetries.takeAttempt(now: 4, outputUID: "A", available: true, busy: false))
check(!runtimeRetries.takeAttempt(now: 6.5, outputUID: "A", available: true, busy: false))
check(runtimeRetries.takeAttempt(now: 7, outputUID: "A", available: true, busy: false))
runtimeRetries.failed(retryable: true, now: 7)
check(!runtimeRetries.pending && runtimeRetries.attempts == 3)
check(runtimeRetries.requestRuntime(now: 8))
runtimeRetries.cancel()
check(runtimeRetries.requestRuntime(now: 9))
runtimeRetries.cancel()
check(!runtimeRetries.requestRuntime(now: 10))

// New external conditions may recover even after runtime exhaustion. Their
// windows do not consume or erase the runtime budget, including cancellation.
check(runtimeRetries.request(now: 11))
check(!runtimeRetries.requestRuntime(now: 12))
runtimeRetries.cancel()
check(!runtimeRetries.requestRuntime(now: 13))
var external = DisplayAudioRecovery()
for now: TimeInterval in [0, 10, 20, 30] {
    check(external.request(now: now))
    check(!external.requestRuntime(now: now + 1))
    external.cancel()
}
for now: TimeInterval in [40, 50, 60] {
    check(external.requestRuntime(now: now))
    external.failed(retryable: false, now: now + 1)
    check(!external.pending && !external.permitsStart)
}
check(!external.requestRuntime(now: 70))
check(external.request(now: 80))
check(!external.requestRuntime(now: 1000) && external.pending)
check(!external.takeAttempt(now: 1000, outputUID: "A", available: true, busy: false))
check(!external.pending)
check(external.requestRuntime(now: 1001))

print("PASS \(checks) display/audio recovery assertions; fake clock and output metadata only")
