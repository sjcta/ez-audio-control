import Foundation
var count = 0
func check(_ value: @autoclosure () throws -> Bool, file: StaticString = #file, line: UInt = #line) rethrows {
    let result = try value(); precondition(result, "Check failed", file: file, line: line); count += 1
}
func fails(_ body: () throws -> Void) { do { try body(); fatalError("Expected rejection") } catch { count += 1 } }
final class FakeTapDriver: ProcessTapDriver {
    var available = true, ready = false, healthy = true, destroyResult = true
    var gain: Float = 0, muted: UInt32 = 1
    var creates = 0, destroys = 0, updates = 0, creationFailure: Error?
    var failureStatus: Int32 = 0, failUpdate = false
    var allowedOutputs: Set<UInt32> = [10]
    var createdOutputs: [UInt32] = []
    var duringCreate: (() -> Void)?, duringDestroy: (() -> Void)?
    func create(output: UInt32, confirmed: Bool, initial: ProcessTapSnapshot) throws -> UnsafeMutableRawPointer {
        guard confirmed, allowedOutputs.contains(output) else { throw ProcessTapError.unavailable }
        creates += 1; createdOutputs.append(output); gain = initial.gain; muted = initial.muted
        duringCreate?()
        if let creationFailure { throw creationFailure }
        return UnsafeMutableRawPointer(bitPattern: 0x10000 + creates)!
    }
    func snapshot(_ handle: UnsafeMutableRawPointer) throws -> ProcessTapSnapshot {
        guard healthy else { throw ProcessTapError.interrupted }; return .init(gain: gain, muted: muted)
    }
    func progress(_ handle: UnsafeMutableRawPointer) throws -> ProcessTapStatus {
        .init(callbacks: ready ? 2 : 0, validFrames: ready ? 512 : 0, ready: ready, stage: healthy ? 0 : Int32(EZTapTimeout.rawValue), status: healthy ? 0 : failureStatus)
    }
    func update(_ handle: UnsafeMutableRawPointer, gain: Float, muted: UInt32) -> Bool {
        updates += 1
        if failUpdate { healthy = false; return false }
        self.gain = gain; self.muted = muted; return healthy
    }
    func heartbeat(_ handle: UnsafeMutableRawPointer) -> Bool { healthy }
    func pause(_ handle: UnsafeMutableRawPointer) { healthy = false }
    func destroy(_ handle: UnsafeMutableRawPointer) -> Bool { destroys += 1; duringDestroy?(); return destroyResult }
}
func activate(_ controller: ProcessTapController, driver: FakeTapDriver, output: UInt32) throws -> (request: UInt64, token: UInt64, device: ProcessTapVolumeDevice) {
    driver.healthy = true
    let consent = ProcessTapConsent.confirmed(output: output)
    let request = try controller.beginPreparation(output: output, consent: consent)
    let token = try controller.establish(output: output, consent: consent)
    try controller.didEstablish(output: output, token: token, request: request)
    driver.ready = true
    try controller.tick()
    guard let device = controller.device else { throw ProcessTapError.interrupted }
    return (request, token, device)
}
// Real driver entry with absent consent must remain inert even though tap code is linked.
let inert = ProcessTapSession()
fails { _ = try inert.start(output: 10, consent: nil) }
let fake = FakeTapDriver()
let activeSession = ProcessTapSession(driver: fake)
let controller = ProcessTapController(session: activeSession)
check(controller.available && controller.state == .off && !controller.blocksPhysicalFallback)
fails { try controller.beginPreparation(output: 10, consent: nil) }
check(fake.creates == 0 && controller.state == .off)
let consent = ProcessTapConsent.confirmed(output: 10)
let request = try controller.beginPreparation(output: 10, consent: consent)
check(controller.state == .preparing && controller.blocksPhysicalFallback && controller.device == nil)
let token = try controller.establish(output: 10, consent: consent)
try controller.didEstablish(output: 10, token: token, request: request)
try controller.tick(); check(controller.state == .preparing && controller.device == nil)
fake.ready = true; try controller.tick()
check(controller.state == .active && controller.device != nil)
let device = controller.device!
try check(device.readVolume().current == 0); try check(device.readMute() == 1)
try device.writeVolume(2500); try device.writeMute(2)
try check(device.readVolume().current == 2500 && device.readMute() == 2)
for raw in [-1,10001,Int.min,Int.max] { fails { try device.writeVolume(raw) } }
fails { try device.writeMute(0) }; fails { try activeSession.update(generation: token, gain: .nan) }
fails { try activeSession.update(generation: token, gain: .infinity) }
check(fake.updates == 2)
controller.pause(); check(controller.state == .paused && controller.blocksPhysicalFallback && controller.device == nil)
fails { try device.writeVolume(10000) }; check(fake.updates == 2)
try controller.shutdown(); check(controller.state == .off && fake.destroys == 1)
// Recovery starts at zero and needs new consent; old device token cannot write.
fake.healthy = true; fake.gain = 0; fake.muted = 1
let secondRequest = try controller.beginPreparation(output: 10, consent: .confirmed(output: 10))
let second = try controller.establish(output: 10, consent: .confirmed(output: 10))
fails { try controller.didEstablish(output: 10, token: token, request: request) }
check(!controller.preparationFailed(request) && controller.isPreparing(secondRequest))
try controller.didEstablish(output: 10, token: second, request: secondRequest); try controller.tick()
check(second != token); fails { try device.writeMute(2) }
fake.healthy = false; fails { try controller.tick() }
check(controller.state == .paused && controller.device == nil)
try controller.shutdown()
var clock: TimeInterval = 100
let expiredDriver = FakeTapDriver()
let timed = ProcessTapSession(driver: expiredDriver, now: { clock })
fails { _ = try timed.start(output: 10, consent: .confirmed(output: 11, now: 100)) }
clock = 160; fails { _ = try timed.start(output: 10, consent: .confirmed(output: 10, now: 100)) }
clock = 99; fails { _ = try timed.start(output: 10, consent: .confirmed(output: 10, now: 100)) }
check(expiredDriver.creates == 0)
// Pause while CoreAudio waits for user permission does not block the UI lock.
let pendingDriver = FakeTapDriver()
let cancellable = ProcessTapSession(driver: pendingDriver)
pendingDriver.duringCreate = { cancellable.pause() }
fails { _ = try cancellable.start(output: 10, consent: .confirmed(output: 10)) }
check(pendingDriver.destroys == 1 && cancellable.shutdown())
// Cancelling creation must reserve the session until the old handle is gone.
let cleaningDriver = FakeTapDriver()
let cleaning = ProcessTapSession(driver: cleaningDriver)
cleaningDriver.duringCreate = { cleaning.pause() }
cleaningDriver.duringDestroy = {
    check(!cleaning.shutdown())
    fails { _ = try cleaning.start(output: 10, consent: .confirmed(output: 10)) }
}
fails { _ = try cleaning.start(output: 10, consent: .confirmed(output: 10)) }
check(cleaningDriver.creates == 1 && cleaningDriver.destroys == 1)
cleaningDriver.duringDestroy = nil
check(cleaning.shutdown())
let brokenDriver = FakeTapDriver()
let quarantine = ProcessTapSession(driver: brokenDriver)
_ = try quarantine.start(output: 10, consent: .confirmed(output: 10)); brokenDriver.destroyResult = false
check(!quarantine.shutdown()); check(!quarantine.shutdown()); check(brokenDriver.destroys == 1)
fails { _ = try quarantine.start(output: 10, consent: .confirmed(output: 10)) }
let failedDriver = FakeTapDriver(); failedDriver.creationFailure = ProcessTapError.backend(stage: Int32(EZTapCleanup.rawValue), status: -1)
let failed = ProcessTapSession(driver: failedDriver)
fails { _ = try failed.start(output: 10, consent: .confirmed(output: 10)) }; check(!failed.shutdown())
// Route disappearance while preparing cancels creation before it can be adopted.
let routeDriver = FakeTapDriver()
let routeSession = ProcessTapSession(driver: routeDriver)
let route = ProcessTapController(session: routeSession)
let routeRequest = try route.beginPreparation(output: 10, consent: .confirmed(output: 10))
var routeRelease: UInt64?
routeDriver.duringCreate = { routeRelease = route.outputChanged(to: nil) }
fails { _ = try route.establish(output: 10, consent: .confirmed(output: 10)) }
check(route.state == .stopping && routeRelease != nil && routeDriver.destroys == 1 && !route.isPreparing(routeRequest))
let routeCleanup = routeRelease!
check(route.releaseForOutputChange())
try check(route.completeOutputChange(routeCleanup, released: true))
check(route.state == .off && routeDriver.destroys == 1)
// Delayed success and failure from an old preparation cannot disturb a new one.
let lateDriver = FakeTapDriver(), lateSession: ProcessTapSession
lateSession = ProcessTapSession(driver: lateDriver)
let late = ProcessTapController(session: lateSession)
let oldRequest = try late.beginPreparation(output: 10, consent: .confirmed(output: 10))
let oldToken = try late.establish(output: 10, consent: .confirmed(output: 10))
try late.shutdown()
let newRequest = try late.beginPreparation(output: 10, consent: .confirmed(output: 10))
let newToken = try late.establish(output: 10, consent: .confirmed(output: 10))
fails { try late.didEstablish(output: 10, token: oldToken, request: oldRequest) }
check(!late.preparationFailed(oldRequest) && late.isPreparing(newRequest))
try late.didEstablish(output: 10, token: newToken, request: newRequest)
lateDriver.ready = true; try late.tick()
check(late.state == .active && lateDriver.healthy); try late.shutdown()
// Refusal can be explicitly retried after a clean shutdown; no sticky fake handle.
let denyDriver = FakeTapDriver(), denySession: ProcessTapSession
denySession = ProcessTapSession(driver: denyDriver)
denyDriver.creationFailure = ProcessTapError.backend(stage: Int32(EZTapCreate.rawValue), status: -555)
fails { _ = try denySession.start(output: 10, consent: .confirmed(output: 10)) }
check(denySession.shutdown() && denyDriver.destroys == 0)
denyDriver.creationFailure = nil
_ = try denySession.start(output: 10, consent: .confirmed(output: 10)); check(denySession.shutdown())
// Creating our own aggregate must not invalidate the UI generation mid-start.
let listDriver = FakeTapDriver()
let listController = ProcessTapController(session: ProcessTapSession(driver: listDriver))
check(listController.shouldInvalidateForOutputNotification(deviceListOnly: true, currentOutput: 10))
let listRequest = try listController.beginPreparation(output: 10, consent: .confirmed(output: 10))
listDriver.duringCreate = {
    check(!listController.shouldInvalidateForOutputNotification(deviceListOnly: true, currentOutput: 10))
    check(listController.shouldInvalidateForOutputNotification(deviceListOnly: false, currentOutput: 10))
    check(listController.shouldInvalidateForOutputNotification(deviceListOnly: true, currentOutput: 11))
    check(listController.shouldInvalidateForOutputNotification(deviceListOnly: true, currentOutput: nil))
}
let listToken = try listController.establish(output: 10, consent: .confirmed(output: 10))
try listController.didEstablish(output: 10, token: listToken, request: listRequest)
listDriver.ready = true; try listController.tick()
check(listController.device != nil && !listController.shouldInvalidateForOutputNotification(deviceListOnly: true, currentOutput: 10))
try listController.shutdown()

