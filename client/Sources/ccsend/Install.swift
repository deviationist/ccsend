import Foundation

/// `ccsend install`: (re)create the Finder Quick Actions from the config.
///
/// menu = "per-host" → "Send to <label>" per host; menu = "single" → "Send to remote".
/// Each one only runs: open -n -a <ccsend.app> --args ui [--host H] -- <files>.
/// Quick Actions created earlier by ccsend that no longer match the config are removed.
enum Installer {
    static let services = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Services")

    static func appPath() throws -> String {
        let exe = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath().path
        let marker = ".app/Contents/MacOS/"
        guard let r = exe.range(of: marker) else { throw RemoteError("run install from the installed ccsend.app (make install)") }
        let app = String(exe[..<r.lowerBound]) + ".app"
        guard !app.contains("'") else { throw RemoteError("unsupported app path \(app)") }
        return app
    }

    static func install() throws {
        let config = try Config.load()
        let app = try appPath()
        var wanted: [(title: String, args: String)] = []
        switch config.menu {
        case .perHost:
            for h in config.hosts { wanted.append(("Send to \(h.label)", "ui --host \(h.name)")) }
        case .single:
            wanted.append(("Send to remote", "ui"))
        }
        let fm = FileManager.default
        try fm.createDirectory(at: services, withIntermediateDirectories: true)

        // Remove ccsend's own Quick Actions (recognised by their command), then write the wanted ones.
        var removed: [String] = []
        for name in (try? fm.contentsOfDirectory(atPath: services.path)) ?? [] where name.hasSuffix(".workflow") {
            let wf = services.appendingPathComponent(name)
            if isOurs(wf) { try fm.removeItem(at: wf); removed.append(String(name.dropLast(".workflow".count))) }
        }
        for w in wanted {
            let file = w.title.replacingOccurrences(of: "/", with: "-")
            let wf = services.appendingPathComponent("\(file).workflow")
            guard !fm.fileExists(atPath: wf.path) else {
                throw RemoteError("\(wf.path) exists and was not made by ccsend; rename the host label or remove it")
            }
            // Host names are validated identifiers; the app path has no single quote.
            let command = "open -n -a '\(app)' --args \(w.args) -- \"$@\""
            try write(workflow: wf, title: w.title, command: command)
            print("created Quick Action \"\(w.title)\"")
        }
        for r in removed where !wanted.contains(where: { $0.title == r }) { print("removed Quick Action \"\(r)\"") }

        resaveWithAutomator(wanted.map { services.appendingPathComponent("\($0.title.replacingOccurrences(of: "/", with: "-")).workflow").path })
        enable(wanted.map(\.title), disable: removed.filter { r in !wanted.contains(where: { $0.title == r }) })
        _ = try? Proc.run("/System/Library/CoreServices/pbs", ["-flush"], stdin: nil, timeout: 20)
        _ = try? Proc.run("/System/Library/CoreServices/pbs", ["-update"], stdin: nil, timeout: 20)
        print("Finder → right-click → Quick Actions. A keyboard shortcut can be set in System Settings → Keyboard → Keyboard Shortcuts → Services → Files and Folders.")
    }

    /// `ccsend uninstall`: remove only the Quick Actions ccsend created.
    static func uninstall() throws {
        let fm = FileManager.default
        var removed: [String] = []
        for name in (try? fm.contentsOfDirectory(atPath: services.path)) ?? [] where name.hasSuffix(".workflow") {
            let wf = services.appendingPathComponent(name)
            if isOurs(wf) { try fm.removeItem(at: wf); removed.append(String(name.dropLast(".workflow".count))) }
        }
        enable([], disable: removed)
        _ = try? Proc.run("/System/Library/CoreServices/pbs", ["-update"], stdin: nil, timeout: 20)
        for r in removed { print("removed Quick Action \"\(r)\"") }
        if removed.isEmpty { print("no ccsend Quick Actions found") }
    }

    static func isOurs(_ wf: URL) -> Bool {
        guard let d = try? Data(contentsOf: wf.appendingPathComponent("Contents/document.wflow")),
              let s = String(data: d, encoding: .utf8) else { return false }
        return s.contains("ccsend.app' --args ui")
    }

