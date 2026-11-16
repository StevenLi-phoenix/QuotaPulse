import Foundation

/// iCloud account state as the UI needs it (mirrors `CKAccountStatus` without importing CloudKit).
public enum CloudAccountState: String, Codable, Sendable, Hashable {
    case unknown
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable
    /// This build has no iCloud entitlement (unsigned dev build); CloudKit would crash, so it is never touched.
    case notEntitled

    public var message: String {
        switch self {
        case .unknown: "Couldn't determine the iCloud account."
        case .available: "OK"
        case .noAccount: "This device isn't signed in to iCloud."
        case .restricted: "iCloud is restricted on this device."
        case .temporarilyUnavailable: "iCloud is temporarily unavailable."
        case .notEntitled: "This build isn't signed for iCloud."
        }
    }
}

public enum CloudError: Error, LocalizedError, Sendable, Equatable {
    case account(CloudAccountState)
    /// Network, rate limit or busy service; `after` is the server's Retry-After when it gave one.
    case retryLater(after: TimeInterval?, message: String)
    /// The zone is gone (first use, or the user deleted the data): `prepare()` recreates it.
    case zoneMissing
    case quotaExceeded
    /// The server refused this app for the container, with its reason. Seen on a new App ID, where the same request flips between success and this error.
    case rejected(String)
    /// Written by a newer app version than this one understands.
    case incompatible(schema: Int)
    case corrupt
    case other(String)

    public var errorDescription: String? {
        switch self {
        case let .account(state): state.message
        case let .retryLater(_, message): message
        case .zoneMissing: "QuotaPulse's iCloud zone is missing."
        case .quotaExceeded: "Your iCloud storage is full."
        case let .rejected(reason): "iCloud isn't accepting this app yet (\(reason)). This can happen right after a first install. QuotaPulse keeps trying."
        case .incompatible: "iCloud data comes from a newer QuotaPulse. Update this device."
        case .corrupt: "iCloud data couldn't be read."
        case let .other(message): message
        }
    }
}

/// One stored blob: searchable metadata plus a compressed JSON payload.
public struct CloudRecord: Sendable, Equatable {
    public var name: String
    public var schema: Int
    public var generatedAt: Date
    public var hubName: String
    public var payload: Data

    public init(name: String, schema: Int, generatedAt: Date, hubName: String, payload: Data) {
        self.name = name
        self.schema = schema
        self.generatedAt = generatedAt
        self.hubName = hubName
        self.payload = payload
    }

    public init<T: Encodable>(name: String, generatedAt: Date, hubName: String, encoding value: T) throws {
        self.init(name: name, schema: CloudPayload.schema, generatedAt: generatedAt, hubName: hubName, payload: try CloudPayload.encode(value))
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        guard schema <= CloudPayload.schema else { throw CloudError.incompatible(schema: schema) }
        return try CloudPayload.decode(type, from: payload)
    }

