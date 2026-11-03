import Foundation
import IOKit

/// How hard something is working, in four steps: green, yellow, orange, red.
public enum LoadLevel: Int, Comparable, Sendable, CaseIterable {
    case calm, busy, heavy, critical

    public static func < (a: LoadLevel, b: LoadLevel) -> Bool { a.rawValue < b.rawValue }

    /// Processor or graphics use, 0…1.
    public static func usage(_ fraction: Double) -> LoadLevel {
        switch fraction {
        case ..<0.5: .calm
        case ..<0.75: .busy
        case ..<0.9: .heavy
        default: .critical
        }
    }

    /// Memory pressure, 0…1 (macOS's own measure, not how much RAM is filled: macOS keeps RAM
    /// full on purpose).
    public static func memory(_ pressure: Double) -> LoadLevel {
        switch pressure {
        case ..<0.6: .calm
        case ..<0.75: .busy
        case ..<0.9: .heavy
        default: .critical
        }
    }

    /// Processor die temperature in °C. Apple silicon is designed to run warm under load and
    /// slows itself down near 100 °C.
    public static func temperature(_ celsius: Double) -> LoadLevel {
        switch celsius {
        case ..<60: .calm
        case ..<75: .busy
        case ..<90: .heavy
        default: .critical
        }
    }

    public var word: String {
        switch self {
        case .calm: "Calm"
        case .busy: "Busy"
        case .heavy: "Heavy"
        case .critical: "Maxed"
        }
    }
}

/// Graphics processor use, from the GPU driver's own statistics (no privileges needed).
public enum GPUUsage {
    public static func current() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
                  let percent = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { continue }
            best = max(best ?? 0, min(100, max(0, percent)) / 100)
        }
        return best
    }
}
