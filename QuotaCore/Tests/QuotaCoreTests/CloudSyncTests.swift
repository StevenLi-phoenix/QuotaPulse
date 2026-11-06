import Foundation
import Testing
@testable import QuotaCore

/// In-memory stand-in for the CloudKit private database.
final class FakeCloudStore: CloudRecordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _records: [String: CloudRecord] = [:]
    private var _saves: [[String]] = []
    private var _saveError: CloudError?
    private var _fetchError: CloudError?
    private var _account: CloudAccountState
    private var _prepares = 0
    private var _subscribes = 0
    private let fetchDelay: Duration?
    private let firstSaveDelay: Duration?
    private var _delayedFirstSave = false
    private var _savedSnapshotTimes: [Date] = []
    private var _events: [String] = []

    init(account: CloudAccountState = .available, fetchDelay: Duration? = nil, firstSaveDelay: Duration? = nil) {
        _account = account
        self.fetchDelay = fetchDelay
        self.firstSaveDelay = firstSaveDelay
    }

    var records: [String: CloudRecord] { lock.withLock { _records } }
    var saves: [[String]] { lock.withLock { _saves } }
    var prepares: Int { lock.withLock { _prepares } }
    var subscribes: Int { lock.withLock { _subscribes } }
    var savedSnapshotTimes: [Date] { lock.withLock { _savedSnapshotTimes } }
    var events: [String] { lock.withLock { _events } }
    func failSaves(with e: CloudError?) { lock.withLock { _saveError = e } }
    func failFetches(with e: CloudError?) { lock.withLock { _fetchError = e } }
    func setAccount(_ a: CloudAccountState) { lock.withLock { _account = a } }
    func put(_ r: CloudRecord) { lock.withLock { _records[r.name] = r } }

    func accountState() async -> CloudAccountState { lock.withLock { _account } }
    func accountID() async -> String? { "abc123" }
    func prepare() async throws { lock.withLock { _prepares += 1 } }
    func save(_ records: [CloudRecord]) async throws {
        let delay: Duration? = lock.withLock {
            defer { _delayedFirstSave = true }
            return _delayedFirstSave ? nil : firstSaveDelay
        }
        if let delay { try await Task.sleep(for: delay) }
        try lock.withLock {
            if let e = _saveError { throw e }
            _saves.append(records.map(\.name).sorted())
            _events.append("save")
            for r in records {
                _records[r.name] = r
                if r.name == CloudPayload.snapshotRecord { _savedSnapshotTimes.append(r.generatedAt) }
            }
        }
    }
    func fetch(_ names: [String]) async throws -> [String: CloudRecord] {
        if let fetchDelay { try await Task.sleep(for: fetchDelay) }
        return try lock.withLock {
            if let e = _fetchError { throw e }
            return _records.filter { names.contains($0.key) }
        }
    }
    func subscribeToChanges() async throws { lock.withLock { _subscribes += 1 } }
    func removeAll() async throws {
        lock.withLock {
            _records = [:]
            _events.append("removeAll")
        }
    }
}

private let now = Date(timeIntervalSince1970: 1_760_600_000)

private func snapshot(at date: Date = now, util: Double = 40, hub: String = "mini") -> QuotaSnapshot {
    QuotaSnapshot(generatedAt: date, hubName: hub, providers: [
        ProviderSnapshot(id: .claude, fetchedAt: date, account: AccountInfo(plan: "Max"), windows: [
            UsageWindow(id: "five_hour", title: "5-hour", utilization: util, resetsAt: now.addingTimeInterval(3600), duration: 5 * 3600),
        ], forecasts: ["five_hour": Forecast(confidence: .medium, rate: date.timeIntervalSince1970.truncatingRemainder(dividingBy: 7), sampleCount: 8, span: 3600)]),
    ])
}

