import SwiftUI
import SweepwellKit

struct JunkView: View {
    @Environment(AppModel.self) private var app
    @State private var focusedKind: JunkKind?
    @State private var confirming = false

    var body: some View {
        let model = app.junk
        ModuleScaffold(module: .junk) {
            switch model.phase {
            case .idle:
                IdleView(module: .junk, headline: "Clear out what your Mac can rebuild",
                         details: ["App caches, logs and crash reports",
                                   "Xcode build data and developer tool downloads",
                                   "Incomplete downloads, Mail copies and the Trash"]) { model.scan() }
            case .scanning:
                ScanningView(module: .junk, control: model.control, title: "Looking for junk…")
            case .working:
                VStack(spacing: 14) { ProgressView().controlSize(.large); Text("Cleaning…").foregroundStyle(.secondary) }
            case .results, .finished:
                if model.groups.isEmpty {
                    VStack(spacing: 0) {
                        if let report = model.report {
                            ReportBanner(report: report, mode: model.reportMode, tint: Module.junk.accent) { model.report = nil }
                        }
                        EmptyResultView(module: .junk, title: "Spotless",
                                        message: "There is no junk worth removing right now.") { model.scan() }
                    }
                } else {
                    resultsBody(model)
                }
            }
        } footer: {
            if model.phase == .results || model.phase == .finished, !model.groups.isEmpty {
                ActionBar(module: .junk, actionTitle: actionTitle("Clean", model.selectedSize),
                          enabled: model.selectedSize > 0 && model.phase != .working) { confirming = true } leading: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(Format.bytes(model.totalSize)) found").font(.callout.weight(.semibold))
                        Text("\(model.selectedItems.count) items selected").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Scan Again") { model.scan() }.buttonStyle(PillButtonStyle())
                }
            }
        }
        .confirmationDialog(confirmTitle(model), isPresented: $confirming) {
            Button(Preferences.removalMode == .trash ? "Move to Trash" : "Delete Permanently", role: .destructive) {
                if model.phase == .finished { model.phase = .results }
                model.clean()
            }
        } message: {
            Text(confirmMessage(model))
        }
    }

    private func confirmTitle(_ model: JunkModel) -> String {
        "Clean \(Format.bytes(model.selectedSize)) of junk?"
    }

    private func confirmMessage(_ model: JunkModel) -> String {
        let includesTrash = model.selectedItems.contains { $0.kind == .trash }
        var text = Preferences.removalMode == .trash
            ? "Selected items are moved to the Trash, so you can still put them back."
            : "Selected items are deleted immediately. This cannot be undone."
        if includesTrash { text += " Items that are already in the Trash are deleted for good." }
        return text
    }

    private func resultsBody(_ model: JunkModel) -> some View {
        let focused = model.groups.first { $0.kind == focusedKind } ?? model.groups[0]
        return VStack(spacing: 0) {
            if let report = model.report {
                ReportBanner(report: report, mode: model.reportMode, tint: Module.junk.accent) { model.report = nil }
            }
            HStack(spacing: 14) {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.groups) { group in
                            GroupRow(group: group, isFocused: group.kind == focused.kind) { focusedKind = group.kind }
                        }
                    }
                }
                .frame(width: 300)

                VStack(alignment: .leading, spacing: 10) {
                    Text(focused.kind.summary).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(focused.items) { item in ItemRow(item: item) }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .card()
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 16)
        }
    }
}

private struct GroupRow: View {
    @Environment(AppModel.self) private var app
    let group: JunkGroup
    let isFocused: Bool
    let focus: () -> Void

    var body: some View {
        let model = app.junk
        let state = model.selectionState(of: group)
        HStack(spacing: 10) {
            CheckBox(state: state.selected == 0 ? .off : (state.selected == state.total ? .on : .mixed),
                     tint: Module.junk.accent) { model.setGroup(group, selected: state.selected != state.total) }
            Image(systemName: group.kind.symbol).frame(width: 22).foregroundStyle(Module.junk.gradient)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.kind.title).font(.callout.weight(.medium))
                Text(group.items.count == 1 ? "1 item" : "\(group.items.count) items").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Format.bytes(group.totalSize)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .card(cornerRadius: 11, highlighted: isFocused)
        .contentShape(Rectangle())
        .onTapGesture(perform: focus)
    }
}

private struct ItemRow: View {
    @Environment(AppModel.self) private var app
    let item: JunkItem

    var body: some View {
        let model = app.junk
        let isOn = model.selected.contains(item.id)
        HStack(spacing: 10) {
            CheckBox(state: isOn ? .on : .off, tint: Module.junk.accent) {
                if isOn { model.selected.remove(item.id) } else { model.selected.insert(item.id) }
            }
            FileIcon(url: item.url, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                if let note = item.note {
                    Text(note).font(.caption).foregroundStyle(.yellow.opacity(0.85)).lineLimit(2)
                }
            }
            Spacer()
            Text(Format.bytes(item.size)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.reveal(item.url) }
        }
    }
}
