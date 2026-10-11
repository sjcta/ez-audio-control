import AppKit

struct FeedbackPolicy {
    private var lastTime: TimeInterval = -.infinity
    mutating func permit(changed: Bool, snapshot: AudioSnapshot, enabled: Bool,
                         playing: Bool, now: TimeInterval) -> Bool {
        guard enabled, changed, snapshot.volume.current > 0, snapshot.mute != 1,
              !playing, now - lastTime >= 0.05 else { return false }
        lastTime = now
        return true
    }
}
// Injectable playback keeps regression tests entirely silent.
protocol FeedbackSound: AnyObject {
    var isPlaying: Bool { get }
    var volume: Float { get set }
    var playbackDeviceIdentifier: String? { get set }
    func play() -> Bool
    func stop() -> Bool
}
extension NSSound: FeedbackSound {}

final class VolumeFeedback {
    private var policy = FeedbackPolicy()
    private let makeSound: () -> FeedbackSound?
    private let now: () -> TimeInterval
    private lazy var sound = makeSound()
    init(makeSound: @escaping () -> FeedbackSound? = {
        // Read the OS-owned asset in place; never redistribute it with the app.
        NSSound(contentsOfFile: "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff", byReference: true)
    }, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.makeSound = makeSound; self.now = now
    }
    func stop() { _ = sound?.stop() }
    func confirmed(_ snapshot: AudioSnapshot, changed: Bool, enabled: Bool,
                   software: Bool, outputUID: String?) {
        guard enabled, let outputUID, !outputUID.isEmpty,
              snapshot.volume.maximum > 0,
              (1...snapshot.volume.maximum).contains(snapshot.volume.current),
              snapshot.mute != 1, !software || snapshot.mute == 2 else { stop(); return }
        guard let sound else { return }
        if sound.playbackDeviceIdentifier != outputUID { _ = sound.stop() }
        // Our process is excluded from the capture tap to prevent a loop. Apply
        // software attenuation here; native devices already apply master volume.
        sound.volume = software ? Float(snapshot.volume.current) / Float(snapshot.volume.maximum) : 1
        sound.playbackDeviceIdentifier = outputUID
        guard policy.permit(changed: changed, snapshot: snapshot, enabled: enabled,
                            playing: sound.isPlaying, now: now()) else { return }
        if !sound.play() { AudioDiagnostics.shared.record("volume feedback unavailable") }
    }
}
