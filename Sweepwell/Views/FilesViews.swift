import SwiftUI
import SweepwellKit

private func removalVerb() -> String {
    Preferences.removalMode == .trash ? "Move to Trash" : "Delete Permanently"
}

private func removalExplanation() -> String {
    Preferences.removalMode == .trash
        ? "The files are moved to the Trash, so you can still put them back."
        : "The files are deleted immediately. This cannot be undone."
}

// MARK: - Large & Old Files

struct LargeFilesView: View {
    @Environment(AppModel.self) private var app
    @State private var confirming = false

    var body: some View {
        @Bindable var model = app.largeFiles
        ModuleScaffold(module: .largeFiles) {
            switch model.phase {
            case .idle:
                IdleView(module: .largeFiles, headline: "Find the heavyweights",
                         details: ["Looks through Desktop, Documents, Downloads, Movies, Music and Pictures",
                                   "Lists files over \(Format.bytes(Preferences.largeFileThreshold)), biggest first",
                                   "Nothing is ticked for you: these are your files"]) { model.scan() }
            case .scanning:
                ScanningView(module: .largeFiles, control: model.control, title: "Weighing your files…")
            case .working:
                VStack(spacing: 14) { ProgressView().controlSize(.large); Text("Removing…").foregroundStyle(.secondary) }
            case .results, .finished:
                VStack(spacing: 0) {
                    if let report = model.report {
                        ReportBanner(report: report, mode: model.reportMode, tint: Module.largeFiles.accent) { model.report = nil }
                    }
                    if model.files.isEmpty {
                        EmptyResultView(module: .largeFiles, title: "Nothing heavy here",
                                        message: "No files over \(Format.bytes(Preferences.largeFileThreshold)) in your personal folders.") { model.scan() }
                    } else {
                        HStack {
                            Picker("Size", selection: $model.sizeFilter) {
                                ForEach(SizeFilter.allCases) { Text($0.rawValue).tag($0) }
                            }.frame(width: 190)
                            Picker("Age", selection: $model.ageFilter) {
                                ForEach(AgeFilter.allCases) { Text($0.rawValue).tag($0) }
                            }.frame(width: 230)
                            Spacer()
                            Text("\(model.visibleFiles.count) files").font(.callout).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 28).padding(.bottom, 10)

                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(model.visibleFiles) { file in LargeFileRow(file: file) }
                            }
                            .padding(8)
                        }
                        .card()
                        .padding(.horizontal, 28).padding(.bottom, 16)
                    }
                }
            }
        } footer: {
            if model.phase == .results, !model.files.isEmpty {
                ActionBar(module: .largeFiles, actionTitle: actionTitle("Remove", model.selectedSize),
                          enabled: model.selectedSize > 0) { confirming = true } leading: {
                    Text("\(Format.bytes(model.totalSize)) in \(model.files.count) large files").font(.callout.weight(.semibold))
                    Button("Scan Again") { model.scan() }.buttonStyle(PillButtonStyle())
                }
            }
        }
        .confirmationDialog("Remove \(model.selected.count) file(s), \(Format.bytes(model.selectedSize))?", isPresented: $confirming) {
            Button(removalVerb(), role: .destructive) { model.removeSelected() }
        } message: { Text(removalExplanation()) }
    }
}

private struct LargeFileRow: View {
    @Environment(AppModel.self) private var app
    let file: LargeFile

    var body: some View {
        let model = app.largeFiles
        let isOn = model.selected.contains(file.id)
        HStack(spacing: 10) {
            CheckBox(state: isOn ? .on : .off, tint: Module.largeFiles.accent) {
                if isOn { model.selected.remove(file.id) } else { model.selected.insert(file.id) }
            }
            FileIcon(url: file.url)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(file.url.deletingLastPathComponent().path.replacingOccurrences(of: app.environment.home.path, with: "~"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            Text("opened \(file.accessed.relativeDescription)").font(.caption).foregroundStyle(.secondary)
                .frame(width: 150, alignment: .trailing)
            Text(Format.bytes(file.size)).font(.callout.monospacedDigit().weight(.medium)).frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.reveal(file.url) }
            Button("Quick Look") { NSWorkspace.shared.open(file.url) }
            Divider()
            Button("Add to Shredder…") {
                app.shredder.add([file.url])
                app.selection = .shredder
            }
        }
    }
}

// MARK: - Duplicates

struct DuplicatesView: View {
    @Environment(AppModel.self) private var app
    @State private var confirming = false

