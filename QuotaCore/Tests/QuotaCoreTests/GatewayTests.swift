import Foundation
import Testing
@testable import QuotaCore

// Gateway hub contract: https://llm.lishuyu.app/llm/hub (see docs/research.md "Gateway").

private let gatewayBase = URL(string: "https://llm.lishuyu.app/llm/hub")!

private func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("qp-gw-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

/// What the gateway sends: ISO dates without fractional seconds, Swift-synthesized enum coding.
private let gatewaySnapshotJSON = """
{"version":1,"generatedAt":"2026-11-06T20:33:35Z","hubName":"llmgateway","providers":[
 {"id":"opencode","fetchedAt":"2026-11-06T20:33:35Z","status":{"ok":{}},"forecasts":{},
  "lastSuccessAt":"2026-11-06T20:33:35Z",
  "windows":[{"id":"rolling","title":"5-hour","utilization":12.5,"resetsAt":"2026-11-06T23:00:00Z","duration":18000,
              "resetSemantics":"fixedCadence","availability":"reported"}]},
 {"id":"deepseek","fetchedAt":"2026-11-06T20:33:35Z","status":{"ok":{}},"forecasts":{},"windows":[],
  "balance":{"currency":"CNY","total":23.45,"granted":0,"toppedUp":23.45,"isAvailable":true}}
]}
"""

private func gatewayLink(_ transport: StubTransport) -> GatewayLink {
    GatewayLink(config: GatewayConfig(baseURL: gatewayBase, token: "test-token"), cache: GatewaySnapshotCache())
}

private func ctx(_ transport: StubTransport, link: GatewayLink? = nil, now: Date = Date(timeIntervalSince1970: 1_793_997_215),
                 env: [String: String] = [:]) -> FetchContext {
    var c = FetchContext(transport: transport, secrets: InMemorySecretStore(), environment: env, now: now)
    c.gateway = link
    return c
}

@Suite struct HubClientPathTests {
    @Test func endpointKeepsBasePath() {
        let q = [URLQueryItem(name: "provider", value: "claude"), URLQueryItem(name: "hours", value: "24")]
        #expect(HubClient.endpoint(base: gatewayBase, path: "/v1/health").absoluteString == "https://llm.lishuyu.app/llm/hub/v1/health")
        #expect(HubClient.endpoint(base: URL(string: "https://llm.lishuyu.app/llm/hub/")!, path: "/v1/health").absoluteString
                == "https://llm.lishuyu.app/llm/hub/v1/health")
        #expect(HubClient.endpoint(base: URL(string: "http://100.64.0.1:48422")!, path: "/v1/snapshot").absoluteString == "http://100.64.0.1:48422/v1/snapshot")
        #expect(HubClient.endpoint(base: URL(string: "http://100.64.0.1:48422/")!, path: "/v1/snapshot").absoluteString == "http://100.64.0.1:48422/v1/snapshot")
        #expect(HubClient.endpoint(base: gatewayBase, path: "/v1/history", query: q).absoluteString
                == "https://llm.lishuyu.app/llm/hub/v1/history?provider=claude&hours=24")
    }

    @Test func clientRequestsGoUnderTheBasePath() async throws {
        let transport = StubTransport { req in
            let body = req.url!.path.hasSuffix("/health") ? "{\"ok\":true,\"version\":1,\"hubName\":\"llmgateway\"}" : gatewaySnapshotJSON
            return HTTPResponse(statusCode: 200, data: Data(body.utf8))
        }
        let client = HubClient(pairing: HubPairing(baseURL: gatewayBase, token: "t", hubName: "llmgateway"), transport: transport)
        _ = try await client.health()
        _ = try await client.snapshot()
        #expect(transport.requests.map { $0.url!.absoluteString } == ["https://llm.lishuyu.app/llm/hub/v1/health", "https://llm.lishuyu.app/llm/hub/v1/snapshot"])
    }

    @Test func telemetryUploadSkippedForGateway() async {
        let logger = FileLogger(directory: tempDir(), identity: DeviceIdentity(name: "iPhone-TEST", appVersion: "1", platform: "iOS"))
        logger.log("info", "pairing", "paired", at: Date())
        logger.flush()
        let transport = StubTransport(status: 404, json: "{}")
        let client = HubClient(pairing: HubPairing(baseURL: gatewayBase, token: "t", hubName: "llmgateway"), transport: transport)
        let r = await client.syncTelemetry(from: logger)
        #expect(transport.requests.isEmpty)
        #expect(r.uploaded == 0 && r.error == nil)
        #expect(!HubPairing(baseURL: gatewayBase, token: "t", hubName: "x").supportsTelemetry)
        #expect(HubPairing(baseURL: URL(string: "http://100.64.0.1:48422")!, token: "t", hubName: "x").supportsTelemetry)
    }
}

