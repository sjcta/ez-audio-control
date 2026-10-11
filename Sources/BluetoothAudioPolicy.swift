import Foundation

struct BluetoothAudioDevice {
    let address: String
    let name: String
    let isConnected: Bool
    var allowsNameFallback = true
}

struct BluetoothAudioOutput {
    let id: UInt32
    let name: String
    let uid: String?
    let isBluetooth: Bool
}

enum AudioOutputSelectionResult { case waiting, confirmed, superseded, timedOut }

enum BluetoothAudioPolicy {
    static func normalizedAddress(_ address: String) -> String? {
        let value = address.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").uppercased()
        guard value.count == 12, value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789ABCDEF").contains($0) }) else { return nil }
        return value
    }

    // HAL UIDs are opaque. Recognize a complete MAC token only; never strip an
    // arbitrary UID down to hex or guess a device when its address conflicts.
    private static func addresses(in uid: String?) -> Set<String> {
        guard let uid else { return [] }
        let expression = try! NSRegularExpression(pattern: "(?i)(?<![0-9a-f])(?:[0-9a-f]{2}(?:[:-][0-9a-f]{2}){5}|[0-9a-f]{12})(?![0-9a-f])")
        return Set(expression.matches(in: uid, range: NSRange(uid.startIndex..., in: uid)).compactMap {
            Range($0.range, in: uid).flatMap { normalizedAddress(String(uid[$0])) }
        })
    }

    static func outputID(for device: BluetoothAudioDevice, among outputs: [BluetoothAudioOutput]) -> UInt32? {
        guard let address = normalizedAddress(device.address) else { return nil }
        let bluetooth = outputs.filter(\.isBluetooth)
        let exact = bluetooth.filter { addresses(in: $0.uid) == [address] }
        if !exact.isEmpty { return exact.count == 1 ? exact[0].id : nil }
        guard device.allowsNameFallback else { return nil }
        let named = bluetooth.filter { $0.name == device.name }
        guard named.count == 1, addresses(in: named[0].uid).isEmpty else { return nil }
        return named[0].id
    }

    static func uniqueDevices(_ devices: [BluetoothAudioDevice]) -> [BluetoothAudioDevice] {
        var seen = Set<String>()
        let unique = devices.filter { device in
            guard let address = normalizedAddress(device.address) else { return false }
            return seen.insert(address).inserted
        }
        let names = Dictionary(grouping: unique, by: \.name)
        return unique.map { device in
            var result = device
            result.allowsNameFallback = device.allowsNameFallback && names[device.name]?.count == 1
            return result
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func isAudioOutput(major: UInt32, minor: UInt32, cachedServices: Set<UInt16>) -> Bool {
        // Audio Sink, Headset, Hands-Free, and Headset HS. Audio Source and
        // audio gateways alone are not destinations for this Mac's playback.
        if !cachedServices.isDisjoint(with: [0x110B, 0x1108, 0x111E, 0x1131]) { return true }
        guard major == 0x04 else { return false }
        return [1, 2, 5, 6, 7, 8, 10, 15, 18].contains(minor)
    }

    static func selectionResult(target: UInt32, initial: UInt32?, current: UInt32?,
                                now: TimeInterval, deadline: TimeInterval) -> AudioOutputSelectionResult {
        if current == target { return .confirmed }
        if let current, current != initial { return .superseded }
        if now >= deadline { return .timedOut }
        return .waiting
    }
}
