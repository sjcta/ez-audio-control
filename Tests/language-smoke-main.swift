import AppKit
let english = CommandLine.arguments.contains("--english")
func check(_ ok: @autoclosure () -> Bool, _ label: String) { precondition(ok(), label) }
check(L("设置") == (english ? "Settings" : "设置"), "system/app language")
check(AboutContent.makeAlert().buttons[0].title == (english ? "Close" : "关闭"), "about language")
check(AboutContent.makeAlert().informativeText.hasPrefix(english ? "Version" : "版本"), "multiline localization")
check(DisplayMode.hud.title == (english ? "HUD mode" : "HUD 模式"), "settings mode")
check(CompactControls().slider.accessibilityLabel() == (english ? "Volume percentage" : "显示器音量百分比"), "VoiceOver language")
check(volumePercent(100) == "100%", "compact percent")
let text = L("目标音量 \("27%")，等待设备确认")
check(text == (english ? "Target volume 27%; waiting for device confirmation" : "目标音量 27%，等待设备确认"), "dynamic text")
check(AboutContent.makeAlert().buttons.count == 3, "no sponsor placeholder")
check(Sponsorship(url: nil, codes: []).makeAlert().messageText == (english ? "Buy me a coffee" : "请我喝杯咖啡"), "coffee localization")
print("PASS app-bundle language smoke: \(Bundle.main.preferredLocalizations), 9 checks, no windows shown")
