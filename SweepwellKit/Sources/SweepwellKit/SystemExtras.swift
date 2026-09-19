import Foundation
import Darwin
import IOKit

// MARK: - Memory pressure

public enum MemoryPressure {
    /// 0…1. The kernel publishes how much memory it still considers available (0–100);
    /// pressure is the remainder. This is the figure behind Activity Monitor's pressure graph.
    public static func current() -> Double? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 else { return nil }
        return Double(100 - max(0, min(100, level))) / 100
    }
}

// MARK: - Network throughput

public struct NetworkCounters: Sendable {
    public var received: UInt64 = 0
    public var sent: UInt64 = 0

    /// Totals over the physical interfaces (en*). `NET_RT_IFLIST2` carries 64-bit counters;
    /// the `getifaddrs` ones are 32-bit and wrap every 4 GB.
    public static func current() -> NetworkCounters {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return .init() }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: 8)
        defer { buffer.deallocate() }
        guard sysctl(&mib, UInt32(mib.count), buffer, &length, nil, 0) == 0 else { return .init() }

        var totals = NetworkCounters()
        var offset = 0
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        while offset + MemoryLayout<if_msghdr>.size <= length {
            let header = (buffer + offset).loadUnaligned(as: if_msghdr.self)
            guard header.ifm_msglen > 0 else { break }
            if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                let info = (buffer + offset).loadUnaligned(as: if_msghdr2.self)
                if if_indextoname(UInt32(info.ifm_index), &name) != nil, String(cString: name).hasPrefix("en") {
                    totals.received += info.ifm_data.ifi_ibytes
                    totals.sent += info.ifm_data.ifi_obytes
                }
            }
            offset += Int(header.ifm_msglen)
        }
        return totals
    }
}

// MARK: - CPU temperature

/// Apple silicon has no public temperature API. The thermal sensors are reachable through
/// the HID event system, whose entry points are resolved at run time: if a future macOS
/// drops them, `cpuTemperature()` just returns nil and the UI falls back to thermal state.
public final class ThermalSensors: @unchecked Sendable {
    private typealias Create = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias SetMatching = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (UnsafeMutableRawPointer) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (UnsafeRawPointer, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEvent = @convention(c) (UnsafeRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias GetFloat = @convention(c) (UnsafeRawPointer, Int32) -> Double

    private static let temperatureEvent: Int64 = 15
    private static let temperatureField: Int32 = 15 << 16

    private let client: UnsafeMutableRawPointer
    private let copyServices: CopyServices
    private let copyProperty: CopyProperty
    private let copyEvent: CopyEvent
    private let getFloat: GetFloat
    private let lock = NSLock()

    public init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let create = symbol("IOHIDEventSystemClientCreate", as: Create.self),
              let setMatching = symbol("IOHIDEventSystemClientSetMatching", as: SetMatching.self),
              let copyServices = symbol("IOHIDEventSystemClientCopyServices", as: CopyServices.self),
              let copyProperty = symbol("IOHIDServiceClientCopyProperty", as: CopyProperty.self),
              let copyEvent = symbol("IOHIDServiceClientCopyEvent", as: CopyEvent.self),
              let getFloat = symbol("IOHIDEventGetFloatValue", as: GetFloat.self),
              let client = create(kCFAllocatorDefault) else { return nil }
        // Vendor page 0xff00, usage 5: temperature sensors.
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        self.client = client
        self.copyServices = copyServices
        self.copyProperty = copyProperty
        self.copyEvent = copyEvent
        self.getFloat = getFloat
    }

    /// The hottest CPU die sensor, in °C: the figure temperature monitors conventionally show,
    /// since one busy core throttles the chip long before the average moves.
    public func cpuTemperature() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let services = copyServices(client)?.takeRetainedValue() else { return nil }
        var die: [Double] = []
        var any: [Double] = []
        for index in 0..<CFArrayGetCount(services) {
            guard let service = CFArrayGetValueAtIndex(services, index),
                  let event = copyEvent(service, Self.temperatureEvent, 0, 0) else { continue }
            let value = getFloat(event, Self.temperatureField)
            Unmanaged<AnyObject>.fromOpaque(event).release()
            guard value > 0, value < 130 else { continue }
            any.append(value)
            let name = (copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String) ?? ""
            // "PMU tdie*" on M1/M2, "pACC"/"eACC" cluster sensors on later chips.
            if name.contains("tdie") || name.contains("ACC") { die.append(value) }
        }
        let values = die.isEmpty ? any : die
        return values.max()
    }
}

