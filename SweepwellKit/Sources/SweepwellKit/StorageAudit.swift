import Foundation
import Darwin

/// One line of the storage audit: what it is, how big, what removing it costs, and how it would
/// be removed. The audit itself is read-only; nothing here deletes anything.
public struct AuditItem: Identifiable, Sendable, Hashable {
    public enum Group: String, CaseIterable, Sendable {
        case caches = "A", machines = "B", ai = "C", toolchains = "D", hidden = "E", large = "F"

        public var title: String {
            switch self {
            case .caches: "Pure caches"
            case .machines: "VMs, simulators, emulators"
            case .ai: "AI tools and models"
            case .toolchains: "Developer toolchains"
            case .hidden: "Other hidden folders"
            case .large: "Not hidden, but large"
            }
        }

        public var summary: String {
            switch self {
            case .caches: "Rebuild by themselves. The safest space to take back."
            case .machines: "Usually the biggest group. Cost: re-downloads and slow first starts."
            case .ai: "Local models and AI coding tools. Models re-download; tool settings may be lost."
            case .toolchains: "SDKs and language tools. Check that nothing you build still needs them."
            case .hidden: "Big hidden folders Sweepwell cannot identify. Shown so you know they are there."
            case .large: "Your own files and apps. Listed for context, never proposed for removal."
            }
        }
    }

    public enum Removal: Sendable, Hashable {
        /// A folder Sweepwell can move to the Trash (recoverable).
        case trash
        /// A permanent, tool-driven deletion: shown for the user to run themselves.
        case command(String)
        /// Too risky or too privileged to offer: shown in Finder only.
        case reveal
    }

    public var id: String
    public let group: Group
    public let title: String
    public let url: URL?
    public let size: Int64
    /// What removing it costs: a re-download, a rebuild, lost settings or data.
    public let cost: String
    public let removal: Removal
    public var lastUsed: Date?
    /// True when `lastUsed` came from the tool itself (simulators, runtimes); otherwise it is
    /// the last time the folder's contents changed. Access times are useless here: measuring a
    /// folder, or any earlier scan, updates them.
    public var lastUsedFromTool = false
    /// Pre-flight findings: running, booted, mentioned in shell config, default toolchain…
    public var warnings: [String]
    /// Part of the low-regret set.
    public let recommended: Bool

    public init(group: Group, title: String, url: URL?, size: Int64, cost: String, removal: Removal,
                lastUsed: Date? = nil, warnings: [String] = [], recommended: Bool = false) {
        self.id = ""
        self.group = group
        self.title = title
        self.url = url
        self.size = size
        self.cost = cost
        self.removal = removal
        self.lastUsed = lastUsed
        self.warnings = warnings
        self.recommended = recommended && warnings.isEmpty
    }
}

public struct StorageAuditReport: Sendable {
    public var items: [AuditItem]
    public var disk: DiskSpace?
    /// Directories the scan was not allowed into (usually missing Full Disk Access).
    public var deniedDirectories: Int
    /// Tools that did not answer in time, and what is missing from the map because of it.
    public var notes: [String] = []

    public func items(in group: AuditItem.Group) -> [AuditItem] { items.filter { $0.group == group } }
    public func total(of group: AuditItem.Group) -> Int64 { items(in: group).reduce(0) { $0 + $1.size } }
}

/// Where the space goes that a normal scan cannot see.
public struct StorageAccounting: Sendable {
    /// What APFS says the Data volume uses.
    public var consumed: Int64
    /// What could actually be read and measured.
    public var readable: Int64
    public var gap: Int64 { max(0, consumed - readable) }
    /// Files deleted while still open; their space returns when the app closes them.
    public var heldByOpenFiles: Int64
    public var localSnapshots: Int
    public var deniedDirectories: Int
}

/// The `mac-storage-audit` workflow as a library: a read-only map of hidden dotfolders,
/// caches, VMs, simulators, models and toolchains, grouped A–F with stable IDs.
public struct StorageAuditor: Sendable {
    public let environment: ScanEnvironment
    /// Ask installed tools (simctl, ollama, limactl, rustup, brew) for their own inventories.
    /// Off in fixture homes, so tests never touch the real machine.
    public let probeTools: Bool