    static func write(workflow wf: URL, title: String, command: String) throws {
        let contents = wf.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["NSServices": [[
            "NSMenuItem": ["default": title],
            "NSMessage": "runWorkflowAsService",
            "NSSendFileTypes": ["public.item"],
            "NSIconName": "NSActionTemplate",
            "NSBackgroundColorName": "background",
        ]]]
        let action: [String: Any] = [
            "AMAccepts": ["Container": "List", "Optional": true, "Types": ["com.apple.cocoa.string"]],
            "AMActionVersion": "2.0.3",
            "AMApplication": ["Automator"],
            "AMParameterProperties": ["COMMAND_STRING": [:], "CheckedForUserDefaultShell": [:], "inputMethod": [:], "shell": [:], "source": [:]],
            "AMProvides": ["Container": "List", "Types": ["com.apple.cocoa.string"]],
            "ActionBundlePath": "/System/Library/Automator/Run Shell Script.action",
            "ActionName": "Run Shell Script",
            "ActionParameters": ["COMMAND_STRING": command, "CheckedForUserDefaultShell": true,
                                 "inputMethod": 1, "shell": "/bin/zsh", "source": ""],
            "BundleIdentifier": "com.apple.RunShellScript",
            "CFBundleVersion": "2.0.3",
            "CanShowSelectedItemsWhenRun": false,
            "CanShowWhenRun": true,
            "Category": ["AMCategoryUtilities"],
            "Class Name": "RunShellScriptAction",
            "InputUUID": UUID().uuidString, "OutputUUID": UUID().uuidString, "UUID": UUID().uuidString,
            "Keywords": ["Shell"],
            "UnlocalizedApplications": ["Automator"],
            "arguments": [:],
            "isViewVisible": 1,
            "location": "309.5:253.0",
        ]
        let doc: [String: Any] = [
            "AMApplicationBuild": "528", "AMApplicationVersion": "2.10", "AMDocumentVersion": "2",
            "actions": [["action": action, "isViewVisible": 1]],
            "connectors": [:],
            "workflowMetaData": [
                "applicationBundleIDsByPath": [:], "applicationPaths": [],
                "inputTypeIdentifier": "com.apple.Automator.fileSystemObject",
                "outputTypeIdentifier": "com.apple.Automator.nothing",
                "presentationMode": 15, "processesInput": false,
                "serviceApplicationBundleID": "com.apple.finder",
                "serviceApplicationPath": "/System/Library/CoreServices/Finder.app",
                "serviceInputTypeIdentifier": "com.apple.Automator.fileSystemObject",
                "serviceOutputTypeIdentifier": "com.apple.Automator.nothing",
                "serviceProcessesInput": false,
                "systemImageName": "NSActionTemplate",
                "useAutomaticInputType": false,
                "workflowTypeIdentifier": "com.apple.Automator.servicesMenu",
            ],
        ]
        for (name, obj) in [("Info.plist", info), ("document.wflow", doc)] {
            let data = try PropertyListSerialization.data(fromPropertyList: obj, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent(name))
        }
    }

    /// Finder only lists Quick Actions saved by Automator itself; have it open and save each one.
    static func resaveWithAutomator(_ paths: [String]) {
        for p in paths {
            let script = ["on run argv", "tell application \"Automator\"", "set d to open (POSIX file (item 1 of argv))",
                          "save d", "close d", "end tell", "end run"]
            var a: [String] = []
            for l in script { a += ["-e", l] }
            let r = try? Proc.run("/usr/bin/osascript", a + [p], stdin: nil, timeout: 30)
            if r?.status != 0 { print("note: Automator could not re-save \(p); open and save it in Automator once") }
        }
        _ = try? Proc.run("/usr/bin/osascript", ["-e", "tell application \"Automator\" to quit"], stdin: nil, timeout: 10)
    }

    /// Show them in Finder's context menu (hand-made services start disabled).
    static func enable(_ titles: [String], disable: [String]) {
        let key = "NSServicesStatus" as CFString, domain = "pbs" as CFString
        var status = (CFPreferencesCopyAppValue(key, domain) as? [String: Any]) ?? [:]
        let on: [String: Any] = ["enabled_context_menu": true, "enabled_services_menu": true,
                                 "presentation_modes": ["ContextMenu": true, "ServicesMenu": true, "FinderPreview": true, "TouchBar": true]]
        for t in titles { status["(null) - \(t) - runWorkflowAsService"] = on }
        for t in disable { status.removeValue(forKey: "(null) - \(t) - runWorkflowAsService") }
        CFPreferencesSetAppValue(key, status as CFDictionary, domain)
        CFPreferencesAppSynchronize(domain)
    }
}
