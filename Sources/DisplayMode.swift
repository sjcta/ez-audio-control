import Foundation

enum DisplayMode: String, CaseIterable {
    case hud, full
    init(savedValue: String?) { self = savedValue.flatMap(Self.init(rawValue:)) ?? .full }
    var showsHUD: Bool { true }
    var showsNumbers: Bool { self != .hud }
    var title: String {
        switch self {
        case .hud: return L("HUD 模式")
        case .full: return L("完整模式")
        }
    }
    var detail: String {
        switch self {
        case .hud: return L("仅显示顶部 HUD，菜单栏只保留图标")
        case .full: return L("同时显示顶部 HUD 和菜单栏数字")
        }
    }
}