// A software -> native -> software route change must release the old tap once,
// leave the native middle route alone, and reject the old device token after
// the software session is recreated for the original output.
let transitionDriver = FakeTapDriver()
transitionDriver.allowedOutputs = [10, 11]
let transitionController = ProcessTapController(session: ProcessTapSession(driver: transitionDriver))
let firstTransition = try activate(transitionController, driver: transitionDriver, output: 10)
let transitionRelease = transitionController.outputChanged(to: 11)
check(transitionRelease != nil && transitionController.state == .stopping && transitionController.device == nil)
fails { try firstTransition.device.writeVolume(4000) }
check(transitionController.outputChanged(to: 10) == nil)
let transitionRequest = transitionRelease!
check(transitionController.releaseForOutputChange())
check(transitionDriver.destroys == 1 && transitionDriver.createdOutputs == [10])
try check(transitionController.completeOutputChange(transitionRequest, released: true))
check(transitionController.state == .off && !transitionController.blocksPhysicalFallback)
let secondTransition = try activate(transitionController, driver: transitionDriver, output: 10)
fails { try firstTransition.device.writeVolume(4900) }
check(secondTransition.token != firstTransition.token && transitionDriver.createdOutputs == [10, 10])
try transitionController.shutdown()
print("PASS dynamic output transition: A software -> B native -> A software; old token rejected")

