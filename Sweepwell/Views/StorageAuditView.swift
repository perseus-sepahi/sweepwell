import SwiftUI
import AppKit
import SweepwellKit

// MARK: - Model

/// The mac-storage-audit workflow: a read-only scan, a menu with stable IDs, removal of only
/// what is picked (folders to the Trash, permanent deletions handed over as commands), then a
/// re-check of free space, since APFS can take minutes to give large deletions back.
@MainActor @Observable
final class StorageAuditModel {
    let environment = ScanEnvironment.live
    var phase: Phase = .idle
    var report: StorageAuditReport?
    var picked: Set<String> = []
    var control = ScanControl()
    var removal: RemovalReport?
    var freeBefore: Int64?
    var freeNow: Int64?
    var accounting: StorageAccounting?
    var accountingRunning = false
    var accountingControl = ScanControl()
    var copiedID: String?

    var pickedItems: [AuditItem] { report?.items.filter { picked.contains($0.id) } ?? [] }
    var pickedTrash: [AuditItem] { pickedItems.filter { $0.removal == .trash } }
    var pickedCommands: [AuditItem] { pickedItems.filter { if case .command = $0.removal { true } else { false } } }
    var pickedTrashSize: Int64 { pickedTrash.reduce(0) { $0 + $1.size } }

    func scan(keepingReport: Bool = false) {
        guard phase != .scanning, phase != .working else { return }
        phase = .scanning
        if !keepingReport { removal = nil }
        let control = ScanControl()
        self.control = control
        let auditor = StorageAuditor(environment: environment)
        Task {
            let found = await background { auditor.scan(control: control) }
            guard !control.isCancelled else { phase = report == nil ? .idle : .results; return }
            report = found
            picked = picked.filter { id in found.items.contains { $0.id == id && $0.removal != .reveal } }
            phase = .results
        }
    }

    /// The low-regret set: pure caches, orphaned simulators, leftover backups. Nothing with a warning.
    func pickLowRegret() {
        picked = Set(report?.items.filter { $0.recommended && $0.removal != .reveal }.map(\.id) ?? [])
    }

    func toggle(_ item: AuditItem) {
        if picked.contains(item.id) { picked.remove(item.id) } else { picked.insert(item.id) }
    }

    /// Picked folders go to the Trash, always: the audit never deletes outright.
    func moveToTrash() {
        let items = pickedTrash
        guard !items.isEmpty else { return }
        phase = .working
        freeBefore = DiskSpace.startupVolume()?.available
        let remover = Remover(environment: environment)
        let requests = items.compactMap { item in item.url.map { RemovalRequest(url: $0, size: item.size, purpose: .auditItem) } }
        Task {
            let result = await background { remover.remove(requests, mode: .trash) }
            AppModel.shared.recordSweep(result)
            removal = result
            picked.subtract(items.filter { item in result.removed.contains { $0 == item.url } }.map(\.id))
            freeNow = DiskSpace.startupVolume()?.available
            phase = .results
            scan(keepingReport: true)   // refresh the map, keep the "moved to Trash" card
        }
    }

    func recheckFreeSpace() {
        freeNow = DiskSpace.startupVolume()?.available
    }

    func runAccounting() {
        guard !accountingRunning else { return }
        accountingRunning = true
        let control = ScanControl()
        accountingControl = control
        let auditor = StorageAuditor(environment: environment)
        Task {
            let result = await background { auditor.account(control: control) }
            accountingRunning = false
            if !control.isCancelled { accounting = result }
        }
    }

    func copy(_ text: String, id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedID = id
    }
}

private extension AuditItem {
    var command: String? { if case .command(let text) = removal { text } else { nil } }
}

// MARK: - View

struct StorageAuditView: View {
    @Environment(AppModel.self) private var app
    @State private var confirming = false

