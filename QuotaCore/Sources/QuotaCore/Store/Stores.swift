import Foundation

/// Standard on-disk layout. macOS: the team-prefixed App Group container
/// (`~/Library/Group Containers/88U7V98QAC.app.lishuyu.quotapulse/QuotaPulse`), which both the
/// unsandboxed app and the sandboxed widget may use without a provisioning profile.
/// iOS/watchOS: the `group.…` container when available, else the app's own.
public struct DataLocation: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    public static let appGroupID = "group.app.lishuyu.quotapulse"
    public static let macGroupID = "88U7V98QAC.app.lishuyu.quotapulse"

    public static func standard() -> DataLocation {
        #if os(macOS)
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: macGroupID) {
            return DataLocation(root: group.appendingPathComponent("QuotaPulse", isDirectory: true))
        }
        return legacyMac()
        #else
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return DataLocation(root: group.appendingPathComponent("QuotaPulse", isDirectory: true))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return DataLocation(root: base.appendingPathComponent("QuotaPulse", isDirectory: true))
        #endif
    }

    #if os(macOS)
    /// Pre-0.2 location (Application Support); migrated into the group container on launch.
    public static func legacyMac() -> DataLocation {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return DataLocation(root: base.appendingPathComponent("QuotaPulse", isDirectory: true))
    }

    /// Moves settings/samples/snapshot from the legacy folder once; returns true when something moved.
    @discardableResult
    public static func migrateLegacyIfNeeded() -> Bool {
        let old = legacyMac(), new = standard()
        guard old.root != new.root, FileManager.default.fileExists(atPath: old.settingsURL.path) || FileManager.default.fileExists(atPath: old.samplesURL.path),
              !FileManager.default.fileExists(atPath: new.settingsURL.path) else { return false }
        try? FileManager.default.createDirectory(at: new.root, withIntermediateDirectories: true)
        var moved = false
        for name in ["settings.json", "snapshot.json", "samples.json", "pairing.json"] {
            let src = old.root.appendingPathComponent(name), dst = new.root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: src.path), (try? FileManager.default.moveItem(at: src, to: dst)) != nil { moved = true }
        }
        QPLog.store.notice("migrated legacy data to \(new.root.path, privacy: .public): \(moved)")
        return moved
    }
    #endif

    public var settingsURL: URL { root.appendingPathComponent("settings.json") }
    public var snapshotURL: URL { root.appendingPathComponent("snapshot.json") }
    public var samplesURL: URL { root.appendingPathComponent("samples.json") }
    public var hubPairingURL: URL { root.appendingPathComponent("pairing.json") }
    /// Optional gateway link (0600): `{"baseURL": "...", "token": "..."}`. See `GatewayConfig`.
    public var gatewayURL: URL { root.appendingPathComponent("gateway.json") }
    public var logURL: URL { root.appendingPathComponent("quotapulse.log") }
}

/// Latest snapshot on disk: the single source of truth for widgets and the hub.
public struct SnapshotStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() -> QuotaSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSON.decoder.decode(QuotaSnapshot.self, from: data)
    }

    public func save(_ snapshot: QuotaSnapshot) throws {
        try FileIO.writeAtomically(try JSON.encoder.encode(snapshot), to: url)
    }
}

/// Append-mostly sample history kept in one JSON file; bounded by retention and a hard cap.
public actor SampleStore {
    public let url: URL
    public let retention: TimeInterval
    public let hardCap: Int
    private var samples: [Sample]
    private var loaded = false
    private var dirty = false

    public init(url: URL, retentionDays: Int = 30, hardCap: Int = 50_000) {
        self.url = url
        self.retention = TimeInterval(retentionDays) * 86400
        self.hardCap = hardCap
        self.samples = []
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: url) else { return }
        do { samples = try JSON.decoder.decode([Sample].self, from: data) } catch {
            QPLog.store.error("samples decode failed; starting empty: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func append(_ new: [Sample], now: Date = Date()) {
        ensureLoaded()
        samples.append(contentsOf: new)
        prune(now: now)
        dirty = true
    }

    public func all() -> [Sample] { ensureLoaded(); return samples }

    public func samples(provider: ProviderID, window: String, since: Date? = nil) -> [Sample] {
        ensureLoaded()
        return samples.filter { sample in sample.provider == provider && sample.window == window && (since.map { sample.at >= $0 } ?? true) }
    }

    public func samples(provider: ProviderID, since: Date? = nil) -> [Sample] {
        ensureLoaded()
        return samples.filter { sample in sample.provider == provider && (since.map { sample.at >= $0 } ?? true) }
    }

    public func replaceAll(_ new: [Sample]) { ensureLoaded(); samples = new; dirty = true }

    public func clear() { loaded = true; samples = []; dirty = true; try? flush() }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-retention)
        samples.removeAll { $0.at < cutoff }
        if samples.count > hardCap { samples.removeFirst(samples.count - hardCap) }
    }

    public func flush() throws {
        guard dirty else { return }
        try FileIO.writeAtomically(try JSON.encoder.encode(samples), to: url)
        dirty = false
    }

    public var count: Int { ensureLoaded(); return samples.count }
}

/// 429 / failure backoff per provider (exponential, capped).
public struct BackoffGate: Sendable, Equatable {
    public var blockedUntil: [ProviderID: Date] = [:]
    public var failures: [ProviderID: Int] = [:]
    public var base: TimeInterval
    public var cap: TimeInterval

    public init(base: TimeInterval = 5 * 60, cap: TimeInterval = 30 * 60) {
        self.base = base
        self.cap = cap
    }

    public func isBlocked(_ id: ProviderID, now: Date) -> Bool {
        guard let until = blockedUntil[id] else { return false }
        return until > now
    }

    public mutating func recordSuccess(_ id: ProviderID) {
        blockedUntil[id] = nil
        failures[id] = nil
    }

    public mutating func recordRateLimit(_ id: ProviderID, retryAfter: Date?, now: Date) {
        let n = (failures[id] ?? 0) + 1
        failures[id] = n
        let backoff = min(cap, base * pow(2, Double(n - 1)))
        let candidate = now.addingTimeInterval(backoff)
        blockedUntil[id] = max(retryAfter ?? candidate, candidate)
    }

    /// Transient errors (network) get a short retry hold so we don't hammer a dead link.
    public mutating func recordTransient(_ id: ProviderID, now: Date) {
        let n = (failures[id] ?? 0) + 1
        failures[id] = n
        blockedUntil[id] = now.addingTimeInterval(min(cap, 60 * pow(2, Double(min(n, 6) - 1))))
    }
}