private func publisher(_ store: FakeCloudStore, samples: [Sample] = []) -> CloudPublisher {
    CloudPublisher(store: store, history: { p, since in samples.filter { $0.provider == p && $0.at >= since } })
}

@Suite struct CloudPayloadTests {
    @Test func snapshotRoundTripsThroughACompressedRecord() throws {
        let s = snapshot()
        let record = try CloudRecord(name: CloudPayload.snapshotRecord, generatedAt: s.generatedAt, hubName: s.hubName, encoding: s)
        #expect(record.schema == CloudPayload.schema)
        let back = try record.decode(QuotaSnapshot.self)
        #expect(back == s)
        #expect(record.payload != (try JSON.encoder.encode(s)), "payload should be compressed, not raw JSON")
    }

    @Test func newerSchemaIsRefusedInsteadOfMisread() throws {
        var record = try CloudRecord(name: CloudPayload.snapshotRecord, generatedAt: now, hubName: "mini", encoding: snapshot())
        record.schema = CloudPayload.schema + 1
        #expect(throws: CloudError.incompatible(schema: CloudPayload.schema + 1)) { try record.decode(QuotaSnapshot.self) }
    }

    @Test func garbageIsReportedAsCorrupt() {
        let record = CloudRecord(name: "snapshot", schema: CloudPayload.schema, generatedAt: now, hubName: "mini", payload: Data("not lzfse".utf8))
        #expect(throws: CloudError.corrupt) { try record.decode(QuotaSnapshot.self) }
    }

    @Test func payloadCarriesNoSecrets() throws {
        // The snapshot type has no credential field; this pins that down for what actually gets uploaded.
        let s = snapshot()
        let json = try #require(String(data: try JSON.encoder.encode(s), encoding: .utf8))
        for needle in ["token", "apikey", "api_key", "Bearer", "refresh"] { #expect(!json.lowercased().contains(needle.lowercased())) }
    }
}

@Suite struct CloudHistoryTests {
    @Test func recentSamplesKeepResolutionAndOlderOnesAreThinned() {
        // 7 days at 5-minute polls: one window.
        let samples = (0..<2016).map { Sample(provider: .claude, window: "w", at: now.addingTimeInterval(-Double($0) * 300), value: Double($0 % 100)) }
        let h = CloudHistory(provider: .claude, samples: samples, now: now, policy: .standard)
        let recentCut = now.addingTimeInterval(-24 * 3600)
        let recent = h.samples.filter { $0.at >= recentCut }
        let older = h.samples.filter { $0.at < recentCut }
        #expect(recent.count == 288)
        #expect(older.count <= 200)
        #expect(older.count > 100)
        #expect(h.samples == h.samples.sorted { $0.at < $1.at })
    }

    @Test func eachWindowGetsItsOwnBudgetAndAncientSamplesAreDropped() {
        var samples = (0..<400).map { Sample(provider: .claude, window: "a", at: now.addingTimeInterval(-Double($0) * 60), value: 1) }
        samples += (0..<3).map { Sample(provider: .claude, window: "b", at: now.addingTimeInterval(-Double($0) * 3600), value: 2) }
        samples.append(Sample(provider: .claude, window: "b", at: now.addingTimeInterval(-30 * 86400), value: 9))
        let h = CloudHistory(provider: .claude, samples: samples, now: now, policy: .standard)
        #expect(h.samples.filter { $0.window == "a" }.count == 288)
        #expect(h.samples.filter { $0.window == "b" }.count == 3)
        #expect(!h.samples.contains { $0.value == 9 })
    }

