import SwiftUI
import AppKit
import IOKit
import SweepwellKit

/// The panel is one sheet of glass. The dial blends a tinted solid over it, exactly like the
/// cards in the main window, so both respond to the same control.
struct PanelBackground: View {
    let glass: Double

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        let wash = LinearGradient(colors: [Module.overview.colors[1].opacity(0.22), Module.duplicates.colors[0].opacity(0.16)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        if #available(macOS 26.0, *), glass >= 0.05 {
            ZStack {
                // The panel floats over arbitrary windows and their text. Clear glass does not
                // blur, so here the dial only thins the tint and the glass itself stays frosted.
                shape.fill(Color.panelSolid.opacity(max(0.1, 1 - glass)))
                shape.fill(wash)
            }
            .glassEffect(.regular, in: shape)
        } else {
            ZStack {
                VibrantBackground(material: .popover).clipShape(shape)
                shape.fill(Color.panelSolid.opacity(1 - glass * 0.8))
                shape.fill(wash)
                shape.strokeBorder(Color.hairline)
            }
        }
    }
}

enum MacModel {
    /// "MacBook Pro (14-inch, Nov 2024)" from the device tree; the computer's name otherwise.
    static let name: String = {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        defer { if entry != 0 { IOObjectRelease(entry) } }
        if entry != 0,
           let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data,
           let name = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters.union(.whitespaces)), !name.isEmpty {
            return name
        }
        return Host.current().localizedName ?? "This Mac"
    }()
}

/// The "how glassy" dial, shared by the sidebar and Settings.
struct GlassSlider: View {
    @AppStorage(Preferences.glassKey) private var glass = Glassiness.default
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Glass", systemImage: "drop.halffull").font(compact ? .caption.weight(.semibold) : .body)
                Spacer()
                Text(Glassiness.label(glass)).font(.caption).foregroundStyle(.secondary)
                    .contentTransition(.opacity).animation(.easeOut(duration: 0.2), value: Glassiness.label(glass))
            }
            Slider(value: $glass, in: 0...1) {
                EmptyView()
            } minimumValueLabel: {
                Image(systemName: "square.fill").font(.system(size: 8)).foregroundStyle(.tertiary)
            } maximumValueLabel: {
                Image(systemName: "square.dashed").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .controlSize(compact ? .mini : .regular)
            .tint(Module.spaceLens.accent)
            if !compact {
                Text("From solid cards to clear Liquid Glass that lets your desktop through. Applies to the window and the menu bar panel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
