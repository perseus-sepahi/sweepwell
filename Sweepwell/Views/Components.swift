import SwiftUI
import SweepwellKit

/// Title block + content + optional footer bar, shared by every module.
struct ModuleScaffold<Content: View, Footer: View>: View {
    let module: Module
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: module.symbol)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(module.gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.white.opacity(0.3)))
                    .shadow(color: module.accent.opacity(0.45), radius: 12, y: 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(module.title).font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(module.tagline).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 18)

            content.frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
    }
}

extension ModuleScaffold where Footer == EmptyView {
    init(module: Module, @ViewBuilder content: () -> Content) {
        self.init(module: module, content: content, footer: { EmptyView() })
    }
}

/// The big round call-to-action in the middle of an idle module: a glossy sphere with
/// halo rings that breathe, so the screen never feels static while it waits for a click.
struct OrbButton: View {
    let title: String
    let module: Module
    var diameter: CGFloat = 132
    let action: () -> Void
    @State private var hovering = false
    @State private var breathing = false

    var body: some View {
        Button(action: action) {
            ZStack {
                ForEach(0..<2, id: \.self) { ring in
                    Circle()
                        .stroke(module.accent.opacity(breathing ? 0 : 0.35), lineWidth: 1.5)
                        .frame(width: diameter, height: diameter)
                        .scaleEffect(breathing ? 1.55 + CGFloat(ring) * 0.25 : 1)
                        .animation(.easeOut(duration: 2.8).repeatForever(autoreverses: false).delay(Double(ring) * 1.2),
                                   value: breathing)
                }
                Circle().fill(module.gradient)
                    .overlay {
                        // Gloss: a soft highlight top-left, as if lit from above.
                        Circle().fill(RadialGradient(colors: [.white.opacity(0.55), .clear], center: .init(x: 0.32, y: 0.22),
                                                     startRadius: 2, endRadius: diameter * 0.6))
                    }
                    .overlay(Circle().strokeBorder(.white.opacity(0.45), lineWidth: 1.5))
                    .frame(width: diameter, height: diameter)
                    .shadow(color: module.accent.opacity(hovering ? 0.8 : 0.5), radius: hovering ? 34 : 22, y: 10)
                Text(title)
                    .font(.system(size: diameter * 0.17, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            }
            .frame(width: diameter * 1.9, height: diameter * 1.35)
            .scaleEffect(hovering ? 1.05 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .onAppear { breathing = true }
        .animation(.spring(duration: 0.35), value: hovering)
    }
}

struct IdleView: View {
    let module: Module
    let headline: String
    let details: [String]
    var buttonTitle = "Scan"
    let action: () -> Void

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            Image(systemName: module.symbol)
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(module.gradient)
                .symbolRenderingMode(.hierarchical)
                .shadow(color: module.accent.opacity(0.4), radius: 18, y: 6)
            VStack(spacing: 10) {
                Text(headline).font(.system(size: 24, weight: .bold, design: .rounded))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(details, id: \.self) { line in
                        Label(line, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .symbolRenderingMode(.hierarchical)
                    }
                }
            }
            OrbButton(title: buttonTitle, module: module, action: action)
            Spacer()
        }
        .padding(30)
    }
}

/// Live progress. The scan updates plain counters; this view just polls them, so a scan of a
/// million files never floods the main thread with updates.
struct ScanningView: View {
    let module: Module
    let control: ScanControl
    var title = "Scanning…"
    @State private var spin = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle().stroke(Color.track, lineWidth: 10)
                Circle().trim(from: 0, to: 0.3)
                    .stroke(module.gradient, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: spin)
                    .shadow(color: module.accent.opacity(0.6), radius: 8)
                Circle().trim(from: 0, to: 0.18)
                    .stroke(module.colors[1].opacity(0.7), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .padding(16)
                    .rotationEffect(.degrees(spin ? -360 : 0))
                    .animation(.linear(duration: 1.9).repeatForever(autoreverses: false), value: spin)
                Image(systemName: module.symbol).font(.system(size: 36, weight: .light)).foregroundStyle(module.gradient)
                    .scaleEffect(spin ? 1.06 : 0.94)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: spin)
            }
            .frame(width: 140, height: 140)
            .onAppear { spin = true }

            TimelineView(.periodic(from: .now, by: 0.12)) { _ in
                VStack(spacing: 6) {
                    Text(title).font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text("\(control.filesScanned.formatted()) files · \(Format.bytes(control.bytesScanned))")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Text(control.currentPath)
                        .font(.caption).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 520)
                }
            }
            Button("Stop") { control.cancel() }.buttonStyle(PillButtonStyle())
            Spacer()
        }
        .padding(30)
    }
}