    @Test func oversizedHistoryShrinksBelowTheRecordLimit() throws {
        // Incompressible values across many windows, with a limit small enough to force shrinking.
        var rng = SystemRandomNumberGenerator()
        var samples: [Sample] = []
        for w in 0..<20 {
            samples += (0..<2000).map { Sample(provider: .claude, window: "w\(w)", at: now.addingTimeInterval(-Double($0) * 300), value: Double.random(in: 0...1, using: &rng)) }
        }
        var policy = CloudSyncPolicy.standard
        policy.maxRecordBytes = 20_000
        let record = try CloudHistory.record(provider: .claude, samples: samples, hubName: "mini", now: now, policy: policy)
        #expect(record.payload.count <= 20_000)
        let back = try record.decode(CloudHistory.self)
        #expect(!back.samples.isEmpty)
        #expect(back.samples.count < 288 * 20)
    }
}

@Suite struct CloudPublisherTests {
    /// The refresh loop fires two publishes a second apart at launch; the first save is still on the network when the second arrives.
    @Test func overlappingPublishesWriteHistoryOnceAndLeaveTheNewestSnapshot() async throws {
        let store = FakeCloudStore(firstSaveDelay: .milliseconds(200))
        let pub = publisher(store)
        let older = snapshot(at: now)
        let newer = snapshot(at: now.addingTimeInterval(1), util: 99)

        async let first = pub.publish(older, now: now)
        try await Task.sleep(for: .milliseconds(50))
        async let second = pub.publish(newer, now: now.addingTimeInterval(1))
        _ = await (first, second)

        #expect(store.saves == [["history.claude", "snapshot"], ["snapshot"]])
        #expect(store.savedSnapshotTimes == [now, now.addingTimeInterval(1)])
        #expect(try #require(store.records["snapshot"]).generatedAt == now.addingTimeInterval(1))
    }

    /// Otherwise a save still on the network brings back what the user just deleted.
    @Test func removeAllWaitsForAPublishInFlight() async throws {
        let store = FakeCloudStore(firstSaveDelay: .milliseconds(200))
        let pub = publisher(store)

        async let publishing = pub.publish(snapshot(), now: now)
        try await Task.sleep(for: .milliseconds(50))
        try await pub.removeAll()
        _ = await publishing

        #expect(store.events == ["save", "removeAll"])
        #expect(store.records.isEmpty)
    }

    @Test func firstPublishWritesSnapshotAndHistoryAndCreatesTheZone() async throws {
        let store = FakeCloudStore()
        let samples = [Sample(provider: .claude, window: "five_hour", at: now.addingTimeInterval(-60), value: 12)]
        let status = await publisher(store, samples: samples).publish(snapshot(), now: now)
        #expect(store.prepares == 1)
        #expect(store.saves == [["history.claude", "snapshot"]])
        #expect(status.lastPublishedAt == now)
        #expect(status.lastHistoryAt == now)
        #expect(status.account == .available)
        #expect(status.accountID == "abc123")
        #expect(status.lastError == nil)
        let stored = try #require(store.records["snapshot"])
        #expect(stored.hubName == "mini")
        #expect(stored.generatedAt == now)
        #expect(try stored.decode(QuotaSnapshot.self) == snapshot())
        #expect(try #require(store.records["history.claude"]).decode(CloudHistory.self).samples == samples)
    }

    @Test func anIdleMacDoesNotWriteEveryPollButKeepsAHeartbeat() async {
        let store = FakeCloudStore()
        let pub = publisher(store)
        await pub.publish(snapshot(at: now), now: now)
        // Same numbers 5 and 10 minutes later: only timestamps and forecast noise changed.
        await pub.publish(snapshot(at: now.addingTimeInterval(300)), now: now.addingTimeInterval(300))
        await pub.publish(snapshot(at: now.addingTimeInterval(600)), now: now.addingTimeInterval(600))
        #expect(store.saves.count == 1)
        // Past the heartbeat the snapshot is rewritten so devices can tell the Mac is alive; history isn't due yet.
        let beat = now.addingTimeInterval(15 * 60)
        let s = await pub.publish(snapshot(at: beat), now: beat)
        #expect(store.saves.count == 2)
        #expect(store.saves.last == ["snapshot"])
        #expect(s.lastPublishedAt == beat)
    }

