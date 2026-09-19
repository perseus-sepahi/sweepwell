import SwiftUI
import AppKit

// MARK: - Appearance

enum AppearanceMode: String, CaseIterable, Identifiable {
    case auto, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .light: "Day"
        case .dark: "Night"
        }
    }

    var symbol: String {
        switch self {
        case .auto: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.stars.fill"
        }
    }

    /// `nil` hands control back to macOS, so the app follows the system's day/night switch.
    /// Set on NSApp rather than through `.preferredColorScheme`, which does not reliably
    /// return to automatic once it has been forced.
    @MainActor func apply() {
        switch self {
        case .auto: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    static var stored: AppearanceMode {
        // UI checks can force a theme for one launch without touching the saved choice.
        if let forced = ProcessInfo.processInfo.environment["SWEEPWELL_THEME"].flatMap(AppearanceMode.init(rawValue:)) {
            return forced
        }
        return AppearanceMode(rawValue: UserDefaults.standard.string(forKey: Preferences.appearanceKey) ?? "") ?? .auto
    }
}

// MARK: - Colour tokens

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }

    /// A colour with a day and a night value. AppKit re-resolves it whenever the effective
    /// appearance changes, so views never have to watch the colour scheme themselves.
    init(day: UInt32, night: UInt32, dayAlpha: Double = 1, nightAlpha: Double = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isNight = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isNight ? night : day
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: isNight ? nightAlpha : dayAlpha)
        })
    }

    // Window
    static let canvasTop = Color(day: 0xF7F8FD, night: 0x1B1E33)
    static let canvasBottom = Color(day: 0xE8EBF7, night: 0x0D0F1E)
    static let sidebarTint = Color(day: 0xFFFFFF, night: 0x0B0D1C, dayAlpha: 0.35, nightAlpha: 0.45)

    // Surfaces: white cards with shadows by day, translucent glass by night.
    static let surface = Color(day: 0xFFFFFF, night: 0xFFFFFF, dayAlpha: 0.78, nightAlpha: 0.06)
    static let surfaceRaised = Color(day: 0xFFFFFF, night: 0xFFFFFF, dayAlpha: 1, nightAlpha: 0.12)
    static let hairline = Color(day: 0x1A1F44, night: 0xFFFFFF, dayAlpha: 0.08, nightAlpha: 0.09)
    static let cardShadow = Color(day: 0x2A3170, night: 0x000000, dayAlpha: 0.10, nightAlpha: 0)
    static let barBackground = Color(day: 0xFFFFFF, night: 0x000000, dayAlpha: 0.6, nightAlpha: 0.28)
    static let well = Color(day: 0x1A1F44, night: 0x000000, dayAlpha: 0.05, nightAlpha: 0.25)

    // Controls
    static let track = Color(day: 0x1A1F44, night: 0xFFFFFF, dayAlpha: 0.09, nightAlpha: 0.09)
    static let hoverFill = Color(day: 0x1A1F44, night: 0xFFFFFF, dayAlpha: 0.05, nightAlpha: 0.05)
    static let selectionFill = Color(day: 0x1A1F44, night: 0xFFFFFF, dayAlpha: 0.08, nightAlpha: 0.11)
    static let quietButton = Color(day: 0x1A1F44, night: 0xFFFFFF, dayAlpha: 0.08, nightAlpha: 0.13)
    /// Text on top of an accent fill: accents are bright at night and deep by day.
    static let onAccent = Color(day: 0xFFFFFF, night: 0x0B0D1C)

    static let warning = Color(day: 0xB46A00, night: 0xFFD60A)
    static let danger = Color(day: 0xD62A3D, night: 0xFF6B6B)
    static let success = Color(day: 0x1F9D55, night: 0x4ADE80)
}

// MARK: - Modules