// A fast A -> B -> A route can deliver its final notification after the
// current output ID has already returned to A.  A plain duplicate ID is
// ignored, while an explicit route notification still forces cleanup/rebuild.
let routeNotificationDriver = FakeTapDriver()
routeNotificationDriver.allowedOutputs = [10, 11]
let routeNotificationController = ProcessTapController(session: ProcessTapSession(driver: routeNotificationDriver))
_ = try activate(routeNotificationController, driver: routeNotificationDriver, output: 10)
let toBRelease = routeNotificationController.outputChanged(to: 11)!
check(routeNotificationController.releaseForOutputChange())
try check(routeNotificationController.completeOutputChange(toBRelease, released: true))
_ = try activate(routeNotificationController, driver: routeNotificationDriver, output: 10)
check(routeNotificationController.outputChanged(to: 10) == nil && routeNotificationDriver.destroys == 1)
let sameIDRelease = routeNotificationController.outputChanged(to: 10, routeNotification: true)
check(sameIDRelease != nil && routeNotificationController.state == .stopping)
check(routeNotificationController.releaseForOutputChange() && routeNotificationDriver.destroys == 2)
try check(routeNotificationController.completeOutputChange(sameIDRelease!, released: true))
_ = try activate(routeNotificationController, driver: routeNotificationDriver, output: 10)
check(routeNotificationDriver.createdOutputs == [10, 10, 10])
try routeNotificationController.shutdown()
print("PASS route notification: duplicate ID ignored; same-ID route event rebuilds")