    public init(environment: ScanEnvironment, probeTools: Bool? = nil) {
        self.environment = environment
        self.probeTools = probeTools ?? !environment.isFixture
    }

    // MARK: Scan

    public func scan(control: ScanControl = ScanControl()) -> StorageAuditReport {
        let probe = Probe(control: control, enabled: probeTools)
        var candidates: [Candidate] = []
        probe.step("Looking for caches…")
        candidates += caches()
        candidates += machines(probe)
        probe.step("Asking Ollama for its models…")
        candidates += ai(probe)
        probe.step("Looking for toolchains…")
        candidates += toolchains(probe)
        var claimed = Set(candidates.compactMap { $0.url?.standardizedFileURL.path })
        // Ollama models are listed one by one (no folder of their own), so their store is claimed.
        if candidates.contains(where: { $0.title.hasPrefix("Ollama model ") }) {
            claimed.insert(environment.homeRelative(".ollama").path)
        }
        candidates += otherHidden(claimed: claimed)
        candidates += large()

        // Activity dates first: measuring touches the folders.
        var sized = candidates
        for i in sized.indices where sized[i].lastUsed == nil {
            sized[i].lastUsed = sized[i].url.flatMap(Self.lastChange)
        } 
        let fromTool = Set(candidates.indices.filter { candidates[$0].lastUsed != nil })
        // Size every folder candidate, all cores at once; tool-reported sizes are kept.
        sized.withUnsafeMutableBufferPointer { buffer in
            let slots = UnsafeSendableBuffer(buffer)
            DispatchQueue.concurrentPerform(iterations: slots.base.count) { i in
                guard !control.isCancelled, slots.base[i].size == nil, let url = slots.base[i].url else { return }
                slots.base[i].size = DiskScanner.measure(url, control: control).bytes
            }
        }

        probe.step("Checking what is running…")
        let running = probe.enabled ? runningExecutables(probe) : []
        let shellConfig = shellConfigText()
        var items: [AuditItem] = []
        for (index, candidate) in sized.enumerated() {
            guard let size = candidate.size, size >= candidate.minimum else { continue }
            var warnings = candidate.warnings
            // Pre-flight only matters for things that can be removed from here.
            if candidate.removal != .reveal, let path = candidate.url?.path {
                if running.contains(where: { $0.hasPrefix(path + "/") }) { warnings.append("In use by a running app") }
                if candidate.checkShellConfig, let name = candidate.url?.lastPathComponent, name.count >= 3,
                   shellConfig.contains("/" + name) {
                    warnings.append("Mentioned in your shell config")
                }
            }
            var item = AuditItem(group: candidate.group, title: candidate.title, url: candidate.url, size: size,
                                 cost: candidate.cost, removal: candidate.removal, lastUsed: candidate.lastUsed,
                                 warnings: warnings, recommended: candidate.recommended)
            item.lastUsedFromTool = fromTool.contains(index)
            items.append(item)
        }

        // Stable IDs: group letter + rank by size within the group, as in "A1, B3".
        var numbered: [AuditItem] = []
        for group in AuditItem.Group.allCases {
            let ranked = items.filter { $0.group == group }.sorted { $0.size > $1.size }
            for (index, var item) in ranked.enumerated() {
                item.id = "\(group.rawValue)\(index + 1)"
                numbered.append(item)
            }
        }
        return StorageAuditReport(items: numbered, disk: environment.isFixture ? nil : DiskSpace.startupVolume(),
                                  deniedDirectories: control.inaccessibleDirectories, notes: probe.notes)
    }

    // MARK: A. Pure caches