@Suite struct GatewayWireTests {
    @Test func decodesDateWithoutFractionalSeconds() throws {
        let d = try JSON.decoder.decode(Date.self, from: Data("\"2026-11-06T20:33:35Z\"".utf8))
        #expect(d.timeIntervalSince1970 == 1_793_997_215)
    }

    @Test func decodesContractStatusSamples() throws {
        func status(_ json: String) throws -> ProviderStatus { try JSON.decoder.decode(ProviderStatus.self, from: Data(json.utf8)) }
        #expect(try status("{\"ok\":{}}") == .ok)
        #expect(try status("{\"network\":{\"_0\":\"msg\"}}") == .network("msg"))
        #expect(try status("{\"server\":{\"code\":500,\"_1\":\"msg\"}}") == .server(code: 500, "msg"))
        let r = try status("{\"rateLimited\":{\"retryAfter\":\"2026-11-06T20:33:35Z\"}}")
        #expect(r == .rateLimited(retryAfter: Date(timeIntervalSince1970: 1_793_997_215)))
    }

    @Test func decodesGatewaySnapshot() throws {
        let s = try JSON.decoder.decode(QuotaSnapshot.self, from: Data(gatewaySnapshotJSON.utf8))
        #expect(s.provider(.opencode)?.windows.first?.id == "rolling")
        #expect(s.provider(.deepseek)?.balance?.currency == "CNY")
    }

    @Test func configFile() throws {
        let url = tempDir().appendingPathComponent("gateway.json")
        #expect(GatewayConfig.load(from: url) == nil)
        try Data("{\"token\":\"abc\"}".utf8).write(to: url)
        #expect(GatewayConfig.load(from: url) == GatewayConfig(baseURL: gatewayBase, token: "abc"))
        try Data("{\"baseURL\":\"https://api.lishuyu.app/llm/hub\",\"token\":\" abc \\n\"}".utf8).write(to: url)
        #expect(GatewayConfig.load(from: url) == GatewayConfig(baseURL: URL(string: "https://api.lishuyu.app/llm/hub")!, token: "abc"))
        try Data("{\"token\":\"\"}".utf8).write(to: url)
        #expect(GatewayConfig.load(from: url) == nil)
        try Data("not json".utf8).write(to: url)
        #expect(GatewayConfig.load(from: url) == nil)
    }
}

