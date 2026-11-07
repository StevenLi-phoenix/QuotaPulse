import Foundation
import Testing
@testable import QuotaCore

/// Whole seconds, near today, so the 90-day retention in `SampleStore.absorb` (which uses the real clock) keeps these points.
private let anchor = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))

private func claudeSnapshot(at date: Date, util: Double = 40) -> QuotaSnapshot {
    QuotaSnapshot(generatedAt: date, hubName: "mini", providers: [
        ProviderSnapshot(id: .claude, fetchedAt: date, account: AccountInfo(plan: "Max"), windows: [
            UsageWindow(id: "five_hour", title: "5-hour", utilization: util, resetsAt: date.addingTimeInterval(3600), duration: 5 * 3600),
        ]),
    ])
}

/// `count` five-minute points ending at `end`, oldest first.
private func points(_ count: Int, provider: ProviderID = .claude, window: String = "five_hour", endingAt end: Date = anchor) -> [Sample] {
    (0..<count).reversed().map { Sample(provider: provider, window: window, at: end.addingTimeInterval(-Double($0) * 300), value: Double($0 % 97)) }
}

/// One Mac: its own sample store (in memory until flushed) and a publisher wired to it the way the app wires them.
private func mac(_ cloud: FakeCloudStore) -> (local: SampleStore, publisher: CloudPublisher) {
    let local = SampleStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("qp-samples-\(UUID().uuidString).json"), retentionDays: 90)
    let publisher = CloudPublisher(store: cloud,
                                   history: { provider, since in await local.samples(provider: provider, since: since) },
                                   absorb: { incoming, cutoffs in _ = await local.absorb(incoming, cutoffs: cutoffs, now: anchor) })
    return (local, publisher)
}

@Suite struct CloudSamplesTests {
    @Test func piecesHoldTheWholeSetInOrder() throws {
        let input = points(25_000)
        let records = try CloudSamples.records(provider: .claude, samples: input, clearedAt: anchor, hubName: "mini", now: anchor, policy: .standard)
        #expect(records.map(\.name) == ["samples.claude.0", "samples.claude.1", "samples.claude.2"])
        let pieces = try records.map { try $0.decode(CloudSamplePiece.self) }
        #expect(pieces.map(\.index) == [0, 1, 2])
        #expect(pieces.allSatisfy { $0.count == 3 && $0.clearedAt == anchor && $0.provider == .claude })
        #expect(pieces.flatMap(\.samples) == input)
        #expect(records.allSatisfy { $0.payload.count <= CloudSyncPolicy.standard.maxRecordBytes })
    }

    @Test func piecesAreHalvedUntilEachFitsTheRecordLimit() throws {
        var rng = SystemRandomNumberGenerator()
        let input = (0..<600).map { Sample(provider: .codex, window: "w", at: anchor.addingTimeInterval(Double($0)), value: Double.random(in: 0...1_000_000, using: &rng)) }
        var policy = CloudSyncPolicy.standard
        policy.samplesPerRecord = 600
        policy.maxRecordBytes = 3_000
        let records = try CloudSamples.records(provider: .codex, samples: input, clearedAt: nil, hubName: "mini", now: anchor, policy: policy)
        #expect(records.count > 1)
        #expect(records.allSatisfy { $0.payload.count <= 3_000 })
        let pieces = try records.map { try $0.decode(CloudSamplePiece.self) }
        #expect(pieces.allSatisfy { $0.count == records.count })
        #expect(pieces.flatMap(\.samples) == input)
    }

    @Test func anEmptySetWritesNothingUnlessItCarriesACutOff() throws {
        #expect(try CloudSamples.records(provider: .claude, samples: [], clearedAt: nil, hubName: "mini", now: anchor, policy: .standard).isEmpty)
        let cut = try CloudSamples.records(provider: .claude, samples: [], clearedAt: anchor, hubName: "mini", now: anchor, policy: .standard)
        #expect(cut.map(\.name) == ["samples.claude.0"])
        #expect(try cut[0].decode(CloudSamplePiece.self).clearedAt == anchor)
    }