    @Test func aChangedNumberIsPublishedImmediately() async throws {
        let store = FakeCloudStore()
        let pub = publisher(store)
        await pub.publish(snapshot(util: 40), now: now)
        let later = now.addingTimeInterval(120)
        await pub.publish(snapshot(at: later, util: 41), now: later)
        #expect(store.saves.count == 2)
        #expect(store.saves.last == ["snapshot"])
        #expect(try #require(store.records["snapshot"]).generatedAt == later)
    }

    @Test func historyIsRewrittenOnlyEveryThirtyMinutes() async {
        let store = FakeCloudStore()
        let pub = publisher(store)
        await pub.publish(snapshot(), now: now)
        let t29 = now.addingTimeInterval(29 * 60)
        await pub.publish(snapshot(at: t29, util: 41), now: t29)
        #expect(store.saves.last == ["snapshot"])
        let t30 = now.addingTimeInterval(30 * 60)
        await pub.publish(snapshot(at: t30, util: 42), now: t30)
        #expect(store.saves.last == ["history.claude", "snapshot"])
    }

    @Test func emptySnapshotsAreNeverPublished() async {
        let store = FakeCloudStore()
        let pub = publisher(store)
        await pub.publish(.empty, now: now)
        await pub.publish(QuotaSnapshot(generatedAt: now, hubName: "mini", providers: []), now: now)
        #expect(store.saves.isEmpty)
        #expect(store.prepares == 0)
    }

    @Test func noICloudAccountIsReportedAndRecoversOnItsOwn() async {
        let store = FakeCloudStore(account: .noAccount)
        let pub = publisher(store)
        let s1 = await pub.publish(snapshot(), now: now)
        #expect(s1.account == .noAccount)
        #expect(s1.lastError != nil)
        #expect(s1.lastPublishedAt == nil)
        #expect(store.saves.isEmpty)
        store.setAccount(.available)
        let later = now.addingTimeInterval(300)
        let s2 = await pub.publish(snapshot(at: later), now: later)
        #expect(s2.account == .available)
        #expect(s2.lastError == nil)
        #expect(store.saves.count == 1)
    }

    @Test func failedSaveIsRetriedAndRespectsRetryAfter() async {
        let store = FakeCloudStore()
        store.failSaves(with: .retryLater(after: 600, message: "rate limited"))
        let pub = publisher(store)
        let s1 = await pub.publish(snapshot(), now: now)
        #expect(s1.lastError == "rate limited")
        store.failSaves(with: nil)
        // Inside the server's Retry-After: nothing is attempted.
        let t5 = now.addingTimeInterval(300)
        await pub.publish(snapshot(at: t5), now: t5)
        #expect(store.saves.isEmpty)
        let t11 = now.addingTimeInterval(660)
        let s2 = await pub.publish(snapshot(at: t11), now: t11)
        #expect(store.saves == [["history.claude", "snapshot"]])
        #expect(s2.lastError == nil)
    }

    @Test func aDeletedZoneIsRecreatedOnTheNextPublish() async {
        let store = FakeCloudStore()
        let pub = publisher(store)
        await pub.publish(snapshot(), now: now)
        store.failSaves(with: .zoneMissing)
        let t1 = now.addingTimeInterval(120)
        await pub.publish(snapshot(at: t1, util: 50), now: t1)
        store.failSaves(with: nil)
        let t2 = now.addingTimeInterval(240)
        await pub.publish(snapshot(at: t2, util: 50), now: t2)
        #expect(store.prepares == 2)
        #expect(store.saves.last == ["snapshot"])
    }

    @Test func forcedPublishWritesEverythingEvenWhenNothingChanged() async {
        let store = FakeCloudStore()
        let pub = publisher(store)
        await pub.publish(snapshot(), now: now)
        await pub.publish(snapshot(), force: true, now: now.addingTimeInterval(1))
        #expect(store.saves.count == 2)
        #expect(store.saves.last == ["history.claude", "snapshot"])
    }