    var body: some View {
        let model = app.audit
        ModuleScaffold(module: .storageAudit) {
            switch model.phase {
            case .idle:
                IdleView(module: .storageAudit, headline: "See what is quietly filling your disk",
                         details: ["Hidden dotfolders, caches, VMs, simulators, AI models and toolchains",
                                   "Each with its size and what removing it costs",
                                   "Read-only: nothing is removed until you pick it"],
                         buttonTitle: "Audit") { model.scan() }
            case .scanning:
                ScanningView(module: .storageAudit, control: model.control, title: "Mapping your storage…")
            case .working:
                VStack(spacing: 14) { ProgressView().controlSize(.large); Text("Moving to the Trash…").foregroundStyle(.secondary) }
            case .results, .finished:
                if let report = model.report { results(model, report) }
            }
        } footer: {
            if model.phase == .results, model.report != nil {
                ActionBar(module: .storageAudit,
                          actionTitle: model.pickedTrash.isEmpty ? "Move to Trash" : "Move \(model.pickedTrash.count) to Trash · \(Format.bytes(model.pickedTrashSize))",
                          enabled: !model.pickedTrash.isEmpty) { confirming = true } leading: {
                    Button("Low-regret set") { model.pickLowRegret() }.buttonStyle(PillButtonStyle())
                        .help("Pure caches, orphaned simulators and leftover backups: things that rebuild or were never needed")
                    Button("Clear") { model.picked = [] }.buttonStyle(PillButtonStyle()).disabled(model.picked.isEmpty)
                    Button("Audit Again") { model.scan() }.buttonStyle(PillButtonStyle())
                }
            }
        }
        .confirmationDialog("Move \(model.pickedTrash.count) item\(model.pickedTrash.count == 1 ? "" : "s") to the Trash?",
                            isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) { model.moveToTrash() }
        } message: {
            Text(confirmMessage(model))
        }
    }

    private func confirmMessage(_ model: StorageAuditModel) -> String {
        var lines = model.pickedTrash.map { "\($0.id)  \($0.title): \($0.cost)" }
        let warned = model.pickedTrash.filter { !$0.warnings.isEmpty }
        if !warned.isEmpty { lines.append("\nCheck first: " + warned.map { "\($0.id) (\($0.warnings.joined(separator: ", ")))" }.joined(separator: "; ")) }
        lines.append("\nEverything can be put back from the Trash. The space returns when you empty the Trash.")
        return lines.joined(separator: "\n")
    }

    private func results(_ model: StorageAuditModel, _ report: StorageAuditReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                summary(model, report)
                if let removal = model.removal { afterRemoval(model, removal) }
                if !model.pickedCommands.isEmpty { commands(model) }
                ForEach(AuditItem.Group.allCases, id: \.self) { group in
                    let items = report.items(in: group)
                    if !items.isEmpty { GroupCard(group: group, items: items, total: report.total(of: group)) }
                }
                accounting(model)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
    }

    private func summary(_ model: StorageAuditModel, _ report: StorageAuditReport) -> some View {
        HStack(spacing: 12) {
            if let disk = report.disk {
                stat("Free now", Format.bytes(disk.available), "of \(Format.bytes(disk.total))")
                stat("Purgeable", Format.bytes(disk.purgeable), "macOS frees this itself")
            }
            stat("Removable here", Format.bytes(report.items.filter { $0.removal == .trash }.reduce(0) { $0 + $1.size }),
                 "folders you can send to the Trash")
            stat("Low-regret", Format.bytes(report.items.filter { $0.recommended && $0.removal != .reveal }.reduce(0) { $0 + $1.size }),
                 "rebuilds by itself")
        }
    }

    private func stat(_ title: String, _ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
            Text(caption).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func afterRemoval(_ model: StorageAuditModel, _ removal: RemovalReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Moved \(removal.removed.count) item\(removal.removed.count == 1 ? "" : "s") (\(Format.bytes(removal.bytesFreed))) to the Trash.",
                  systemImage: "checkmark.circle.fill").font(.callout.weight(.semibold))
            if !removal.failures.isEmpty {
                Text(removal.failures.map { "\($0.url.lastPathComponent): \($0.message)" }.joined(separator: "\n"))
                    .font(.caption).foregroundStyle(Color.warning)
            }
            Text("The space comes back when you empty the Trash. After that, APFS can take several minutes to report it, so check again before concluding something did not free space.")
                .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            HStack {
                if let before = model.freeBefore, let now = model.freeNow {
                    Text("Free: \(Format.bytes(before)) before → \(Format.bytes(now)) now").font(.caption.monospacedDigit())
                }
                Spacer()
                Button("Check Free Space Again") { model.recheckFreeSpace() }.buttonStyle(PillButtonStyle())
            }
        }
        .padding(16)
        .card()
    }

    /// Permanent, tool-driven deletions are the user's to run, one command per line.
    private func commands(_ model: StorageAuditModel) -> some View {
        let picked = model.pickedCommands
        let all = picked.compactMap(\.command).joined(separator: "\n")
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                IconDisc(symbol: "terminal.fill", color: Module.storageAudit.colors[1], size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Commands for you to run").font(.callout.weight(.semibold))
                    Text("These deletions are permanent, so Sweepwell does not run them. Paste them into Terminal.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.copiedID == "all" ? "Copied" : "Copy All") { model.copy(all, id: "all") }.buttonStyle(PillButtonStyle())
            }
            ForEach(picked) { item in
                HStack(spacing: 8) {
                    Text(item.id).font(.caption.monospaced().weight(.semibold)).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
                    Text(item.command ?? "").font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(model.copiedID == item.id ? "Copied" : "Copy") { model.copy(item.command ?? "", id: item.id) }
                        .buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(Module.storageAudit.accent)
                }
            }
        }
        .padding(16)
        .card()
    }

    private func accounting(_ model: StorageAuditModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                IconDisc(symbol: "questionmark.folder.fill", color: Module.storageAudit.colors[1], size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Space the scan cannot see").font(.callout.weight(.semibold))
                    Text("Compares what APFS says is used with what can be read. Takes about a minute.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.accountingRunning {
                    ProgressView().controlSize(.small)
                    Button("Stop") { model.accountingControl.cancel() }.buttonStyle(PillButtonStyle())
                } else {
                    Button(model.accounting == nil ? "Account for It" : "Again") { model.runAccounting() }.buttonStyle(PillButtonStyle())
                }
            }
            if let result = model.accounting {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    row("APFS says in use", Format.bytes(result.consumed))
                    row("Readable by Sweepwell", Format.bytes(result.readable))
                    row("Gap", Format.bytes(result.gap))
                    row("Held by deleted-but-open files", Format.bytes(result.heldByOpenFiles))
                    row("Local snapshots", "\(result.localSnapshots)")
                    row("Folders macOS would not let it read", "\(result.deniedDirectories)")
                }
                .font(.caption)
                Text("The rest is in places macOS protects: Photos, Mail, Messages, Safari, iPhone backups, the Spotlight index and Apple Intelligence models. Storage settings shows them by category; the command below sizes the root-only ones (it asks for your password in Terminal). Anything not measured is left unsized rather than guessed.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(5)
                HStack {
                    Button("Open Storage Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!)
                    }.buttonStyle(PillButtonStyle())
                    Button(model.copiedID == "sudo" ? "Copied" : "Copy Sizing Command") {
                        model.copy(StorageAuditor.rootSizingCommand, id: "sudo")
                    }.buttonStyle(PillButtonStyle())
                }
            }
        }
        .padding(16)
        .card()
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}

