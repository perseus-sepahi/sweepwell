import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SweepwellKit

// MARK: - Model

@MainActor @Observable
final class ShredderModel {
    let environment = ScanEnvironment.live
    var phase: Phase = .idle
    var items: [URL] = []
    var sizes: [URL: Int64] = [:]
    var passes: ShredPasses = .one
    var control = ScanControl()
    var report: ShredReport?
    var conditions: ShredConditions?
    var refusals: [String] = []

    var totalSize: Int64 { items.reduce(0) { $0 + (sizes[$1] ?? 0) } }

    /// Checks each new item against the shred safety rules straight away, so a refused item
    /// never sits in the list looking as if it will be shredded.
    func add(_ urls: [URL]) {
        let guardian = SafetyGuard(environment: environment)
        refusals = []
        report = nil
        for url in urls where !items.contains(url) {
            do {
                try guardian.validate(url, purpose: .shred)
                items.append(url)
                Task {
                    let size = await background { Shredder.size(of: [url]) }
                    sizes[url] = size
                }
            } catch {
                refusals.append("\(url.lastPathComponent): \((error as? SafetyViolation)?.reason ?? error.localizedDescription)")
            }
        }
    }

    func remove(_ url: URL) { items.removeAll { $0 == url } }

    func loadConditions() {
        guard conditions == nil else { return }
        Task { conditions = await background { ShredConditions.current() } }
    }

    func shred() {
        let targets = items
        guard !targets.isEmpty, phase != .working else { return }
        phase = .working
        report = nil
        let control = ScanControl()
        self.control = control
        let shredder = Shredder(environment: environment)
        let passes = passes
        Task {
            let result = await background { shredder.shred(targets, passes: passes, control: control) }
            let gone = Set(result.shredded)
            var removal = RemovalReport()
            removal.removed = result.shredded
            removal.bytesFreed = targets.filter(gone.contains).reduce(0) { $0 + (sizes[$1] ?? 0) }
            AppModel.shared.recordSweep(removal)
            items.removeAll(where: gone.contains)
            report = result
            phase = .results
        }
    }
}

// MARK: - View

