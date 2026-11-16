import Foundation
import Testing
@testable import QuotaCore

/// The id as every build before dynamic providers declared it. Those builds are still installed on iPhones and Watches.
private enum LegacyProviderID: String, Codable, Hashable { case claude, codex, deepseek, opencode, zai }
/// Just enough of an old build's snapshot types to see whether it can decode what a new Mac sends.
private struct LegacyProviderSnapshot: Decodable { var id: LegacyProviderID; var fetchedAt: Date; var status: ProviderStatus; var windows: [UsageWindow] }
private struct LegacyQuotaSnapshot: Decodable { var version: Int; var generatedAt: Date; var hubName: String; var providers: [LegacyProviderSnapshot] }

private let now = Date(timeIntervalSince1970: 1_760_600_000)

private let acmeInfo = ProviderInfo(displayName: "Acme Agent", subtitle: "Desktop app", kind: .rateWindows, brandHex: 0x123456, symbol: "bolt",
                                    dashboardURL: URL(string: "https://acme.example/usage"))

private func reading(_ id: ProviderID, info: ProviderInfo? = nil, util: Double = 30, at date: Date = now) -> ProviderSnapshot {
    ProviderSnapshot(id: id, fetchedAt: date, account: AccountInfo(plan: "Pro"),
                     windows: [UsageWindow(id: "weekly", title: "Weekly", utilization: util, resetsAt: date.addingTimeInterval(86400), duration: 7 * 86400)],
                     info: info)
}

private struct NoGrokBot: GrokBotCredentialLoading {
    func load() async throws -> GrokBotCredentials { throw ProviderError.notConfigured("Grok Bot is not installed on this Mac.") }
}

@Suite struct ProviderIDCompatibilityTests {
    @Test func encodesExactlyLikeTheOldEnum() throws {
        #expect(try JSON.encoder.encode(ProviderID.claude) == JSON.encoder.encode(LegacyProviderID.claude))
        // One entry each, so key order can't differ: the dictionary keeps the array form old settings files use.
        let settings = ProviderSettings(enabled: true, options: ["region": "cn"])
        let new = try JSON.encoder.encode([ProviderID.zai: settings])
        let old = try JSON.encoder.encode([LegacyProviderID.zai: settings])
        #expect(new == old)
        #expect(try JSON.decoder.decode([ProviderID: ProviderSettings].self, from: old) == [.zai: settings])
        #expect(try JSON.decoder.decode([LegacyProviderID: ProviderSettings].self, from: new) == [.zai: settings])
    }

    @Test func settingsWithAProviderThisBuildDoesntKnowStillDecode() throws {
        var s = AppSettings()
        s.providers[.claude] = ProviderSettings(enabled: false)
        s.providers["acme"] = ProviderSettings(enabled: true, options: ["x": "y"])
        let back = try JSON.decoder.decode(AppSettings.self, from: JSON.encoder.encode(s))
        #expect(back.providers["acme"]?.options == ["x": "y"], "another Mac's provider is kept, not dropped")
        #expect(!back.isEnabled(ClaudeProvider().descriptor))
        #expect(back.enabledProviders(in: ProviderRegistry.all().map(\.descriptor)) == [.codex, .grokbot], "acme is not polled: this Mac can't read it")
    }

    @Test func freshSettingsFollowEachProvidersDefault() {
        let lineup = ProviderRegistry.all().map(\.descriptor)
        #expect(AppSettings().enabledProviders(in: lineup) == [.claude, .codex, .grokbot])
        #expect(lineup.map(\.id) == [.claude, .codex, .deepseek, .opencode, .zai, .grokbot])
        #expect(lineup.filter(\.usesAPIKey).map(\.id) == [.deepseek, .opencode, .zai])
    }

    @Test func untrustedIdsAreValidated() {
        #expect(ProviderID(validating: "grokbot") == .grokbot)
        #expect(ProviderID(validating: "new-agent_2") != nil)
        for bad in ["", "Claude", "a b", "../x", "provider.x", String(repeating: "a", count: 33)] { #expect(ProviderID(validating: bad) == nil, "\(bad)") }
    }

    @Test func displayOrderPutsTheOriginalFiveFirst() {
        let ids: [ProviderID] = ["zeta", .grokbot, .zai, "acme", .claude, .deepseek]
        #expect(ids.sorted(by: ProviderID.displayOrder) == [.claude, .deepseek, .zai, "acme", .grokbot, "zeta"])
    }
}

@Suite struct ProviderInfoTests {
    @Test func aSnapshotCarriesItsOwnDescription() throws {
        let back = try JSON.decoder.decode(ProviderSnapshot.self, from: JSON.encoder.encode(reading("acme", info: acmeInfo)))
        #expect(back.id == "acme")
        #expect(back.display == acmeInfo)
    }

