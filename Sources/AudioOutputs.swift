import Foundation
import CoreAudio

struct AudioOutputDevice {
    let id: AudioDeviceID
    let name: String
    let transport: UInt32?
    let iconURL: URL?

    init(id: AudioDeviceID, name: String, transport: UInt32? = nil, iconURL: URL? = nil) {
        self.id = id
        self.name = name
        self.transport = transport
        self.iconURL = iconURL
    }
}
enum AudioOutputs {
    static func transport(_ id: AudioDeviceID) -> UInt32? {
        var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
    static func iconURL(_ id: AudioDeviceID) -> URL? {
        var value: Unmanaged<CFURL>?, size = UInt32(MemoryLayout<Unmanaged<CFURL>?>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIcon,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let icon = value?.takeRetainedValue() else { return nil }
        let url = icon as URL
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
        return url
    }
    static func uid(_ id: AudioDeviceID) -> String? {
        var value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    static func currentID() -> AudioDeviceID? {
        var id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return nil }
        return id == 0 ? nil : id
    }
    static func name(_ id: AudioDeviceID) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    static func available() throws -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size))
        guard size > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        try check(devices.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        })
        return devices.compactMap { id in
            // Our private replay device is an implementation detail, never a
            // destination the user should select (or feed back into its own tap).
            guard uid(id)?.hasPrefix("local.SimpleAudioControl.tap.") != true else { return nil }
            guard isAvailable(id), let title = name(id) else { return nil }
            return AudioOutputDevice(id: id, name: title, transport: transport(id), iconURL: iconURL(id))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func isAvailable(_ id: AudioDeviceID) -> Bool {
        var alive: UInt32 = 0, aliveSize = UInt32(MemoryLayout<UInt32>.size)
        var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &aliveSize, &alive) == noErr, alive != 0 else { return false }
        property.mSelector = kAudioDevicePropertyStreamConfiguration; property.mScope = kAudioDevicePropertyScopeOutput
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &bytes) == noErr,
              bytes >= MemoryLayout<AudioBufferList>.size else { return false }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &bytes, storage) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains(where: { $0.mNumberChannels > 0 })
    }
    static func select(_ id: AudioDeviceID, verifyImmediately: Bool = true) throws {
        guard try available().contains(where: { $0.id == id }) else {
            throw NSError(domain: "SimpleAudioControl.AudioOutput", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: L("这个输出设备已断开，请重新选择")])
        }
        var selected = id
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                            UInt32(MemoryLayout<AudioDeviceID>.size), &selected))
        guard !verifyImmediately || currentID() == id else {
            throw NSError(domain: "SimpleAudioControl.AudioOutput", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: L("系统未确认输出切换，请重试")])
        }
    }
    private static func check(_ status: OSStatus) throws {
        guard status == noErr else {
            throw NSError(domain: "SimpleAudioControl.AudioOutput", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: L("音频输出操作失败（\(status)）")])
        }
    }
}