// Losing the output while preparation is still pending still produces a
// release request.  The serial work queue drains establish first, then the
// controller releases and completes the route change.
let preparingDriver = FakeTapDriver()
let preparingController = ProcessTapController(session: ProcessTapSession(driver: preparingDriver))
let preparingRequest = try preparingController.beginPreparation(output: 10, consent: .confirmed(output: 10))
let preparingRelease = preparingController.outputChanged(to: 11)
check(preparingRelease != nil && preparingController.state == .stopping && !preparingController.isPreparing(preparingRequest))
_ = try preparingController.establish(output: 10, consent: .confirmed(output: 10))
check(preparingDriver.creates == 1)
check(preparingController.releaseForOutputChange() && preparingDriver.destroys == 1)
try check(preparingController.completeOutputChange(preparingRelease!, released: true))
check(preparingController.state == .off)
print("PASS preparation route change: queued establish drains before release")

// A route change during destroy is still a single cleanup.  The callback
// deliberately sends B -> A; shutdown is rejected while stopping, so no
// second synchronous cleanup can overlap the in-flight destroy.
let routeCleaningDriver = FakeTapDriver()
let routeCleaningController = ProcessTapController(session: ProcessTapSession(driver: routeCleaningDriver))
_ = try activate(routeCleaningController, driver: routeCleaningDriver, output: 10)
let routeCleaningRelease = routeCleaningController.outputChanged(to: 11)!
var routeCleaningCallbacks = 0
routeCleaningDriver.duringDestroy = {
    routeCleaningCallbacks += 1
    check(routeCleaningController.outputChanged(to: 10) == nil)
    fails { try routeCleaningController.shutdown() }
}
check(routeCleaningController.releaseForOutputChange())
check(routeCleaningCallbacks == 1 && routeCleaningDriver.destroys == 1)
try check(routeCleaningController.completeOutputChange(routeCleaningRelease, released: true))
check(routeCleaningController.state == .off)
print("PASS cleanup race: B -> A during stopping releases exactly once")

// An old establish completion and an old cleanup completion must not touch a
// newer software session after the route has returned to the same output.
let routeLateDriver = FakeTapDriver()
routeLateDriver.allowedOutputs = [10, 11]
let routeLateController = ProcessTapController(session: ProcessTapSession(driver: routeLateDriver))
let routeLateOld = try activate(routeLateController, driver: routeLateDriver, output: 10)
let routeLateCleanup = routeLateController.outputChanged(to: 11)!
check(routeLateController.releaseForOutputChange())
try check(routeLateController.completeOutputChange(routeLateCleanup, released: true))
let routeLateNew = try activate(routeLateController, driver: routeLateDriver, output: 10)
fails { try routeLateController.didEstablish(output: 10, token: routeLateOld.token, request: routeLateOld.request) }
try check(!(try routeLateController.completeOutputChange(routeLateCleanup, released: true)))
check(routeLateController.state == .active && routeLateNew.token != routeLateOld.token)
try routeLateController.shutdown()

// This covers an establish result that arrives after preparation was cancelled
// by a route change, then after a new session has already become active. The
// queued establish is drained before release, just like the production queue.
let staleEstablishDriver = FakeTapDriver()
let staleEstablishController = ProcessTapController(session: ProcessTapSession(driver: staleEstablishDriver))
let staleRequest = try staleEstablishController.beginPreparation(output: 10, consent: .confirmed(output: 10))
let staleToken = try staleEstablishController.establish(output: 10, consent: .confirmed(output: 10))
let staleRelease = staleEstablishController.outputChanged(to: 11)!
check(staleEstablishController.releaseForOutputChange())
try check(staleEstablishController.completeOutputChange(staleRelease, released: true))
let staleNew = try activate(staleEstablishController, driver: staleEstablishDriver, output: 10)
fails { try staleEstablishController.didEstablish(output: 10, token: staleToken, request: staleRequest) }
check(staleEstablishController.state == .active && staleNew.token != staleToken)
try staleEstablishController.shutdown()
print("PASS late completions: stale establish/cleanup cannot override a new session")

// A health failure may pause the session before the output notification lands.
// The later route notification must not ask for a second release.
let tickDriver = FakeTapDriver()
let tickController = ProcessTapController(session: ProcessTapSession(driver: tickDriver))
_ = try activate(tickController, driver: tickDriver, output: 10)
tickDriver.healthy = false
fails { try tickController.tick() }
check(tickController.state == .paused)
check(tickController.outputChanged(to: 10) == nil)
let tickRelease = tickController.outputChanged(to: 11)
check(tickRelease != nil && tickController.state == .stopping)
check(tickController.releaseForOutputChange() && tickDriver.destroys == 1)
try check(tickController.completeOutputChange(tickRelease!, released: true))
check(tickController.state == .off)
print("PASS tick/route race: pause first, later output change releases once")