struct PillButtonStyle: ButtonStyle {
    var prominent = false
    var tint: Color = .accentColor
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .foregroundStyle(prominent ? AnyShapeStyle(Color.onAccent) : AnyShapeStyle(.primary))
            .background(prominent ? AnyShapeStyle(tint) : AnyShapeStyle(Color.quietButton), in: Capsule())
            .shadow(color: prominent && enabled ? tint.opacity(0.4) : .clear, radius: 8, y: 3)
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

/// Bottom bar with the running total and the one destructive button of a module.
struct ActionBar<Leading: View>: View {
    let module: Module
    let actionTitle: String
    let enabled: Bool
    let action: () -> Void
    @ViewBuilder var leading: Leading

    var body: some View {
        HStack(spacing: 16) {
            leading
            Spacer()
            Button(actionTitle, action: action)
                .buttonStyle(PillButtonStyle(prominent: true, tint: module.accent))
                .disabled(!enabled)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Color.hairline.frame(height: 1) }
    }
}

/// "Clean 2.8 GB", or just "Clean" while nothing is ticked.
func actionTitle(_ verb: String, _ size: Int64) -> String {
    size > 0 ? "\(verb) \(Format.bytes(size))" : verb
}

struct CheckBox: View {
    enum State { case off, on, mixed }
    let state: State
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: state == .off ? "circle" : (state == .on ? "checkmark.circle.fill" : "minus.circle.fill"))
                .font(.system(size: 17))
                .foregroundStyle(state == .off ? AnyShapeStyle(.tertiary) : AnyShapeStyle(tint))
        }
        .buttonStyle(.plain)
    }
}

struct FileIcon: View {
    let url: URL
    var size: CGFloat = 28

    var body: some View {
        Image(nsImage: IconCache.icon(for: url)).resizable().frame(width: size, height: size)
    }
}

/// What happened after a removal, including anything macOS refused to let go of.
struct ReportBanner: View {
    let report: RemovalReport
    let mode: RemovalMode
    let tint: Color
    let dismiss: () -> Void
    @State private var showFailures = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: report.failures.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(report.failures.isEmpty ? tint : Color.warning)
                Text(summary).font(.callout.weight(.medium))
                Spacer()
                if !report.failures.isEmpty {
                    Button(showFailures ? "Hide details" : "Show details") { showFailures.toggle() }.buttonStyle(.link)
                }
                Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            if showFailures {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(report.failures) { failure in
                            Text("\(failure.url.lastPathComponent): \(failure.message)")
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 90)
            }
        }
        .padding(12)
        .card(cornerRadius: 10, highlighted: true)
        .padding(.horizontal, 28)
        .padding(.bottom, 10)
    }

    private var summary: String {
        var text = mode == .trash
            ? "\(Format.bytes(report.bytesFreed)) moved to the Trash. Empty it to get the space back."
            : "\(Format.bytes(report.bytesFreed)) freed."
        if report.removed.isEmpty { text = "Nothing was removed." }
        if !report.failures.isEmpty { text += " \(report.failures.count) item(s) could not be removed." }
        return text
    }
}

struct EmptyResultView: View {
    let module: Module
    let title: String
    let message: String
    let rescan: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle").font(.system(size: 56, weight: .light)).foregroundStyle(module.gradient)
            Text(title).font(.system(size: 22, weight: .bold, design: .rounded))
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Scan Again", action: rescan).buttonStyle(PillButtonStyle()).padding(.top, 6)
            Spacer()
        }
    }
}

extension Date {
    var relativeDescription: String {
        if self == .distantPast { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: self, relativeTo: .now)
    }
}