    /// CloudKit refuses a request with too many records or too many bytes, so a save goes out in batches within both limits.
    public static func batches(_ records: [CloudRecord], maxRecords: Int = 100, maxBytes: Int = 1_000_000) -> [[CloudRecord]] {
        var out: [[CloudRecord]] = []
        var current: [CloudRecord] = []
        var bytes = 0
        for r in records {
            if !current.isEmpty, current.count >= maxRecords || bytes + r.payload.count > maxBytes {
                out.append(current)
                current = []
                bytes = 0
            }
            current.append(r)
            bytes += r.payload.count
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

/// What the sync logic needs from iCloud. `CloudKitRecordStore` is the real one; tests use an in-memory fake.
public protocol CloudRecordStore: Sendable {
    func accountState() async -> CloudAccountState
    /// Short hash that is identical on every device signed in to the same iCloud account.
    func accountID() async -> String?
    /// Creates the zone; safe to call repeatedly.
    func prepare() async throws
    /// Last writer wins: there is one publishing Mac and readers never write.
    func save(_ records: [CloudRecord]) async throws
    /// Missing records are simply absent from the result.
    func fetch(_ names: [String]) async throws -> [String: CloudRecord]
    /// Asks iCloud to wake this device with a silent push when records change.
    func subscribeToChanges() async throws
    func removeAll() async throws
}

public enum CloudPayload {
    /// 2: one record per provider (`provider.<id>`). Readers on schema 1 refuse these records instead of misreading them.
    public static let schema = 2
    /// The account's reading of one provider. Every Mac that has that provider writes the same record; the newer reading wins.
    public static func providerRecord(_ provider: ProviderID) -> String { providerPrefix + provider.rawValue }
    public static let providerPrefix = "provider."
    /// Which providers have a `provider.<id>` record (`CloudProviderIndex`). CloudKit can't list a zone cheaply (its change feed
    /// walks every past write), so the publishing Macs keep this one record and readers fetch it with the providers they know.
    public static let providerIndexRecord = "providers"
    /// The account's settings. One record, newest `updatedAt` wins.
    public static let settingsRecord = "settings"
    public static func historyRecord(_ provider: ProviderID) -> String { "history.\(provider.rawValue)" }
    /// One piece of a provider's raw samples; pieces are numbered from 0 and the first one says how many follow.
    public static func samplesRecord(_ provider: ProviderID, _ index: Int) -> String { "samples.\(provider.rawValue).\(index)" }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try (JSON.encoder.encode(value) as NSData).compressed(using: .lzfse) as Data
    }

    static func decode<T: Decodable>(_ type: T.Type, from payload: Data) throws -> T {
        do {
            let raw = try (payload as NSData).decompressed(using: .lzfse) as Data
            return try JSON.decoder.decode(type, from: raw)
        } catch {
            throw CloudError.corrupt
        }
    }
}

public struct CloudSyncPolicy: Sendable, Equatable {
    /// Rewrite the snapshot this often even when nothing changed, so readers can tell the Mac is alive.
    public var heartbeat: TimeInterval = 15 * 60
    /// History changes slowly and is the bulk of the bytes.
    public var historyInterval: TimeInterval = 30 * 60
    public var historyDays = 7
    public var recentHours = 24
    /// Per window: 24 h of 5-minute polls stay at full resolution, the older days are thinned.
    public var recentPoints = 288
    public var olderPoints = 200
    /// CloudKit caps a record at 1 MB including metadata.
    public var maxRecordBytes = 900_000
    public var retryDelay: TimeInterval = 5 * 60
    /// Raw samples go back this far: the longest retention the app offers.
    public var sampleDays = 90
    /// Samples per piece before the size check; halved until a piece fits `maxRecordBytes`.
    public var samplesPerRecord = 10_000

    public static let standard = CloudSyncPolicy()
}

/// The providers published to this account. Every Mac adds the ones it writes and never removes any, so two Macs racing can
/// only lose an entry until the loser's next heartbeat puts it back.
public struct CloudProviderIndex: Codable, Sendable, Equatable {
    public var providers: [ProviderID]

    public init(providers: [ProviderID]) {
        self.providers = Array(Set(providers)).sorted(by: ProviderID.displayOrder)
    }

    /// Ids that came from iCloud are checked before they become record names.
    public var valid: [ProviderID] { providers.filter { ProviderID(validating: $0.rawValue) != nil } }

    /// The index with `ids` added, or nil when it already lists them all (nothing to write).
    public func adding(_ ids: [ProviderID]) -> CloudProviderIndex? {
        let missing = Set(ids).subtracting(providers)
        return missing.isEmpty ? nil : CloudProviderIndex(providers: providers + missing)
    }
}

/// One provider's recent samples, ready for a chart on another device.
public struct CloudHistory: Codable, Sendable, Equatable {
    public var provider: ProviderID
    public var generatedAt: Date
    public var samples: [Sample]
    /// Set when history was deleted: samples before this time are gone for every Mac and are never merged back in.
    public var clearedAt: Date?

    public init(provider: ProviderID, samples: [Sample], now: Date, policy: CloudSyncPolicy) {
        self.init(provider: provider, samples: samples, now: now, policy: policy, recentPoints: policy.recentPoints, olderPoints: policy.olderPoints)
    }

    private init(provider: ProviderID, samples: [Sample], now: Date, policy: CloudSyncPolicy, recentPoints: Int, olderPoints: Int) {
        self.provider = provider
        self.generatedAt = now
        let oldest = now.addingTimeInterval(-Double(policy.historyDays) * 86400)
        let recentCut = now.addingTimeInterval(-Double(policy.recentHours) * 3600)
        let kept = samples.filter { $0.at >= oldest }
        self.samples = Dictionary(grouping: kept, by: \.window).values.flatMap { window -> [Sample] in
            let recent = window.filter { $0.at >= recentCut }
            let older = window.filter { $0.at < recentCut }
            return Downsample.samples(older, maxPoints: olderPoints) + Downsample.samples(recent, maxPoints: recentPoints)
        }
        .sorted { $0.at < $1.at }
    }

    /// Encodes within CloudKit's record limit, halving resolution until it fits.
    public static func record(provider: ProviderID, samples: [Sample], hubName: String, now: Date, policy: CloudSyncPolicy, clearedAt: Date? = nil) throws -> CloudRecord {
        var recent = policy.recentPoints, older = policy.olderPoints
        while recent >= 4 {
            var history = CloudHistory(provider: provider, samples: samples, now: now, policy: policy, recentPoints: recent, olderPoints: older)
            history.clearedAt = clearedAt
            let record = try CloudRecord(name: CloudPayload.historyRecord(provider), generatedAt: now, hubName: hubName, encoding: history)
            if record.payload.count <= policy.maxRecordBytes { return record }
            QPLog.cloud.notice("history for \(provider.rawValue, privacy: .public) is \(record.payload.count) bytes; halving resolution")
            recent /= 2
            older /= 2
        }
        return try CloudRecord(name: CloudPayload.historyRecord(provider), generatedAt: now, hubName: hubName,
                               encoding: CloudHistory(provider: provider, samples: [], now: now, policy: policy))
    }
}

public extension QuotaSnapshot {
    /// True when the publishing Mac has missed two heartbeats: it is off, asleep or offline.
    func isStale(now: Date = Date(), threshold: TimeInterval = 2 * CloudSyncPolicy.standard.heartbeat) -> Bool {
        generatedAt != .distantPast && now.timeIntervalSince(generatedAt) > threshold
    }

    /// What a reader can notice. Timestamps and forecast noise are left out so an idle Mac doesn't write on every poll.
    internal var cloudFingerprint: [String] {
        providers.map { p in
            let windows = p.windows.map { w in
                "\(w.id):\(String(format: "%.1f", w.utilization)):\(w.resetsAt.map { Int($0.timeIntervalSince1970) } ?? 0):\(w.availability.rawValue)"
            }
            let balance = p.balance.map { String(format: "%.2f", $0.total) } ?? "-"
            return "\(p.id.rawValue)|\(p.status.shortLabel)|\(p.account?.plan ?? "-")|\(balance)|\(windows.joined(separator: ","))"
        }
    }
}
