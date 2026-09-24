import Foundation
import Darwin
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import SystemConfiguration
import AppKit
import DiskArbitration

// MARK: - Swap and load

public struct SwapUsage: Sendable, Equatable {
    public let used: Int64
    public let total: Int64

    /// macOS grows swap files on demand; any use at all means RAM ran short at some point.
    public static func current() -> SwapUsage? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return SwapUsage(used: Int64(usage.xsu_used), total: Int64(usage.xsu_total))
    }
}

public enum LoadAverage {
    /// Runnable threads averaged over 1, 5 and 15 minutes.
    public static func current() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? loads : []
    }
}

// MARK: - Power

public struct PowerDetails: Sendable, Equatable {
    /// Minutes until empty (on battery) or full (charging). Nil while macOS is still estimating.
    public var minutesRemaining: Int?
    public var onAdapter = false
    public var charging = false
    /// Rated wattage of the connected power adapter.
    public var adapterWatts: Int?
    /// What the whole Mac is drawing right now, in watts, from the battery's power telemetry.
    public var systemWatts: Double?
    public var batteryTemperature: Double?

    public init() {}

    public static func current() -> PowerDetails {
        var details = PowerDetails()
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                      (info[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
                details.onAdapter = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
                details.charging = (info[kIOPSIsChargingKey] as? Bool) ?? false
                let key = details.charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
                if let minutes = info[key] as? Int, minutes > 0, minutes < 65535 { details.minutesRemaining = minutes }
                if details.onAdapter, !details.charging { details.minutesRemaining = nil }
            }
        }
        if let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            details.adapterWatts = adapter[kIOPSPowerAdapterWattsKey] as? Int
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            // Hundredths of a degree Celsius.
            // Top-level on older macOS, inside "BatteryData" on newer versions.
            let centi = (property("Temperature") as? Int) ?? ((property("BatteryData") as? [String: Any])?["Temperature"] as? Int)
            if let centi, centi > 0 { details.batteryTemperature = Double(centi) / 100 }
            // Milliwatts drawn by the whole system, whether it comes from the adapter or the battery.
            if let telemetry = property("PowerTelemetryData") as? [String: Any],
               let milliwatts = telemetry["SystemLoad"] as? Int, milliwatts > 0 {
                details.systemWatts = Double(milliwatts) / 1000
            } else if let millivolts = property("Voltage") as? Int, let milliamps = property("InstantAmperage") as? Int, milliamps < 0 {
                details.systemWatts = Double(millivolts) * Double(-milliamps) / 1_000_000
            }
        }
        return details
    }
}

// MARK: - Network link

public struct NetworkLink: Sendable, Equatable {
    public enum Kind: String, Sendable { case wifi = "Wi-Fi", ethernet = "Ethernet", other = "Network" }

    public let interface: String
    public let kind: Kind
    public let address: String
    /// A tunnel interface (utun, ipsec, ppp) carries an IPv4 address: a VPN is up.
    public let vpnActive: Bool

    /// The first up-and-running Ethernet-style interface with an IPv4 address. SSIDs are left
    /// out on purpose: reading them needs Location Services.
    public static func current() -> NetworkLink? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var primary: (name: String, address: String)?
        var tunnel = false
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  let socket = entry.pointee.ifa_addr, socket.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(socket, socklen_t(socket.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") {
                tunnel = true
            } else if name.hasPrefix("en"), primary == nil {
                primary = (name, String(cString: host))
            }
        }
        guard let primary else { return nil }
        return NetworkLink(interface: primary.name, kind: kind(of: primary.name), address: primary.address, vpnActive: tunnel)
    }

    private static let kindCache = NSCache<NSString, NSString>()

    private static func kind(of bsdName: String) -> Kind {
        if let cached = kindCache.object(forKey: bsdName as NSString) { return Kind(rawValue: cached as String) ?? .other }
        var result = Kind.other
        for interface in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
            guard (SCNetworkInterfaceGetBSDName(interface) as String?) == bsdName,
                  let type = SCNetworkInterfaceGetInterfaceType(interface) as String? else { continue }
            result = type == (kSCNetworkInterfaceTypeIEEE80211 as String) ? .wifi
                : (type == (kSCNetworkInterfaceTypeEthernet as String) ? .ethernet : .other)
        }
        kindCache.setObject(result.rawValue as NSString, forKey: bsdName as NSString)
        return result
    }
}

// MARK: - Disk

public struct DiskSpace: Sendable, Equatable {
    public let total: Int64
    /// Truly free blocks.
    public let free: Int64
    /// Free plus purgeable: what macOS will make available when something asks for it.
    public let available: Int64

    /// Space held by local Time Machine snapshots, iCloud-evictable files and caches that macOS
    /// clears by itself as the disk fills.
    public var purgeable: Int64 { max(0, available - free) }
    public var used: Int64 { max(0, total - available) }

    public static func startupVolume() -> DiskSpace? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity else { return nil }
        let free = Int64(values.volumeAvailableCapacity ?? 0)
        return DiskSpace(total: Int64(total), free: free,
                         available: max(free, values.volumeAvailableCapacityForImportantUsage ?? free))
    }
}

// MARK: - Keep awake

/// Holds the display (and so the Mac) awake, the way `caffeinate -d` does. The assertion is
/// given a timeout, so macOS itself ends it on time even if Sweepwell quits or crashes.
public final class KeepAwake: @unchecked Sendable {
    public static let assertionName = "Sweepwell Keep Awake"

    private var assertion: IOPMAssertionID = 0
    public private(set) var endsAt: Date?
    public private(set) var isIndefinite = false

    public init() {}

    public var isActive: Bool {
        guard assertion != 0 else { return false }
        if let endsAt, endsAt <= Date() { stop(); return false }
        return true
    }

    /// - Parameter duration: nil keeps the Mac awake until `stop()` or quit.
    @discardableResult
    public func start(for duration: TimeInterval?) -> Bool {
        stop()
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 Self.assertionName as CFString, &id)
        guard status == kIOReturnSuccess else { return false }
        if let duration {
            IOPMAssertionSetProperty(id, kIOPMAssertionTimeoutKey as CFString, NSNumber(value: duration))
            IOPMAssertionSetProperty(id, kIOPMAssertionTimeoutActionKey as CFString, kIOPMAssertionTimeoutActionRelease as CFString)
            endsAt = Date().addingTimeInterval(duration)
        } else {
            endsAt = nil
        }
        isIndefinite = duration == nil
        assertion = id
        return true
    }

    public func stop() {
        if assertion != 0 { IOPMAssertionRelease(assertion) }
        assertion = 0
        endsAt = nil
        isIndefinite = false
    }

    deinit { stop() }
}

// MARK: - Ejecting

extension ExternalVolume {
    /// Unmounts and, for a physical drive, powers it down so it can be unplugged.
    public func eject() throws {
        try NSWorkspace.shared.unmountAndEjectDevice(at: url)
    }

    /// Disk images mounted from a .dmg, as opposed to physical drives.
    public var isDiskImage: Bool {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any] else { return false }
        return (description[kDADiskDescriptionDeviceModelKey as String] as? String)?.contains("Disk Image") ?? false
    }
}

