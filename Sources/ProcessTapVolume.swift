import Foundation

struct AutomaticSoftwareOffer {
    private var lastOutput: UInt32?
    private var offered = false
    mutating func shouldOffer(output: UInt32?, nativeWritable: Bool, available: Bool, idle: Bool) -> Bool {
        if output != lastOutput { lastOutput = output; offered = false }
        guard let output, output != 0, !nativeWritable, available, idle, !offered else { return false }
        offered = true
        return true
    }
}

enum ProcessTapError: LocalizedError {
    case consentRequired, unavailable, invalidGain, interrupted
    case backend(stage: Int32, status: Int32)
    var errorDescription: String? {
        switch self {
        case .consentRequired: return L("请先确认本次系统音频处理与安全播放范围")
        case .unavailable: return L("此系统或当前输出不支持软件衰减")
        case .invalidGain: return L("软件增益必须是 0% 至 100% 的有限数值")
        case .interrupted: return L("软件衰减已暂停；请先暂停播放，再退出软件模式")
        case let .backend(stage, status): return L("软件音频启动或运行失败（阶段 \(stage)，状态 \(status)）；请暂停播放后退出软件模式")
        }
    }
    var cleanupFailed: Bool {
        if case .backend(let stage, _) = self { return stage == Int32(EZTapCleanup.rawValue) }
        return false
    }
    var runtimeRecoverable: Bool {
        guard case .backend(let stage, let status) = self else { return false }
        if stage == Int32(EZTapTimeout.rawValue) { return status == Int32(EZTapTimeoutOwnerLease.rawValue) }
        return [EZTapInspectOutput, EZTapFormats, EZTapTopology].contains { stage == Int32($0.rawValue) }
    }
}

