import AppKit
import SwiftUI

/// `ccsend ui [--host HOST] [--] FILE...`: the send window.
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

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate

        do {
            guard !files.isEmpty else { throw RemoteError("select one or more files or folders in Finder first") }
            let config = try Config.load()
            let host = try hostName.map(config.host) ?? config.hosts[0]
            delegate.model = SendModel(config: config, host: host, files: files)
        } catch {
            // No window to put it in yet: a plain alert, then quit.
            app.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "ccsend"
            alert.informativeText = Display.sentence("\(error)")
            alert.runModal()
            exit(1)
        }
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: SendModel!
    var window: NSWindow!

    func applicationDidFinishLaunching(_ n: Notification) {
        let view = NSHostingView(rootView: SendView(model: model))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 380),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ccsend"
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
    func applicationWillTerminate(_ n: Notification) { model?.close() }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}
