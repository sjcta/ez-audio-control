import AppKit
import ApplicationServices

// All sources share this route: physical media keys and injected system volume
// commands. Three tap points cover injection at HID/session/annotated stages.
// No mouse-wheel, ordinary keyboard or non-volume event is consumed.
final class MediaKeys {
    private var taps: [CFMachPort] = []
    private var sources: [CFRunLoopSource] = []
    private var deduplicator = VolumeEventDeduplicator()
    var activeTapCount: Int { taps.filter { CGEvent.tapIsEnabled(tap: $0) }.count }
    private(set) var lastStartStatus = L("尚未尝试")
    private(set) var phaseStatus: [String] = []
    private(set) var timeoutCount = 0
    private(set) var userDisableCount = 0
    private(set) var receivedVolumeCommands = 0
    private(set) var handledVolumeCommands = 0
    var handler: ((MediaKey) -> Bool)?
    var sourceFilter: ((CGEvent) -> Bool)? // Used only by marker-isolated event tests.
    func start() -> Bool {
        guard AXIsProcessTrusted() else { stop(); phaseStatus = []; lastStartStatus = L("辅助功能检查=false；未创建事件监听"); return false }
        if !taps.isEmpty && taps.allSatisfy({ CGEvent.tapIsEnabled(tap: $0) }) { return true }
        stop(); phaseStatus = []; lastStartStatus = L("正在创建事件监听")
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<MediaKeys>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout {
                owner.timeoutCount += 1
                for tap in owner.taps { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if type == .tapDisabledByUserInput { owner.userDisableCount += 1; owner.lastStartStatus = L("系统停用了事件监听"); return Unmanaged.passUnretained(event) }
            guard type.rawValue == 14, owner.sourceFilter?(event) != false,
                  let e = NSEvent(cgEvent: event),
                  let key = MediaKey.decode(data1: e.data1, subtype: Int(e.subtype.rawValue)) else {
                return Unmanaged.passUnretained(event)
            }
            if key.down { owner.receivedVolumeCommands += 1 }
            let pid = event.getIntegerValueField(.eventSourceUnixProcessID)
            if owner.deduplicator.wasHandled(timestamp: event.timestamp, source: pid, data1: e.data1) { return nil }
            guard owner.handler?(key) == true else { return Unmanaged.passUnretained(event) }
            if key.down { owner.handledVolumeCommands += 1 }
            owner.deduplicator.markHandled(timestamp: event.timestamp, source: pid, data1: e.data1)
            return nil
        }
        for (index, location) in [CGEventTapLocation.cghidEventTap, .cgSessionEventTap, .cgAnnotatedSessionEventTap].enumerated() {
            let name = ["HID", "Session", "Annotated"][index]
            guard let port = CGEvent.tapCreate(tap: location, place: .headInsertEventTap, options: .defaultTap,
                                               eventsOfInterest: CGEventMask(1 << 14), callback: callback,
                                               userInfo: Unmanaged.passUnretained(self).toOpaque()) else { phaseStatus.append(L("\(name)：CGEventTapCreate=nil（API未提供错误码）")); continue }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)!
            taps.append(port); sources.append(source)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            phaseStatus.append(L("\(name)：创建成功，启用=\(CGEvent.tapIsEnabled(tap: port))"))
        }
        lastStartStatus = L("已启用\(activeTapCount)/3阶段")
        return activeTapCount > 0
    }
    func stop() {
        for tap in taps { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        for source in sources { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        taps.removeAll(); sources.removeAll(); deduplicator = VolumeEventDeduplicator()
    }
    deinit { stop() }
}
