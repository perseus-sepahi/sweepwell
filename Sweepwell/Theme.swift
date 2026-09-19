import SwiftUI

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

    var colors: [Color] {
        switch self {
        case .overview: [Color(hex: 0x35E0B2), Color(hex: 0x1C9FD8)]
        case .junk: [Color(hex: 0xFFA14A), Color(hex: 0xF0487E)]
        case .largeFiles: [Color(hex: 0x5AA2FF), Color(hex: 0x7B5CF5)]
        case .duplicates: [Color(hex: 0xB07CFF), Color(hex: 0xF062B5)]
        case .spaceLens: [Color(hex: 0x43D9F0), Color(hex: 0x3B7BF2)]
        case .uninstaller: [Color(hex: 0xFF7A59), Color(hex: 0xE5395F)]
        case .startup: [Color(hex: 0xF7D34B), Color(hex: 0x5FCB6B)]
        case .maintenance: [Color(hex: 0x4FE0C0), Color(hex: 0x3FA66B)]
        }
    }

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

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    static let canvasTop = Color(hex: 0x1B1E33)
    static let canvasBottom = Color(hex: 0x0E1020)
    static let sidebar = Color(hex: 0x12142A)
}

struct CardBackground: ViewModifier {
    var cornerRadius: CGFloat = 14
    var highlighted = false

    func body(content: Content) -> some View {
        content
            .background(.white.opacity(highlighted ? 0.11 : 0.06), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }
}

extension View {
    func card(cornerRadius: CGFloat = 14, highlighted: Bool = false) -> some View {
        modifier(CardBackground(cornerRadius: cornerRadius, highlighted: highlighted))
    }
}