    private func caches() -> [Candidate] {
        var list: [Candidate] = [
            folder(.caches, "Library/Developer/Xcode/DerivedData", "Xcode build data", "Full rebuild of each project next time", recommended: true),
            folder(.caches, ".gradle/caches", "Gradle caches", "The next Gradle or Android build re-downloads dependencies", recommended: true),
            folder(.caches, ".npm/_cacache", "npm cache", "Re-downloaded on the next install", recommended: true),
            folder(.caches, ".npm/_npx", "npx packages", "Re-downloaded the next time npx runs them", recommended: true),
            folder(.caches, "Library/Caches/ms-playwright", "Playwright browsers", "Re-downloaded on the next test run", recommended: true),
            folder(.caches, "Library/Caches/Homebrew", "Homebrew downloads", "None; installed formulae keep working", recommended: true),
            folder(.caches, "Library/Caches/pip", "pip cache", "Re-downloaded on the next install", recommended: true),
            folder(.caches, "Library/Caches/lima", "Lima image cache", "Only needed to create new VMs", recommended: true),
            folder(.caches, "Library/Caches/org.swift.swiftpm", "Swift Package Manager cache", "Packages re-download on the next build", recommended: true),
            folder(.caches, "Library/Caches/go-build", "Go build cache", "The next Go build is slower", recommended: true),
            folder(.caches, "Library/Caches/Yarn", "Yarn cache", "Re-downloaded on the next install", recommended: true),
            folder(.caches, "Library/Caches/pnpm", "pnpm cache", "Re-downloaded on the next install", recommended: true),
            folder(.caches, "Library/Caches/CocoaPods", "CocoaPods cache", "Pods re-download on the next install", recommended: true),
            folder(.caches, ".cargo/registry/cache", "Cargo crate downloads", "Crates re-download on the next build", recommended: true),
            folder(.caches, ".bun/install/cache", "Bun cache", "Re-downloaded on the next install", recommended: true),
            folder(.caches, "Library/Developer/CoreSimulator/Caches", "Simulator caches (yours)", "Rebuilt when a simulator boots", recommended: true),
        ]
        for platform in ["iOS", "watchOS", "tvOS", "visionOS"] {
            list.append(folder(.caches, "Library/Developer/Xcode/\(platform) DeviceSupport", "\(platform) device support files",
                               "Copied again from a device the next time you connect one", recommended: true))
        }
        // ~/.cache is the catch-all of command-line tools; model stores are AI, not cache.
        for url in children(of: ".cache") where !["huggingface", "lm-studio", "torch", "whisper"].contains(url.lastPathComponent) {
            list.append(Candidate(group: .caches, title: "\(url.lastPathComponent) (~/.cache)", url: url,
                                  cost: "Re-downloaded or rebuilt when the tool needs it", removal: .trash, recommended: true))
        }
        if !environment.isFixture {
            list.append(Candidate(group: .caches, title: "Simulator system caches", url: URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Caches"),
                                  cost: "Rebuilt automatically. Needs your administrator password: drag it to the Trash in Finder",
                                  removal: .reveal))
        }
        return list
    }

    // MARK: B. VMs, simulators, emulators

    private func machines(_ probe: Probe) -> [Candidate] {
        var list: [Candidate] = []
        if probe.enabled {
            probe.step("Asking Xcode about simulators…")
            list += simulators(probe)
        }

        // Lima VMs: a sparse disk image per VM; the allocated size is the real cost.
        probe.step("Looking for virtual machines…")
        let limaStatus = probe.enabled ? limaStates(probe) : [:]
        for url in children(of: ".lima") where !url.lastPathComponent.hasPrefix("_") {
            let name = url.lastPathComponent
            var warnings: [String] = []
            if limaStatus[name] == "Running" { warnings.append("Running: stop it first (limactl stop \(name))") }
            list.append(Candidate(group: .machines, title: "Lima VM “\(name)”", url: url,
                                  cost: "Re-downloads the base image and a slow first boot. Check your project does not recreate it.",
                                  removal: .trash, warnings: warnings))
        }
        for url in children(of: ".android/avd") where url.pathExtension == "avd" {
            let name = url.deletingPathExtension().lastPathComponent
            list.append(Candidate(group: .machines, title: "Android emulator “\(name)”", url: url,
                                  cost: "Recreate it in Android Studio", removal: .command("avdmanager delete avd -n \(Self.quote(name))")))
        }
        list.append(folder(.machines, "Library/Android/sdk/system-images", "Android system images",
                           "Re-download with the SDK Manager in Android Studio", removal: .reveal))
        list.append(folder(.machines, "Library/Containers/com.docker.docker", "Docker Desktop data",
                           "Unused images and containers are pulled again", removal: .command("docker system prune -a")))
        for (path, title) in [(".colima", "Colima VMs"), (".orbstack", "OrbStack machines"), ("VirtualBox VMs", "VirtualBox VMs"),
                              ("Parallels", "Parallels VMs"), ("Library/Application Support/UTM", "UTM VMs"),
                              ("Library/Containers/com.utmapp.UTM", "UTM VMs (App Store)")] {
            list.append(folder(.machines, path, title, "A virtual machine can hold your own files. Delete it from its own app.", removal: .reveal))
        }
        list.append(folder(.machines, "Library/Application Support/Claude/vm_bundles", "Claude desktop VM bundle",
                           "Re-downloaded if Claude's local agent mode is used again"))
        for (path, title) in [("Library/Application Support/CrossOver/Bottles", "CrossOver bottles"),
                              ("Library/Application Support/Oriel", "Oriel / Wine bottles")] {
            list.append(folder(.machines, path, title, "Deletes the Windows apps and games installed inside", removal: .reveal))
        }
        return list
    }