    @Test func withoutADescriptionTheBuiltInsKeepTheirLookAndOthersGetANeutralOne() {
        #expect(reading(.codex).display.displayName == "Codex")
        #expect(reading(.codex).display.brandHex == 0x10A37F)
        let unknown = reading("new_agent").display
        #expect(unknown.displayName == "New Agent")
        #expect(unknown.brandHex == ProviderInfo.neutralHex)
        #expect(unknown.symbol == ProviderInfo.neutralSymbol)
        #expect(unknown.dashboardURL == nil)
    }

    @Test func grokBotIsDescribedOnlyByItsReader() {
        // The display side has no entry for it: whatever draws Grok Bot drew it from the snapshot.
        #expect(ProviderInfo.builtIn[.grokbot] == nil)
        #expect(GrokBotProvider().descriptor.info.displayName == "Grok Bot")
        #expect(ProviderInfo.builtIn.keys.sorted() == ProviderID.legacy.sorted())
    }

    @Test func aNewerMacsFieldsAndValuesDoNotBreakDecoding() throws {
        let json = #"{"displayName":"Acme","kind":"credits","brandHex":4660,"symbol":"","futureField":{"a":1}}"#
        let info = try JSON.decoder.decode(ProviderInfo.self, from: Data(json.utf8))
        #expect(info.displayName == "Acme")
        #expect(info.kind == .rateWindows, "an unknown kind falls back")
        #expect(info.brandHex == 4660)
        #expect(info.symbol == ProviderInfo.neutralSymbol, "an empty symbol falls back")
    }

    @Test func oldBuildsIgnoreTheNewField() throws {
        let data = try JSON.encoder.encode(QuotaSnapshot(generatedAt: now, hubName: "mini", providers: [reading(.claude, info: ProviderInfo.builtIn[.claude])]))
        let old = try JSON.decoder.decode(LegacyQuotaSnapshot.self, from: data)
        #expect(old.providers.map(\.id) == [.claude])
    }

    @Test func theEngineStampsEveryReadingWithItsProvidersDescription() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qp-dyn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let engine = QuotaEngine(location: DataLocation(root: dir), providers: [GrokBotProvider(credentials: NoGrokBot())],
                                 secrets: InMemorySecretStore(), transport: StubTransport(status: 500, json: ""), hubName: "test")
        let snap = await engine.refresh(reason: "t", now: now)
        let p = try #require(snap.provider(.grokbot))
        #expect(p.info?.displayName == "Grok Bot")
        #expect(p.info?.symbol == "scope")
        // The gateway report never sees the description: it stays the shape the gateway always got.
        var claude = reading(.claude, info: ProviderInfo.builtIn[.claude])
        claude.account = AccountInfo(plan: "Max", label: "me@example.com")
        #expect(GatewayReport.providers(from: [claude]).first?.info == nil)
    }
}

@Suite struct DynamicCloudReadingTests {
    private func record(_ p: ProviderSnapshot, hub: String = "macm4") throws -> CloudRecord {
        try CloudRecord(name: CloudPayload.providerRecord(p.id), generatedAt: p.fetchedAt, hubName: hub, encoding: p)
    }

    @Test func aReaderShowsProvidersItHasNeverHeardOf() async throws {
        let store = FakeCloudStore()
        store.put(try record(reading(.claude, info: ProviderInfo.builtIn[.claude])))
        store.put(try record(reading("acme", info: acmeInfo, at: now.addingTimeInterval(60))))
        store.put(try CloudRecord(name: CloudPayload.historyRecord("acme"), generatedAt: now, hubName: "macm4", encoding: [String]()))
        let snap = try #require(try await CloudReader(store: store).snapshot())
        #expect(snap.providers.map(\.id) == [.claude, "acme"])
        #expect(snap.provider("acme")?.display == acmeInfo)
        #expect(snap.generatedAt == now.addingTimeInterval(60))
    }