// Cleanup failure quarantines the controller.  Repeated route notifications,
// release calls, and automatic starts must not form a retry loop.
let failedCleanupDriver = FakeTapDriver()
let failedCleanupController = ProcessTapController(session: ProcessTapSession(driver: failedCleanupDriver))
_ = try activate(failedCleanupController, driver: failedCleanupDriver, output: 10)
let failedCleanupRequest = failedCleanupController.outputChanged(to: 11)!
failedCleanupDriver.destroyResult = false
check(!failedCleanupController.releaseForOutputChange())
check(failedCleanupDriver.destroys == 1)
fails { try failedCleanupController.completeOutputChange(failedCleanupRequest, released: false) }
check(failedCleanupController.state == .paused)
check(failedCleanupController.outputChanged(to: 10) == nil)
check(!failedCleanupController.releaseForOutputChange())
try check(!(try failedCleanupController.completeOutputChange(failedCleanupRequest, released: false)))
fails { _ = try failedCleanupController.beginPreparation(output: 10, consent: .confirmed(output: 10)) }
check(failedCleanupDriver.creates == 1 && failedCleanupDriver.destroys == 1)
print("PASS cleanup failure quarantine: no repeated release or automatic create")

print("PASS \(count) Swift consent/readiness/gain/cancellation/recovery assertions; injected driver only")
var automatic = AutomaticSoftwareOffer()
check(!automatic.shouldOffer(output: 10, nativeWritable: true, available: true, idle: true))
check(automatic.shouldOffer(output: 10, nativeWritable: false, available: true, idle: true))
check(!automatic.shouldOffer(output: 10, nativeWritable: false, available: true, idle: true))
check(!automatic.shouldOffer(output: 11, nativeWritable: false, available: true, idle: false))
check(automatic.shouldOffer(output: 11, nativeWritable: false, available: true, idle: true))
check(!automatic.shouldOffer(output: nil, nativeWritable: false, available: true, idle: true))
check(!automatic.shouldOffer(output: 10, nativeWritable: false, available: false, idle: true))
check(automatic.shouldOffer(output: 10, nativeWritable: false, available: true, idle: true))
print("PASS automatic software selection: native control, unsupported output, coalescing, route changes and availability")

for (system, saved, expected) in [(Float(0.4), Float(0.7), Float(0.4)), (nil, Float(0.7), Float(0.7)), (nil, nil, Float(1)), (Float.nan, Float(0.2), Float(0.2)), (Float(0), Float(0.8), Float(0))] {
    let initial = ProcessTapSnapshot.initial(systemGain: system, systemMuted: false, savedGain: saved)
    check(initial.gain == expected && initial.muted == 0)
}
check(ProcessTapSnapshot.initial(systemGain: 0.4, systemMuted: true, savedGain: nil).muted == 1)
let referenceDriver = FakeTapDriver()
let referenceSession = ProcessTapSession(driver: referenceDriver)
let referenceToken = try referenceSession.start(output: 10, consent: .confirmed(output: 10), initial: .init(gain: 0.42, muted: 0))
try check(referenceSession.snapshot(generation: referenceToken).gain == 0.42)
check(referenceDriver.updates == 0)
check(referenceSession.shutdown())
fails { _ = try referenceSession.start(output: 10, consent: .confirmed(output: 10), initial: .init(gain: .nan, muted: 0)) }
print("PASS \(count) total Swift assertions including initial system/saved/default levels")

// A display can return with the same AudioDeviceID after the backend has
// already faulted. Recovery must retire the latched session once, then adopt
// a new token without changing its confirmed 0% or software-mute snapshot.
for initial in [ProcessTapSnapshot(gain: 0, muted: 0), ProcessTapSnapshot(gain: 0.42, muted: 1)] {
    let wakeDriver = FakeTapDriver()
    let wakeController = ProcessTapController(session: ProcessTapSession(driver: wakeDriver))
    let oldConsent = ProcessTapConsent.confirmed(output: 10)
    let oldRequest = try wakeController.beginPreparation(output: 10, consent: oldConsent)
    let oldToken = try wakeController.establish(output: 10, consent: oldConsent, initial: initial)
    try wakeController.didEstablish(output: 10, token: oldToken, request: oldRequest)
    wakeDriver.ready = true; try wakeController.tick()
    let oldDevice = wakeController.device!
    let confirmed = wakeController.latestStatus!
    check(confirmed.gain == initial.gain && confirmed.muted == initial.muted)
    wakeDriver.healthy = false
    fails { try wakeController.tick() }
    check(wakeController.state == .paused && wakeController.device == nil)
    check(wakeController.outputChanged(to: 10) == nil)
    let wakeRelease = wakeController.outputChanged(to: 10, routeNotification: true)!
    check(wakeController.state == .stopping)
    check(wakeController.outputChanged(to: 10, routeNotification: true) == nil)
    fails { try oldDevice.writeVolume(10000) }
    check(wakeDriver.updates == 0)
    check(wakeController.releaseForOutputChange() && wakeDriver.destroys == 1)
    try check(wakeController.completeOutputChange(wakeRelease, released: true))
    check(wakeController.state == .off)
    wakeDriver.healthy = true; wakeDriver.ready = false
    let newConsent = ProcessTapConsent.confirmed(output: 10)
    let newRequest = try wakeController.beginPreparation(output: 10, consent: newConsent)
    let newToken = try wakeController.establish(output: 10, consent: newConsent, initial: confirmed)
    try wakeController.didEstablish(output: 10, token: newToken, request: newRequest)
    try wakeController.tick()
    check(wakeController.state == .preparing && wakeController.device == nil)
    wakeDriver.ready = true; try wakeController.tick()
    check(wakeController.state == .active && newToken != oldToken)
    try check(wakeController.device!.readVolume().current == Int((initial.gain * 10000).rounded()))
    try check(wakeController.device!.readMute() == (initial.muted == 1 ? 1 : 2))
    fails { try oldDevice.writeMute(2) }
    fails { try wakeController.didEstablish(output: 10, token: oldToken, request: oldRequest) }
    try check(!(try wakeController.completeOutputChange(wakeRelease, released: true)))
    check(wakeController.state == .active && wakeDriver.createdOutputs == [10, 10] && wakeDriver.updates == 0)
    try wakeController.shutdown()
    check(wakeDriver.destroys == 2)
}
print("PASS \(count) total Swift assertions including same-ID wake, zero/mute restoration and stale-token rejection")

