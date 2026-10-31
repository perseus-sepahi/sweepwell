import SwiftUI
import AppKit
import SweepwellKit

/// What to sell and where. This is the direct-download edition: Stripe plus offline licence keys.
enum StoreConfig {
    /// The Stripe payment link. Do not ship a build until the licence service is deployed and
    /// this link's confirmation redirect points at its /claim page, or buyers pay and get no key.
    static let checkoutURL: URL? = nil
    /// Public half of the Ed25519 key that signs licence keys. The private half lives only in
    /// the licence service's secrets and in ~/.sweepwell on the creator's Mac.
    static let licencePublicKey = "Gz1qGe5ZmZU9vQjJwVsOAX2hlxUy/FqX5XJICMyQVsI="
    /// The licence service: /revoked lists refunded keys. Nil until deployed.
    static let licenceService: URL? = nil
    static let price = "US$1.99"
}

/// The trial, the licence and the paywall. Scanning and the menu bar stay free for good; anything
/// that cleans, removes or shreds asks `allowed()` first.
@MainActor @Observable
final class ProModel {
    private let ledger: ProLedger
    /// True for the owner's own builds (debug, or scripts/build-release.sh). The distribution
    /// script refuses to package a binary containing the marker.
    let isOwnerBuild: Bool
    private(set) var status: ProStatus
    var paywallShown = false
    var activationError: String?
    var justActivated = false

    init(environment: ScanEnvironment) {
        ledger = ProLedger(environment: environment, publicKey: StoreConfig.licencePublicKey)
        var owner = false
        #if DEBUG || OWNER
        owner = !Self.ownerMarker.isEmpty
        #endif
        #if DEBUG
        // UI check: behave like a customer, inside a demo home only.
        let hooks = ProcessInfo.processInfo.environment
        if environment.isFixture, hooks["SWEEPWELL_AS_CUSTOMER"] == "1" { owner = false }
        #endif
        isOwnerBuild = owner
        status = ledger.status()
        #if DEBUG
        if environment.isFixture, let days = hooks["SWEEPWELL_TRIAL_USED"].flatMap(Int.init), days >= 0 {
            let left = ProLedger.trialDays - days
            status = left > 0 ? .trial(daysLeft: left) : .expired
        }
        #endif
    }

    #if DEBUG || OWNER
    private static let ownerMarker = "SWEEPWELL-OWNER-BUILD-ALWAYS-PRO"
    #endif

    var unlocked: Bool { isOwnerBuild || status.unlocked }

    /// Call before a paid action. When locked it opens the paywall and says no.
    func allowed() -> Bool {
        refresh()
        guard !unlocked else { return true }
        showPaywall()
        return false
    }

    func showPaywall() {
        activationError = nil
        justActivated = false
        paywallShown = true
        AppDelegate.showMainWindow()
    }

    func refresh() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SWEEPWELL_TRIAL_USED"] != nil { return }
        #endif
        status = ledger.status()
    }

    func activate(_ raw: String) {
        do {
            try ledger.activate(raw)
            activationError = nil
            justActivated = true
            status = ledger.status()
        } catch {
            activationError = error.localizedDescription
        }
    }

    /// `sweepwell://activate?key=…`, the button on the page buyers land on after paying.
    func handle(_ url: URL) {
        guard url.scheme == "sweepwell", url.host == "activate",
              let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "key" })?.value else { return }
        showPaywall()
        activate(key)
    }

    func removeLicence() {
        ledger.deactivate()
        status = ledger.status()
    }

    /// Weekly, for licensed copies only: drops the key if its purchase was refunded. Any network
    /// failure is ignored, so being offline never locks a payer out.
    func checkRevocationIfDue() {
        guard let service = StoreConfig.licenceService, ledger.revocationCheckDue() else { return }
        let ledger = ledger
        Task {
            struct Answer: Decodable { let revoked: [String] }
            guard let (data, response) = try? await URLSession.shared.data(from: service.appendingPathComponent("revoked")),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let answer = try? JSONDecoder().decode(Answer.self, from: data) else { return }
            ledger.applyRevocations(answer.revoked)
            status = ledger.status()
        }
    }

    /// Plain words for Settings and the paywall.
    var summary: String {
        if isOwnerBuild { return "Owner build: everything is unlocked." }
        switch status {
        case .licensed: return "Sweepwell Pro is active on this Mac. Thank you!"
        case .trial(let days): return "Free trial: \(days) day\(days == 1 ? "" : "s") left, with everything unlocked."
        case .expired: return "Your 7-day trial has ended."
        }
    }
}

