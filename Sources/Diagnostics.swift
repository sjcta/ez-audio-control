import Foundation

// Bounded, local-only diagnostics. Callers supply fixed stage names and numeric
// DDC state, never keyboard contents, display identifiers, or personal data.
final class AudioDiagnostics {
    static let shared = AudioDiagnostics(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/SimpleAudioControl", isDirectory: true))
    let file: URL
    private let lock = NSLock()
    private var lines: [String] = []
    private let disk = DispatchQueue(label: "SimpleAudioControl.Diagnostics", qos: .utility)
    private var diskFailure: String?
    var failure: String? { lock.lock(); defer { lock.unlock() }; return diskFailure }
    init(directory: URL) { file = directory.appendingPathComponent("audio-transactions.log") }
    func record(_ stage: String) {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "\(formatter.string(from: Date())) pid=\(ProcessInfo.processInfo.processIdentifier) \(stage)"
        lock.lock()
        lines.append(line); lines = Array(lines.suffix(128))
        lock.unlock()
        disk.async { self.appendToFile(line) }
    }
    func flush() { disk.sync {} }
    private func appendToFile(_ line: String) {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            if !fm.fileExists(atPath: file.path) {
                guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            if size > 256 * 1024 {
                try handle.truncate(atOffset: 0)
                try handle.seek(toOffset: 0)
            }
            try handle.write(contentsOf: Data((line + "\n").utf8))
            lock.lock(); diskFailure = nil; lock.unlock()
        } catch {
            lock.lock(); diskFailure = L("日志写入失败 code=\((error as NSError).code)"); lock.unlock()
        }
    }
    func snapshot() -> String {
        lock.lock(); defer { lock.unlock() }
        return (diskFailure.map { [$0] } ?? []) .joined(separator: "\n") + "\n" + lines.suffix(18).joined(separator: "\n")
    }
}

// Trace before and after each operation, including failures before the old
// high-level mute trace could begin. The underlying DDC behavior is unchanged.
final class TracedAudioDevice: AudioDDCDevice {
    let device: AudioDDCDevice
    let diagnostics: AudioDiagnostics
    let transaction = UUID().uuidString.prefix(8)
    init(_ device: AudioDDCDevice, diagnostics: AudioDiagnostics = .shared) {
        self.device = device; self.diagnostics = diagnostics
    }
    private func action<T>(_ name: String, _ body: () throws -> T, describe: (T) -> String) throws -> T {
        let start = ProcessInfo.processInfo.systemUptime
        diagnostics.record("tx=\(transaction) \(name) begin")
        do {
            let value = try body()
            diagnostics.record("tx=\(transaction) \(name) ok \(describe(value)) elapsed_ms=\(Int((ProcessInfo.processInfo.systemUptime - start) * 1000))")
            return value
        } catch {
            diagnostics.record("tx=\(transaction) \(name) failed code=\((error as NSError).code)")
            throw error
        }
    }
    func readVolume() throws -> AudioState {
        try action("read VCP62", device.readVolume) { "value=\($0.current) max=\($0.maximum)" }
    }
    func readMute() throws -> Int { try action("read VCP8D", device.readMute) { "value=\($0)" } }
    func writeVolume(_ value: Int) throws { try action("write VCP62 value=\(value)", { try device.writeVolume(value) }) { _ in "" } }
    func writeMute(_ value: Int) throws { try action("write VCP8D value=\(value)", { try device.writeMute(value) }) { _ in "" } }
}