@Suite struct GatewayProviderTests {
    @Test func oneSnapshotRequestServesBothProviders() async throws {
        let transport = StubTransport(status: 200, json: gatewaySnapshotJSON)
        let c = ctx(transport, link: gatewayLink(transport))
        async let oc = OpenCodeProvider().fetch(c)
        async let ds = DeepSeekProvider().fetch(c)
        let (o, d) = try await (oc, ds)
        #expect(o.id == .opencode && o.windows.first?.utilization == 12.5)
        #expect(d.id == .deepseek && d.balance?.total == 23.45)
        #expect(transport.requests.count == 1)
        let r = transport.requests[0]
        #expect(r.url?.absoluteString == "https://llm.lishuyu.app/llm/hub/v1/snapshot")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    }

    @Test func nextRoundFetchesAgain() async throws {
        let transport = StubTransport(status: 200, json: gatewaySnapshotJSON)
        let link = gatewayLink(transport)
        let t0 = Date(timeIntervalSince1970: 1_793_997_215)
        _ = try await OpenCodeProvider().fetch(ctx(transport, link: link, now: t0))
        _ = try await DeepSeekProvider().fetch(ctx(transport, link: link, now: t0))
        _ = try await OpenCodeProvider().fetch(ctx(transport, link: link, now: t0.addingTimeInterval(300)))
        #expect(transport.requests.count == 2)
    }

    @Test func gatewayIgnoresLocalKeys() async throws {
        let transport = StubTransport(status: 200, json: gatewaySnapshotJSON)
        _ = try await OpenCodeProvider().fetch(ctx(transport, link: gatewayLink(transport), env: ["OPENCODE_API_KEY": "should-not-be-used"]))
        #expect(transport.requests.allSatisfy { $0.url?.host == "llm.lishuyu.app" })
        #expect(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" })
    }

    @Test func unauthorizedMapsFor401And403() async {
        for code in [401, 403] {
            let transport = StubTransport(status: code, json: "{}")
            do {
                _ = try await DeepSeekProvider().fetch(ctx(transport, link: gatewayLink(transport)))
                Issue.record("expected throw")
            } catch let e as ProviderError {
                guard case .unauthorized = e else { Issue.record("got \(e)"); continue }
            } catch { Issue.record("got \(error)") }
        }
    }

    @Test func networkErrorMapsToNetwork() async {
        let transport = StubTransport { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await OpenCodeProvider().fetch(ctx(transport, link: gatewayLink(transport)))
            Issue.record("expected throw")
        } catch let e as ProviderError {
            guard case .network = e else { Issue.record("got \(e)"); return }
        } catch { Issue.record("got \(error)") }
    }

    @Test func rateLimitedAndServerErrors() async {
        let now = Date(timeIntervalSince1970: 1_793_997_215)
        let limited = StubTransport(status: 429, json: "{}", headers: ["Retry-After": "120"])
        do { _ = try await OpenCodeProvider().fetch(ctx(limited, link: gatewayLink(limited), now: now)); Issue.record("expected throw") }
        catch let e as ProviderError { #expect(e == .rateLimited(retryAfter: now.addingTimeInterval(120))) }
        catch { Issue.record("got \(error)") }
        let broken = StubTransport(status: 502, json: "bad gateway")
        do { _ = try await OpenCodeProvider().fetch(ctx(broken, link: gatewayLink(broken), now: now)); Issue.record("expected throw") }
        catch let e as ProviderError { #expect(e == .server(502, "bad gateway")) }
        catch { Issue.record("got \(error)") }
        let garbage = StubTransport(status: 200, json: "{\"nope\":1}")
        do { _ = try await OpenCodeProvider().fetch(ctx(garbage, link: gatewayLink(garbage), now: now)); Issue.record("expected throw") }
        catch let e as ProviderError { guard case .decoding = e else { Issue.record("got \(e)"); return } }
        catch { Issue.record("got \(error)") }
    }

    @Test func missingProviderIsNotConfigured() async {
        let json = "{\"version\":1,\"generatedAt\":\"2026-11-06T20:33:35Z\",\"hubName\":\"g\",\"providers\":[]}"
        let transport = StubTransport(status: 200, json: json)
        do { _ = try await DeepSeekProvider().fetch(ctx(transport, link: gatewayLink(transport))); Issue.record("expected throw") }
        catch let e as ProviderError { guard case .notConfigured = e else { Issue.record("got \(e)"); return } }
        catch { Issue.record("got \(error)") }
    }

    @Test func errorStatusComesBackAsIs() async throws {
        let json = """
        {"version":1,"generatedAt":"2026-11-06T20:33:35Z","hubName":"g","providers":[
         {"id":"deepseek","fetchedAt":"2026-11-06T20:33:35Z","status":{"server":{"code":500,"_1":"upstream down"}},"windows":[],"forecasts":{}}]}
        """
        let transport = StubTransport(status: 200, json: json)
        let snap = try await DeepSeekProvider().fetch(ctx(transport, link: gatewayLink(transport)))
        #expect(snap.status == .server(code: 500, "upstream down"))
    }

    @Test func withoutGatewayTheUpstreamURLsAreUsed() async throws {
        let ds = StubTransport(status: 200, json: String(decoding: try Data(contentsOf: Bundle.module.url(forResource: "deepseek_balance", withExtension: "json", subdirectory: "Fixtures")!), as: UTF8.self))
        _ = try await DeepSeekProvider().fetch(ctx(ds, env: ["DEEPSEEK_API_KEY": "k"]))
        #expect(ds.requests.map { $0.url } == [DeepSeekProvider.balanceURL])
        #expect(ds.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer k")

        let oc = StubTransport(status: 200, json: String(decoding: try Data(contentsOf: Bundle.module.url(forResource: "opencode_usage", withExtension: "json", subdirectory: "Fixtures")!), as: UTF8.self))
        _ = try await OpenCodeProvider().fetch(ctx(oc, env: ["OPENCODE_API_KEY": "k"]))
        #expect(oc.requests.map { $0.url } == [OpenCodeProvider.usageURL])
    }
}

@Suite struct GatewayReportTests {
    let now = Date(timeIntervalSince1970: 1_793_997_215)

    @Test func reportSelection() {
        let fc = Forecast(confidence: .low, rate: 2)
        let merged = [
            ProviderSnapshot(id: .claude, fetchedAt: now, account: AccountInfo(plan: "Max", label: "me@example.com"),
                             windows: [UsageWindow(id: "five_hour", title: "5h", utilization: 10, resetsAt: nil, duration: 18000)]),
            ProviderSnapshot(id: .codex, fetchedAt: now, status: .notConfigured("Waiting for first fetch…")),
            ProviderSnapshot(id: .zai, fetchedAt: now, windows: [UsageWindow(id: "w", title: "W", utilization: 5, resetsAt: nil, duration: nil)]),
            ProviderSnapshot(id: .opencode, fetchedAt: now,
                             windows: [UsageWindow(id: "rolling", title: "5-hour", utilization: 50, resetsAt: nil, duration: 18000)],
                             forecasts: ["rolling": fc]),
            ProviderSnapshot(id: .deepseek, fetchedAt: now, balance: Balance(currency: "CNY", total: 9), forecasts: [:]),
        ]
        let out = GatewayReport.providers(from: merged)
        #expect(out.map(\.id) == [.claude, .zai, .opencode])
        #expect(out[0].account?.label == nil && out[0].account?.plan == "Max")
        #expect(out[0].windows.count == 1)
        #expect(out[2].forecasts == ["rolling": fc] && out[2].windows.isEmpty && out[2].balance == nil)
        let body = String(decoding: GatewayReport.body(out), as: UTF8.self)
        #expect(!body.contains("me@example.com"))
        #expect(body.hasPrefix("{\"providers\":["))
    }

    private struct Static: UsageProvider {
        let id: ProviderID
        func fetch(_ context: FetchContext) async throws -> ProviderSnapshot {
            ProviderSnapshot(id: id, fetchedAt: context.now, account: AccountInfo(plan: "P", label: "me@example.com"),
                             windows: [UsageWindow(id: "w", title: "W", utilization: 10, resetsAt: context.now.addingTimeInterval(3600), duration: 18000)])
        }
    }

    private func engine(_ dir: URL, transport: StubTransport) -> QuotaEngine {
        QuotaEngine(location: DataLocation(root: dir),
                    providers: [Static(id: .claude), Static(id: .zai), Static(id: .opencode), Static(id: .deepseek)],
                    secrets: InMemorySecretStore(), transport: transport, hubName: "t")
    }

    @Test func engineReportsAfterRefresh() async throws {
        let dir = tempDir()
        try Data("{\"token\":\"test-token\"}".utf8).write(to: DataLocation(root: dir).gatewayURL)
        let transport = StubTransport(status: 200, json: "{\"accepted\":3}")
        let e = engine(dir, transport: transport)
        await e.update { $0.providers[.zai] = ProviderSettings(enabled: true) }
        _ = await e.refresh(reason: "t", now: now)
        // gateway file present: deepseek and opencode are enabled by default
        let enabled = await e.settings.enabledProviders
        #expect(Set(enabled) == [.claude, .codex, .zai, .opencode, .deepseek])
        let posts = transport.requests.filter { $0.httpMethod == "POST" }
        #expect(posts.count == 1)
        let req = try #require(posts.first)
        #expect(req.url?.absoluteString == "https://llm.lishuyu.app/llm/hub/v1/report")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        let sent = try JSON.decoder.decode(ReportBody.self, from: try #require(req.httpBody))
        #expect(sent.providers.map(\.id) == [.claude, .deepseek, .opencode, .zai])
        #expect(sent.providers.allSatisfy { $0.account?.label == nil })
        #expect(sent.providers[1].windows.isEmpty && sent.providers[1].forecasts["w"] != nil)
        #expect(sent.providers[2].windows.isEmpty && sent.providers[2].forecasts["w"] != nil)
        #expect(!String(decoding: req.httpBody!, as: UTF8.self).contains("test-token"))
    }

    private struct ReportBody: Decodable { var providers: [ProviderSnapshot] }

    @Test func reportFailureDoesNotBreakRefreshOrStorm() async throws {
        let dir = tempDir()
        try Data("{\"token\":\"test-token\"}".utf8).write(to: DataLocation(root: dir).gatewayURL)
        let transport = StubTransport(status: 500, json: "boom")
        let e = engine(dir, transport: transport)
        let s1 = await e.refresh(reason: "t1", now: now)
        #expect(s1.provider(.claude)?.status == .ok)
        _ = await e.refresh(reason: "t2", force: true, now: now.addingTimeInterval(30))
        #expect(transport.requests.count == 1, "no retry within the cool-down")
        _ = await e.refresh(reason: "t3", force: true, now: now.addingTimeInterval(400))
        #expect(transport.requests.count == 2)
    }

    @Test func noGatewayFileMeansNoReportAndNoSeeding() async throws {
        let transport = StubTransport(status: 200, json: "{}")
        let e = engine(tempDir(), transport: transport)
        _ = await e.refresh(reason: "t", now: now)
        #expect(transport.requests.isEmpty)
        #expect(await e.settings.isEnabled(.opencode) == false)
    }

    @Test func userChoiceSurvivesSeeding() async throws {
        let dir = tempDir()
        try Data("{\"token\":\"test-token\"}".utf8).write(to: DataLocation(root: dir).gatewayURL)
        let e = engine(dir, transport: StubTransport(status: 200, json: "{}"))
        _ = await e.refresh(reason: "t1", now: now)
        await e.update { $0.providers[.deepseek] = ProviderSettings(enabled: false) }
        _ = await e.refresh(reason: "t2", force: true, now: now.addingTimeInterval(400))
        #expect(await e.settings.isEnabled(.deepseek) == false)
        // a settings file written before gatewaySeeded existed still decodes
        let legacy = try JSON.decoder.decode(AppSettings.self, from: JSON.encoder.encode(AppSettings()).replacingKey("gatewaySeeded"))
        #expect(legacy.gatewaySeeded == false)
    }
}

private extension Data {
    func replacingKey(_ key: String) -> Data {
        var obj = (try? JSONSerialization.jsonObject(with: self) as? [String: Any]) ?? [:]
        obj[key] = nil
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? self
    }
}
