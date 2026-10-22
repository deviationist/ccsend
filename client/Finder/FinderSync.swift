import Cocoa
import FinderSync

/// Finder extension: "Import from <host>" in the right-click menu of the
/// Desktop and of empty space in folders (Quick Actions can't appear there).
///
/// Sandboxed. It reads only ~/.config/ccsend/finder-menu.json, which
/// `ccsend install` writes from the config (titles and host names of
/// import-enabled hosts), and on a click starts ccsend.app with the folder.
/// It never connects anywhere or touches files itself.
final class FinderSync: FIFinderSync {
    struct Item: Decodable { let title: String; let host: String }
    struct Menu: Decodable { let items: [Item]; let token: String }

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    /// The real home, not the sandbox container's.
    private static var home: String {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return NSHomeDirectory() }
        return String(cString: dir)
    }

    private var token = ""

    private func load() -> [Item] {
        let path = FinderSync.home + "/.config/ccsend/finder-menu.json"
        guard let data = FileManager.default.contents(atPath: path), data.count < 64 << 10,
              let menu = try? JSONDecoder().decode(Menu.self, from: data) else {
            NSLog("ccsend: cannot read %@", path)
            return []
        }
        token = menu.token
        // Host names go into the URL; accept only plain identifiers.
        return menu.items.prefix(20).filter { i in
            !i.title.isEmpty && i.title.count <= 60 &&
                (i.host.isEmpty || i.host.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,252}$", options: .regularExpression) != nil)
        }
    }

    override func menu(for kind: FIMenuKind) -> NSMenu? {
        guard kind == .contextualMenuForContainer else { return nil }
        let items = load()
        guard !items.isEmpty else { return nil }
        let menu = NSMenu(title: "")
        for (i, it) in items.enumerated() {
            let m = NSMenuItem(title: it.title, action: #selector(importHere(_:)), keyEquivalent: "")
            m.tag = i
            m.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)
            menu.addItem(m)
        }
        return menu
    }

    @objc func importHere(_ sender: NSMenuItem) {
        let items = load()
        guard items.indices.contains(sender.tag) else { return }
        let item = items[sender.tag]
        let folder = FIFinderSyncController.default().targetedURL()?.path ?? (FinderSync.home + "/Desktop")
        // A sandboxed extension can't pass launch arguments, so it opens a ccsend:// URL.
        // The token proves the request came from here (it is only in finder-menu.json).
        var c = URLComponents()
        c.scheme = "ccsend"
        c.host = "import"
        c.queryItems = [URLQueryItem(name: "host", value: item.host), URLQueryItem(name: "dir", value: folder),
                        URLQueryItem(name: "token", value: token)]
        guard let url = c.url else { return }
        // ccsend.app/Contents/PlugIns/<this>.appex → ccsend.app, so the URL goes to this copy.
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: cfg) { _, err in
            if let err { NSLog("ccsend: cannot open ccsend: %@", "\(err)") }
        }
    }
}
