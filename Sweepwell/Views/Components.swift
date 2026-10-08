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
                IconDisc(symbol: module.symbol, color: module.colors[1], size: 48)
                    .padding(4)
                    .panelGlass(Circle(), interactive: true)
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
        }
        // The footer floats over the content as a glass bar; scrolling content passes under
        // it with the system's soft scroll-edge fade, as in Apple's own apps. Screens without
        // a footer get no bar at all: an empty one still takes part in layout.
        .safeAreaBar(edge: .bottom) {
            if Footer.self != EmptyView.self { footer }
        }
    }
}

extension ModuleScaffold where Footer == EmptyView {
    init(module: Module, @ViewBuilder content: () -> Content) {
        self.init(module: module, content: content, footer: { EmptyView() })
    }
}

/// The big round call-to-action in the middle of an idle module: a sphere of tinted Liquid
/// Glass that bends the colours behind it and responds to the pointer. Halo rings ripple out
/// on hover only; at rest nothing animates, so an idle window costs no CPU.
struct OrbButton: View {
    let title: String
    let module: Module
    var diameter: CGFloat = 132
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                ForEach(0..<2, id: \.self) { ring in
                    Circle()
                        .stroke(module.accent.opacity(hovering ? 0 : 0.3), lineWidth: 1.5)
                        .frame(width: diameter, height: diameter)
                        .scaleEffect(hovering ? 1.45 + CGFloat(ring) * 0.22 : 1.12 + CGFloat(ring) * 0.1)
                        .animation(.easeOut(duration: hovering ? 1.1 : 0.4).delay(hovering ? Double(ring) * 0.18 : 0),
                                   value: hovering)
                }
                // A soft pool of the module's colour for the glass to refract.
                Circle().fill(module.gradient).frame(width: diameter * 0.9, height: diameter * 0.9)
                    .blur(radius: 18).opacity(0.85)
                Text(title)
                    .font(.system(size: diameter * 0.17, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    .frame(width: diameter, height: diameter)
                    .glassEffect(.control(tint: module.accent.opacity(0.55)), in: .circle)
            }
            .frame(width: diameter * 1.9, height: diameter * 1.35)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
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

/// Sweepwell's button: a capsule of interactive Liquid Glass, tinted with the module colour
/// when it is the primary action. Inside a glass bar it draws as plain text, so glass is
/// never stacked on glass.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    var tint: Color = .accentColor
    var large = false
    /// Text on a prominent button. White by default; dark on light fills such as yellow,
    /// where white cannot be read.
    var labelColor: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, prominent: prominent, tint: tint, large: large, labelColor: labelColor)
    }
}

private struct PillButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let prominent: Bool
    let tint: Color
    let large: Bool
    let labelColor: Color
    @Environment(\.isEnabled) private var enabled
    @Environment(\.onGlass) private var onGlass
    @State private var hovering = false

    var body: some View {
        let label = configuration.label
            .font(.system(size: large ? 14 : 13, weight: .semibold))
            .padding(.horizontal, large ? 22 : 16)
            .padding(.vertical, large ? 10 : 7)
        Group {
            if onGlass {
                // Already on a glass module: a plain capsule, tinted solid when primary.
                label
                    .foregroundStyle(prominent ? AnyShapeStyle(labelColor) : AnyShapeStyle(.primary))
                    .background(prominent ? AnyShapeStyle(tint) : AnyShapeStyle(hovering || configuration.isPressed ? Color.selectionFill : Color.quietButton),
                                in: Capsule())
            } else {
                label
                    .foregroundStyle(prominent ? AnyShapeStyle(labelColor) : AnyShapeStyle(.primary))
                    .glassEffect(.control(tint: prominent ? tint : nil), in: .capsule)
            }
        }
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
    }
}

/// The floating bar at the bottom of a module: the running total in one glass capsule, the
/// module's one primary action in another, tinted. They share a glass container, so they
/// read as one piece of glass that parts in the middle.
struct ActionBar<Leading: View>: View {
    let module: Module
    let actionTitle: String
    let enabled: Bool
    let action: () -> Void
    @ViewBuilder var leading: Leading

    var body: some View {
        GlassEffectContainer(spacing: 16) {
            HStack(spacing: 12) {
                HStack(spacing: 14) { leading }
                    .environment(\.onGlass, true)
                    .padding(.leading, 20).padding(.trailing, 8).padding(.vertical, 7)
                    .glassEffect(.regular, in: .capsule)
                Spacer(minLength: 12)
                Button(actionTitle, action: action)
                    .buttonStyle(PillButtonStyle(prominent: true, tint: module.accent, large: true))
                    .disabled(!enabled)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 18)
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
        .padding(.horizontal, 16).padding(.vertical, 12)
        .floatingGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
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

/// The round badge at the front of a module: white with a coloured glyph when it stands for
/// something live or on, dim glass otherwise, as in Control Center.
struct IconDisc: View {
    let symbol: String
    var isAsset = false
    let color: Color
    var on = true
    var size: CGFloat = 38

    var body: some View {
        Group {
            if isAsset {
                Image(symbol).resizable().renderingMode(.template).scaledToFit().frame(width: size * 0.48, height: size * 0.48)
            } else {
                Image(systemName: symbol).font(.system(size: size * 0.42, weight: .semibold))
            }
        }
        .foregroundStyle(on ? color : Color.primary)
        .frame(width: size, height: size)
        .background(on ? AnyShapeStyle(.white) : AnyShapeStyle(Color.quietButton), in: Circle())
    }
}