enum Module: String, CaseIterable, Identifiable {
    case overview, junk, largeFiles, duplicates, spaceLens, uninstaller, startup, maintenance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .junk: "System Junk"
        case .largeFiles: "Large & Old Files"
        case .duplicates: "Duplicates"
        case .spaceLens: "Space Lens"
        case .uninstaller: "Uninstaller"
        case .startup: "Startup & Activity"
        case .maintenance: "Maintenance"
        }
    }

    var tagline: String {
        switch self {
        case .overview: "One look at how your Mac is doing, one button to tidy it up."
        case .junk: "Caches, logs and build leftovers that your Mac recreates when it needs them."
        case .largeFiles: "The heavy files you forgot about, sorted so the easy wins come first."
        case .duplicates: "Byte-for-byte identical files that are taking up space twice."
        case .spaceLens: "A map of your disk. The bigger the block, the more space it takes."
        case .uninstaller: "Remove apps together with the support files they scatter around."
        case .startup: "What launches behind your back, and what is using your Mac right now."
        case .maintenance: "Safe, well-known fixes for a Mac that is acting up."
        }
    }

    var symbol: String {
        switch self {
        case .overview: "sparkles"
        case .junk: "bubbles.and.sparkles"
        case .largeFiles: "doc.badge.clock"
        case .duplicates: "square.on.square"
        case .spaceLens: "square.grid.3x3.topleft.filled"
        case .uninstaller: "xmark.bin"
        case .startup: "bolt"
        case .maintenance: "wrench.and.screwdriver"
        }
    }

    /// (day, night) pairs. Night accents glow against navy; on white the same hues wash out,
    /// so the day values are a few steps deeper.
    private var palette: [(day: UInt32, night: UInt32)] {
        switch self {
        case .overview: [(0x10B68D, 0x35E0B2), (0x1583C4, 0x1C9FD8)]
        case .junk: [(0xF2842A, 0xFFA14A), (0xE0336C, 0xF0487E)]
        case .largeFiles: [(0x3B82F0, 0x5AA2FF), (0x6A45E8, 0x7B5CF5)]
        case .duplicates: [(0x9556F0, 0xB07CFF), (0xE0439F, 0xF062B5)]
        case .spaceLens: [(0x12AECB, 0x43D9F0), (0x2F66E0, 0x3B7BF2)]
        case .uninstaller: [(0xF25C38, 0xFF7A59), (0xD62A52, 0xE5395F)]
        case .startup: [(0xE3A400, 0xF7D34B), (0x35A84A, 0x5FCB6B)]
        case .maintenance: [(0x14B391, 0x4FE0C0), (0x2E9459, 0x3FA66B)]
        }
    }

    var colors: [Color] { palette.map { Color(day: $0.day, night: $0.night) } }

    var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var accent: Color { colors[0] }

    static let sections: [(String, [Module])] = [
        ("", [.overview]),
        ("Cleanup", [.junk, .largeFiles, .duplicates, .spaceLens]),
        ("Applications", [.uninstaller]),
        ("Speed", [.startup, .maintenance])
    ]
}

// MARK: - Surfaces

struct CardBackground: ViewModifier {
    var cornerRadius: CGFloat = 16
    var highlighted = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(highlighted ? Color.surfaceRaised : Color.surface, in: shape)
            .overlay(shape.strokeBorder(Color.hairline))
            .shadow(color: .cardShadow, radius: highlighted ? 14 : 9, y: highlighted ? 6 : 3)
    }
}

extension View {
    func card(cornerRadius: CGFloat = 16, highlighted: Bool = false) -> some View {
        modifier(CardBackground(cornerRadius: cornerRadius, highlighted: highlighted))
    }
}

/// Behind-window vibrancy, so the sidebar picks up the desktop like Finder's does.
struct VibrantBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}

/// Slow, blurred colour fields in the active module's hues. Purely decorative, so it sits
/// behind everything and ignores hit testing.
struct AuroraBackground: View {
    let module: Module
    @State private var drift = false

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            ZStack {
                LinearGradient(colors: [.canvasTop, .canvasBottom], startPoint: .top, endPoint: .bottom)
                Circle().fill(module.colors[0].opacity(0.30))
                    .frame(width: w * 0.7).blur(radius: 110)
                    .offset(x: w * (drift ? 0.34 : 0.26), y: -h * (drift ? 0.42 : 0.34))
                Circle().fill(module.colors[1].opacity(0.24))
                    .frame(width: w * 0.55).blur(radius: 120)
                    .offset(x: -w * (drift ? 0.30 : 0.38), y: h * (drift ? 0.40 : 0.48))
            }
            .frame(width: w, height: h)
            .clipped()
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { drift = true }
        }
    }
}