    @Test func removeAllWipesTheCloudAndAllowsRepublishing() async throws {
        let store = FakeCloudStore()
        let pub = publisher(store)
        await pub.publish(snapshot(), now: now)
        try await pub.removeAll()
        #expect(store.records.isEmpty)
        let status = await pub.status
        #expect(status.lastPublishedAt == nil)
        await pub.publish(snapshot(), now: now.addingTimeInterval(1))
        #expect(store.prepares == 2)
        #expect(store.records["snapshot"] != nil)
    }

    @Test func historyDeletionReachesTheCloud() async throws {
        let store = FakeCloudStore()
        let holder = SampleHolder([Sample(provider: .claude, window: "five_hour", at: now, value: 1)])
        let pub = CloudPublisher(store: store, history: { _, _ in holder.samples })
        await pub.publish(snapshot(), now: now)
        #expect(try #require(store.records["history.claude"]).decode(CloudHistory.self).samples.count == 1)
        holder.samples = []
        await pub.publish(snapshot(), force: true, now: now.addingTimeInterval(1))
        #expect(try #require(store.records["history.claude"]).decode(CloudHistory.self).samples.isEmpty)
    }
}

final class SampleHolder: @unchecked Sendable {
    var samples: [Sample]
    init(_ samples: [Sample]) { self.samples = samples }
}

@Suite struct CloudReaderTests {
    @Test func missingSnapshotMeansTheMacHasNotPublishedYet() async throws {
        #expect(try await CloudReader(store: FakeCloudStore()).snapshot() == nil)
    }

    @Test func historiesAreReturnedPerProviderAndMissingOnesAreSkipped() async throws {
        let store = FakeCloudStore()
        let samples = [Sample(provider: .claude, window: "w", at: now, value: 3)]
        store.put(try CloudHistory.record(provider: .claude, samples: samples, hubName: "mini", now: now, policy: .standard))
        let got = try await CloudReader(store: store).histories(for: [.claude, .codex])
        #expect(got[.claude] == samples)
        #expect(got[.codex] == nil)
    }
}

@Suite struct SnapshotFetcherTests {
    let hubURL = URL(string: "http://hub.test:48422")!

    func hub(_ snap: QuotaSnapshot?) throws -> HubClient {
        let transport: StubTransport
        if let snap {
            transport = StubTransport(status: 200, json: String(data: try JSON.encoder.encode(snap), encoding: .utf8)!)
        } else {
            transport = StubTransport(status: 500, json: "")
        }
        return HubClient(pairing: HubPairing(baseURL: hubURL, token: "t", hubName: "mini"), transport: transport)
    }

    func cloud(_ snap: QuotaSnapshot?, account: CloudAccountState = .available) throws -> CloudReader {
        let store = FakeCloudStore(account: account)
        if let snap { store.put(try CloudRecord(name: CloudPayload.snapshotRecord, generatedAt: snap.generatedAt, hubName: snap.hubName, encoding: snap)) }
        return CloudReader(store: store)
    }

    @Test func freshICloudDataNeedsNoHubAtAll() async throws {
        let transport = StubTransport(status: 500, json: "")
        let client = HubClient(pairing: HubPairing(baseURL: hubURL, token: "t", hubName: "mini"), transport: transport)
        let r = await SnapshotFetcher(cloud: try cloud(snapshot()), hub: client).fetch(now: now.addingTimeInterval(60))
        #expect(r.source == .iCloud)
        #expect(r.snapshot == snapshot())
        #expect(r.userError == nil)
        #expect(transport.requests.isEmpty, "a fresh iCloud snapshot must not wait on an unreachable hub")
    }

