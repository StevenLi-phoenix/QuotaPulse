import Foundation
import Testing
@testable import QuotaCore

@Suite struct StoreTests {
    let now = Date(timeIntervalSince1970: 1_760_600_000)

    func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("qp-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func sampleStoreRoundTripAndPrune() async throws {
        let url = tempDir().appendingPathComponent("samples.json")
        let store = SampleStore(url: url, retentionDays: 1)
        await store.append([
            Sample(provider: .claude, window: "a", at: now.addingTimeInterval(-2 * 86400), value: 1),
            Sample(provider: .claude, window: "a", at: now, value: 2),
        ], now: now)
        try await store.flush()
        let reloaded = SampleStore(url: url)
        let all = await reloaded.all()
        #expect(all.count == 1)
        #expect(all.first?.value == 2)
    }

    @Test func settingsDefaultsAndPersistence() {
        let url = tempDir().appendingPathComponent("settings.json")
        let store = SettingsStore(url: url)
        var s = store.load()
        #expect(s.isEnabled(.claude))
        #expect(!s.isEnabled(.deepseek))
        #expect(s.pollInterval == 300)
        s.providers[.deepseek] = ProviderSettings(enabled: true, options: ["x": "y"])
        store.save(s)
        #expect(store.load() == s)
    }

    @Test func backoffGate() {
        var g = BackoffGate(base: 300, cap: 1800)
        #expect(!g.isBlocked(.claude, now: now))
        g.recordRateLimit(.claude, retryAfter: nil, now: now)
        #expect(g.isBlocked(.claude, now: now.addingTimeInterval(299)))
        #expect(!g.isBlocked(.claude, now: now.addingTimeInterval(301)))
        g.recordRateLimit(.claude, retryAfter: nil, now: now)
        #expect(g.blockedUntil[.claude] == now.addingTimeInterval(600))
        for _ in 0..<10 { g.recordRateLimit(.claude, retryAfter: nil, now: now) }
        #expect(g.blockedUntil[.claude] == now.addingTimeInterval(1800))
        g.recordRateLimit(.codex, retryAfter: now.addingTimeInterval(5000), now: now)
        #expect(g.blockedUntil[.codex] == now.addingTimeInterval(5000))
        g.recordSuccess(.claude)
        #expect(!g.isBlocked(.claude, now: now))
    }

    @Test func engineRefreshRecordsSamplesAndForecasts() async throws {
        struct StaticProvider: UsageProvider {
            let id: ProviderID
            let util: Double
            func fetch(_ context: FetchContext) async throws -> ProviderSnapshot {
                ProviderSnapshot(id: id, fetchedAt: context.now, windows: [UsageWindow(id: "w", title: "W", utilization: util, resetsAt: context.now.addingTimeInterval(3600), duration: 5 * 3600)])
            }
        }
        struct Failing: UsageProvider {
            let id: ProviderID = .codex
            func fetch(_ context: FetchContext) async throws -> ProviderSnapshot { throw ProviderError.rateLimited(retryAfter: nil) }
        }
        let loc = DataLocation(root: tempDir())
        let engine = QuotaEngine(location: loc, providers: [StaticProvider(id: .claude, util: 10), Failing()], secrets: InMemorySecretStore(), transport: StubTransport(status: 500, json: ""), hubName: "test")
        let s1 = await engine.refresh(reason: "t1", now: now)
        #expect(s1.provider(.claude)?.status == .ok)
        #expect(s1.provider(.codex)?.status == .rateLimited(retryAfter: nil))
        #expect(s1.provider(.claude)?.forecasts["w"]?.confidence == .insufficient)
        // second refresh 20 minutes later: codex still blocked (kept previous), claude gets a forecast
        let s2 = await engine.refresh(reason: "t2", now: now.addingTimeInterval(20 * 60))
        #expect(s2.provider(.codex)?.status == .rateLimited(retryAfter: nil))
        #expect(s2.provider(.claude)?.forecasts["w"]?.confidence != .insufficient)
        #expect(await engine.sampleCount() == 2)
        // persisted snapshot readable by a fresh store (what the widget does)
        let onDisk = SnapshotStore(url: loc.snapshotURL).load()
        #expect(onDisk?.provider(.claude)?.windows.first?.utilization == 10)
        let hist = await engine.history(provider: .claude, hours: 24, now: now.addingTimeInterval(20 * 60))
        #expect(hist.count == 2)
    }
}

