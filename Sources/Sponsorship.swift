import AppKit

struct Sponsorship {
    struct QR {
        let label: String
        let image: NSImage
    }
    let url: URL?
    let codes: [QR]
    static func load(_ bundle: Bundle = .main) -> Sponsorship? {
        guard let config = bundle.url(forResource: "Sponsorship", withExtension: "json"),
              let data = try? Data(contentsOf: config), data.count <= 16_384,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var link: URL?
        if let raw = object["url"] as? String, let components = URLComponents(string: raw),
           components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
           components.user == nil, components.password == nil,
           !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            link = components.url
        }
        let providers = [("wechat", L("微信支付")), ("alipay", L("支付宝"))]
        let codes: [QR] = providers.compactMap { key, label in
            guard let name = object[key] as? String, !name.isEmpty,
                  name == (name as NSString).lastPathComponent, !name.contains(".."),
                  ["png", "jpg", "jpeg"].contains((name as NSString).pathExtension.lowercased()),
                  let root = bundle.resourceURL?.appendingPathComponent("Sponsorship", isDirectory: true),
                  root.appendingPathComponent(name).resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath(),
                  let data = try? Data(contentsOf: root.appendingPathComponent(name)),
                  data.count <= 4_194_304, let image = NSImage(data: data),
                  image.size.width > 0, image.size.height > 0 else { return nil }
            return QR(label: label, image: image)
        }
        return link == nil && codes.isEmpty ? nil : Sponsorship(url: link, codes: codes)
    }
    @discardableResult func openWebsite(using opener: (URL) -> Bool = { NSWorkspace.shared.open($0) }) -> Bool {
        guard let url else { return false }
        return opener(url)
    }
    func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = L("请我喝杯咖啡")
        alert.informativeText = L("如果 Ez Audio Control 让你每天调音量少一点折腾，欢迎请我喝杯咖啡，支持兼容性测试和持续维护。赞助完全自愿，所有功能都可以使用。外部网站和支付服务适用其各自的隐私政策。")
        alert.addButton(withTitle: L("关闭"))
        if let url {
            alert.addButton(withTitle: L("打开赞助网站"))
            alert.informativeText += "\n\n" + (url.host ?? "")
        }
        if !codes.isEmpty {
            // Vertical scrolling keeps two full-size, scannable codes usable on small screens.
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 270, height: 270))
            scroll.hasVerticalScroller = true
            let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 12
            stack.alignment = .centerX
            for code in codes {
                let title = NSTextField(labelWithString: code.label)
                let image = NSImageView(); image.image = code.image; image.imageScaling = .scaleProportionallyUpOrDown
                image.setAccessibilityElement(true); image.setAccessibilityRole(.image)
                image.setAccessibilityLabel(L("\(code.label) 收款二维码"))
                image.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([image.widthAnchor.constraint(equalToConstant: 220), image.heightAnchor.constraint(equalToConstant: 220)])
                stack.addArrangedSubview(title); stack.addArrangedSubview(image)
            }
            stack.frame = NSRect(x: 0, y: 0, width: 250, height: CGFloat(codes.count * 262))
            scroll.documentView = stack; alert.accessoryView = scroll
        }
        return alert
    }
}