// A runtime timeout retains its exact reason through Swift. Recovery remains
// limited to transient output/lease faults; permission, malformed PCM and
// uncertain cleanup must never trigger an automatic retry.
for stage in [EZTapInspectOutput, EZTapFormats, EZTapTopology] {
    check(ProcessTapError.backend(stage: Int32(stage.rawValue), status: 0).runtimeRecoverable)
}
for stage in [EZTapConsent, EZTapCreate, EZTapStartIO, EZTapCallbackFormat, EZTapCleanup] {
    check(!ProcessTapError.backend(stage: Int32(stage.rawValue), status: 0).runtimeRecoverable)
}
check(!ProcessTapError.interrupted.runtimeRecoverable && !ProcessTapError.invalidGain.runtimeRecoverable)
check(ProcessTapError.backend(stage: Int32(EZTapTimeout.rawValue), status: Int32(EZTapTimeoutOwnerLease.rawValue)).runtimeRecoverable)
check(!ProcessTapError.backend(stage: Int32(EZTapTimeout.rawValue), status: Int32(EZTapTimeoutFirstPCM.rawValue)).runtimeRecoverable)
check(!ProcessTapError.backend(stage: Int32(EZTapTimeout.rawValue), status: 0).runtimeRecoverable)
for reason in [EZTapTimeoutOwnerLease, EZTapTimeoutFirstPCM] {
    let timeoutDriver = FakeTapDriver()
    let timeoutController = ProcessTapController(session: ProcessTapSession(driver: timeoutDriver))
    _ = try activate(timeoutController, driver: timeoutDriver, output: 10)
    timeoutDriver.failureStatus = Int32(reason.rawValue); timeoutDriver.healthy = false
    do { try timeoutController.tick(); fatalError("Expected timeout") }
    catch ProcessTapError.backend(let stage, let status) {
        check(stage == Int32(EZTapTimeout.rawValue) && status == Int32(reason.rawValue))
    }
    check(timeoutController.state == .paused && timeoutController.device == nil)
    try timeoutController.shutdown()
    check(timeoutDriver.destroys == 1)
}
let writeFailureDriver = FakeTapDriver()
let writeFailureController = ProcessTapController(session: ProcessTapSession(driver: writeFailureDriver))
let writeFailureDevice = try activate(writeFailureController, driver: writeFailureDriver, output: 10).device
writeFailureDriver.failureStatus = Int32(EZTapTimeoutOwnerLease.rawValue)
writeFailureDriver.failUpdate = true
do { try writeFailureDevice.writeVolume(2300); fatalError("Expected failed write") }
catch ProcessTapError.backend(let stage, let status) {
    check(stage == Int32(EZTapTimeout.rawValue) && status == Int32(EZTapTimeoutOwnerLease.rawValue))
}
check(writeFailureDriver.gain == 0 && writeFailureDriver.muted == 1)
try writeFailureController.shutdown()
print("PASS \(count) total Swift assertions including timeout diagnostics and runtime recovery eligibility")

// A driver that does not implement explicit cleanup verification must never
// clear quarantine merely because the device later looks healthy again.
let defaultCleanupDriver = FakeTapDriver()
check(!defaultCleanupDriver.retryCleanup() && defaultCleanupDriver.cleanupDetail == nil)
let defaultCleanupController = ProcessTapController(session: ProcessTapSession(driver: defaultCleanupDriver))
_ = try activate(defaultCleanupController, driver: defaultCleanupDriver, output: 10)
defaultCleanupDriver.destroyResult = false
let defaultRelease = defaultCleanupController.outputChanged(to: 10, routeNotification: true)!
check(!defaultCleanupController.releaseForOutputChange())
fails { try defaultCleanupController.completeOutputChange(defaultRelease, released: false) }
check(defaultCleanupController.state == .paused && defaultCleanupController.recoveryQuarantined)
defaultCleanupDriver.healthy = true; defaultCleanupDriver.destroyResult = true
let defaultRetry = defaultCleanupController.beginCleanupRecovery()!
check(defaultCleanupController.state == .stopping && defaultCleanupController.recoveryQuarantined)
check(!defaultCleanupController.retryCleanup())
fails { try defaultCleanupController.completeOutputChange(defaultRetry, released: false) }
check(defaultCleanupController.state == .paused && defaultCleanupController.recoveryQuarantined)
fails { _ = try defaultCleanupController.beginPreparation(output: 10, consent: .confirmed(output: 10)) }
check(defaultCleanupDriver.creates == 1 && defaultCleanupDriver.destroys == 1)

