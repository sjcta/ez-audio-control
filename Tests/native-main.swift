import Foundation
var checks = 0
func expect(_ ok: @autoclosure () -> Bool, _ message: String) {
    checks += 1; if !ok() { fatalError(message) }
}
final class Device: AudioDDCDevice {
    var value = 2500, mute = 2, writes = 0, muteWrites = 0
    var ignoreVolume = false, ignoreMute = false, quantize = false
    var afterRead: (() -> Void)?
    func readVolume() throws -> AudioState {
        afterRead?(); return AudioState(current: value, maximum: 10000)
    }
    func readMute() throws -> Int { mute }
    func writeVolume(_ value: Int) throws {
        writes += 1; if !ignoreVolume { self.value = value + (quantize ? 20 : 0) }
    }
    func writeMute(_ value: Int) throws { muteWrites += 1; if !ignoreMute { mute = value } }
}
let device = Device()
let first = try NativeAudioOperations.volume(device: device, target: 2600, valid: { true }, pause: {})
expect(first.volume.current == 2600 && device.writes == 1, "native adjustment readback")
_ = try NativeAudioOperations.volume(device: device, target: 2600, valid: { true }, pause: {})
expect(device.writes == 1, "same-value no write")
device.mute = 1
let resumed = try NativeAudioOperations.volume(device: device, target: 2700, valid: { true }, pause: {})
expect(resumed.mute == 2 && device.value == 2700, "positive explicit target unmutes without cache")
let writes = device.writes
_ = try NativeAudioOperations.mute(device: device, valid: { true }, pause: {})
_ = try NativeAudioOperations.mute(device: device, valid: { true }, pause: {})
expect(device.writes == writes && device.value == 2700, "native mute toggles never restore old volume")
var valid = true
device.afterRead = { valid = false }
do { _ = try NativeAudioOperations.volume(device: device, target: 9000, valid: { valid }, pause: {}); fatalError("cancel failed") }
catch { expect(device.writes == writes, "route changed during read cancels write") }
device.afterRead = nil; device.ignoreVolume = true
do { _ = try NativeAudioOperations.volume(device: device, target: 9000, valid: { true }, pause: {}); fatalError("readback failed") }
catch { expect(device.value == 2700, "unconfirmed write reports failure") }
device.ignoreVolume = false; device.quantize = true
let quantized = try NativeAudioOperations.volume(device: device, target: 3000, valid: { true }, pause: {})
expect(quantized.volume.current == 3020, "show actual quantized level")
device.quantize = false; device.mute = 1; device.ignoreMute = true
do { _ = try NativeAudioOperations.volume(device: device, target: 3200, valid: { true }, pause: {}); fatalError("mute readback failed") }
catch { expect(device.mute == 1, "unconfirmed unmute fails") }
var feedback = FeedbackPolicy()
let audible = AudioSnapshot(volume: AudioState(current: 20, maximum: 100), mute: 2)
expect(!feedback.permit(changed: false, snapshot: audible, enabled: true, playing: false, now: 0), "refresh silent")
expect(feedback.permit(changed: true, snapshot: audible, enabled: true, playing: false, now: 1), "successful user change feedback")
expect(!feedback.permit(changed: true, snapshot: audible, enabled: true, playing: false, now: 1.02), "rapid scroll throttled")
expect(!feedback.permit(changed: true, snapshot: audible, enabled: true, playing: true, now: 2), "no overlapping sounds")
expect(!feedback.permit(changed: true, snapshot: audible, enabled: false, playing: false, now: 3), "preference disables sound")
expect(!feedback.permit(changed: true, snapshot: AudioSnapshot(volume: audible.volume, mute: 1), enabled: true, playing: false, now: 4), "muted silent")
expect(!feedback.permit(changed: true, snapshot: AudioSnapshot(volume: AudioState(current: 0, maximum: 100), mute: 2), enabled: true, playing: false, now: 5), "zero silent")
print("PASS \(checks) native transactions and feedback-policy checks; no hardware writes or playback")

for (raw, mute, silent) in [(1,2,false),(0,2,true),(1,2,false),(40,1,true),(0,1,true)] {
    expect(AudioSnapshot(volume: AudioState(current: raw, maximum: 100), mute: mute).effectiveSilent == silent, "zero/explicit mute presentation")
}
print("PASS \(checks) including zero-volume visual policy; no mute write for visuals")

final class SilentFeedbackSound: FeedbackSound {
    var isPlaying = false
    var volume: Float = 1
    var playbackDeviceIdentifier: String?
    var played: [(Float, String?)] = []
    var stops = 0
    func play() -> Bool { played.append((volume, playbackDeviceIdentifier)); isPlaying = true; return true }
    func stop() -> Bool { isPlaying = false; stops += 1; return true }
}
let sound = SilentFeedbackSound()
var instant: TimeInterval = 10
let player = VolumeFeedback(makeSound: { sound }, now: { instant })
func confirm(_ raw: Int, maximum: Int = 10000, mute: Int? = 2, software: Bool = true,
             enabled: Bool = true, changed: Bool = true, uid: String? = "display") {
    instant += 1
    player.confirmed(AudioSnapshot(volume: AudioState(current: raw, maximum: maximum), mute: mute),
                     changed: changed, enabled: enabled, software: software, outputUID: uid)
}
confirm(2500)
expect(sound.played.count == 1 && sound.played[0].0 == 0.25 && sound.played[0].1 == "display", "software gain and physical route applied before playback")
confirm(1000)
expect(sound.played.count == 1 && sound.volume == 0.1, "playing feedback follows lower confirmed gain without overlapping")
confirm(0)
expect(!sound.isPlaying && sound.played.count == 1, "zero stops a currently playing tail")
confirm(10000)
expect(sound.played.last!.0 == 1, "software 100 percent is unity, never amplification")
confirm(5000, mute: 1)
expect(!sound.isPlaying, "mute stops feedback")
let beforeInvalid = sound.played.count
for raw in [-1, 10001] { confirm(raw) }
confirm(1, maximum: 0)
confirm(5000, mute: nil)
confirm(5000, uid: nil)
confirm(5000, uid: "")
confirm(5000, enabled: false)
confirm(5000, changed: false)
expect(sound.played.count == beforeInvalid, "invalid state, missing route, disabled or refresh never plays")
confirm(3000, software: false, uid: "bluetooth")
expect(sound.played.last!.0 == 1 && sound.played.last!.1 == "bluetooth", "native output not attenuated twice and old route not reused")
confirm(2000, uid: "display")
expect(sound.played.last!.0 == 0.2 && sound.played.last!.1 == "display", "switch back applies software gain before play")
player.stop()
expect(!sound.isPlaying, "route invalidation stops feedback")
let missing = VolumeFeedback(makeSound: { nil }, now: { instant })
missing.confirmed(audible, changed: true, enabled: true, software: true, outputUID: "display")
expect(true, "missing system asset fails silently, no substitute beep")
print("PASS \(checks) including software feedback routing/gain/tail regressions; fake player only, no playback")
