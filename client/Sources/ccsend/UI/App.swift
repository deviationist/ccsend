import AppKit
import SwiftUI

/// The windows: `ccsend ui [--host H] -- FILE...` (send) and
/// `ccsend ui-import --host H [--to DIR | --finder] [-- ITEM...]` (import).
enum UI {
    static func run(_ args: [String]) throws {
        var rest = args, hostName: String?
        while let a = rest.first, a != "--" {
            guard a == "--host", rest.count >= 2 else { break }
            hostName = rest[1]
            rest.removeFirst(2)
        }
        if rest.first == "--" { rest.removeFirst() }
        let files = rest.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        start(title: "ccsend") {
            guard !files.isEmpty else { throw RemoteError("select one or more files or folders in Finder first") }
            let config = try Config.load()
            let host = try hostName.map(config.host) ?? config.hosts[0]
            let model = SendModel(config: config, host: host, files: files)
            return (AnyView(SendView(model: model)), model.close)
        }
    }

    static func runImport(_ args: [String]) throws {
        var rest = args, hostName: String?, to: String?, finder = false
        while let a = rest.first, a != "--" {
            if a == "--host", rest.count >= 2 { hostName = rest[1]; rest.removeFirst(2) }
            else if a == "--to", rest.count >= 2 { to = rest[1]; rest.removeFirst(2) }
            else if a == "--finder" { finder = true; rest.removeFirst() }
            else { break }
        }
        if rest.first == "--" { rest.removeFirst() }
        start(title: "ccsend import") {
            let config = try Config.load()
            let host = try hostName.map(config.host) ?? (config.hosts.first(where: \.importEnabled) ?? config.hosts[0])
            guard host.importEnabled else { throw RemoteError("import is off for \(host.name); set import = true in its config") }
            let dest = try destination(items: rest, to: to, finder: finder)
            let model = ImportModel(config: config, host: host, dest: dest)
            return (AnyView(ImportView(model: model)), model.close)
        }
    }

    /// Where an import lands: --to, else the selected folder (a selected file's
    /// folder), else the front Finder window, else the Desktop.
    static func destination(items: [String], to: String?, finder: Bool) throws -> String {
        let fm = FileManager.default
        func folder(_ p: String) -> String? {
            var d: ObjCBool = false
            let path = URL(fileURLWithPath: p).standardizedFileURL.path
            guard fm.fileExists(atPath: path, isDirectory: &d) else { return nil }
            return d.boolValue ? path : (path as NSString).deletingLastPathComponent
        }
        if let to, let f = folder(to) { return f }
        if let first = items.first, let f = folder(first) { return f }
        if finder {
            let script = NSAppleScript(source: """
            tell application "Finder"
                if (count of Finder windows) > 0 then return POSIX path of (target of front Finder window as alias)
            end tell
            return ""
            """)
            var err: NSDictionary?
            if let p = script?.executeAndReturnError(&err).stringValue, !p.isEmpty, let f = folder(p) { return f }
        }
        return fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path
    }

    /// Launched by the Finder extension with a ccsend://import URL (no arguments).
    /// The URL must carry the token from finder-menu.json; anything else is ignored.
    static func runURL() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        delegate.title = "ccsend import"
        delegate.urlHandler = { url in
            guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "ccsend", c.host == "import" else {
                throw RemoteError("unsupported link")
            }
            func q(_ n: String) -> String? { c.queryItems?.first(where: { $0.name == n })?.value }
            let want = Data((FinderMenu.token() ?? "").utf8), got = Data((q("token") ?? "").utf8)
            guard want.count == 64, got.count == want.count, zip(want, got).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 else {
                Log.event([("event", "url"), ("result", "refused"), ("error", "bad-token")])
                throw RemoteError("ignored a ccsend link that did not come from the Finder extension")
            }
            let config = try Config.load()
            let hostName = q("host") ?? ""
            let host = hostName.isEmpty ? (config.hosts.first(where: \.importEnabled) ?? config.hosts[0]) : try config.host(hostName)
            guard host.importEnabled else { throw RemoteError("import is off for \(host.name); set import = true in its config") }
            guard let dir = q("dir"), dir.hasPrefix("/") else { throw RemoteError("no folder in the link") }
            let dest = try destination(items: [], to: dir, finder: false)
            let model = ImportModel(config: config, host: host, dest: dest)
            return (AnyView(ImportView(model: model)), model.close)
        }
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    private static func start(title: String, _ make: @escaping () throws -> (AnyView, () -> Void)) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        do {
            let (view, close) = try make()
            delegate.root = view
            delegate.onClose = close
            delegate.title = title
        } catch {
            // No window to put it in yet: a plain alert, then quit.
            app.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "ccsend"
            alert.informativeText = Display.sentence("\(error)")
            alert.runModal()
            exit(1)
        }
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var root: AnyView?
    var onClose: () -> Void = {}
    var title = "ccsend"
    var window: NSWindow!
    /// Set when launched for a URL: builds the window from it.
    var urlHandler: ((URL) throws -> (AnyView, () -> Void))?

    func application(_ app: NSApplication, open urls: [URL]) {
        guard window == nil, let handler = urlHandler, let url = urls.first else { return }
        do {
            let (view, close) = try handler(url)
            root = view
            onClose = close
            show()
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "ccsend"
            alert.informativeText = Display.sentence("\(error)")
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        if root != nil { show(); return }
        // Waiting for a URL; quit if none arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { if self.window == nil { NSApp.terminate(nil) } }
    }

    private func show() {
        guard let root else { return }
        let view = NSHostingView(rootView: root)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 380),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = title
        window.contentView = view
        window.delegate = self
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.setContentSize(view.fittingSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let out = ProcessInfo.processInfo.environment["CCSEND_SNAPSHOT"] { snapshot(to: out) }
    }

    /// Testing aid: render the window to PNGs (no Screen Recording permission needed).
    private func snapshot(to path: String) {
        // cacheDisplay skips the window background; paint it in the window's own appearance.
        window.contentView?.wantsLayer = true
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            window.contentView?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        let times = (ProcessInfo.processInfo.environment["CCSEND_SNAPSHOT_AT"] ?? "2,5")
            .split(separator: ",").compactMap { Double($0) }
        for (i, delay) in times.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let v = self.window.contentView,
                      let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(path)-\(i).png"))
            }
        }
    }

    func windowWillClose(_ n: Notification) { NSApp.terminate(nil) }
    func applicationWillTerminate(_ n: Notification) { onClose() }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}
