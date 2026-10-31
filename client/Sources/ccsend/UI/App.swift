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
        return Paths.home.appendingPathComponent("Desktop").path
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
        // The window follows the view's size: it grows when sessions, notes or
        // completions appear (a fixed size cut off the buttons once they loaded).
        let snapshotPath = ProcessInfo.processInfo.environment["CCSEND_SNAPSHOT"]
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = [.preferredContentSize]
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 380),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = title
        window.contentViewController = controller
        window.delegate = self
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.setContentSize(controller.view.fittingSize)
        window.center()
        if let out = snapshotPath {
            // Quiet: invisible and never takes focus (cacheDisplay draws it anyway).
            window.level = .normal
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.orderBack(nil)
            snapshot(to: out)
            return
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Testing aid: render the window to PNGs (no Screen Recording permission needed).
    private func snapshot(to path: String) {
        // cacheDisplay skips the window background; paint it in the window's own appearance.
        window.contentView?.wantsLayer = true
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            window.contentView?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        let env = ProcessInfo.processInfo.environment
        let times = (env["CCSEND_SNAPSHOT_AT"] ?? "2,5").split(separator: ",").compactMap { Double($0) }
        let framed = env["CCSEND_SNAPSHOT_FRAME"] == "1"
        for (i, delay) in times.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let v = self.window.contentView,
                      let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                let out = framed ? (self.framedSnapshot(content: rep) ?? rep) : rep
                try? out.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(path)-\(i).png"))
                // The window is invisible: never leave it running after the last one.
                if i == times.count - 1 { NSApp.terminate(nil) }
            }
        }
    }

    /// CCSEND_SNAPSHOT_FRAME=1 (README images): the content under the window's own
    /// title bar, with rounded corners and a drop shadow, on a transparent margin.
    /// cacheDisplay on the frame view draws the title bar but misplaces the
    /// content, so the two are cached separately and stacked here.
    private func framedSnapshot(content: NSBitmapImageRep) -> NSBitmapImageRep? {
        guard let frameView = window.contentView?.superview,
              let barRep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return nil }
        frameView.cacheDisplay(in: frameView.bounds, to: barRep)
        let size = frameView.bounds.size, contentH = window.contentView!.bounds.height
        let margin: CGFloat = 40, radius: CGFloat = 10
        let scale = CGFloat(content.pixelsWide) / window.contentView!.bounds.width
        let canvas = NSSize(width: size.width + 2 * margin, height: size.height + 2 * margin)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        out.size = canvas
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        let win = NSRect(x: margin, y: margin, width: size.width, height: size.height)
        let shape = NSBezierPath(roundedRect: win, xRadius: radius, yRadius: radius)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 22
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        window.effectiveAppearance.performAsCurrentDrawingAppearance { NSColor.windowBackgroundColor.setFill() }
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        // Only the title bar strip (the top of the frame view's image) is used.
        let barH = size.height - contentH
        if let full = barRep.cgImage,
           let strip = full.cropping(to: CGRect(x: 0, y: 0, width: CGFloat(full.width), height: barH * CGFloat(full.height) / size.height)) {
            NSImage(cgImage: strip, size: NSSize(width: size.width, height: barH))
                .draw(in: NSRect(x: margin, y: margin + contentH, width: size.width, height: barH))
            // A window that isn't key draws grey traffic lights; paint the active ones.
            for (i, hex) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
                let c = NSColor(red: CGFloat(hex >> 16) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
                c.setFill()
                let cx = margin + 14 + CGFloat(i) * 20, cy = margin + contentH + barH / 2
                NSBezierPath(ovalIn: NSRect(x: cx - 6.5, y: cy - 6.5, width: 13, height: 13)).fill()
            }
        }
        content.draw(in: NSRect(x: margin, y: margin, width: size.width, height: contentH))
        NSColor(white: 0.5, alpha: 0.35).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    func windowWillClose(_ n: Notification) { NSApp.terminate(nil) }
    func applicationWillTerminate(_ n: Notification) { onClose() }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}