@Suite struct HubTests {
    let now = Date(timeIntervalSince1970: 1_760_600_000)

    func router(token: String = "secret") -> HubRouter {
        let snap = QuotaSnapshot(generatedAt: now, hubName: "mini", providers: [ProviderSnapshot(id: .claude, fetchedAt: now, windows: [UsageWindow(id: "w", title: "W", utilization: 33, resetsAt: nil, duration: nil)])])
        return HubRouter(token: token, hubName: "mini", snapshot: { snap }, history: { p, h in
            [Sample(provider: p, window: "w", at: self.now, value: h)]
        })
    }

    @Test func authAndRoutes() async throws {
        let r = router()
        let noAuth = await r.handle(.init(method: "GET", path: "/v1/snapshot", query: [:], headers: [:]))
        #expect(noAuth.status == 401)
        let wrong = await r.handle(.init(method: "GET", path: "/v1/snapshot", query: [:], headers: ["Authorization": "Bearer nope"]))
        #expect(wrong.status == 401)
        let ok = await r.handle(.init(method: "GET", path: "/v1/snapshot", query: [:], headers: ["authorization": "Bearer secret"]))
        #expect(ok.status == 200)
        let snap = try JSON.decoder.decode(QuotaSnapshot.self, from: ok.body)
        #expect(snap.provider(.claude)?.windows.first?.utilization == 33)
        let health = await r.handle(.init(method: "GET", path: "/v1/health", query: ["token": "secret"], headers: [:]))
        #expect(health.status == 200)
        #expect(try JSON.decoder.decode(HubProtocol.Health.self, from: health.body).hubName == "mini")
        let hist = await r.handle(.init(method: "GET", path: "/v1/history", query: ["provider": "claude", "hours": "6"], headers: ["Authorization": "Bearer secret"]))
        #expect(try JSON.decoder.decode(HubProtocol.History.self, from: hist.body).samples.first?.value == 6)
        let bad = await r.handle(.init(method: "GET", path: "/v1/history", query: [:], headers: ["Authorization": "Bearer secret"]))
        #expect(bad.status == 400)
        #expect((await r.handle(.init(method: "POST", path: "/v1/snapshot", query: [:], headers: [:]))).status == 405)
        #expect((await r.handle(.init(method: "GET", path: "/nope", query: [:], headers: ["Authorization": "Bearer secret"]))).status == 404)
    }

    @Test func httpParserAndSerializer() {
        let raw = Data("GET /v1/history?provider=codex&hours=12 HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer abc\r\n\r\n".utf8)
        let req = HTTPParser.parse(raw)
        #expect(req?.method == "GET")
        #expect(req?.path == "/v1/history")
        #expect(req?.query["provider"] == "codex")
        #expect(req?.headers["Authorization"] == "Bearer abc")
        #expect(HTTPParser.parse(Data("GET / HTTP/1.1\r\nHost".utf8)) == nil)
        let out = String(decoding: HTTPParser.serialize(.init(status: 200, body: Data("{}".utf8))), as: UTF8.self)
        #expect(out.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(out.contains("Content-Length: 2\r\n"))
        #expect(out.hasSuffix("\r\n\r\n{}"))
    }

    @Test func pairingURLRoundTrip() {
        let p = HubPairing(baseURL: URL(string: "http://100.64.1.2:48422")!, token: "tok en", hubName: "Stevens-Mini")
        let back = HubPairing.parse(p.pairingURL)
        #expect(back == p)
        #expect(HubPairing.parse(URL(string: "https://example.com")!) == nil)
        #expect(HubPairing.randomToken().count == 32)
    }

    @Test func serverEndToEnd() async throws {
        let port = UInt16.random(in: 40000...60000)
        let server = HubServer(port: port, exposeOnNetwork: false, router: router())
        try server.start()
        try await Task.sleep(for: .milliseconds(300))
        let client = HubClient(pairing: HubPairing(baseURL: URL(string: "http://127.0.0.1:\(port)")!, token: "secret", hubName: "mini"))
        let h = try await client.health()
        #expect(h.ok && h.hubName == "mini")
        let s = try await client.snapshot()
        #expect(s.provider(.claude)?.windows.first?.utilization == 33)
        let bad = HubClient(pairing: HubPairing(baseURL: URL(string: "http://127.0.0.1:\(port)")!, token: "x", hubName: "mini"))
        await #expect(throws: HubClient.ClientError.self) { try await bad.snapshot() }
        server.stop()
    }
}