/// The paywall. It states what stays free and what costs money.
struct ProSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var showKeyField = false
    @State private var key = ""

    var body: some View {
        let pro = app.pro
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconDisc(symbol: "sparkles", color: Module.overview.accent, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sweepwell Pro").font(.title2.weight(.semibold))
                    Text(pro.summary).font(.callout).foregroundStyle(.secondary)
                }
            }
            if pro.justActivated {
                Label("Licence activated. Everything is unlocked for good.", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.semibold)).foregroundStyle(Color.success)
            } else if case .licensed = pro.status {
                EmptyView()
            } else {
                offer(pro)
            }
            HStack {
                if case .licensed = pro.status {} else if !pro.justActivated {
                    Button("I already have a licence key") { showKeyField.toggle() }.buttonStyle(.plain)
                        .font(.callout).foregroundStyle(Module.overview.accent)
                }
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(PillButtonStyle()).keyboardShortcut(.cancelAction)
                if !pro.justActivated, let checkout = StoreConfig.checkoutURL, !pro.status.isLicensed {
                    Button("Get Pro · \(StoreConfig.price)") { NSWorkspace.shared.open(checkout) }
                        .buttonStyle(PillButtonStyle(prominent: true, tint: Module.overview.accent))
                        .keyboardShortcut(.defaultAction)
                }
            }
            if showKeyField, !pro.justActivated {
                HStack {
                    TextField("KGP1…", text: $key).textFieldStyle(.roundedBorder).font(.caption.monospaced())
                    Button("Activate") { pro.activate(key) }.buttonStyle(PillButtonStyle())
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let error = pro.activationError {
                Text(error).font(.caption).foregroundStyle(Color.warning)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func offer(_ pro: ProModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(StoreConfig.price) once. No subscription, no account.").font(.callout.weight(.semibold))
            column("Needs Pro after the trial", "lock.open.fill",
                   "Cleaning junk, removing large files and duplicates, uninstalling apps, shredding, Storage Audit removals, startup item removal, maintenance tasks, and freeing RAM and app caches.")
            column("Free for good", "checkmark.seal",
                   "Every scan and report, Space Lens, the menu bar panel with its live readings, Keep Awake, Eject and Empty Trash.")
        }
    }

    private func column(_ title: String, _ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Module.overview.accent).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension ProStatus {
    var isLicensed: Bool { if case .licensed = self { true } else { false } }
    var unlockedForGood: Bool { isLicensed }
}

/// Above the sidebar's module: how much of the trial is left, and the way to buy.
struct TrialChip: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let pro = app.pro
        if !pro.isOwnerBuild {
            switch pro.status {
            case .licensed: EmptyView()
            case .trial(let days): chip("Trial: \(days) day\(days == 1 ? "" : "s") left", Color.secondary, pro)
            case .expired: chip("Trial ended", Color.warning, pro)
            }
        }
    }

    private func chip(_ text: String, _ color: Color, _ pro: ProModel) -> some View {
        HStack {
            Text(text).font(.caption.weight(.semibold)).foregroundStyle(color)
            Spacer()
            Button("Get Pro") { pro.showPaywall() }.buttonStyle(.plain)
                .font(.caption.weight(.semibold)).foregroundStyle(Module.overview.accent)
        }
        .padding(.horizontal, 4)
    }
}
