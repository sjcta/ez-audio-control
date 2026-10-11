import AppKit

enum AboutContent {
    static func version(_ bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L("开发版")
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }
    static func makeAlert(_ bundle: Bundle = .main) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Ez Audio Control"
        alert.informativeText = L("""
        开发版本 \(version(bundle))

        轻量的 macOS 菜单栏音量工具。
        由 Ez Studio（Jeson）开发；软件音量模式通过 CoreAudio process tap 在内存中衰减当前输出，无需安装驱动，不读取物理麦克风，不保存音频。排错记录仅保存在本机，不自动上传。

        版权声明
        新增内容的权利归相应权利人；复用代码的版权归原作者，并保留其原始许可。

        本项目新增代码采用 MIT 许可；DDC 桥接改编自 m1ddc、MonitorControl（MIT）。
        应用图标采用 AI 辅助生成设计。
        """)
        if let url = bundle.url(forResource: "AppIcon", withExtension: "icns") { alert.icon = NSImage(contentsOf: url) }
        alert.addButton(withTitle: L("关闭"))
        alert.addButton(withTitle: L("开源许可"))
        alert.addButton(withTitle: L("复制支持信息"))
        if Sponsorship.load(bundle) != nil { alert.addButton(withTitle: L("请我喝杯咖啡")) }
        return alert
    }
    static func licenseText(_ bundle: Bundle = .main) -> String {
        let entries = [("m1ddc", "https://github.com/waydabber/m1ddc", "MIT"),
                       ("MonitorControl", "https://github.com/MonitorControl/MonitorControl", "MIT")]
        return entries.map { name, url, license in
            let text = bundle.url(forResource: name, withExtension: "txt", subdirectory: "Licenses")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? L("许可文件缺失，请重新安装完整应用。")
            return "\(name) · \(license)\n\(url)\n\n\(text)"
        }.joined(separator: "\n\n————————————————————————\n\n")
    }

    static func makeLicenseAlert(_ bundle: Bundle = .main) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = L("开源许可")
        alert.informativeText = L("以下为本应用复用代码的完整许可。版权归各原作者所有。")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.contentView.bounds)
        text.isEditable = false; text.isSelectable = true
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.font = .systemFont(ofSize: 12); text.string = licenseText(bundle)
        scroll.documentView = text; alert.accessoryView = scroll
        alert.addButton(withTitle: L("返回"))
        return alert
    }
}