// A short-lived start intent from automatic routing or an explicit menu action.
// Never persisted; CoreAudio still enforces the separate OS permission.
struct ProcessTapConsent {
    let output: UInt32
    private let issuedAt: TimeInterval
    static func confirmed(output: UInt32, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Self {
        Self(output: output, issuedAt: now)
    }
    func valid(for output: UInt32, now: TimeInterval) -> Bool {
        output != 0 && self.output == output && now.isFinite && issuedAt.isFinite && now >= issuedAt && now - issuedAt < 60
    }
}
struct ProcessTapSnapshot {
    let gain: Float; let muted: UInt32
    static func initial(systemGain: Float?, systemMuted: Bool, savedGain: Float?) -> Self {
        let gain = [systemGain, savedGain].compactMap { $0 }.first { $0.isFinite && (0...1).contains($0) } ?? 1
        return .init(gain: gain, muted: systemMuted ? 1 : 0)
    }
}
struct ProcessTapStatus {
    let callbacks: UInt64, validFrames: UInt64
    let ready: Bool
    let stage: Int32, status: Int32
    init(callbacks: UInt64, validFrames: UInt64, ready: Bool, stage: Int32, status: Int32 = 0) {
        self.callbacks = callbacks; self.validFrames = validFrames; self.ready = ready
        self.stage = stage; self.status = status
    }
}
protocol ProcessTapDriver {
    var available: Bool { get }
    func create(output: UInt32, confirmed: Bool, initial: ProcessTapSnapshot) throws -> UnsafeMutableRawPointer
    func snapshot(_ handle: UnsafeMutableRawPointer) throws -> ProcessTapSnapshot
    func progress(_ handle: UnsafeMutableRawPointer) throws -> ProcessTapStatus
    func update(_ handle: UnsafeMutableRawPointer, gain: Float, muted: UInt32) -> Bool
    func heartbeat(_ handle: UnsafeMutableRawPointer) -> Bool
    func pause(_ handle: UnsafeMutableRawPointer)
    func destroy(_ handle: UnsafeMutableRawPointer) -> Bool
    func retryCleanup() -> Bool
    var cleanupDetail: String? { get }
}
extension ProcessTapDriver {
    func retryCleanup() -> Bool { false }
    var cleanupDetail: String? { nil }
}
struct CoreAudioProcessTapDriver: ProcessTapDriver {
    var available: Bool { EZProcessTapAvailable() != 0 }
    func create(output: UInt32, confirmed: Bool, initial: ProcessTapSnapshot) throws -> UnsafeMutableRawPointer {
        var error = EZProcessTapFailure()
        guard let handle = EZProcessTapCreate(output, confirmed ? 1 : 0, initial.gain, Int32(initial.muted), &error) else {
            throw ProcessTapError.backend(stage: error.stage, status: error.status)
        }
        return handle
    }
    func snapshot(_ handle: UnsafeMutableRawPointer) throws -> ProcessTapSnapshot {
        var gain: Float = 0, muted: Int32 = 1
        guard EZProcessTapSnapshot(handle, &gain, &muted) != 0 else {
            let p = try progress(handle)
            if p.stage != 0 { throw ProcessTapError.backend(stage: p.stage, status: p.status) }
            throw ProcessTapError.interrupted
        }
        return ProcessTapSnapshot(gain: gain, muted: UInt32(muted))
    }
    func progress(_ handle: UnsafeMutableRawPointer) throws -> ProcessTapStatus {
        var p = EZProcessTapProgress()
        guard EZProcessTapReadProgress(handle, &p) != 0 else { throw ProcessTapError.interrupted }
        return ProcessTapStatus(callbacks: p.callbacks, validFrames: p.validFrames, ready: p.ready != 0, stage: p.stage, status: p.status)
    }
    func update(_ handle: UnsafeMutableRawPointer, gain: Float, muted: UInt32) -> Bool { EZProcessTapSetGain(handle, gain, Int32(muted)) != 0 }
    func heartbeat(_ handle: UnsafeMutableRawPointer) -> Bool {
        EZProcessTapHeartbeat(handle); return EZProcessTapHealthy(handle) != 0
    }
    func pause(_ handle: UnsafeMutableRawPointer) { EZProcessTapPause(handle) }
    func destroy(_ handle: UnsafeMutableRawPointer) -> Bool { EZProcessTapDestroy(handle) != 0 }
    func retryCleanup() -> Bool {
        var failure = EZProcessTapCleanupFailure()
        return EZProcessTapRetryCleanup(&failure) != 0
    }
    var cleanupDetail: String? {
        var f = EZProcessTapCleanupFailure()
        guard EZProcessTapReadCleanupFailure(&f) != 0 else { return nil }
        return "operation=\(f.operation) object=\(f.objectID) selector=\(f.selector) status=\(f.status)"
    }
}

final class ProcessTapSession {
    private let lock = NSLock()
    private let driver: ProcessTapDriver
    private let now: () -> TimeInterval
    private var handle: UnsafeMutableRawPointer?
    private var cleanupFailed = false, starting = false
    private var generation: UInt64 = 0
    init(driver: ProcessTapDriver = CoreAudioProcessTapDriver(), now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.driver = driver; self.now = now
    }
    var available: Bool { driver.available }
    var cleanupDetail: String? { driver.cleanupDetail }
    func retryCleanup() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard cleanupFailed, !starting, handle == nil else { return !cleanupFailed && !starting }
        if driver.retryCleanup() { cleanupFailed = false; return true }
        return false
    }
    // Called on the serial work queue. No UI/main-thread lock is held while the
    // system may present its permission dialog or while CoreAudio creates objects.
    func start(output: UInt32, consent: ProcessTapConsent?, initial: ProcessTapSnapshot = .init(gain: 0, muted: 1)) throws -> UInt64 {
        guard consent?.valid(for: output, now: now()) == true else { throw ProcessTapError.consentRequired }
        guard driver.available else { throw ProcessTapError.unavailable }
        guard initial.gain.isFinite, (0...1).contains(initial.gain), initial.muted <= 1 else { throw ProcessTapError.invalidGain }
        lock.lock()
        guard handle == nil, !cleanupFailed, !starting else { lock.unlock(); throw ProcessTapError.interrupted }
        generation &+= 1; let token = generation; starting = true; lock.unlock()
        let created: UnsafeMutableRawPointer
        do { created = try driver.create(output: output, confirmed: true, initial: initial) }
        catch {
            lock.lock(); starting = false
            if (error as? ProcessTapError)?.cleanupFailed == true { cleanupFailed = true }
            lock.unlock(); throw error
        }
        lock.lock()
        if generation != token {
            // Keep the reservation while destroying the cancelled handle. A UI
            // shutdown/restart must not overlap a tap whose cleanup is in flight.
            lock.unlock(); let released = driver.destroy(created)
            lock.lock(); cleanupFailed = cleanupFailed || !released; starting = false; lock.unlock()
            throw ProcessTapError.interrupted
        }
        handle = created; starting = false; lock.unlock(); return token
    }
    func snapshot(generation expected: UInt64) throws -> ProcessTapSnapshot {
        lock.lock(); defer { lock.unlock() }
        return try checked(expected)
    }
    private func checked(_ expected: UInt64) throws -> ProcessTapSnapshot {
        guard expected == generation, let handle else { throw ProcessTapError.interrupted }
        return try driver.snapshot(handle)
    }
    func update(generation expected: UInt64, gain: Float? = nil, muted: UInt32? = nil) throws {
        if let gain, !gain.isFinite || !(0...1).contains(gain) { throw ProcessTapError.invalidGain }
        if let muted, muted > 1 { throw ProcessTapError.invalidGain }
        lock.lock(); defer { lock.unlock() }
        let old = try checked(expected)
        guard let handle else { throw ProcessTapError.interrupted }
        if !driver.update(handle, gain: gain ?? old.gain, muted: muted ?? old.muted) {
            let p = try driver.progress(handle)
            if p.stage != 0 { throw ProcessTapError.backend(stage: p.stage, status: p.status) }
            throw ProcessTapError.interrupted
        }
    }
    func poll() throws -> ProcessTapStatus {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { throw ProcessTapError.interrupted }
        let healthy = driver.heartbeat(handle), p = try driver.progress(handle)
        guard healthy, p.stage == 0 else { throw ProcessTapError.backend(stage: p.stage, status: p.status) }
        return p
    }
    func pause() {
        lock.lock(); defer { lock.unlock() }; generation &+= 1
        if let handle { driver.pause(handle) }
    }
    @discardableResult func shutdown() -> Bool {
        lock.lock(); defer { lock.unlock() }; generation &+= 1
        guard !cleanupFailed, !starting else { return false }
        let result = handle.map { driver.destroy($0) } ?? true
        handle = nil; cleanupFailed = !result; return result
    }
    deinit { shutdown() }
}
struct ProcessTapVolumeDevice: AudioDDCDevice {
    let id: UInt32, generation: UInt64
    let session: ProcessTapSession
    func readVolume() throws -> AudioState {
        AudioState(current: Int((try session.snapshot(generation: generation).gain * 10000).rounded()), maximum: 10000)
    }
    func readMute() throws -> Int { try session.snapshot(generation: generation).muted == 1 ? 1 : 2 }
    func writeVolume(_ raw: Int) throws {
        guard (0...10000).contains(raw) else { throw ProcessTapError.invalidGain }
        try session.update(generation: generation, gain: Float(raw) / 10000)
    }
    func writeMute(_ raw: Int) throws {
        guard raw == 1 || raw == 2 else { throw ProcessTapError.invalidGain }
        try session.update(generation: generation, muted: raw == 1 ? 1 : 0)
    }
}
// Main-thread state machine; establish/releaseForOutputChange share one serial work queue.
final class ProcessTapController {
    enum State { case off, preparing, active, paused, stopping }
    private let session: ProcessTapSession
    private var prepared: (output: UInt32, token: UInt64)?
    private var preparation: UInt64 = 0
    private var boundOutput: UInt32?
    private var routeCleanupFailed = false
    private(set) var state: State = .off
    private(set) var device: ProcessTapVolumeDevice?
    private(set) var latestStatus: ProcessTapSnapshot?
    private(set) var progress: ProcessTapStatus?
    init(session: ProcessTapSession = ProcessTapSession()) { self.session = session }
    var blocksPhysicalFallback: Bool { state != .off }
    var recoveryQuarantined: Bool { routeCleanupFailed }
    var cleanupDetail: String? { session.cleanupDetail }
    var available: Bool { session.available }
    func shouldInvalidateForOutputNotification(deviceListOnly: Bool, currentOutput: UInt32?) -> Bool {
        // Our private aggregate changes the device list without changing output.
        // The backend validates device removal/format changes independently.
        if deviceListOnly, state == .preparing || state == .active,
           let currentOutput, boundOutput == currentOutput { return false }
        return true
    }
    @discardableResult func beginPreparation(output: UInt32, consent: ProcessTapConsent?) throws -> UInt64 {
        guard available else { throw ProcessTapError.unavailable }
        guard consent?.valid(for: output, now: ProcessInfo.processInfo.systemUptime) == true else { throw ProcessTapError.consentRequired }
        guard state == .off else { throw ProcessTapError.interrupted }
        preparation &+= 1; boundOutput = output; state = .preparing
        return preparation
    }
    func establish(output: UInt32, consent: ProcessTapConsent, initial: ProcessTapSnapshot = .init(gain: 0, muted: 1)) throws -> UInt64 { try session.start(output: output, consent: consent, initial: initial) }
    func isPreparing(_ request: UInt64) -> Bool { request == preparation && state == .preparing }
    func didEstablish(output: UInt32, token: UInt64, request: UInt64) throws {
        // An old main-queue completion must never adopt or pause a newer session.
        guard isPreparing(request), boundOutput == output else { throw ProcessTapError.interrupted }
        prepared = (output, token)
    }
    @discardableResult func preparationFailed(_ request: UInt64, error: Error? = nil) -> Bool {
        guard isPreparing(request) else { return false }
        if (error as? ProcessTapError)?.cleanupFailed == true { routeCleanupFailed = true }
        pause(); return true
    }
    @discardableResult func outputChanged(to output: UInt32?, routeNotification: Bool = false) -> UInt64? {
        guard state != .off, state != .stopping, !routeCleanupFailed,
              boundOutput != output || routeNotification else { return nil }
        pause()
        state = .stopping
        return preparation
    }
    // Runs after any in-flight establish/write on the same work queue. Only
    // session state is touched here; the UI adopts the result on the main thread.
    func releaseForOutputChange() -> Bool { session.shutdown() }
    func retryCleanup() -> Bool { session.retryCleanup() }
    func beginCleanupRecovery() -> UInt64? {
        guard routeCleanupFailed, state == .paused else { return nil }
        preparation &+= 1; state = .stopping
        return preparation
    }
    @discardableResult func completeOutputChange(_ request: UInt64, released: Bool) throws -> Bool {
        guard state == .stopping, preparation == request else { return false }
        boundOutput = nil
        routeCleanupFailed = !released
        state = released ? .off : .paused
        if !released { throw ProcessTapError.backend(stage: Int32(EZTapCleanup.rawValue), status: 0) }
        return true
    }
    func tick() throws {
        guard state == .preparing || state == .active, let prepared else { return }
        do {
            progress = try session.poll()
            guard progress?.ready == true else { return }
            latestStatus = try session.snapshot(generation: prepared.token)
            device = ProcessTapVolumeDevice(id: prepared.output, generation: prepared.token, session: session)
            state = .active
        } catch { pause(); throw error }
    }
    func pause() {
        guard state != .off, state != .stopping else { return }
        // Keep the owner output even after a backend fault. A subsequent route
        // notification must still be able to release this stale session.
        preparation &+= 1
        session.pause(); prepared = nil; device = nil; latestStatus = nil; progress = nil; state = .paused
    }
    func shutdown() throws {
        guard state != .stopping else { throw ProcessTapError.interrupted }
        preparation &+= 1; boundOutput = nil
        let released = session.shutdown(); prepared = nil; device = nil; latestStatus = nil; progress = nil
        state = released ? .off : .paused
        if released { routeCleanupFailed = false }
        if !released { throw ProcessTapError.interrupted }
    }
}