    private func simulators(_ probe: Probe) -> [Candidate] {
        var list: [Candidate] = []
        let devicesList = probe.ask("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"], tool: "Xcode's simulator service")
        guard !devicesList.timedOut else {
            // The simulator service is stuck (often Xcode waiting to finish installing). Its
            // folders still say what each simulator is; runtimes have to wait for Xcode.
            probe.notes.append("Xcode's simulator service did not answer, so simulators were read from their folders and simulator runtimes are not listed. Opening Xcode once usually fixes this.")
            return simulatorsFromFolders()
        }
        if let json = devicesList.output?.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
           let byRuntime = root["devices"] as? [String: [[String: Any]]] {
            var unavailable: (count: Int, bytes: Int64) = (0, 0)
            for (runtime, devices) in byRuntime {
                let os = Self.runtimeName(runtime)
                for device in devices {
                    let bytes = (device["dataPathSize"] as? NSNumber)?.int64Value ?? 0
                    if (device["isAvailable"] as? Bool) == false {
                        unavailable.count += 1
                        unavailable.bytes += bytes
                        continue
                    }
                    guard let udid = device["udid"] as? String, let name = device["name"] as? String else { continue }
                    let booted = (device["state"] as? String) == "Booted"
                    list.append(Candidate(group: .machines, title: "\(name) simulator (\(os))",
                                          url: (device["dataPath"] as? String).map { URL(fileURLWithPath: $0).deletingLastPathComponent() },
                                          size: bytes, minimum: 100 << 20,
                                          cost: "Wipes its installed apps and data; the device stays in Xcode",
                                          removal: .command("xcrun simctl erase \(udid)"),
                                          warnings: booted ? ["Booted: shut it down first"] : [],
                                          lastUsed: Self.isoDate(device["lastUsedAt"])))
                }
            }
            if unavailable.count > 0 {
                list.append(Candidate(group: .machines, title: "\(unavailable.count) orphaned simulator\(unavailable.count == 1 ? "" : "s")",
                                      url: nil, size: unavailable.bytes, minimum: 0,
                                      cost: "None: their runtime is already gone",
                                      removal: .command("xcrun simctl delete unavailable"), recommended: true))
            }
        }
        if let json = probe.ask("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"], tool: "Xcode's simulator service").output?.data(using: .utf8),
           let runtimes = try? JSONSerialization.jsonObject(with: json) as? [String: [String: Any]] {
            for runtime in runtimes.values {
                guard (runtime["deletable"] as? Bool) ?? false, let id = runtime["identifier"] as? String else { continue }
                let platform = Self.platformName(runtime["platformIdentifier"] as? String)
                let version = runtime["version"] as? String ?? ""
                list.append(Candidate(group: .machines, title: "\(platform) \(version) simulator runtime",
                                      url: (runtime["path"] as? String).map { URL(fileURLWithPath: $0) },
                                      size: (runtime["sizeBytes"] as? NSNumber)?.int64Value ?? 0,
                                      cost: "Re-download from Xcode › Settings › Components (several GB)",
                                      removal: .command("xcrun simctl runtime delete \(id)"),
                                      lastUsed: Self.isoDate(runtime["lastUsedAt"])))
            }
        }
        return list
    }

    /// Each simulator folder carries a device.plist with its name, OS and state.
    private func simulatorsFromFolders() -> [Candidate] {
        children(of: "Library/Developer/CoreSimulator/Devices").compactMap { url in
            guard let data = try? Data(contentsOf: url.appendingPathComponent("device.plist")),
                  let device = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let udid = device["UDID"] as? String, let name = device["name"] as? String else { return nil }
            let os = Self.runtimeName(device["runtime"] as? String ?? "")
            let booted = (device["state"] as? NSNumber)?.intValue == 3
            return Candidate(group: .machines, title: "\(name) simulator (\(os))", url: url, minimum: 100 << 20,
                             cost: "Wipes its installed apps and data; the device stays in Xcode",
                             removal: .command("xcrun simctl erase \(udid)"),
                             warnings: booted ? ["Booted: shut it down first"] : [])
        }
    }

    // MARK: C. AI tools and models

    private func ai(_ probe: Probe) -> [Candidate] {
        var list: [Candidate] = []
        var ollamaListed = false
        if probe.enabled, let output = probe.ask(Self.tool("ollama") ?? "/usr/local/bin/ollama", ["list"], tool: "Ollama").output,
           output.hasPrefix("NAME") {
            for line in output.split(separator: "\n").dropFirst() {
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                guard fields.count >= 4, let bytes = Self.parseSize(String(fields[2]), unit: String(fields[3])) else { continue }
                ollamaListed = true
                list.append(Candidate(group: .ai, title: "Ollama model \(fields[0])", url: nil, size: bytes,
                                      cost: "Re-download with ollama pull", removal: .command("ollama rm \(fields[0])")))
            }
        }
        if !ollamaListed {
            list.append(folder(.ai, ".ollama/models", "Ollama models", "Re-download with ollama pull", removal: .reveal))
        }
        list.append(folder(.ai, ".cache/huggingface", "Hugging Face models", "Models re-download on next use"))
        list.append(folder(.ai, ".cache/lm-studio", "LM Studio cache", "Re-downloaded by LM Studio"))
        list.append(folder(.ai, ".lmstudio/models", "LM Studio models", "Re-download them in LM Studio"))
        list.append(folder(.ai, ".cache/torch", "PyTorch model cache", "Re-downloaded on next use"))
        list.append(folder(.ai, ".cache/whisper", "Whisper models", "Re-downloaded on next use"))
        for (path, title) in [(".antigravity", "Antigravity"), (".antigravity-ide", "Antigravity IDE"), (".gemini", "Gemini CLI"),
                              (".cursor", "Cursor"), (".codex", "Codex"), (".windsurf", "Windsurf"), (".continue", "Continue"),
                              (".ai-navigator", "AI Navigator (micromamba)"), (".claude-science", "Claude Science environments"),
                              (".vscode/extensions", "VS Code extensions")] {
            list.append(folder(.ai, path, title, "Settings and history are lost; extensions and environments reinstall"))
        }
        // Leftover backup copies of tool folders are the first, cheapest candidates.
        for url in children(of: "", includeHidden: true) where url.lastPathComponent.hasPrefix(".") && url.lastPathComponent.hasSuffix("-backup") {
            list.append(Candidate(group: .ai, title: "Backup copy \(url.lastPathComponent)", url: url,
                                  cost: "None, unless you kept it on purpose", removal: .trash, recommended: true))
        }
        return list
    }

    // MARK: D. Developer toolchains

    private func toolchains(_ probe: Probe) -> [Candidate] {
        var list: [Candidate] = []
        let rustDefault = probe.enabled ? probe.ask(Self.tool("rustup") ?? "/opt/homebrew/bin/rustup", ["default"], tool: "rustup").output?
            .split(separator: " ").first.map(String.init) : nil
        for url in children(of: ".rustup/toolchains") {
            let name = url.lastPathComponent
            if name == rustDefault {
                list.append(Candidate(group: .toolchains, title: "Rust \(name) (default)", url: url,
                                      cost: "Keep: it is your default toolchain", removal: .reveal,
                                      warnings: ["Default toolchain"]))
            } else {
                list.append(Candidate(group: .toolchains, title: "Rust \(name)", url: url, cost: "Reinstall with rustup if a project pins it",
                                      removal: .command("rustup toolchain uninstall \(name)")))
            }
        }
        list.append(folder(.toolchains, ".cargo", "Cargo home (installed Rust tools)", "Keep: removing it uninstalls Rust", removal: .reveal))

        if probeTools {
            for prefix in ["/opt/homebrew", "/usr/local"] {
                let cellar = URL(fileURLWithPath: prefix).appendingPathComponent("Cellar")
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: cellar.path) else { continue }
                for name in names where !name.hasPrefix(".") {
                    list.append(Candidate(group: .toolchains, title: "Homebrew \(name)", url: cellar.appendingPathComponent(name),
                                          minimum: 200 << 20,
                                          cost: "Check first: brew uses --installed \(name). Other tools or your projects may need it.",
                                          removal: .command("brew uninstall \(name)")))
                }
            }
        }
        for conda in ["miniconda3", "anaconda3", "miniforge3", "mambaforge"] where exists(conda) {
            list.append(folder(.toolchains, "\(conda)/pkgs", "\(conda) package cache", "None; environments keep working",
                               removal: .command("conda clean -a"), recommended: true))
        }
        for (path, title, cost) in [
            ("VulkanSDK", "Vulkan SDK", "Re-downloadable; check your shell config for VULKAN_SDK"),
            ("vcpkg", "vcpkg", "Re-downloadable; projects using it need it back"),
            ("go/pkg/mod", "Go module cache", "Modules re-download on the next build"),
            (".m2/repository", "Maven repository", "Dependencies re-download on the next build"),
            (".gradle/wrapper/dists", "Gradle distributions", "Re-downloaded by the wrapper"),
            (".pub-cache", "Dart / Flutter packages", "Re-downloaded on the next pub get"),
            (".nvm/versions", "nvm Node versions", "Reinstall the versions you use"),
            (".pyenv/versions", "pyenv Python versions", "Reinstall the versions you use"),
            (".rbenv/versions", "rbenv Ruby versions", "Reinstall the versions you use"),
            ("flutter", "Flutter SDK", "Re-downloadable; check your PATH"),
        ] {
            list.append(folder(.toolchains, path, title, cost, checkShellConfig: true))
        }
        list.append(folder(.toolchains, "Library/Android/sdk", "Android SDK", "Managed by Android Studio's SDK Manager", removal: .reveal))
        for (path, title) in [("Library/Application Support/MathWorks", "MathWorks support files"),
                              ("Library/Application Support/Autodesk", "Autodesk support files")] {
            list.append(folder(.toolchains, path, title, "May break add-ons or licensing", removal: .reveal))
        }
        return list
    }

    // MARK: E. Other hidden folders, F. large but not hidden

    private func otherHidden(claimed: Set<String>) -> [Candidate] {
        let skip: Set<String> = [".Trash", ".ssh", ".gnupg", ".DS_Store", ".CFUserTextEncoding", ".zsh_sessions"]
        return children(of: "", includeHidden: true)
            .filter { $0.lastPathComponent.hasPrefix(".") && !skip.contains($0.lastPathComponent) }
            .filter { url in !claimed.contains { $0 == url.path || $0.hasPrefix(url.path + "/") } }
            .map { Candidate(group: .hidden, title: "~/\($0.lastPathComponent)", url: $0, minimum: 500 << 20,
                             cost: "Unknown tool data. Check what made it before removing anything", removal: .reveal) }
    }

    private func large() -> [Candidate] {
        var list = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"].map {
            folder(.large, $0, "~/\($0)", "Your files: decide in Finder", removal: .reveal, minimum: 1 << 30)
        }
        for directory in environment.applicationDirectories {
            for url in children(at: directory) where url.pathExtension == "app" {
                list.append(Candidate(group: .large, title: url.deletingPathExtension().lastPathComponent, url: url, minimum: 2 << 30,
                                      cost: "An app. Use the Uninstaller to remove it with its support files", removal: .reveal))
            }
        }
        return list
    }

    // MARK: Accounting

    /// Compares what APFS says is used with what can be read. Slow: it measures the whole Data
    /// volume, so the UI runs it only when asked.
    public func account(control: ScanControl = ScanControl()) -> StorageAccounting {
        var consumed: Int64 = 0
        if let output = Shell.run("/usr/sbin/diskutil", ["info", "-plist", "/System/Volumes/Data"], timeout: 30, control: control)
            .output?.data(using: .utf8),
           let info = try? PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any] {
            consumed = (info["CapacityInUse"] as? NSNumber)?.int64Value ?? 0
        }
        let roots = ["Users", "Applications", "Library", "System", "private", "opt", "usr"]
            .map { URL(fileURLWithPath: "/System/Volumes/Data/\($0)") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let lock = NSLock()
        var readable: Int64 = 0
        DispatchQueue.concurrentPerform(iterations: roots.count) { i in
            let bytes = DiskScanner.measure(roots[i], control: control).bytes
            lock.withLock { readable += bytes }
        }
        var held: Int64 = 0
        if let output = Shell.run("/usr/sbin/lsof", ["-nP", "+L1"], timeout: 120, control: control).output {
            for line in output.split(separator: "\n").dropFirst() {
                let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                if fields.count > 6, let bytes = Int64(fields[6]) { held += bytes }
            }
        }
        let snapshots = (Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 30, control: control).output ?? "")
            .split(separator: "\n").filter { $0.contains("com.apple") }.count
        return StorageAccounting(consumed: consumed, readable: readable, heldByOpenFiles: held,
                                 localSnapshots: snapshots, deniedDirectories: control.inaccessibleDirectories)
    }

    /// For the user to run in Terminal: sizes the root-only places the audit cannot read.
    public static let rootSizingCommand = """
    sudo du -sh /System/Volumes/Data/.Spotlight-V100 /System/Volumes/Data/private/var/db/Spotlight-V100 /System/Volumes/Data/private/var/db/coreml /System/Volumes/Data/System/Library/AssetsV2/com_apple_MobileAsset_UAF_FM_* "/Library/Caches/com.microsoft.autoupdate.helper" /Library/Trial 2>/dev/null
    """

    // MARK: Pieces

    private struct Candidate {
        let group: AuditItem.Group
        let title: String
        let url: URL?
        var size: Int64?
        var minimum: Int64 = 50 << 20
        let cost: String
        let removal: AuditItem.Removal
        var warnings: [String] = []
        var lastUsed: Date?
        var recommended = false
        var checkShellConfig = false

        init(group: AuditItem.Group, title: String, url: URL?, size: Int64? = nil, minimum: Int64 = 50 << 20, cost: String,
             removal: AuditItem.Removal, warnings: [String] = [], lastUsed: Date? = nil, recommended: Bool = false,
             checkShellConfig: Bool = false) {
            self.group = group; self.title = title; self.url = url; self.size = size; self.minimum = minimum
            self.cost = cost; self.removal = removal; self.warnings = warnings; self.lastUsed = lastUsed
            self.recommended = recommended; self.checkShellConfig = checkShellConfig
        }
    }

    private func folder(_ group: AuditItem.Group, _ path: String, _ title: String, _ cost: String,
                        removal: AuditItem.Removal = .trash, recommended: Bool = false, minimum: Int64 = 50 << 20,
                        checkShellConfig: Bool = false) -> Candidate {
        let url = environment.homeRelative(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Candidate(group: group, title: title, url: nil, size: 0, minimum: .max, cost: cost, removal: removal)
        }
        return Candidate(group: group, title: title, url: url, minimum: minimum, cost: cost, removal: removal,
                         recommended: recommended, checkShellConfig: checkShellConfig)
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: environment.homeRelative(path).path)
    }

    private func children(of path: String, includeHidden: Bool = false) -> [URL] {
        children(at: path.isEmpty ? environment.home : environment.homeRelative(path), includeHidden: includeHidden)
    }

    private func children(at directory: URL, includeHidden: Bool = true) -> [URL] {
        guard let entries = try? FastDirectoryReader.read(directory.path) else { return [] }
        return entries.filter { $0.kind == .directory && (includeHidden || !$0.name.hasPrefix(".")) }
            .map { directory.appendingPathComponent($0.name, isDirectory: true) }
    }

    private func runningExecutables(_ probe: Probe) -> [String] {
        (probe.ask("/bin/ps", ["-Axo", "comm="], tool: "ps").output ?? "").split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    private func limaStates(_ probe: Probe) -> [String: String] {
        guard let tool = Self.tool("limactl"),
              let output = probe.ask(tool, ["list", "--format", "{{.Name}}\t{{.Status}}"], tool: "Lima").output else { return [:] }
        var states: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            if parts.count == 2 { states[String(parts[0])] = String(parts[1]) }
        }
        return states
    }

    private func shellConfigText() -> String {
        [".zshrc", ".zprofile", ".bashrc", ".bash_profile", ".profile"]
            .compactMap { try? String(contentsOf: environment.homeRelative($0), encoding: .utf8) }
            .joined(separator: "\n")
    }

    /// When the folder's own entries last changed (something added or removed inside it).
    static func lastChange(_ url: URL) -> Date? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    }

    static func tool(_ name: String) -> String? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// "com.apple.platform.xrsimulator" → "visionOS"
    static func platformName(_ identifier: String?) -> String {
        switch identifier?.split(separator: ".").last {
        case "iphonesimulator": "iOS"
        case "xrsimulator": "visionOS"
        case "watchsimulator": "watchOS"
        case "appletvsimulator": "tvOS"
        default: "Simulator"
        }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-18-2" → "iOS 18.2"
    static func runtimeName(_ identifier: String) -> String {
        let tail = identifier.split(separator: ".").last.map(String.init) ?? identifier
        let parts = tail.split(separator: "-")
        guard let platform = parts.first else { return tail }
        return parts.count > 1 ? "\(platform) \(parts.dropFirst().joined(separator: "."))" : String(platform)
    }

    static func isoDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }

    /// "3.3" "GB" → bytes, as `ollama list` prints sizes.
    static func parseSize(_ number: String, unit: String) -> Int64? {
        guard let value = Double(number) else { return nil }
        let scale: Double = switch unit.uppercased() {
        case "KB": 1e3
        case "MB": 1e6
        case "GB": 1e9
        case "TB": 1e12
        default: 1
        }
        return Int64(value * scale)
    }

    static func quote(_ text: String) -> String {
        text.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) } ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// One audit's questions to installed tools: each gets a time limit, stops with the scan, and
/// shows up as the current step in the progress view.
final class Probe: @unchecked Sendable {
    /// How long any one tool may take. A healthy one answers in well under a second; a cold
    /// simulator service can take several.
    static let timeLimit: TimeInterval = 15

    let control: ScanControl
    var enabled: Bool
    var notes: [String] = []
    private var stuck: Set<String> = []

    init(control: ScanControl, enabled: Bool) {
        self.control = control
        self.enabled = enabled
    }

    func step(_ text: String) {
        control.record(files: 0, bytes: 0, path: text)
    }

    /// A tool that already hung once in this audit is not asked again.
    func ask(_ executable: String, _ arguments: [String], tool: String) -> Shell.Result {
        guard !stuck.contains(tool), !control.isCancelled else { return Shell.Result(status: -1, output: nil, timedOut: true) }
        let result = Shell.run(executable, arguments, timeout: Self.timeLimit, control: control)
        if result.timedOut, !control.isCancelled {
            stuck.insert(tool)
            if tool != "Xcode's simulator service" {
                notes.append("\(tool) did not answer within \(Int(Self.timeLimit)) seconds, so what it would have reported is missing.")
            }
        }
        return result
    }
}
