import Foundation

/// iPhone / Watch side: reads what the Mac published.
public struct CloudReader: Sendable {
    public let store: any CloudRecordStore

    public init(store: any CloudRecordStore) { self.store = store }

    public func account() async -> CloudAccountState { await store.accountState() }
    public func accountID() async -> String? { await store.accountID() }

    /// nil means the Mac hasn't published yet.
    public func snapshot() async throws -> QuotaSnapshot? {
        guard let record = try await store.fetch([CloudPayload.snapshotRecord])[CloudPayload.snapshotRecord] else { return nil }
        return try record.decode(QuotaSnapshot.self)
    }

    public func histories(for providers: [ProviderID]) async throws -> [ProviderID: [Sample]] {
        let records = try await store.fetch(providers.map(CloudPayload.historyRecord))
        var out: [ProviderID: [Sample]] = [:]
        for p in providers {
            if let record = records[CloudPayload.historyRecord(p)] { out[p] = try record.decode(CloudHistory.self).samples }
        }
        return out
    }
}

public enum SnapshotSource: String, Sendable {
    case iCloud
    case hub
    case iPhone
}

public struct SnapshotFetchResult: Sendable, Equatable {
    public var snapshot: QuotaSnapshot?
    public var source: SnapshotSource?
    public var account: CloudAccountState
    public var cloudError: String?
    public var hubError: String?

    /// Only worth showing when nothing answered: a dead hub is no news while iCloud works.
    public var userError: String? { snapshot == nil ? (hubError ?? cloudError) : nil }
}

/// Picks the data source: iCloud first, the paired hub when iCloud can't deliver something recent.
public struct SnapshotFetcher: Sendable {
    public var cloud: CloudReader?
    public var hub: HubClient?
    /// A snapshot younger than this (heartbeat + one poll) makes asking the hub pointless. An unreachable hub costs a full timeout.
    public var freshEnough: TimeInterval

    public init(cloud: CloudReader?, hub: HubClient?, freshEnough: TimeInterval = 20 * 60) {
        self.cloud = cloud
        self.hub = hub
        self.freshEnough = freshEnough
    }

    public func fetch(now: Date = Date()) async -> SnapshotFetchResult {
        var result = SnapshotFetchResult(account: .notEntitled)
        if let cloud {
            result.account = await cloud.account()
            if result.account == .available {
                do {
                    if let s = try await cloud.snapshot() {
                        result.snapshot = s
                        result.source = .iCloud
                    }
                } catch {
                    result.cloudError = error.localizedDescription
                    QPLog.cloud.notice("snapshot fetch failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        if let s = result.snapshot, now.timeIntervalSince(s.generatedAt) <= freshEnough { return result }
        if let hub {
            do {
                let s = try await hub.snapshot()
                if s.generatedAt >= result.snapshot?.generatedAt ?? .distantPast {
                    result.snapshot = s
                    result.source = .hub
                }
            } catch {
                result.hubError = error.localizedDescription
                QPLog.hub.notice("snapshot fetch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return result
    }
}

/// Widgets can't wait for the app: when the shared snapshot has aged, they fetch for themselves.
public enum CloudSnapshotRefresh {
    /// Newest of disk and iCloud, never waiting past `timeout`. Newer data is written back for the app and other widgets.
    public static func latest(store: SnapshotStore, reader: CloudReader?, maxAge: TimeInterval = 5 * 60,
                              timeout: Duration = .seconds(5), now: Date = Date()) async -> QuotaSnapshot {
        let local = store.load() ?? .empty
        guard let reader, now.timeIntervalSince(local.generatedAt) > maxAge else { return local }
        let fetched = await withTaskGroup(of: QuotaSnapshot?.self) { group in
            group.addTask { try? await reader.snapshot() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let fetched, fetched.generatedAt > local.generatedAt else { return local }
        do { try store.save(fetched) } catch {
            QPLog.store.error("widget snapshot save failed: \(error.localizedDescription, privacy: .public)")
        }
        return fetched
    }
}
