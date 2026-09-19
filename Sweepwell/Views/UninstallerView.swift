import SwiftUI
import SweepwellKit

struct UninstallerView: View {
    @Environment(AppModel.self) private var app
    @State private var confirming: InstalledApp?

    var body: some View {
        @Bindable var model = app.uninstaller
        ModuleScaffold(module: .uninstaller) {
            switch model.phase {
            case .idle:
                IdleView(module: .uninstaller, headline: "Uninstall apps completely",
                         details: ["Finds caches, preferences and containers each app left in your Library",
                                   "Shows when you last used every app",
                                   "Apps that came with macOS are never listed"],
                         buttonTitle: "Find\nApps") { model.scan() }
            case .scanning:
                ScanningView(module: .uninstaller, control: model.control, title: "Taking inventory…")
            case .working:
                VStack(spacing: 14) { ProgressView().controlSize(.large); Text("Uninstalling…").foregroundStyle(.secondary) }
            case .results, .finished:
                VStack(spacing: 0) {
                    if let report = model.report {
                        ReportBanner(report: report, mode: Preferences.removalMode, tint: Module.uninstaller.accent) { model.report = nil }
                    }
                    HStack(spacing: 12) {
                        VStack(spacing: 8) {
                            HStack {
                                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                                TextField("Search \(model.apps.count) apps", text: $model.search).textFieldStyle(.plain)
                                Picker("", selection: $model.sort) {
                                    ForEach(AppSort.allCases) { Text($0.rawValue).tag($0) }
                                }.labelsHidden().fixedSize()
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .card(cornerRadius: 9)
                            ScrollView {
                                LazyVStack(spacing: 2) {
                                    ForEach(model.visibleApps) { item in AppRow(item: item) }
                                }
                            }
                        }
                        .frame(width: 340)

                        if let selected = model.selectedApp {
                            AppDetail(item: selected) { confirming = selected }
                        } else {
                            Text("Select an app").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).card()
                        }
                    }
                    .padding(.horizontal, 28).padding(.bottom, 16)
                }
            }
        }
        .confirmationDialog("Uninstall \(confirming?.name ?? "")?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            presenting: confirming) { item in
            Button("Uninstall", role: .destructive) { model.uninstall(item) }
        } message: { item in
            let count = item.leftovers.filter { !model.keptLeftovers.contains($0.id) }.count
            Text(Preferences.removalMode == .trash
                 ? "The app and \(count) support item(s) are moved to the Trash. You may be asked for an administrator password."
                 : "The app and \(count) support item(s) are deleted immediately. This cannot be undone.")
        }
    }
}

private struct AppRow: View {
    @Environment(AppModel.self) private var app
    let item: InstalledApp

    var body: some View {
        let model = app.uninstaller
        let selected = model.selectedAppID == item.id
        HStack(spacing: 10) {
            FileIcon(url: item.url, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1)
                Text(item.lastUsed.map { "used \($0.relativeDescription)" } ?? "never opened, or unknown")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Format.bytes(item.totalSize)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.white.opacity(selected ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedAppID = item.id; model.keptLeftovers = [] }
    }
}

private struct AppDetail: View {
    @Environment(AppModel.self) private var app
    let item: InstalledApp
    let uninstall: () -> Void

    var body: some View {
        let model = app.uninstaller
        let running = model.runningInstance(of: item)
        let removing = item.leftovers.filter { !model.keptLeftovers.contains($0.id) }
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                FileIcon(url: item.url, size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("Version \(item.version) · \(item.bundleID)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(item.url.path).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Reveal") { NSWorkspace.shared.reveal(item.url) }.buttonStyle(PillButtonStyle())
            }
            Divider().opacity(0.4)
            HStack {
                Text("What gets removed").font(.callout.weight(.semibold))
                Spacer()
                Text(Format.bytes(item.bundleSize + removing.reduce(0) { $0 + $1.size })).font(.callout.monospacedDigit().weight(.semibold))
            }
            ScrollView {
                VStack(spacing: 2) {
                    row(icon: item.url, name: item.url.lastPathComponent, location: "Application", size: item.bundleSize, state: .on, toggle: nil)
                    ForEach(item.leftovers) { leftover in
                        let kept = model.keptLeftovers.contains(leftover.id)
                        row(icon: leftover.url, name: leftover.url.lastPathComponent, location: leftover.location,
                            size: leftover.size, state: kept ? .off : .on) {
                            if kept { model.keptLeftovers.remove(leftover.id) } else { model.keptLeftovers.insert(leftover.id) }
                        }
                        .contextMenu { Button("Reveal in Finder") { NSWorkspace.shared.reveal(leftover.url) } }
                    }
                }
            }
            HStack {
                if running != nil {
                    Label("\(item.name) is running", systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.yellow)
                    Button("Quit It") { running?.terminate() }.buttonStyle(PillButtonStyle())
                }
                Spacer()
                Button("Uninstall", action: uninstall)
                    .buttonStyle(PillButtonStyle(prominent: true, tint: Module.uninstaller.accent))
                    .disabled(running != nil)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }

    private func row(icon: URL, name: String, location: String, size: Int64, state: CheckBox.State, toggle: (() -> Void)?) -> some View {
        HStack(spacing: 10) {
            CheckBox(state: state, tint: Module.uninstaller.accent) { toggle?() }.disabled(toggle == nil)
            FileIcon(url: icon, size: 20)
            Text(name).lineLimit(1).truncationMode(.middle)
            Text(location).font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1).background(.white.opacity(0.07), in: Capsule())
            Spacer()
            Text(Format.bytes(size)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
    }
}
