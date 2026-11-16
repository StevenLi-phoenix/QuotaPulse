#if canImport(CloudKit)
import CloudKit
import CryptoKit
import Foundation

/// The user's private CloudKit database: one zone, one record type holding compressed JSON.
public struct CloudKitRecordStore: CloudRecordStore {
    public static let containerID = "iCloud.app.lishuyu.quotapulse"
    private static let zoneName = "QuotaPulse"
    private static let recordType = "QuotaBlob"
    private static let subscriptionID = "quotapulse.changes"

    private let container: CKContainer
    private var database: CKDatabase { container.privateCloudDatabase }
    private var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName) }

    /// nil when this process isn't entitled: `CKContainer(identifier:)` would kill it with SIGTRAP.
    public static func standard() -> CloudKitRecordStore? {
        guard hasICloudEntitlement else {
            QPLog.cloud.notice("no iCloud entitlement; iCloud sync unavailable in this build")
            return nil
        }
        return CloudKitRecordStore(container: CKContainer(identifier: containerID))
    }

    /// True when a remote notification is this store's change subscription firing.
    public static func isChangeNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID == subscriptionID
    }

    /// SecTask is only in the macOS SDK headers but exists on every Apple platform.
    private static var hasICloudEntitlement: Bool {
        typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
        typealias Copy = @convention(c) (AnyObject, CFString, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<AnyObject>?
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let createSym = dlsym(defaultHandle, "SecTaskCreateFromSelf"),
              let copySym = dlsym(defaultHandle, "SecTaskCopyValueForEntitlement") else { return false }
        let create = unsafeBitCast(createSym, to: Create.self)
        let copy = unsafeBitCast(copySym, to: Copy.self)
        guard let task = create(nil)?.takeRetainedValue() else { return false }
        return copy(task, "com.apple.developer.icloud-services" as CFString, nil)?.takeRetainedValue() != nil
    }

    public func accountState() async -> CloudAccountState {
        do {
            switch try await container.accountStatus() {
            case .available: return .available
            case .noAccount: return .noAccount
            case .restricted: return .restricted
            case .temporarilyUnavailable: return .temporarilyUnavailable
            case .couldNotDetermine: return .unknown
            @unknown default: return .unknown
            }
        } catch {
            QPLog.cloud.notice("account status failed: \(error.localizedDescription, privacy: .public)")
            return .unknown
        }
    }

    public func accountID() async -> String? {
        guard let id = try? await container.userRecordID() else { return nil }
        let hash = SHA256.hash(data: Data(id.recordName.utf8))
        return String(hash.map { String(format: "%02x", $0) }.joined().prefix(6))
    }

    public func prepare() async throws {
        try await run { db in _ = try await db.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: []) }
    }

    public func save(_ records: [CloudRecord]) async throws {
        do {
            try await write(records)
        } catch CloudError.zoneMissing {
            try await prepare()
            try await write(records)
        }
    }

    private func write(_ records: [CloudRecord]) async throws {
        try await run { db in
            for batch in CloudRecord.batches(records) {
                let (results, _) = try await db.modifyRecords(saving: batch.map(makeRecord), deleting: [], savePolicy: .allKeys, atomically: false)
                for (_, result) in results {
                    if case let .failure(error) = result { throw error }
                }
            }
        }
    }

    public func fetch(_ names: [String]) async throws -> [String: CloudRecord] {
        let ids = names.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        do {
            return try await run { db in
                var out: [String: CloudRecord] = [:]
                for (id, result) in try await db.records(for: ids) {
                    switch result {
                    case let .success(record):
                        if let decoded = Self.decode(record) { out[id.recordName] = decoded }
                    case let .failure(error):
                        if !Self.isMissing(error) { throw error }
                    }
                }
                return out
            }
        } catch CloudError.zoneMissing {
            return [:] // nothing published yet
        }
    }

    public func subscribeToChanges() async throws {
        let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: Self.subscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        try await run { db in _ = try await db.modifySubscriptions(saving: [subscription], deleting: []) }
    }

    public func removeAll() async throws {
        do {
            try await run { db in _ = try await db.modifyRecordZones(saving: [], deleting: [zoneID]) }
        } catch CloudError.zoneMissing {
            // already gone
        }
    }

    // MARK: Plumbing

    private func run<R: Sendable>(_ body: @Sendable (CKDatabase) async throws -> R) async throws -> R {
        let config = CKOperation.Configuration()
        config.qualityOfService = .userInitiated
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        do {
            return try await database.configuredWith(configuration: config) { try await body($0) }
        } catch {
            throw Self.map(error)
        }
    }

    private func makeRecord(_ r: CloudRecord) -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: r.name, zoneID: zoneID))
        record["schema"] = r.schema
        record["generatedAt"] = r.generatedAt
        record["hubName"] = r.hubName
        record["payload"] = r.payload
        return record
    }

    private static func decode(_ record: CKRecord) -> CloudRecord? {
        guard let schema = record["schema"] as? Int, let generatedAt = record["generatedAt"] as? Date,
              let payload = record["payload"] as? Data else { return nil }
        return CloudRecord(name: record.recordID.recordName, schema: schema, generatedAt: generatedAt,
                           hubName: record["hubName"] as? String ?? "", payload: payload)
    }

    private static func isMissing(_ error: Error) -> Bool {
        guard let ck = error as? CKError else { return false }
        return [.unknownItem, .zoneNotFound, .userDeletedZone].contains(ck.code)
    }

    static func map(_ error: Error) -> Error {
        if error is CloudError { return error }
        guard let ck = error as? CKError else { return CloudError.other(error.localizedDescription) }
        if ck.code != .partialFailure { QPLog.cloud.error("CKError \(ck.code.rawValue, privacy: .public): \(ck.localizedDescription, privacy: .public)") }
        switch ck.code {
        case .partialFailure:
            if let first = ck.partialErrorsByItemID?.values.first { return map(first) }
            return CloudError.other(ck.localizedDescription)
        case .notAuthenticated:
            return CloudError.account(.noAccount)
        case .managedAccountRestricted:
            return CloudError.account(.restricted)
        case .accountTemporarilyUnavailable:
            return CloudError.account(.temporarilyUnavailable)
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy, .serverResponseLost:
            return CloudError.retryLater(after: ck.retryAfterSeconds, message: ck.localizedDescription)
        case .zoneNotFound, .userDeletedZone:
            return CloudError.zoneMissing
        case .quotaExceeded:
            return CloudError.quotaExceeded
        case .permissionFailure, .badContainer:
            return CloudError.rejected(serverReason(ck.localizedDescription))
        default:
            return CloudError.other(ck.localizedDescription)
        }
    }

    /// "Error fetching record <CKRecordID: 0x…> from server: reason" → "reason".
    private static func serverReason(_ description: String) -> String {
        guard let range = description.range(of: "from server: ") else { return description }
        return String(description[range.upperBound...])
    }
}
#endif
