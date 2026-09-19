import SwiftUI
import SweepwellKit

struct SpaceLensView: View {
    @Environment(AppModel.self) private var app
    @State private var confirming: DiskNode?

    var body: some View {
        let model = app.spaceLens
        ModuleScaffold(module: .spaceLens) {
            switch model.phase {
            case .scanning:
                ScanningView(module: .spaceLens, control: model.control, title: "Mapping \(model.root.lastPathComponent)…")
            case .results, .working, .finished:
                if let current = model.current { map(model, current) }
            case .idle:
                VStack(spacing: 0) {
                    IdleView(module: .spaceLens, headline: "See where the space went",
                             details: ["Builds a size map of every folder", "Click a block to select it, double-click to look inside",
                                       "Sizes are what the files really occupy on disk"],
                             buttonTitle: "Map") { model.scan(model.root) }
                    rootPicker(model).padding(.bottom, 26)
                }
            }
        } footer: {
            if model.phase == .results, let node = model.highlighted {
                ActionBar(module: .spaceLens, actionTitle: Preferences.removalMode == .trash ? "Move to Trash" : "Delete",
                          enabled: !node.isAggregate && node.parent != nil) { confirming = node } leading: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(node.name) · \(Format.bytes(node.size))").font(.callout.weight(.semibold)).lineLimit(1)
                        Text("\(node.fileCount.formatted()) files").font(.caption).foregroundStyle(.secondary)
                    }
                    if !node.isAggregate {
                        Button("Reveal in Finder") { NSWorkspace.shared.reveal(node.url) }.buttonStyle(PillButtonStyle())
                    }
                    if node.isDirectory, !node.children.isEmpty {
                        Button("Look Inside") { model.open(node) }.buttonStyle(PillButtonStyle())
                    }
                }
            }
        }
        .confirmationDialog("Remove “\(confirming?.name ?? "")”?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            presenting: confirming) { node in
            Button(Preferences.removalMode == .trash ? "Move to Trash" : "Delete Permanently", role: .destructive) { model.remove(node) }
        } message: { node in
            Text("\(Format.bytes(node.size)) in \(node.fileCount.formatted()) files. \(node.path)")
        }
    }

    private func rootPicker(_ model: SpaceLensModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(model.root.path).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Menu("Change") {
                Button("Home Folder") { model.root = model.environment.home }
                if !model.environment.isFixture {
                    Button("Applications") { model.root = URL(fileURLWithPath: "/Applications") }
                    Button("Whole Disk") { model.root = URL(fileURLWithPath: "/System/Volumes/Data") }
                }
                Divider()
                Button("Choose Folder…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url { model.root = url }
                }
            }
            .fixedSize()
        }
    }

    private func map(_ model: SpaceLensModel, _ current: DiskNode) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(model.breadcrumbs) { node in
                    if node !== model.breadcrumbs.first { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    Button(node.name) { model.current = node; model.highlighted = nil }
                        .buttonStyle(.plain)
                        .font(.callout.weight(node === current ? .semibold : .regular))
                        .foregroundStyle(node === current ? .primary : .secondary)
                }
                Spacer()
                if model.inaccessible > 0 {
                    Label("\(model.inaccessible) folders not readable", systemImage: "lock")
                        .font(.caption).foregroundStyle(.yellow.opacity(0.8))
                        .help("Grant Full Disk Access in System Settings to include them.")
                }
                Text(Format.bytes(current.size)).font(.callout.monospacedDigit().weight(.semibold))
                Button("Rescan") { model.scan(model.root) }.buttonStyle(PillButtonStyle())
                Button("New Map") { model.phase = .idle }.buttonStyle(PillButtonStyle())
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(current.children) { child in NodeRow(node: child, parentSize: current.size) }
                    }.padding(6)
                }
                .frame(width: 310)
                .card()

                TreemapView(node: current)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 16)
        .id(model.revision)
    }
}

private struct NodeRow: View {
    @Environment(AppModel.self) private var app
    let node: DiskNode
    let parentSize: Int64

