import Foundation
import CoreAudio
import AudioToolbox

// Public HAL properties only. The virtual main control preserves channel balance.
struct NativeAudioDevice: AudioDDCDevice {
    // Read-only reference, including properties that the system cannot set.
    static func volumeReference(_ id: AudioDeviceID) -> (gain: Float?, muted: Bool) {
        var gain: Float?
        for selector in [kAudioDevicePropertyVolumeScalar, kAudioHardwareServiceDeviceProperty_VirtualMainVolume] {
            var property = address(selector), value: Float32 = 0, size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value) == noErr,
               value.isFinite, (0...1).contains(value) { gain = value; break }
        }
        var property = address(kAudioDevicePropertyMute), mute: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        let muted = AudioObjectGetPropertyData(id, &property, 0, nil, &size, &mute) == noErr && mute != 0
        return (gain, muted)
    }
    let id: AudioDeviceID
    let volumeSelector: AudioObjectPropertySelector
    let supportsMute: Bool
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: 0)
    }
    static func writable(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = address(selector), writable: DarwinBoolean = false
        return AudioObjectHasProperty(id, &address) &&
            AudioObjectIsPropertySettable(id, &address, &writable) == noErr && writable.boolValue
    }
    static func discover(_ id: AudioDeviceID) -> NativeAudioDevice? {
        for selector in [kAudioDevicePropertyVolumeScalar, kAudioHardwareServiceDeviceProperty_VirtualMainVolume] {
            guard writable(id, selector) else { continue }
            let device = NativeAudioDevice(id: id, volumeSelector: selector, supportsMute: writable(id, kAudioDevicePropertyMute))
            if (try? device.readVolume()) != nil { return device }
        }
        return nil
    }
    private func get<T>(_ selector: AudioObjectPropertySelector, into value: inout T) throws {
        var address = Self.address(selector), size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutablePointer(to: &value) { pointer in
            try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer))
        }
    }
    private func put<T>(_ selector: AudioObjectPropertySelector, value: inout T) throws {
        guard AudioOutputs.currentID() == id else { throw DDCOperationError.cancelled }
        var address = Self.address(selector)
        try withUnsafePointer(to: &value) { pointer in
            try check(AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<T>.size), pointer))
        }
    }
    private func check(_ code: OSStatus) throws {
        if code != noErr { throw NSError(domain: "SimpleAudioControl.NativeAudio", code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: L("系统音量操作失败（\(code)）")]) }
    }
    func readVolume() throws -> AudioState {
        var value: Float32 = 0
        try get(volumeSelector, into: &value)
        guard value.isFinite, value >= 0, value <= 1 else { throw DDCOperationError.rangeChanged }
        return AudioState(current: Int((Double(value) * 10000).rounded()), maximum: 10000)
    }
    func readMute() throws -> Int {
        guard supportsMute else { throw DDCOperationError.rangeChanged }
        var value: UInt32 = 0
        try get(kAudioDevicePropertyMute, into: &value)
        return value == 0 ? 2 : 1
    }
    func writeVolume(_ raw: Int) throws {
        var value = Float32(min(10000, max(0, raw))) / 10000
        try put(volumeSelector, value: &value)
    }
    func writeMute(_ raw: Int) throws {
        guard supportsMute else { throw DDCOperationError.rangeChanged }
        var value: UInt32 = raw == 1 ? 1 : 0
        try put(kAudioDevicePropertyMute, value: &value)
    }
}

enum NativeAudioOperations {
    static func volume(device: AudioDDCDevice, target: Int, valid: () -> Bool,
                       pause: () -> Void = { Thread.sleep(forTimeInterval: 0.02) },
                       resolveTarget: (() -> Int?)? = nil) throws -> AudioSnapshot {
        guard valid() else { throw DDCOperationError.cancelled }
        let before = try device.readVolume()
        guard let target = resolveTarget.map({ $0() }) ?? target else { throw DDCOperationError.cancelled }
        let desired = min(before.maximum, max(0, target))
        guard before.maximum == 10000, valid() else { throw DDCOperationError.cancelled }
        if before.current != desired { try device.writeVolume(desired) }
        guard valid() else { throw DDCOperationError.cancelled }
        // An explicit positive volume intent resumes sound, without restoring a cache.
        let unmute = desired > 0 && (try? device.readMute()) == 1
        if unmute { try device.writeMute(2) }
        for attempt in 0..<6 {
            guard valid() else { throw DDCOperationError.cancelled }
            let actual = try device.readVolume()
            // HAL can quantize the scalar; always display the actual readback.
            let mute = try? device.readMute()
            if abs(actual.current - desired) <= 50, !unmute || mute == 2 {
                return AudioSnapshot(volume: actual, mute: mute)
            }
            if attempt < 5 { pause() }
        }
        throw DDCOperationError.readbackMismatch
    }
    static func mute(device: AudioDDCDevice, valid: () -> Bool,
                     pause: () -> Void = { Thread.sleep(forTimeInterval: 0.02) }) throws -> AudioSnapshot {
        guard valid() else { throw DDCOperationError.cancelled }
        let desired = try device.readMute() == 1 ? 2 : 1
        guard valid() else { throw DDCOperationError.cancelled }
        try device.writeMute(desired)
        for attempt in 0..<6 {
            guard valid() else { throw DDCOperationError.cancelled }
            if try device.readMute() == desired {
                return AudioSnapshot(volume: try device.readVolume(), mute: desired)
            }
            if attempt < 5 { pause() }
        }
        throw DDCOperationError.readbackMismatch
    }
}
