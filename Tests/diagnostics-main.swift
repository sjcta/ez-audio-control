import Foundation
final class Fake: AudioDDCDevice {
    var volume = AudioState(current: 37, maximum: 100)
    var muted = 2
    var fail = false
    func readVolume() throws -> AudioState { if fail { throw NSError(domain: "fake", code: 41) }; return volume }
    func readMute() throws -> Int { muted }
    func writeVolume(_ value: Int) throws { volume = AudioState(current: value, maximum: 100) }
    func writeMute(_ value: Int) throws { muted = value }
}
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sac-trace-tests-"+UUID().uuidString)
let log = AudioDiagnostics(directory: dir)
let fake = Fake(); let traced = TracedAudioDevice(fake, diagnostics: log)
var memory: MuteMemory?
_ = try DDCOperations.mute(device: traced, memory: &memory, valid: { true }, pause: {})
_ = try DDCOperations.mute(device: traced, memory: &memory, valid: { true }, pause: {})
fake.fail = true
_ = try? traced.readVolume()
log.flush()
let text = try String(contentsOf: log.file, encoding: .utf8)
precondition(text.contains("write VCP8D value=1 ok") && text.contains("write VCP8D value=2 ok"))
precondition(text.contains("read VCP62 failed code=41") && text.contains("value=37 max=100"))
let permissions = try FileManager.default.attributesOfItem(atPath: log.file.path)[.posixPermissions] as! NSNumber
precondition(permissions.intValue == 0o600)
for _ in 0..<150 { log.record("bounded-buffer-check") }
precondition(log.snapshot().components(separatedBy:"\n").count <= 20)
let bad = AudioDiagnostics(directory: log.file)
bad.record("test-file-error")
bad.flush()
precondition(bad.failure != nil && bad.snapshot().contains("test-file-error"))
print("PASS: fake mute/unmute VCP chain, pre-read failure, file mode0600, bounded memory, disk failure retained in memory. No hardware accessed.")
