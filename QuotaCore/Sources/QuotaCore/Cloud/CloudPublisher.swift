import Foundation

public struct CloudPublishStatus: Sendable, Equatable {
    public var account: CloudAccountState = .unknown
    public var accountID: String?
    public var lastPublishedAt: Date?
    public var lastHistoryAt: Date?
    public var lastError: String?

    public init() {}
}

/// Mac side: mirrors each provider's latest reading and its history into iCloud. The account has one set of numbers per
/// provider, so every Mac writes the same record for a provider: a newer reading replaces an older one, and history from
/// two Macs is merged instead of replaced. A Mac writes only the providers it has read, so it never erases another's.
public actor CloudPublisher {
    public private(set) var status = CloudPublishStatus()

    private let store: any CloudRecordStore
    private let history: @Sendable (ProviderID, Date) async -> [Sample]
    private let absorb: @Sendable ([Sample], [ProviderID: Date]) async -> Void
    private let policy: CloudSyncPolicy
    private var prepared = false
    private var lastFingerprint: [ProviderID: String] = [:]
    private var lastChecked: [ProviderID: Date] = [:]
    private var retryNotBefore: Date?
    private var tail: Task<Void, Never>?

    /// `history` returns raw samples for a provider since a date. `absorb` takes in the points other Macs sampled, with the
    /// deletion cut-off of each provider, after they have been saved to iCloud.
    public init(store: any CloudRecordStore, history: @escaping @Sendable (ProviderID, Date) async -> [Sample],
                absorb: @escaping @Sendable ([Sample], [ProviderID: Date]) async -> Void = { _, _ in },
                policy: CloudSyncPolicy = .standard) {
        self.store = store
        self.history = history
        self.absorb = absorb
        self.policy = policy
    }

    /// `force` writes everything now: sync was just turned on, or history was deleted and must disappear from iCloud too.
    @discardableResult
    public func publish(_ snapshot: QuotaSnapshot, force: Bool = false, clearHistory: Bool = false, now: Date = Date()) async -> CloudPublishStatus {
        await inOrder { await $0.publishNow(snapshot, force: force, clearHistory: clearHistory, now: now) }
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
    /// publishes would both write history and could land the older reading last, and a save still on the
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

    private func publishNow(_ snapshot: QuotaSnapshot, force: Bool, clearHistory: Bool, now: Date) async -> CloudPublishStatus {
        guard snapshot.generatedAt != .distantPast, !snapshot.providers.isEmpty else { return status }
        if !force, let retryNotBefore, retryNotBefore > now {
            QPLog.cloud.debug("publish skipped: retry not before \(retryNotBefore, privacy: .public)")
            return status
        }
        let fingerprints = Dictionary(uniqueKeysWithValues: zip(snapshot.providers.map(\.id), snapshot.cloudFingerprint))
        // A provider is due when what a reader would see changed, or when its heartbeat has run out.
        // A Mac that has nothing to read for a provider (Grok Bot not installed, no key) must not overwrite another Mac's reading.
        let due = snapshot.providers.filter { p in
            if case .notConfigured = p.status { return false }
            return force || lastFingerprint[p.id] != fingerprints[p.id] || isDue(lastChecked[p.id], every: policy.heartbeat, now: now)
        }
        let historyDue = force || clearHistory || isDue(status.lastHistoryAt, every: policy.historyInterval, now: now)
        guard !due.isEmpty || historyDue else { return status }

        do {
            try await ensureReady()
            // One read covers everything this pass might write: the current reading of each due provider, and for a history
            // pass the history and first sample piece iCloud holds for each provider.
            var names = due.map { CloudPayload.providerRecord($0.id) }
            if historyDue {
                names += snapshot.providers.map { CloudPayload.historyRecord($0.id) }
                names += CloudSamples.firstPieceNames(snapshot.providers.map(\.id))
            }
            let current = try await store.fetch(names)

            var records: [CloudRecord] = []
            var written: [ProviderID] = []
            for p in due {
                if let theirs = current[CloudPayload.providerRecord(p.id)], theirs.generatedAt > p.fetchedAt {
                    QPLog.cloud.notice("kept \(p.id.rawValue, privacy: .public): iCloud has a newer reading from \(theirs.hubName, privacy: .public)")
                    continue
                }
                records.append(try CloudRecord(name: CloudPayload.providerRecord(p.id), generatedAt: p.fetchedAt, hubName: snapshot.hubName, encoding: p))
                written.append(p.id)
            }
            var merge: HistoryMerge?
            if historyDue {
                let m = try await mergeHistory(snapshot, current: current, clearHistory: clearHistory, now: now)
                records += m.records
                merge = m
            }
            if !records.isEmpty { try await store.save(records) }
            // Only after the save: the points taken back are the ones iCloud now holds.
            if let merge { await absorb(merge.samples, merge.cutoffs) }
            for p in due {
                lastFingerprint[p.id] = fingerprints[p.id]
                lastChecked[p.id] = now
            }
            if !written.isEmpty { status.lastPublishedAt = now }
            if historyDue { status.lastHistoryAt = now }
            status.lastError = nil
            retryNotBefore = nil
            let bytes = records.reduce(0) { $0 + $1.payload.count }
            QPLog.cloud.notice("published \(records.count) records, \(bytes) bytes: providers [\(written.map(\.rawValue).joined(separator: ","), privacy: .public)], history=\(historyDue), samples=\(merge?.sampleCount ?? 0), force=\(force)")
        } catch {
            record(failure: error, now: now)
        }
        return status
    }

    /// What a history pass writes, and what this Mac takes back from iCloud.
    private struct HistoryMerge {
        var records: [CloudRecord] = []
        var samples: [Sample] = []
        var cutoffs: [ProviderID: Date] = [:]
        var sampleCount = 0
    }

    /// Per provider: joins this Mac's samples with the ones iCloud holds, drops what a deletion cut off, and builds the
    /// history and sample records. Samples go back `policy.sampleDays`; the history record keeps its own shorter window.
    private func mergeHistory(_ snapshot: QuotaSnapshot, current: [String: CloudRecord], clearHistory: Bool, now: Date) async throws -> HistoryMerge {
        let remote = try await CloudSamples.read(snapshot.providers.map(\.id), first: current, store: store)
        let horizon = now.addingTimeInterval(-Double(policy.sampleDays) * 86400)
        var out = HistoryMerge()
        for p in snapshot.providers {
            let mine = await history(p.id, horizon)
            let theirs = remote[p.id]
            let stored = try? current[CloudPayload.historyRecord(p.id)]?.decode(CloudHistory.self)
            // Deleting history sets a cut-off; samples before it are dropped everywhere, so another Mac's copy can't bring them back.
            let cutoff = clearHistory ? now : [stored?.clearedAt, theirs?.clearedAt].compactMap { $0 }.max()
            let all = Self.merged(mine, theirs?.samples ?? []).filter { $0.at >= horizon }
            let kept = cutoff.map { cut in all.filter { $0.at >= cut } } ?? all
            if let cutoff { out.cutoffs[p.id] = cutoff }
            out.records += try CloudSamples.records(provider: p.id, samples: kept, clearedAt: cutoff, hubName: snapshot.hubName, now: now, policy: policy)
            out.records.append(try CloudHistory.record(provider: p.id, samples: kept, hubName: snapshot.hubName, now: now, policy: policy, clearedAt: cutoff))
            out.samples += kept
            out.sampleCount += kept.count
        }
        return out
    }

    /// Settings are one set for the whole account, so the copy with the newer `updatedAt` wins. Returns the settings this Mac
    /// should adopt: the iCloud copy when it is newer, or the local copy stamped now when it had no timestamp yet. nil means
    /// nothing changes here.
    public func reconcileSettings(_ local: AppSettings, hubName: String, now: Date = Date()) async -> AppSettings? {
        await inOrder { publisher in await publisher.reconcileSettingsNow(local, hubName: hubName, now: now) }
    }

    private func reconcileSettingsNow(_ local: AppSettings, hubName: String, now: Date) async -> AppSettings? {
        do {
            try await ensureReady()
            let remote = try await store.fetch([CloudPayload.settingsRecord])[CloudPayload.settingsRecord]
            let localStamp = local.updatedAt ?? .distantPast
            // Compared to the second: the copy inside the record carries whole seconds, and a record written by an older build may not.
            if let remote {
                let remoteStamp = AppSettings.stampNow(remote.generatedAt)
                if remoteStamp > localStamp {
                    QPLog.cloud.notice("settings: adopting the iCloud copy written by \(remote.hubName, privacy: .public)")
                    return try remote.decode(AppSettings.self)
                }
                if remoteStamp == localStamp { return nil }
            }
            var stamped = local
            if local.updatedAt == nil { stamped.updatedAt = AppSettings.stampNow(now) }
            let stamp = stamped.updatedAt ?? now
            try await store.save([try CloudRecord(name: CloudPayload.settingsRecord, generatedAt: stamp, hubName: hubName, encoding: stamped)])
            QPLog.cloud.notice("settings: pushed \(remote == nil ? "first copy" : "newer copy", privacy: .public)")
            return local.updatedAt == nil ? stamped : nil
        } catch {
            QPLog.cloud.error("settings sync failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Two Macs read the same account, so each may hold points the other missed: keep both, one per provider, window and second.
    static func merged(_ mine: [Sample], _ theirs: [Sample]) -> [Sample] {
        var seen = Set<String>()
        return (mine + theirs).filter { seen.insert($0.identity).inserted }.sorted { $0.at < $1.at }
    }

    private func removeAllNow() async throws {
        do {
            try await store.removeAll()
            prepared = false
            lastFingerprint = [:]
            lastChecked = [:]
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