    @Test func hubFailureIsSilentWhenICloudAnswered() async throws {
        let stale = snapshot(at: now.addingTimeInterval(-3600))
        let r = await SnapshotFetcher(cloud: try cloud(stale), hub: try hub(nil)).fetch(now: now)
        #expect(r.source == .iCloud)
        #expect(r.userError == nil)
        #expect(r.hubError != nil)
    }

    @Test func staleICloudLosesToANewerHubSnapshot() async throws {
        let stale = snapshot(at: now.addingTimeInterval(-3600), util: 10)
        let fresh = snapshot(at: now, util: 20)
        let r = await SnapshotFetcher(cloud: try cloud(stale), hub: try hub(fresh)).fetch(now: now)
        #expect(r.source == .hub)
        #expect(r.snapshot == fresh)
    }

    @Test func noICloudAccountFallsBackToTheHub() async throws {
        let r = await SnapshotFetcher(cloud: try cloud(nil, account: .noAccount), hub: try hub(snapshot())).fetch(now: now)
        #expect(r.source == .hub)
        #expect(r.account == .noAccount)
        #expect(r.userError == nil)
    }

    @Test func noAccountAndNoHubIsAStateNotAnError() async throws {
        let r = await SnapshotFetcher(cloud: try cloud(nil, account: .noAccount), hub: nil).fetch(now: now)
        #expect(r.snapshot == nil)
        #expect(r.account == .noAccount)
        #expect(r.userError == nil)
    }

    @Test func iCloudAnsweringEmptyIsNotAnError() async throws {
        let r = await SnapshotFetcher(cloud: try cloud(nil), hub: nil).fetch(now: now)
        #expect(r.snapshot == nil)
        #expect(r.account == .available)
        #expect(r.userError == nil)
    }

    @Test func nothingReachableSurfacesAnError() async throws {
        let store = FakeCloudStore()
        store.failFetches(with: .retryLater(after: nil, message: "offline"))
        let viaCloudOnly = await SnapshotFetcher(cloud: CloudReader(store: store), hub: nil).fetch(now: now)
        #expect(viaCloudOnly.userError == "offline")
        let both = await SnapshotFetcher(cloud: CloudReader(store: store), hub: try hub(nil)).fetch(now: now)
        #expect(both.snapshot == nil)
        #expect(both.userError?.contains("500") == true)
    }

    @Test func buildsWithoutTheEntitlementStillWorkOverTheHub() async throws {
        let r = await SnapshotFetcher(cloud: nil, hub: try hub(snapshot())).fetch(now: now)
        #expect(r.source == .hub)
        #expect(r.account == .notEntitled)
    }
}

@Suite struct CloudFreshnessTests {
    @Test func aSilentMacIsFlaggedAfterTwoMissedHeartbeats() {
        let s = snapshot()
        #expect(!s.isStale(now: now.addingTimeInterval(29 * 60)))
        #expect(s.isStale(now: now.addingTimeInterval(31 * 60)))
        #expect(!QuotaSnapshot.empty.isStale(now: now), "no data at all is the empty state, not a stale one")
    }

    @Test func fingerprintIgnoresTimestampsAndForecastNoiseButNotNumbers() {
        let a = snapshot(at: now)
        #expect(a.cloudFingerprint == snapshot(at: now.addingTimeInterval(300)).cloudFingerprint)
        #expect(a.cloudFingerprint != snapshot(at: now, util: 41).cloudFingerprint)
        var failing = a
        failing.providers[0].status = .rateLimited(retryAfter: nil)
        #expect(a.cloudFingerprint != failing.cloudFingerprint)
        var noBalance = a
        noBalance.providers[0].balance = Balance(currency: "USD", total: 5)
        #expect(a.cloudFingerprint != noBalance.cloudFingerprint)
    }
}

@Suite struct CloudWidgetRefreshTests {
    func tempStore() -> SnapshotStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qp-cloud-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SnapshotStore(url: dir.appendingPathComponent("snapshot.json"))
    }