    var body: some View {
        let model = app.duplicates
        ModuleScaffold(module: .duplicates) {
            switch model.phase {
            case .idle:
                VStack(spacing: 0) {
                    IdleView(module: .duplicates, headline: "Find files you have twice",
                             details: ["Compares content, not names: only exact copies count",
                                       "The oldest copy of each set is kept",
                                       "Files under 1 MB are skipped"]) { model.scan() }
                    folderPicker(model)
                }
            case .scanning:
                ScanningView(module: .duplicates, control: model.control, title: "Comparing files…")
            case .working:
                VStack(spacing: 14) { ProgressView().controlSize(.large); Text("Removing…").foregroundStyle(.secondary) }
            case .results, .finished:
                VStack(spacing: 0) {
                    if let report = model.report {
                        ReportBanner(report: report, mode: model.reportMode, tint: Module.duplicates.accent) { model.report = nil }
                    }
                    if model.groups.isEmpty {
                        EmptyResultView(module: .duplicates, title: "No duplicates",
                                        message: "Every file over 1 MB in the scanned folders is unique.") { model.scan() }
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(model.groups) { group in DuplicateGroupCard(group: group) }
                            }
                            .padding(.horizontal, 28).padding(.bottom, 16)
                        }
                    }
                }
            }
        } footer: {
            if model.phase == .results, !model.groups.isEmpty {
                ActionBar(module: .duplicates, actionTitle: actionTitle("Remove", model.selectedSize),
                          enabled: model.selectedSize > 0) { confirming = true } leading: {
                    Text("\(Format.bytes(model.wastedBytes)) wasted in \(model.groups.count) sets").font(.callout.weight(.semibold))
                    Button("Select All Copies") { model.selectAllButOriginals() }.buttonStyle(PillButtonStyle())
                    Button("Scan Again") { model.scan() }.buttonStyle(PillButtonStyle())
                }
            }
        }
        .confirmationDialog("Remove \(model.selected.count) duplicate(s), \(Format.bytes(model.selectedSize))?", isPresented: $confirming) {
            Button(removalVerb(), role: .destructive) { model.removeSelected() }
        } message: { Text(removalExplanation() + " One copy of every file is always kept.") }
    }

    private func folderPicker(_ model: DuplicatesModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(model.roots.map(\.lastPathComponent).joined(separator: ", "))
                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Button("Choose Folders…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = true
                panel.directoryURL = model.environment.home
                if panel.runModal() == .OK, !panel.urls.isEmpty { model.roots = panel.urls }
            }.buttonStyle(PillButtonStyle())
        }
        .padding(.bottom, 26)
    }
}

private struct DuplicateGroupCard: View {
    @Environment(AppModel.self) private var app
    let group: DuplicateGroup

    var body: some View {
        let model = app.duplicates
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                FileIcon(url: group.files[0].url, size: 24)
                Text(group.files[0].url.lastPathComponent).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                Text("\(group.files.count) copies · \(Format.bytes(group.size)) each").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(group.files.enumerated()), id: \.element.id) { index, file in
                let isOn = model.selected.contains(file.id)
                HStack(spacing: 8) {
                    CheckBox(state: isOn ? .on : .off, tint: Module.duplicates.accent) { model.toggle(file, in: group) }
                    Text(file.url.path.replacingOccurrences(of: app.environment.home.path, with: "~"))
                        .font(.caption).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(isOn ? .secondary : .primary)
                        .strikethrough(isOn, color: .secondary)
                    if index == 0 {
                        Text("oldest").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Module.duplicates.accent.opacity(0.25), in: Capsule())
                    }
                    Spacer()
                    Button { NSWorkspace.shared.reveal(file.url) } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Reveal in Finder")
                }
            }
        }
        .padding(12)
        .card(cornerRadius: 11)
    }
}
