import Foundation

public struct CloudPublishStatus: Sendable, Equatable {
    public var account: CloudAccountState = .unknown
    public var accountID: String?
    public var lastPublishedAt: Date?
    public var lastHistoryAt: Date?
    public var lastError: String?

    public init() {}
}

/// Mac side: mirrors the engine's snapshot and history into iCloud, writing only when a reader would notice.
public actor CloudPublisher {
    public private(set) var status = CloudPublishStatus()

    private let store: any CloudRecordStore
    private let history: @Sendable (ProviderID, Date) async -> [Sample]
    private let policy: CloudSyncPolicy
    private var prepared = false
    private var lastFingerprint: [String]?
    private var retryNotBefore: Date?
    private var tail: Task<Void, Never>?

    /// `history` returns raw samples for a provider since a date.
    public init(store: any CloudRecordStore, history: @escaping @Sendable (ProviderID, Date) async -> [Sample], policy: CloudSyncPolicy = .standard) {
        self.store = store
        self.history = history
        self.policy = policy
    }

    /// `force` writes everything now: sync was just turned on, or history was deleted and must disappear from iCloud too.
    @discardableResult
    public func publish(_ snapshot: QuotaSnapshot, force: Bool = false, now: Date = Date()) async -> CloudPublishStatus {
        await inOrder { await $0.publishNow(snapshot, force: force, now: now) }
    }

    /// Deletes everything QuotaPulse keeps in iCloud. The zone comes back on the next publish.
    public func removeAll() async throws {
        let result: Result<Void, Error> = await inOrder { publisher in
            do {
                try await publisher.removeAllNow()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try result.get()
    }

    /// An actor only protects its state between suspension points, so work here runs one at a time: overlapping
    /// publishes would both write history and could land the older snapshot last, and a save still on the
    /// network would bring back what `removeAll` just deleted.
    private func inOrder<T: Sendable>(_ work: @escaping @Sendable (isolated CloudPublisher) async -> T) async -> T {
        let previous = tail
        let task = Task {
            await previous?.value
            return await work(self)
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    private func publishNow(_ snapshot: QuotaSnapshot, force: Bool, now: Date) async -> CloudPublishStatus {
        guard snapshot.generatedAt != .distantPast, !snapshot.providers.isEmpty else { return status }
        if !force, let retryNotBefore, retryNotBefore > now {
            QPLog.cloud.debug("publish skipped: retry not before \(retryNotBefore, privacy: .public)")
            return status
        }
        let fingerprint = snapshot.cloudFingerprint
        let snapshotDue = force || fingerprint != lastFingerprint || isDue(status.lastPublishedAt, every: policy.heartbeat, now: now)
        let historyDue = force || isDue(status.lastHistoryAt, every: policy.historyInterval, now: now)
        guard snapshotDue || historyDue else { return status }

        do {
            try await ensureReady()
            var records: [CloudRecord] = []
            if snapshotDue {
                records.append(try CloudRecord(name: CloudPayload.snapshotRecord, generatedAt: snapshot.generatedAt, hubName: snapshot.hubName, encoding: snapshot))
            }
            if historyDue {
                let since = now.addingTimeInterval(-Double(policy.historyDays) * 86400)
                for p in snapshot.providers {
                    let samples = await history(p.id, since)
                    records.append(try CloudHistory.record(provider: p.id, samples: samples, hubName: snapshot.hubName, now: now, policy: policy))
                }
            }
            try await store.save(records)
            if snapshotDue { status.lastPublishedAt = now; lastFingerprint = fingerprint }
            if historyDue { status.lastHistoryAt = now }
            status.lastError = nil
            retryNotBefore = nil
            let bytes = records.reduce(0) { $0 + $1.payload.count }
            QPLog.cloud.notice("published \(records.count) records, \(bytes) bytes (snapshot=\(snapshotDue), history=\(historyDue), force=\(force))")
        } catch {
            record(failure: error, now: now)
        }
        return status
    }

    private func removeAllNow() async throws {
        do {
            try await store.removeAll()
            prepared = false
            lastFingerprint = nil
            retryNotBefore = nil
            status.lastPublishedAt = nil
            status.lastHistoryAt = nil
            status.lastError = nil
            QPLog.cloud.notice("removed all iCloud data")
        } catch {
            status.lastError = error.localizedDescription
            QPLog.cloud.error("remove failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func isDue(_ last: Date?, every interval: TimeInterval, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    private func ensureReady() async throws {
        let account = await store.accountState()
        if account != status.account { QPLog.cloud.notice("iCloud account state: \(account.rawValue, privacy: .public)") }
        status.account = account
        guard account == .available else { throw CloudError.account(account) }
        if status.accountID == nil {
            let id = await store.accountID()
            status.accountID = id
            QPLog.cloud.notice("iCloud account id: \(id ?? "?", privacy: .public)")
        }
        if !prepared {
            try await store.prepare()
            prepared = true
        }
    }

    private func record(failure error: Error, now: Date) {
        status.lastError = error.localizedDescription
        QPLog.cloud.error("publish failed: \(error.localizedDescription, privacy: .public)")
        switch error as? CloudError {
        case let .retryLater(after, _):
            retryNotBefore = now.addingTimeInterval(after ?? policy.retryDelay)
        case .zoneMissing:
            prepared = false
        case .account:
            break // checked again cheaply on every publish
        default:
            retryNotBefore = now.addingTimeInterval(policy.retryDelay)
        }
    }
}