// The cleanup witness is separate from the fake audio driver. Only its explicit
// success may reopen the controller; retrying does not itself create a session.
final class RetryCleanupDriver: ProcessTapDriver {
    let base = FakeTapDriver()
    var retryResult = false, retries = 0
    var available: Bool { base.available }
    var cleanupDetail: String? { "fake pending cleanup" }
    func create(output: UInt32, confirmed: Bool, initial: ProcessTapSnapshot) throws -> UnsafeMutableRawPointer {
        try base.create(output: output, confirmed: confirmed, initial: initial)
    }
    func snapshot(_ handle: UnsafeMutableRawPointer) throws -> ProcessTapSnapshot { try base.snapshot(handle) }
    func progress(_ handle: UnsafeMutableRawPointer) throws -> ProcessTapStatus { try base.progress(handle) }
    func update(_ handle: UnsafeMutableRawPointer, gain: Float, muted: UInt32) -> Bool { base.update(handle, gain: gain, muted: muted) }
    func heartbeat(_ handle: UnsafeMutableRawPointer) -> Bool { base.heartbeat(handle) }
    func pause(_ handle: UnsafeMutableRawPointer) { base.pause(handle) }
    func destroy(_ handle: UnsafeMutableRawPointer) -> Bool { base.destroy(handle) }
    func retryCleanup() -> Bool { retries += 1; return retryResult }
}
let cleanupDriver = RetryCleanupDriver()
let cleanupController = ProcessTapController(session: ProcessTapSession(driver: cleanupDriver))
check(cleanupController.beginCleanupRecovery() == nil)
let priorCleanupSession = try activate(cleanupController, driver: cleanupDriver.base, output: 10)
try priorCleanupSession.device.writeVolume(2300)
check(cleanupController.beginCleanupRecovery() == nil)
cleanupDriver.base.destroyResult = false
let failedRelease = cleanupController.outputChanged(to: 10, routeNotification: true)!
check(!cleanupController.releaseForOutputChange())
fails { try cleanupController.completeOutputChange(failedRelease, released: false) }
check(cleanupController.state == .paused && cleanupController.recoveryQuarantined && cleanupController.device == nil)
check(cleanupController.cleanupDetail == "fake pending cleanup")
check(cleanupController.outputChanged(to: 20, routeNotification: true) == nil)
fails { _ = try cleanupController.beginPreparation(output: 10, consent: .confirmed(output: 10)) }
fails { _ = try priorCleanupSession.device.readVolume() }
fails { try priorCleanupSession.device.writeVolume(9900) }
check(cleanupDriver.base.creates == 1 && cleanupDriver.base.updates == 1)

let failedRetry = cleanupController.beginCleanupRecovery()!
check(cleanupController.state == .stopping && cleanupController.recoveryQuarantined)
check(cleanupController.beginCleanupRecovery() == nil)
check(cleanupController.outputChanged(to: 10, routeNotification: true) == nil)
check(!cleanupController.retryCleanup() && cleanupDriver.retries == 1)
check(cleanupDriver.base.creates == 1 && cleanupDriver.base.destroys == 1)
fails { try cleanupController.completeOutputChange(failedRetry, released: false) }
check(cleanupController.state == .paused && cleanupController.recoveryQuarantined)
fails { _ = try cleanupController.beginPreparation(output: 10, consent: .confirmed(output: 10)) }

let verifiedRetry = cleanupController.beginCleanupRecovery()!
try check(!(try cleanupController.completeOutputChange(failedRelease, released: true)))
try check(!(try cleanupController.completeOutputChange(failedRetry, released: true)))
check(cleanupController.state == .stopping && cleanupController.recoveryQuarantined)
fails { try cleanupController.didEstablish(output: 10, token: priorCleanupSession.token, request: priorCleanupSession.request) }
cleanupDriver.retryResult = true
check(cleanupController.retryCleanup() && cleanupDriver.retries == 2)
check(cleanupController.state == .stopping && cleanupController.recoveryQuarantined && cleanupDriver.base.creates == 1)
fails { _ = try cleanupController.beginPreparation(output: 10, consent: .confirmed(output: 10)) }
try check(cleanupController.completeOutputChange(verifiedRetry, released: true))
check(cleanupController.state == .off && !cleanupController.recoveryQuarantined && !cleanupController.blocksPhysicalFallback)
check(cleanupController.beginCleanupRecovery() == nil)
fails { _ = try priorCleanupSession.device.readMute() }
fails { try priorCleanupSession.device.writeMute(2) }
check(cleanupDriver.base.updates == 1)

