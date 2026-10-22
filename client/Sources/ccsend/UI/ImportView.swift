import AppKit
import SwiftUI

// Names and paths from the host are rendered with Text(verbatim:) only.

struct ImportView: View {
    @ObservedObject var model: ImportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.config.menu == .single && model.config.hosts.filter(\.importEnabled).count > 1 {
                Picker("Host", selection: Binding(get: { model.host.name }, set: { n in
                    if let h = model.config.hosts.first(where: { $0.name == n }) { model.host = h }
                })) {
                    ForEach(model.config.hosts.filter(\.importEnabled), id: \.name) { h in Text(verbatim: h.label).tag(h.name) }
                }
                .pickerStyle(.segmented)
                .disabled(model.phase == .importing)
            }
            browser
            options
            status
            footer
        }
        .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 18)
        .frame(width: 640)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(verbatim: "Import from \(model.host.label) into").font(.headline)
            HStack(spacing: 5) {
                Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                Text(verbatim: model.localDestLabel + "/").font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.15)))
            .help(model.dest)
            Spacer()
        }
    }

    @ViewBuilder private var browser: some View {
        GroupBox {
            switch model.phase {
            case .connecting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: "Connecting to \(model.host.label)…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            case .failed(let e):
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: Display.sentence(e)).foregroundStyle(.red).textSelection(.enabled)
                    Button("Retry") { model.connect() }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(6)
            default:
                VStack(alignment: .leading, spacing: 8) {
                    navigation
                    if !model.completionNote.isEmpty {
                        Text(verbatim: Display.sentence(model.completionNote)).font(.caption).foregroundStyle(.red)
                    }
                    if !model.candidates.isEmpty { candidates }
                    listing
                }
                .padding(4)
            }
        } label: {
            Text(verbatim: "Files on \(model.host.label)")
        }
    }

    private var navigation: some View {
        HStack(spacing: 6) {
            Button { model.up() } label: { Image(systemName: "chevron.up") }
                .disabled(model.parent.isEmpty || model.loading)
                .help("Parent folder")
            PathField(text: model.path,
                      onEdit: { model.path = $0; model.candidates = []; model.completionNote = "" },
                      onTab: { model.complete() },
                      onSubmit: { model.go(model.path) })
                .frame(height: 22)
            Menu {
                ForEach(Array(model.shortcuts.enumerated()), id: \.offset) { _, s in
                    Button { model.go(s.path) } label: { Text(verbatim: s.label) }
                }
            } label: {
                Text(verbatim: "Go to")
            }
            .fixedSize()
            Button { model.reload() } label: {
                if model.loading { ProgressView().controlSize(.mini).frame(width: 14, height: 14) } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("r", modifiers: .command)
            .help("Reload (⌘R)")
        }
    }

    private var candidates: some View {
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
        .frame(maxHeight: 70)
    }

    @ViewBuilder private var listing: some View {
        if !model.listError.isEmpty {
            Text(verbatim: model.listError).foregroundStyle(.red).font(.callout)
        }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.entries.isEmpty && !model.loading {
                    Text(verbatim: "This folder is empty.").foregroundStyle(.secondary).padding(8)
                }
                ForEach(model.entries) { e in row(e) }
            }
        }
        .frame(height: 260)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
        HStack {
            Button("Select all") { model.selectAll() }.buttonStyle(.link)
            Button("Select none") { model.selection = [] }.buttonStyle(.link)
            Spacer()
            Text(verbatim: "Double-click a folder to open it").font(.caption).foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func row(_ e: Remote.RemoteEntry) -> some View {
        let on = model.selection.contains(e.name), can = model.selectable(e)
        return HStack(spacing: 8) {
            Image(systemName: on ? "checkmark.square.fill" : "square")
                .foregroundStyle(on ? Color.accentColor : .secondary)
                .opacity(can ? 1 : 0.3)
            Image(systemName: e.kind == .dir ? "folder.fill" : e.kind == .link ? "link" : e.kind == .other ? "questionmark.square.dashed" : "doc")
                .foregroundStyle(e.kind == .dir ? Color.accentColor : .secondary)
                .frame(width: 16)
            Text(verbatim: e.name + (e.kind == .dir ? "/" : "")).font(.system(.body, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(can ? .primary : .secondary)
            Spacer()
            if e.kind == .file {
                Text(verbatim: ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(verbatim: stamp(e.mtime)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(on ? Color.accentColor.opacity(0.10) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.open(e) }
        .onTapGesture { model.toggle(e) }
        .help(can ? "" : (e.kind == .link ? "Symbolic links are skipped (turn on Keep symbolic links)" : "Special files are never imported"))
    }

    private var options: some View {
        HStack(spacing: 16) {
            Toggle(isOn: $model.includeHidden) { Text(verbatim: "Include hidden files") }
            Toggle(isOn: $model.applyExcludes) { Text(verbatim: "Exclude common files") }
                .help(model.config.excludes.joined(separator: ", "))
            Toggle(isOn: $model.keepLinks) { Text(verbatim: "Keep symbolic links") }
                .help("Copy symlinks as links instead of skipping them. Off is safer: a link points at a path, and on your Mac that path may be something else.")
        }
        .disabled(model.phase == .importing || model.phase == .done)
    }

    @ViewBuilder private var status: some View {
        if model.selection.isEmpty {
            Text(verbatim: "Select files or folders to import.").font(.callout).foregroundStyle(.secondary)
        } else if model.planning {
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(verbatim: "Counting…").font(.callout).foregroundStyle(.secondary) }
        } else if let p = model.plan {
            Text(verbatim: summary(p)).font(.callout).foregroundStyle(.secondary)
        }
        if model.overLimit {
            Label {
                Text(verbatim: "Over the configured limits (\(model.config.maxTotalMB) MB, \(model.config.maxFiles) files)."
                     + (model.overLimitConfirmed ? " Press Import again to import anyway." : ""))
            } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            .font(.callout)
        }
        if let e = model.importError {
            Text(verbatim: Display.sentence(e)).foregroundStyle(.red).font(.callout).textSelection(.enabled)
        }
    }

    private func summary(_ p: Remote.DownloadPlan) -> String {
        var s = "\(model.selection.count) selected · \(p.files) file\(p.files == 1 ? "" : "s"), "
            + ByteCountFormatter.string(fromByteCount: p.bytes, countStyle: .file)
        var skipped: [String] = []
        if p.skippedHidden > 0 { skipped.append("\(p.skippedHidden) hidden") }
        if p.skippedExcluded > 0 { skipped.append("\(p.skippedExcluded) excluded") }
        if p.skippedLinks > 0 { skipped.append("\(p.skippedLinks) link\(p.skippedLinks == 1 ? "" : "s")") }
        if p.skippedSpecial > 0 { skipped.append("\(p.skippedSpecial) special") }
        if !skipped.isEmpty { s += " · skipping " + skipped.joined(separator: ", ") }
        return s
    }

    private var footer: some View {
        HStack {
            switch model.phase {
            case .importing:
                ProgressView(value: model.progress).frame(width: 220)
                Text(verbatim: "Importing…").foregroundStyle(.secondary)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(verbatim: model.dest.hasSuffix("/Desktop") ? "Imported to the Desktop." : "Imported. Showing in Finder.").lineLimit(1)
            default:
                EmptyView()
            }
            Spacer()
            Button("Cancel") { NSApp.terminate(nil) }
                .keyboardShortcut(.cancelAction)
                .disabled(model.phase == .importing || model.phase == .done)
            Button(model.overLimit && model.overLimitConfirmed ? "Import anyway" : "Import") { model.start() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canImport)
        }
    }
}
