import CryptoKit
import Foundation

/// A Sweepwell Pro licence key: `KGP1.<payload>.<signature>` (base64url). The payload is JSON
/// {"p": product, "id": purchase, "t": issued}; the signature is Ed25519 over the payload text.
/// Checked entirely offline.
public struct LicenceKey: Equatable, Sendable {
    public static let product = "sweepwell-pro"
    public let id: String
    public let issued: Date

    public enum Problem: LocalizedError, Equatable {
        case format, signature, product
        public var errorDescription: String? {
            switch self {
            case .format: return "That doesn't look like a Sweepwell licence key. Copy the whole key, starting with KGP1."
            case .signature: return "That licence key isn't valid. Check it was copied completely."
            case .product: return "This licence key is for a different product."
            }
        }
    }

    public static func verify(_ raw: String, publicKey: String, product: String = LicenceKey.product) throws -> LicenceKey {
        let parts = raw.filter { !$0.isWhitespace }.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "KGP1",
              let payload = base64url(parts[1]), let signature = base64url(parts[2]),
              let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { throw Problem.format }
        guard key.isValidSignature(signature, for: Data(parts[1].utf8)) else { throw Problem.signature }
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let id = json["id"] as? String, !id.isEmpty else { throw Problem.format }
        guard json["p"] as? String == product else { throw Problem.product }
        return LicenceKey(id: id, issued: Date(timeIntervalSince1970: (json["t"] as? Double) ?? 0))
    }

    static func base64url(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}

public enum ProStatus: Equatable, Sendable {
    case licensed(LicenceKey)
    /// Whole days left, rounded up: 7 on the first day, 1 on the last.
    case trial(daysLeft: Int)
    case expired

    /// Cleaning, removing and shredding are allowed. Scanning always is.
    public var unlocked: Bool { if case .expired = self { false } else { true } }
}

/// The trial clock and the licence key. Kept in two files, so deleting one does not restart the
/// trial, and every read restores whichever is missing. Moving the clock back does not add days.
public struct ProLedger: Sendable {
    public static let trialDays = 7

    struct State: Codable, Equatable {
        var started: Date
        var lastSeen: Date
        var key: String?
        var lastRevocationCheck: Date?
    }

    let copies: [URL]
    let publicKey: String

    public init(environment: ScanEnvironment, publicKey: String) {
        copies = [environment.homeRelative("Library/Application Support/Sweepwell/pro.json"),
                  environment.homeRelative("Library/Preferences/.com.williamsepahi.Sweepwell.state")]
        self.publicKey = publicKey
    }

    /// Reads the state, starting the trial if this is the first run ever.
    public func status(now: Date = Date()) -> ProStatus {
        var state = merged(now: now)
        state.lastSeen = max(state.lastSeen, now)
        save(state)
        if let raw = state.key, let key = try? LicenceKey.verify(raw, publicKey: publicKey) { return .licensed(key) }
        let left = TimeInterval(Self.trialDays * 86_400) - state.lastSeen.timeIntervalSince(state.started)
        return left > 0 ? .trial(daysLeft: Int((left / 86_400).rounded(.up))) : .expired
    }

    /// Stores a key after checking it. Throws why it was refused.
    @discardableResult
    public func activate(_ raw: String, now: Date = Date()) throws -> LicenceKey {
        let key = try LicenceKey.verify(raw, publicKey: publicKey)
        var state = merged(now: now)
        state.key = raw.filter { !$0.isWhitespace }
        save(state)
        return key
    }

    public func deactivate(now: Date = Date()) {
        var state = merged(now: now)
        state.key = nil
        save(state)
    }

    /// True once a week at most, and only for a licensed copy.
    public func revocationCheckDue(now: Date = Date()) -> Bool {
        let state = merged(now: now)
        guard state.key != nil else { return false }
        return state.lastRevocationCheck.map { now.timeIntervalSince($0) > 7 * 86_400 } ?? true
    }

    /// Applies a successful answer from the licence service. Only an answer that names this
    /// key removes it; a failed check never reaches here, so being offline cannot lock anyone out.
    public func applyRevocations(_ revoked: [String], now: Date = Date()) {
        var state = merged(now: now)
        state.lastRevocationCheck = now
        if let raw = state.key, let key = try? LicenceKey.verify(raw, publicKey: publicKey), revoked.contains(key.id) {
            state.key = nil
        }
        save(state)
    }

    private func merged(now: Date) -> State {
        let found = copies.compactMap { url -> State? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(State.self, from: data)
        }
        guard var state = found.first else { return State(started: now, lastSeen: now) }
        for other in found.dropFirst() {
            state.started = min(state.started, other.started)
            state.lastSeen = max(state.lastSeen, other.lastSeen)
            state.key = state.key ?? other.key
            state.lastRevocationCheck = [state.lastRevocationCheck, other.lastRevocationCheck].compactMap { $0 }.max()
        }
        return state
    }

    private func save(_ state: State) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        for url in copies {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