    @Test func aSampleLargerThanTheRecordLimitIsAnErrorNotAnOversizedRecord() {
        var policy = CloudSyncPolicy.standard
        policy.maxRecordBytes = 10
        #expect(throws: CloudError.self) {
            _ = try CloudSamples.records(provider: .claude, samples: points(1), clearedAt: nil, hubName: "mini", now: anchor, policy: policy)
        }
    }

    @Test func readingPutsEveryPieceBackTogether() async throws {
        let store = FakeCloudStore()
        let input = points(25_000)
        for r in try CloudSamples.records(provider: .claude, samples: input, clearedAt: nil, hubName: "mini", now: anchor, policy: .standard) { store.put(r) }
        let first = try await store.fetch(CloudSamples.firstPieceNames([.claude]))
        let read = try await CloudSamples.read([.claude], first: first, store: store)
        #expect(read[.claude]?.samples == input)
        #expect(read[.claude]?.clearedAt == nil)
    }

    /// A piece written by another pass (different stamp) must not be mixed into this one.
    @Test func aPieceFromAnotherWriteIsLeftOut() async throws {
        let store = FakeCloudStore()
        let records = try CloudSamples.records(provider: .claude, samples: points(25_000), clearedAt: nil, hubName: "mini", now: anchor, policy: .standard)
        for r in records { store.put(r) }
        var stray = records[1]
        stray.generatedAt = anchor.addingTimeInterval(60)
        store.put(stray)
        let first = try await store.fetch(CloudSamples.firstPieceNames([.claude]))
        let read = try await CloudSamples.read([.claude], first: first, store: store)
        let kept = try records[0].decode(CloudSamplePiece.self).samples + records[2].decode(CloudSamplePiece.self).samples
        #expect(read[.claude]?.samples == kept)
    }

    @Test func anUnreadableFirstPieceMeansNothingForThatProvider() async throws {
        let store = FakeCloudStore()
        store.put(CloudRecord(name: CloudPayload.samplesRecord(.claude, 0), schema: CloudPayload.schema, generatedAt: anchor, hubName: "mini", payload: Data("junk".utf8)))
        let first = try await store.fetch(CloudSamples.firstPieceNames([.claude]))
        let read = try await CloudSamples.read([.claude], first: first, store: store)
        #expect(read[.claude] == nil)
    }

    @Test func aPointKeepsItsIdentityThroughICloudsWholeSeconds() throws {
        let fractional = Sample(provider: .codex, window: Sample.balanceWindowID, at: anchor.addingTimeInterval(0.7), value: 3)
        let back = try JSON.decoder.decode(Sample.self, from: JSON.encoder.encode(fractional))
        #expect(back.identity == fractional.identity)
        let deepseek = Sample(provider: .deepseek, window: Sample.balanceWindowID, at: fractional.at, value: 3)
        #expect(deepseek.identity != fractional.identity, "two providers can both have a balance at the same second")
    }

    @Test func absorbKeepsOwnPointsAddsNewOnesAndDropsWhatADeletionCutOff() async {
        let local = SampleStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("qp-absorb-\(UUID().uuidString).json"))
        await local.append([
            Sample(provider: .claude, window: "five_hour", at: anchor.addingTimeInterval(-600), value: 1),
            Sample(provider: .claude, window: "five_hour", at: anchor.addingTimeInterval(-300), value: 2),
        ], now: anchor)
        let incoming = [
            Sample(provider: .claude, window: "five_hour", at: anchor.addingTimeInterval(-299.6), value: 2), // same second as -300, with a fraction
            Sample(provider: .claude, window: "five_hour", at: anchor, value: 3),
            Sample(provider: .deepseek, window: Sample.balanceWindowID, at: anchor.addingTimeInterval(-900), value: 4),
        ]
        let added = await local.absorb(incoming, cutoffs: [.claude: anchor.addingTimeInterval(-400)], now: anchor)
        #expect(added == 2)
        let all = await local.all()
        #expect(all.map(\.at) == [anchor.addingTimeInterval(-900), anchor.addingTimeInterval(-300), anchor])
        #expect(all.filter { $0.provider == .claude }.count == 2)
    }

    @Test func aSecondMacSeesTheSameUnionAfterAPass() async throws {
        let cloud = FakeCloudStore()
        let (laptopLocal, laptop) = mac(cloud)
        let (miniLocal, mini) = mac(cloud)
        await laptopLocal.append(points(5), now: anchor)
        await miniLocal.append(Array(points(8).prefix(5)), now: anchor) // ages 7...3 of 8, so 3 and 4 overlap the laptop's

        await laptop.publish(claudeSnapshot(at: anchor), now: anchor)
        await mini.publish(claudeSnapshot(at: anchor.addingTimeInterval(60), util: 41), now: anchor.addingTimeInterval(60))
        #expect(await miniLocal.all().count == 8, "mini takes in the laptop's three points it lacked")

        await laptop.publish(claudeSnapshot(at: anchor.addingTimeInterval(120), util: 42), force: true, now: anchor.addingTimeInterval(120))
        #expect(await laptopLocal.all().count == 8, "laptop takes in mini's points")

        let first = try await cloud.fetch(CloudSamples.firstPieceNames([.claude]))
        let stored = try #require(try await CloudSamples.read([.claude], first: first, store: cloud)[.claude])
        #expect(stored.samples.count == 8)
        #expect(stored.clearedAt == nil)
    }

    /// Deleting history on one Mac must also empty the other Mac's copy, which still holds the points.
    @Test func aDeletedSamplePeriodDoesNotComeBackFromAnotherMac() async throws {
        let cloud = FakeCloudStore()
        let (laptopLocal, laptop) = mac(cloud)
        let (miniLocal, mini) = mac(cloud)
        let old = points(4)
        await laptopLocal.append(old, now: anchor)
        await miniLocal.append(old, now: anchor)
        await laptop.publish(claudeSnapshot(at: anchor), now: anchor)

        let cleared = anchor.addingTimeInterval(60)
        await miniLocal.clear()
        await mini.publish(claudeSnapshot(at: cleared, util: 41), clearHistory: true, now: cleared)

        let later = anchor.addingTimeInterval(120)
        await laptop.publish(claudeSnapshot(at: later, util: 42), force: true, now: later)
        #expect(await laptopLocal.all().isEmpty)
        let first = try await cloud.fetch(CloudSamples.firstPieceNames([.claude]))
        let stored = try #require(try await CloudSamples.read([.claude], first: first, store: cloud)[.claude])
        #expect(stored.samples.isEmpty)
        #expect(stored.clearedAt == cleared)
    }

    @Test func samplesOlderThanNinetyDaysStayOnTheMac() async throws {
        let cloud = FakeCloudStore()
        let both = [
            Sample(provider: .claude, window: "five_hour", at: anchor.addingTimeInterval(-91 * 86400), value: 1),
            Sample(provider: .claude, window: "five_hour", at: anchor.addingTimeInterval(-3600), value: 2),
        ]
        // The closure ignores `since` on purpose: the publisher must apply the horizon itself.
        let pub = CloudPublisher(store: cloud, history: { _, _ in both })
        await pub.publish(claudeSnapshot(at: anchor), now: anchor)
        let first = try await cloud.fetch(CloudSamples.firstPieceNames([.claude]))
        let stored = try #require(try await CloudSamples.read([.claude], first: first, store: cloud)[.claude])
        #expect(stored.samples.map(\.value) == [2])
    }

    @Test func aSaveGoesOutInBatchesWithinCountAndBytes() {
        let small = (0..<250).map { CloudRecord(name: "r\($0)", schema: CloudPayload.schema, generatedAt: anchor, hubName: "mini", payload: Data(count: 10)) }
        #expect(CloudRecord.batches(small).map(\.count) == [100, 100, 50])
        let big = (0..<4).map { CloudRecord(name: "b\($0)", schema: CloudPayload.schema, generatedAt: anchor, hubName: "mini", payload: Data(count: 400_000)) }
        #expect(CloudRecord.batches(big).map(\.count) == [2, 2])
    }
}