private struct GroupCard: View {
    let group: AuditItem.Group
    let items: [AuditItem]
    let total: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.rawValue).font(.system(size: 13, weight: .bold, design: .rounded))
                    .frame(width: 24, height: 24).background(.white, in: Circle()).foregroundStyle(Module.storageAudit.colors[1])
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.title).font(.callout.weight(.semibold))
                    Text(group.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Text(Format.bytes(total)).font(.callout.monospacedDigit().weight(.semibold))
            }
            VStack(spacing: 2) {
                ForEach(items) { item in AuditRow(item: item) }
            }
        }
        .padding(16)
        .card()
    }
}

private struct AuditRow: View {
    @Environment(AppModel.self) private var app
    let item: AuditItem
    @State private var hovering = false

    var body: some View {
        let model = app.audit
        let picked = model.picked.contains(item.id)
        HStack(alignment: .top, spacing: 10) {
            if item.removal == .reveal {
                Image(systemName: "eye").font(.system(size: 13)).foregroundStyle(.tertiary).frame(width: 20).padding(.top, 2)
                    .help("Shown for context only")
            } else {
                CheckBox(state: picked ? .on : .off, tint: Module.storageAudit.accent) { model.toggle(item) }.padding(.top, 1)
            }
            Text(item.id).font(.caption.monospaced().weight(.semibold)).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).font(.callout).lineLimit(1)
                    if item.recommended && item.removal != .reveal {
                        badge("low-regret", Color.success)
                    }
                    switch item.removal {
                    case .command: badge("you run it", Module.storageAudit.colors[1])
                    case .reveal: badge("view only", .secondary)
                    case .trash: EmptyView()
                    }
                    ForEach(item.warnings, id: \.self) { badge($0, Color.warning) }
                }
                Text(item.cost).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 8) {
                    if let url = item.url {
                        Text(url.path.replacingOccurrences(of: app.environment.home.path, with: "~"))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if let used = item.lastUsed {
                        Text("\(item.lastUsedFromTool ? "last used" : "changed") \(used.relativeDescription)")
                    }
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if let url = item.url, hovering {
                Button { NSWorkspace.shared.reveal(url) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Reveal in Finder")
            }
            Text(Format.bytes(item.size)).font(.callout.monospacedDigit().weight(.medium)).frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(hovering ? Color.hoverFill : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if item.removal != .reveal { model.toggle(item) } }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold)).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}