let replacementCleanupSession = try activate(cleanupController, driver: cleanupDriver.base, output: 10)
check(replacementCleanupSession.token != priorCleanupSession.token && cleanupDriver.base.creates == 2)
try check(!(try cleanupController.completeOutputChange(verifiedRetry, released: true)))
try check(!(try cleanupController.completeOutputChange(failedRetry, released: false)))
fails { try cleanupController.didEstablish(output: 10, token: priorCleanupSession.token, request: priorCleanupSession.request) }
fails { try priorCleanupSession.device.writeVolume(10000) }
check(cleanupController.state == .active && !cleanupController.recoveryQuarantined && cleanupDriver.base.updates == 1)
try replacementCleanupSession.device.writeVolume(2400)
try check(replacementCleanupSession.device.readVolume().current == 2400)
check(cleanupDriver.base.updates == 2)
cleanupDriver.base.destroyResult = true
try cleanupController.shutdown()
check(cleanupDriver.base.destroys == 2 && cleanupController.state == .off)
print("PASS \(count) total Swift assertions including verified quarantine cleanup, retry rejection and stale completion/token guards")

// Creation can itself leave retained CoreAudio resources. This failure must be
// visible as quarantine before any route notification, so a later authorized
// recovery uses the cleanup path and cannot attempt a second creation first.
let startupCleanupDriver = RetryCleanupDriver()
let startupCleanupSession = ProcessTapSession(driver: startupCleanupDriver)
let startupCleanupController = ProcessTapController(session: startupCleanupSession)
let startupCleanupFailure = ProcessTapError.backend(stage: Int32(EZTapCleanup.rawValue), status: -1)
startupCleanupDriver.base.creationFailure = startupCleanupFailure
let startupConsent = ProcessTapConsent.confirmed(output: 10)
let startupRequest = try startupCleanupController.beginPreparation(output: 10, consent: startupConsent)
do {
    _ = try startupCleanupController.establish(output: 10, consent: startupConsent)
    fatalError("Expected cleanup failure during creation")
} catch {
    check((error as? ProcessTapError)?.cleanupFailed == true)
    check(startupCleanupController.preparationFailed(startupRequest, error: error))
}
check(startupCleanupController.state == .paused && startupCleanupController.recoveryQuarantined)
check(startupCleanupController.device == nil && startupCleanupController.blocksPhysicalFallback)
check(!startupCleanupController.preparationFailed(startupRequest, error: startupCleanupFailure))
check(startupCleanupController.outputChanged(to: 10, routeNotification: true) == nil)
fails { _ = try startupCleanupController.beginPreparation(output: 10, consent: startupConsent) }
fails { _ = try startupCleanupSession.start(output: 10, consent: startupConsent) }
check(startupCleanupDriver.base.creates == 1)
let startupFailedRetry = startupCleanupController.beginCleanupRecovery()!
check(!startupCleanupController.retryCleanup())
fails { try startupCleanupController.completeOutputChange(startupFailedRetry, released: false) }
check(startupCleanupController.state == .paused && startupCleanupController.recoveryQuarantined)
let startupVerifiedRetry = startupCleanupController.beginCleanupRecovery()!
startupCleanupDriver.retryResult = true
check(startupCleanupController.retryCleanup())
try check(startupCleanupController.completeOutputChange(startupVerifiedRetry, released: true))
check(startupCleanupController.state == .off && !startupCleanupController.recoveryQuarantined)
startupCleanupDriver.base.creationFailure = nil
let startupReplacementRequest = try startupCleanupController.beginPreparation(output: 10, consent: .confirmed(output: 10))
check(!startupCleanupController.preparationFailed(startupRequest, error: startupCleanupFailure))
check(startupCleanupController.state == .preparing && !startupCleanupController.recoveryQuarantined)
let startupReplacementToken = try startupCleanupController.establish(output: 10, consent: .confirmed(output: 10), initial: .init(gain: 0.37, muted: 0))
try startupCleanupController.didEstablish(output: 10, token: startupReplacementToken, request: startupReplacementRequest)
startupCleanupDriver.base.ready = true
try startupCleanupController.tick()
check(startupCleanupController.state == .active && startupCleanupDriver.base.creates == 2)
check(!startupCleanupController.preparationFailed(startupRequest, error: startupCleanupFailure))
check(startupCleanupController.state == .active && !startupCleanupController.recoveryQuarantined)
try check(startupCleanupController.device!.readVolume().current == 3700)
check(startupCleanupDriver.retries == 2 && startupCleanupDriver.base.updates == 0)
try startupCleanupController.shutdown()
check(startupCleanupDriver.base.destroys == 1)
print("PASS \(count) total Swift assertions including startup quarantine and stale preparation-failure isolation")