    var body: some View {
        let model = app.spaceLens
        let selected = model.highlighted === node
        HStack(spacing: 8) {
            Image(systemName: node.isAggregate ? "doc.on.doc" : (node.isDirectory ? "folder.fill" : "doc.fill"))
                .foregroundStyle(node.isDirectory ? AnyShapeStyle(Module.spaceLens.gradient) : AnyShapeStyle(.secondary))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(node.name).lineLimit(1).truncationMode(.middle).font(.callout)
                    Spacer()
                    Text(Format.bytes(node.size)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                GeometryReader { proxy in
                    Capsule().fill(.white.opacity(0.07))
                        .overlay(alignment: .leading) {
                            Capsule().fill(Module.spaceLens.gradient)
                                .frame(width: max(2, proxy.size.width * CGFloat(node.size) / CGFloat(max(parentSize, 1))))
                        }
                }
                .frame(height: 3)
            }
            if node.isDirectory, !node.children.isEmpty {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.white.opacity(selected ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded { model.open(node) }
            .exclusively(before: TapGesture().onEnded { model.highlighted = node }))
    }
}

/// Two levels at once: each block is a child of the current folder, subdivided by its own
/// children, which is what makes "this folder is one giant file" visible at a glance.
private struct TreemapView: View {
    @Environment(AppModel.self) private var app
    let node: DiskNode
    @State private var hover: CGPoint?

    private static let palette: [Color] = [
        Color(hex: 0x43D9F0), Color(hex: 0x5AA2FF), Color(hex: 0x7B5CF5), Color(hex: 0xB07CFF), Color(hex: 0xF062B5),
        Color(hex: 0xFF7A59), Color(hex: 0xFFA14A), Color(hex: 0xF7D34B), Color(hex: 0x5FCB6B), Color(hex: 0x35E0B2)
    ]

    /// Blocks under a fraction of a percent cannot be seen or clicked; the list still has them.
    private var blocks: [DiskNode] {
        let floor = Double(node.size) * 0.002
        return Array(node.children.filter { Double($0.size) >= floor }.prefix(80))
    }

    var body: some View {
        let model = app.spaceLens
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let blocks = blocks
            let rects = Treemap.layout(blocks.map { Double($0.size) }, in: bounds)
            let hovered = hover.flatMap { point in rects.firstIndex { $0.contains(point) } }

            Canvas { context, _ in
                for (index, rect) in rects.enumerated() {
                    let block = blocks[index]
                    let color = Self.palette[index % Self.palette.count]
                    let frame = rect.insetBy(dx: 1.5, dy: 1.5)
                    guard frame.width > 1, frame.height > 1 else { continue }
                    let isSelected = model.highlighted === block
                    context.fill(Path(roundedRect: frame, cornerRadius: 5),
                                 with: .color(color.opacity(isSelected ? 0.95 : (hovered == index ? 0.8 : 0.6))))

                    if block.isDirectory, frame.width > 40, frame.height > 40 {
                        let inner = frame.insetBy(dx: 4, dy: 4).offsetBy(dx: 0, dy: 8).insetBy(dx: 0, dy: 8)
                        let grandchildren = Array(block.children.prefix(40))
                        let innerRects = Treemap.layout(grandchildren.map { Double($0.size) }, in: inner)
                        for (i, r) in innerRects.enumerated() where r.width > 3 && r.height > 3 {
                            context.fill(Path(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 3),
                                         with: .color(.black.opacity(i.isMultiple(of: 2) ? 0.16 : 0.26)))
                        }
                    }
                    if isSelected {
                        context.stroke(Path(roundedRect: frame, cornerRadius: 5), with: .color(.white), lineWidth: 2)
                    }
                    if frame.width > 74, frame.height > 22 {
                        let label = Text(block.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        context.draw(context.resolve(label), in: CGRect(x: frame.minX + 6, y: frame.minY + 3, width: frame.width - 12, height: 15))
                        if frame.height > 46 {
                            let size = Text(Format.bytes(block.size)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                            context.draw(context.resolve(size), in: CGRect(x: frame.minX + 6, y: frame.maxY - 17, width: frame.width - 12, height: 14))
                        }
                    }
                }
            }
            .onContinuousHover { phase in
                if case .active(let point) = phase { hover = point } else { hover = nil }
            }
            .gesture(SpatialTapGesture(count: 2).onEnded { tap in
                if let index = rects.firstIndex(where: { $0.contains(tap.location) }) { model.open(blocks[index]) }
            }.exclusively(before: SpatialTapGesture().onEnded { tap in
                model.highlighted = rects.firstIndex { $0.contains(tap.location) }.map { blocks[$0] }
            }))
            .help(hovered.map { "\(blocks[$0].name) — \(Format.bytes(blocks[$0].size))" } ?? "")
        }
        .background(.black.opacity(0.25))
    }
}