    func reader(_ snap: QuotaSnapshot?, delay: Duration? = nil) throws -> CloudReader {
        let store = FakeCloudStore(fetchDelay: delay)
        if let snap { store.put(try CloudRecord(name: CloudPayload.snapshotRecord, generatedAt: snap.generatedAt, hubName: snap.hubName, encoding: snap)) }
        return CloudReader(store: store)
    }

    @Test func recentLocalDataSkipsTheNetwork() async throws {
        let disk = tempStore()
        try disk.save(snapshot(at: now, util: 1))
        let got = await CloudSnapshotRefresh.latest(store: disk, reader: try reader(snapshot(at: now.addingTimeInterval(60), util: 2)), now: now.addingTimeInterval(120))
        #expect(got.providers.first?.windows.first?.utilization == 1)
    }

    @Test func staleLocalDataIsReplacedAndWrittenBack() async throws {
        let disk = tempStore()
        try disk.save(snapshot(at: now, util: 1))
        let t = now.addingTimeInterval(3600)
        let got = await CloudSnapshotRefresh.latest(store: disk, reader: try reader(snapshot(at: t, util: 2)), now: t)
        #expect(got.providers.first?.windows.first?.utilization == 2)
        #expect(disk.load()?.generatedAt == t)
    }

    @Test func olderCloudDataNeverOverwritesLocal() async throws {
        let disk = tempStore()
        try disk.save(snapshot(at: now, util: 1))
        let got = await CloudSnapshotRefresh.latest(store: disk, reader: try reader(snapshot(at: now.addingTimeInterval(-60), util: 2)), now: now.addingTimeInterval(3600))
        #expect(got.providers.first?.windows.first?.utilization == 1)
    }

    @Test func aSlowNetworkFallsBackToLocalWithinTheTimeout() async throws {
        let disk = tempStore()
        try disk.save(snapshot(at: now, util: 1))
        let clock = ContinuousClock()
        let t0 = clock.now
        let got = await CloudSnapshotRefresh.latest(store: disk, reader: try reader(snapshot(at: now.addingTimeInterval(3600), util: 2), delay: .seconds(30)),
                                                    timeout: .milliseconds(100), now: now.addingTimeInterval(3600))
        #expect(got.providers.first?.windows.first?.utilization == 1)
        #expect(clock.now - t0 < .seconds(5))
    }
}

@Suite struct CloudSettingsTests {
    @Test func settingsFromBeforeICloudKeepTheirValues() throws {
        // What 0.2.x wrote: no `cloud` key. A failed decode would silently reset every setting to defaults.
        var old = AppSettings()
        old.pollInterval = 600
        old.retentionDays = 90
        old.providers[.deepseek] = ProviderSettings(enabled: true, options: ["x": "y"])
        var dict = try #require(JSONSerialization.jsonObject(with: try JSON.encoder.encode(old)) as? [String: Any])
        dict.removeValue(forKey: "cloud")
        let legacy = try JSONSerialization.data(withJSONObject: dict)
        let back = try JSON.decoder.decode(AppSettings.self, from: legacy)
        #expect(back.pollInterval == 600)
        #expect(back.retentionDays == 90)
        #expect(back.isEnabled(.deepseek))
        #expect(back.cloud.enabled, "iCloud sync is on by default after upgrading")
    }

    @Test func cloudChoicePersists() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qp-settings-\(UUID().uuidString).json")
        let store = SettingsStore(url: url)
        var s = store.load()
        #expect(s.cloud.enabled)
        s.cloud.enabled = false
        store.save(s)
        #expect(store.load().cloud.enabled == false)
    }
}

@Suite struct CloudKitGuardTests {
    @Test func unentitledProcessesGetNoStoreInsteadOfACrash() {
        // `swift test` has no iCloud entitlement; touching CKContainer here would kill the process with SIGTRAP.
        #expect(CloudKitRecordStore.standard() == nil)
    }
}