    @Test func publishedGrokBotReachesAReaderThatHasNoCodeForIt() async throws {
        let store = FakeCloudStore()
        let publisher = CloudPublisher(store: store, history: { _, _ in [] })
        let info = GrokBotProvider().descriptor.info
        await publisher.publish(QuotaSnapshot(generatedAt: now, hubName: "macm4", providers: [reading(.claude, info: ProviderInfo.builtIn[.claude]), reading(.grokbot, info: info)]), now: now)
        #expect(store.records["provider.grokbot"] != nil)
        let snap = try #require(try await CloudReader(store: store).snapshot())
        #expect(snap.providers.map(\.id) == [.claude, .grokbot])
        #expect(snap.provider(.grokbot)?.display == info)
    }

    @Test func oneUnreadableRecordDoesNotHideTheOthers() async throws {
        let store = FakeCloudStore()
        store.put(try record(reading(.codex)))
        store.put(CloudRecord(name: "provider.acme", schema: CloudPayload.schema, generatedAt: now, hubName: "m", payload: Data("junk".utf8)))
        store.put(CloudRecord(name: "provider.Bad Name", schema: CloudPayload.schema, generatedAt: now, hubName: "m", payload: Data()))
        let snap = try #require(try await CloudReader(store: store).snapshot())
        #expect(snap.providers.map(\.id) == [.codex])
    }

    @Test func nothingReadableStillSaysWhy() async throws {
        let store = FakeCloudStore()
        var newer = try record(reading("acme", info: acmeInfo))
        newer.schema = CloudPayload.schema + 1
        store.put(newer)
        await #expect(throws: CloudError.incompatible(schema: CloudPayload.schema + 1)) { try await CloudReader(store: store).snapshot() }
    }

    @Test func recordNamesMapBackToProviders() {
        #expect(CloudPayload.provider(fromRecord: "provider.grokbot") == .grokbot)
        #expect(CloudPayload.provider(fromRecord: "history.grokbot") == nil)
        #expect(CloudPayload.provider(fromRecord: "provider.") == nil)
    }
}

@Suite struct HubLegacyClientTests {
    private func router(_ snap: QuotaSnapshot) -> HubRouter {
        HubRouter(token: "secret", hubName: "mini", snapshot: { snap }, history: { p, _ in [Sample(provider: p, window: "weekly", at: now, value: 1)] })
    }
    private let snap = QuotaSnapshot(generatedAt: now, hubName: "mini", providers: [reading(.claude), reading(.grokbot, info: GrokBotProvider().descriptor.info)])

    @Test func anOldClientGetsOnlyWhatItCanDecode() async throws {
        let r = await router(snap).handle(.init(method: "GET", path: "/v1/snapshot", query: [:], headers: ["Authorization": "Bearer secret"]))
        #expect(r.status == 200)
        let old = try JSON.decoder.decode(LegacyQuotaSnapshot.self, from: r.body)
        #expect(old.providers.map(\.id) == [.claude])
    }

    @Test func aNewClientAsksForEverything() async throws {
        let r = await router(snap).handle(.init(method: "GET", path: "/v1/snapshot", query: ["providers": "all"], headers: ["Authorization": "Bearer secret"]))
        let all = try JSON.decoder.decode(QuotaSnapshot.self, from: r.body)
        #expect(all.providers.map(\.id) == [.claude, .grokbot])
        #expect(all.provider(.grokbot)?.display.displayName == "Grok Bot")
        // What an old build would do with the full answer: exactly the failure the filter prevents.
        #expect(throws: DecodingError.self) { try JSON.decoder.decode(LegacyQuotaSnapshot.self, from: r.body) }
    }

    @Test func historyTakesAnyValidId() async throws {
        let ok = await router(snap).handle(.init(method: "GET", path: "/v1/history", query: ["provider": "grokbot"], headers: ["Authorization": "Bearer secret"]))
        #expect(ok.status == 200)
        #expect(try JSON.decoder.decode(HubProtocol.History.self, from: ok.body).provider == .grokbot)
        let bad = await router(snap).handle(.init(method: "GET", path: "/v1/history", query: ["provider": "../etc"], headers: ["Authorization": "Bearer secret"]))
        #expect(bad.status == 400)
    }
}