// MARK: - Battery health

public struct BatteryHealth: Sendable {
    public let cycleCount: Int
    /// Present full-charge capacity relative to the design capacity, 0…1.
    public let capacity: Double

    public static func current() -> BatteryHealth? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        // Newer macOS versions tuck the raw capacities into a nested "BatteryData" dictionary.
        let nested = property("BatteryData") as? [String: Any]
        func number(_ key: String) -> Int? { (property(key) as? Int) ?? (nested?[key] as? Int) }
        guard let cycles = number("CycleCount"), let design = number("DesignCapacity"), design > 0,
              let maximum = number("AppleRawMaxCapacity") ?? number("NominalChargeCapacity") else { return nil }
        return BatteryHealth(cycleCount: cycles, capacity: min(1, Double(maximum) / Double(design)))
    }
}

// MARK: - Connected volumes

public struct ExternalVolume: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let total: Int64
    public let available: Int64

    /// External drives, cards and mounted disk images: everything that can be ejected.
    public static func mounted() -> [ExternalVolume] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsRemovableKey,
                                      .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard url.path != "/", let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable ?? true else { return nil }
            let external = !(values.volumeIsInternal ?? true) || (values.volumeIsEjectable ?? false) || (values.volumeIsRemovable ?? false)
            guard external else { return nil }
            return ExternalVolume(url: url, name: values.volumeName ?? url.lastPathComponent,
                                  total: Int64(values.volumeTotalCapacity ?? 0),
                                  available: Int64(values.volumeAvailableCapacity ?? 0))
        }
    }
}

// MARK: - Health score

public struct HealthAssessment: Sendable, Equatable {
    public enum Grade: String, Sendable { case good = "Good", fair = "Fair", poor = "Needs attention" }
    public let score: Int
    public var grade: Grade { score >= 80 ? .good : (score >= 55 ? .fair : .poor) }
    /// Human-readable reasons points were taken off, most serious first.
    public let concerns: [String]

    public static func assess(_ s: SystemSnapshot, brokenLaunchItems: Int = 0) -> HealthAssessment {
        var deductions: [(Int, String)] = []
        let free = 1 - s.diskFraction
        if s.diskTotal > 0 {
            if free < 0.10 { deductions.append((30, "Startup disk is almost full")) }
            else if free < 0.20 { deductions.append((15, "Startup disk is getting full")) }
        }
        if s.memoryPressure > 0.80 { deductions.append((25, "Memory pressure is high")) }
        else if s.memoryPressure > 0.60 { deductions.append((10, "Memory pressure is elevated")) }
        switch s.thermalState {
        case .critical: deductions.append((30, "Mac is critically hot"))
        case .serious: deductions.append((20, "Mac is hot and throttling"))
        case .fair: deductions.append((5, "Mac is running warm"))
        default: break
        }
        if let health = s.batteryHealth, health < 0.80 { deductions.append((10, "Battery capacity is reduced")) }
        if brokenLaunchItems > 0 { deductions.append((min(10, brokenLaunchItems * 5), "Broken startup items")) }
        deductions.sort { $0.0 > $1.0 }
        return HealthAssessment(score: max(0, 100 - deductions.reduce(0) { $0 + $1.0 }), concerns: deductions.map(\.1))
    }
}
