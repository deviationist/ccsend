import AppKit
import SwiftUI

// Every string that came from the host is rendered with Text(verbatim:) so
// SwiftUI never interprets it as Markdown or a localization key.

struct SendView: View {
    @ObservedObject var model: SendModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if model.config.menu == .single && model.config.hosts.count > 1 { hostPicker }
            destinationSection
            if model.plan?.hasFolders == true { folderSection }
            warnings
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 18)
        .frame(width: 600)
        .frame(minHeight: 360)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "Send").font(.headline)
            Flow(spacing: 6) {
                ForEach(Array(model.files.prefix(8).enumerated()), id: \.offset) { _, f in chip(f) }
                if model.files.count > 8 {
                    Text(verbatim: "+\(model.files.count - 8) more").font(.callout).foregroundStyle(.secondary)
                }
            }
            if let p = model.plan {
                Text(verbatim: "Total: " + summary(p)).font(.callout).foregroundStyle(.secondary)
            } else if let e = model.planError {
                Text(verbatim: Display.sentence(e)).font(.callout).foregroundStyle(.red)
            }
        }
    }

    /// One item to send: icon + exact name in monospace on a tinted background;
    /// folders also show how many files and bytes of them will be sent.
    private func chip(_ path: String) -> some View {
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        let name = (path as NSString).lastPathComponent
        var detail = ""
        if isDir.boolValue, let st = model.plan?.stats(name) {
            detail = "\(st.files) file\(st.files == 1 ? "" : "s") · " + ByteCountFormatter.string(fromByteCount: st.bytes, countStyle: .file)
        }
        return HStack(spacing: 5) {
            Image(systemName: isDir.boolValue ? "folder.fill" : "doc.fill")
                .foregroundStyle(isDir.boolValue ? Color.accentColor : .secondary)
            Text(verbatim: name + (isDir.boolValue ? "/" : ""))
                .font(.system(.body, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
            if !detail.isEmpty {
                Text(verbatim: detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.15)))
        .help(path)
    }

    private func summary(_ p: Plan) -> String {
        var s = "\(p.files) file\(p.files == 1 ? "" : "s"), \(ByteCountFormatter.string(fromByteCount: p.bytes, countStyle: .file))"
        var skipped: [String] = []
        if p.skippedHidden > 0 { skipped.append("\(p.skippedHidden) hidden") }
        if p.skippedExcluded > 0 { skipped.append("\(p.skippedExcluded) excluded") }
        if p.skippedSpecial > 0 { skipped.append("\(p.skippedSpecial) special") }
        if !skipped.isEmpty { s += " · skipping " + skipped.joined(separator: ", ") }
        return s
    }

    private var hostPicker: some View {
        Picker("Host", selection: Binding(get: { model.host.name },
                                          set: { n in if let h = model.config.hosts.first(where: { $0.name == n }) { model.host = h } })) {
            ForEach(model.config.hosts, id: \.name) { h in Text(verbatim: h.label).tag(h.name) }
        }
        .pickerStyle(.segmented)
        .disabled(model.phase == .sending)
    }

    @ViewBuilder private var destinationSection: some View {
        GroupBox {
            switch model.phase {
            case .connecting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: "Connecting to \(model.host.label)…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(6)
            case .failed(let e):
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: Display.sentence(e)).foregroundStyle(.red).textSelection(.enabled)
                    Button("Retry") { model.connect() }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(6)
            default:
                if model.destinations.isEmpty {
                    Text(verbatim: "No destinations: no sessions found, and the default location and custom path are turned off for this host.")
                        .foregroundStyle(.secondary).padding(6)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.destinations) { d in row(d) }
                    }
                    .padding(.vertical, 2)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: "Destination on \(model.host.label)")
                Spacer()
                if let t = model.updatedAt {
                    Text(verbatim: "Updated " + t.formatted(date: .omitted, time: .standard))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Button { model.refresh() } label: {
                    if model.refreshing {
                        ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("r", modifiers: .command)
                .help(model.config.refreshSeconds > 0
                      ? "Refresh now (⌘R). Refreshes every \(model.config.refreshSeconds) s."
                      : "Refresh now (⌘R)")
                .disabled(model.phase != .ready || model.refreshing)
            }
        }
        if !model.notice.isEmpty {
            Label { Text(verbatim: model.notice) } icon: { Image(systemName: "info.circle") }
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func row(_ d: SendModel.Destination) -> some View {
        let isSelected = model.selected == d.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                switch d.kind {
                case .session(let s):
                    Text(verbatim: s.kind == .claude ? "Claude" : "Shell").frame(width: 56, alignment: .leading).bold()
                    Text(verbatim: model.tilde(s.cwd)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(verbatim: [s.tmux.isEmpty ? (s.kind == .shell ? "SSH session" : "") : "tmux \(s.tmux)", stamp(s.started)]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                case .defaultLocation:
                    Text(verbatim: "Default").frame(width: 56, alignment: .leading).bold()
                    Text(verbatim: model.host.defaultLocation)
                    Spacer()
                    Text(verbatim: "Created if missing").font(.caption).foregroundStyle(.secondary)
                case .path:
                    Text(verbatim: "Path").frame(width: 56, alignment: .leading).bold()
                    PathField(model: model, onFocus: { model.selected = "path" })
                        .frame(height: 22)
                    Text(verbatim: "Tab completes").font(.caption).foregroundStyle(.secondary)
                }
            }
            if d.kind == .path && isSelected { completions }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(isSelected ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { model.selected = d.id }
    }

    @ViewBuilder private var completions: some View {
        if !model.completionNote.isEmpty {
            Text(verbatim: Display.sentence(model.completionNote)).font(.caption).foregroundStyle(.red).padding(.leading, 72)
        }
        if !model.candidates.isEmpty {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 2) {
                    ForEach(model.candidates, id: \.self) { e in
                        Button { model.pick(e) } label: {
                            Text(verbatim: e.name + (e.isDir ? "/" : "")).font(.system(.caption, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 90)
            .padding(.leading, 72)
        }
    }

    private var folderSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: $model.includeHidden) { Text(verbatim: "Include hidden files") }
                Toggle(isOn: $model.applyExcludes) {
                    Text(verbatim: "Exclude common files (" + model.config.excludes.prefix(5).joined(separator: ", ")
                         + (model.config.excludes.count > 5 ? ", …)" : ")"))
                        .lineLimit(1).truncationMode(.tail)
                }
                .help(model.config.excludes.joined(separator: ", "))
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(4)
        } label: {
            Text(verbatim: "Folders")
        }
        .disabled(model.phase == .sending)
    }

    @ViewBuilder private var warnings: some View {
        if let p = model.plan, !p.sensitive.isEmpty {
            Label {
                Text(verbatim: "Sensitive-looking files will be sent: " + p.sensitive.prefix(5).joined(separator: ", ")
                     + (p.sensitive.count > 5 ? " and \(p.sensitive.count - 5) more" : ""))
            } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            .font(.callout)
        }
        if model.overLimit {
            Label {
                Text(verbatim: "Over the configured limits (\(model.config.maxTotalMB) MB, \(model.config.maxFiles) files)."
                     + (model.overLimitConfirmed ? " Press Send again to send anyway." : ""))
            } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            .font(.callout)
        }
        if let e = model.sendError {
            Text(verbatim: Display.sentence(e)).foregroundStyle(.red).font(.callout).textSelection(.enabled)
        }
    }

    private var footer: some View {
        HStack {
            switch model.phase {
            case .sending:
                ProgressView(value: model.progress).frame(width: 220)
                Text(verbatim: "Sending…").foregroundStyle(.secondary)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(verbatim: "Sent. Path copied to the clipboard.").lineLimit(1)
            default:
                EmptyView()
            }
            Spacer()
            Button("Cancel") { NSApp.terminate(nil) }
                .keyboardShortcut(.cancelAction)
                .disabled(model.phase == .sending || model.phase == .done)
            Button(model.overLimit && model.overLimitConfirmed ? "Send anyway" : "Send") { model.send() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSend)
        }
    }
}

/// Left-to-right wrapping layout for the item chips.
struct Flow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.init(width: bounds.width, height: nil))
                let w = min(size.width, bounds.width)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: .init(width: w, height: size.height))
                x += w + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var cur: (items: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.init(width: width, height: nil))
            let w = min(s.width, width)
            if !cur.items.isEmpty && cur.width + spacing + w > width {
                rows.append(cur)
                cur = ([], 0, 0)
            }
            cur.width += (cur.items.isEmpty ? 0 : spacing) + w
            cur.items.append(i)
            cur.height = max(cur.height, s.height)
        }
        if !cur.items.isEmpty { rows.append(cur) }
        return rows
    }
}

/// NSTextField with Tab handed to the model for completion.
struct PathField: NSViewRepresentable {
    @ObservedObject var model: SendModel
    var onFocus: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        f.placeholderString = "~/path/on/host"
        f.delegate = context.coordinator
        f.isBordered = true
        f.bezelStyle = .roundedBezel
        f.focusRingType = .default
        f.lineBreakMode = .byTruncatingHead
        f.cell?.isScrollable = true
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        if f.stringValue != model.path {
            f.stringValue = model.path
            // Keep the caret at the end after a completion.
            if let editor = f.currentEditor() { editor.selectedRange = NSRange(location: (model.path as NSString).length, length: 0) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: PathField
        init(_ p: PathField) { parent = p }

        func controlTextDidBeginEditing(_ obj: Notification) { parent.onFocus() }

        func controlTextDidChange(_ obj: Notification) {
            guard let f = obj.object as? NSTextField else { return }
            parent.model.path = f.stringValue
            parent.model.candidates = []
            parent.model.completionNote = ""
            parent.onFocus()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertTab(_:)) {
                parent.onFocus()
                parent.model.complete()
                return true
            }
            return false
        }
    }
}