struct ShredderView: View {
    @Environment(AppModel.self) private var app
    @State private var confirming = false
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = app.shredder
        ModuleScaffold(module: .shredder) {
            if model.phase == .working {
                ScanningView(module: .shredder, control: model.control, title: "Shredding…")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let report = model.report { result(report, passes: model.passes) }
                        if !model.refusals.isEmpty { refusals(model.refusals) }
                        if model.items.isEmpty { dropZone(model) } else { list(model) }
                        conditions(model.conditions)
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
                }
            }
        } footer: {
            if model.phase != .working {
                ActionBar(module: .shredder,
                          actionTitle: model.items.isEmpty ? "Shred" : "Shred \(model.items.count) · \(Format.bytes(model.totalSize))",
                          enabled: !model.items.isEmpty) { confirming = true } leading: {
                    Picker("Passes", selection: $model.passes) {
                        Text("1 pass").tag(ShredPasses.one)
                        Text("3 passes").tag(ShredPasses.three)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .help("One random pass is as effective as more on modern drives. Three passes (random, random, zeros) take three times as long.")
                    Button("Add…") { choose(model) }.buttonStyle(PillButtonStyle())
                    Button("Clear") { model.items = []; model.refusals = [] }.buttonStyle(PillButtonStyle()).disabled(model.items.isEmpty)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls.filter(\.isFileURL))
            return true
        } isTargeted: { dropTargeted = $0 }
        .confirmationDialog("Shred \(model.items.count) item\(model.items.count == 1 ? "" : "s") for good?", isPresented: $confirming) {
            Button("Shred", role: .destructive) { model.shred() }
        } message: {
            Text((model.items.prefix(8).map { "• " + $0.lastPathComponent } + (model.items.count > 8 ? ["…and \(model.items.count - 8) more"] : []))
                .joined(separator: "\n")
                 + "\n\nEach file is overwritten \(model.passes == .one ? "once with random data" : "three times") and then deleted. They do not go to the Trash and cannot be put back.")
        }
        .onAppear { model.loadConditions() }
    }

    private func choose(_ model: ShredderModel) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Shredder"
        panel.directoryURL = model.environment.home
        if panel.runModal() == .OK { model.add(panel.urls) }
    }

    private func dropZone(_ model: ShredderModel) -> some View {
        VStack(spacing: 14) {
            IconDisc(symbol: "doc.badge.plus", color: Module.shredder.colors[0], size: 56)
            Text("Drop files or folders here").font(.system(size: 20, weight: .bold, design: .rounded))
            Text("Nothing is shredded until you press Shred and confirm.").font(.callout).foregroundStyle(.secondary)
            Button("Choose Files…") { choose(model) }.buttonStyle(PillButtonStyle(prominent: true, tint: Module.shredder.colors[0], large: true))
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .card(highlighted: dropTargeted)
        .overlay {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(dropTargeted ? Module.shredder.colors[0] : Color.hairline)
                .padding(8)
        }
    }

    private func list(_ model: ShredderModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("To shred").font(.callout.weight(.semibold))
                Spacer()
                Text("Drop more here").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.bottom, 4)
            ForEach(model.items, id: \.self) { url in
                HStack(spacing: 10) {
                    FileIcon(url: url, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text(url.deletingLastPathComponent().path.replacingOccurrences(of: model.environment.home.path, with: "~"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    Spacer()
                    Text(model.sizes[url].map(Format.bytes) ?? "…").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Button { model.remove(url) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary).help("Take it off the list")
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
            }
        }
        .padding(16)
        .card(highlighted: dropTargeted)
    }

    private func refusals(_ refusals: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Not added", systemImage: "hand.raised.fill").font(.callout.weight(.semibold)).foregroundStyle(Color.warning)
            ForEach(refusals, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func result(_ report: ShredReport, passes: ShredPasses) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(report.cancelled ? "Stopped. \(report.shredded.count) item\(report.shredded.count == 1 ? "" : "s") were shredded before that."
                                   : "Shredded \(report.shredded.count) item\(report.shredded.count == 1 ? "" : "s").",
                  systemImage: report.failures.isEmpty && !report.cancelled ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
            Text("\(Format.bytes(report.bytesOverwritten)) written over them in \(passes.rawValue) pass\(passes == .one ? "" : "es"), then deleted.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(report.failures) { failure in
                Text("\(failure.url.lastPathComponent) was left alone: \(failure.message)").font(.caption).foregroundStyle(Color.warning)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// What shredding can and cannot promise on this Mac, in plain words.
    private func conditions(_ conditions: ShredConditions?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How far shredding goes on this Mac").font(.callout.weight(.semibold))
            if let c = conditions {
                fact(c.fileVaultOn == true ? "lock.fill" : "lock.open.fill",
                     c.fileVaultOn == true ? Color.success : Color.warning,
                     c.fileVaultOn == true ? "FileVault is on" : "FileVault is off",
                     c.fileVaultOn == true
                        ? "Your disk is encrypted, so any old copies the drive keeps are unreadable without your password. This is the real protection."
                        : "Without FileVault, copies the drive keeps behind the scenes could be recovered with lab tools. Turn it on in System Settings › Privacy & Security.")
                if c.solidState == true {
                    fact("internaldrive.fill", Color.warning, "This is an SSD with APFS",
                         "The drive and the file system may write new data to fresh blocks and keep the old ones for a while. Shredding overwrites everything the Mac lets an app reach; it cannot reach those.")
                }
                fact(c.localSnapshots == 0 ? "clock.badge.checkmark" : "clock.badge.exclamationmark",
                     c.localSnapshots == 0 ? Color.success : Color.warning,
                     c.localSnapshots == 0 ? "No local snapshots" : "\(c.localSnapshots) local snapshot\(c.localSnapshots == 1 ? "" : "s")",
                     c.localSnapshots == 0 ? "No Time Machine snapshot is holding an older copy of these files."
                                           : "A snapshot keeps its own copy of files that existed when it was taken. Maintenance › Thin Time Machine Snapshots releases them.")
                fact("doc.on.doc", .secondary, "Copies elsewhere are not touched",
                     "Backups, cloud copies, email attachments and files duplicated with ⌘D in Finder (which can share blocks) keep their data.")
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func fact(_ symbol: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 18).padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
    }
}
