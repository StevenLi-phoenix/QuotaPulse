import Foundation
import Testing
@testable import QuotaCore

// A gateway reading that someone else took (phm's quota-reader, or the Worker) replaces the local read while it is good and fresh.

private let now = Date(timeIntervalSince1970: 1_793_997_215)
private let gatewayHost = "llm.lishuyu.app"

private func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

private func entry(_ id: ProviderID, source: String?, age: TimeInterval = 300, status: String = "{\"ok\":{}}", util: Double = 77) -> String {
    let src = source.map { ",\"source\":\"\($0)\"" } ?? ""
    return """
    {"id":"\(id.rawValue)","fetchedAt":"\(iso(now.addingTimeInterval(-age)))","status":\(status),"forecasts":{},"account":{"plan":"Reader"}\(src),
     "windows":[{"id":"w","title":"W","utilization":\(util),"duration":18000,"resetSemantics":"fixedCadence","availability":"reported"}]}
    """
}
private func snapshot(_ entries: String...) -> String {
    "{\"version\":1,\"generatedAt\":\"\(iso(now))\",\"hubName\":\"llmgateway\",\"providers\":[\(entries.joined(separator: ","))]}"
}

private struct ClaudeCreds: ClaudeCredentialLoading {
    func load() async throws -> ClaudeCredentialRecord {
        .init(credentials: ClaudeCredentials(accessToken: "local", refreshToken: nil, expiresAt: nil, scopes: [], rateLimitTier: nil, subscriptionType: nil), source: .file)
    }
}
private struct NoClaudeCreds: ClaudeCredentialLoading {
    func load() async throws -> ClaudeCredentialRecord { throw ProviderError.notConfigured("no creds") }
}
private final class CodexCreds: CodexCredentialLoading, @unchecked Sendable {
    func load() async throws -> CodexCredentials { try CodexCredentials.parse(try fixture("codex_auth")) }
    func store(_ refreshed: CodexCredentials) async throws {}
}

/// The gateway answers `gateway` (or fails); every upstream answers its usage fixture and is recorded.
private func transport(_ gateway: String?, status: Int = 200) -> StubTransport {
    StubTransport { req in
        switch req.url?.host {
        case gatewayHost:
            guard let gateway else { throw URLError(.notConnectedToInternet) }
            return HTTPResponse(statusCode: status, data: Data(gateway.utf8))
        case "api.anthropic.com": return HTTPResponse(statusCode: 200, data: try fixture("claude_usage"))
        case "chatgpt.com": return HTTPResponse(statusCode: 200, data: try fixture("codex_usage"))
        case "auth.openai.com": return HTTPResponse(statusCode: 200, data: Data("{\"access_token\":\"eyJhbGciOiJSUzI1NiJ9.eyJleHAiOjk5OTk5OTk5OTl9.x\",\"refresh_token\":\"rt2\"}".utf8))
        case "open.bigmodel.cn": return HTTPResponse(statusCode: 200, data: try fixture("zai_quota"))
        default: throw URLError(.badURL)
        }
    }
}
private func context(_ t: StubTransport, env: [String: String] = [:]) -> FetchContext {
    var c = FetchContext(transport: t, secrets: InMemorySecretStore(), environment: env, now: now)
    c.gateway = GatewayLink(config: GatewayConfig(token: "test-token"), cache: GatewaySnapshotCache())
    return c
}
private func hosts(_ t: StubTransport) -> [String] { t.requests.compactMap { $0.url?.host } }

@Suite struct GatewayReadingTests {
    @Test func freshReaderReadingReplacesTheLocalRead() async throws {
        let t = transport(snapshot(entry(.claude, source: "reader"), entry(.codex, source: "reader"), entry(.zai, source: "gateway")))
        let c = context(t)
        async let claude = ClaudeProvider(credentials: NoClaudeCreds()).fetch(c)
        async let codex = CodexProvider(credentials: CodexCreds()).fetch(c)
        async let zai = ZaiProvider().fetch(c)
        let (a, b, d) = try await (claude, codex, zai)
        #expect(a.id == .claude && a.windows.first?.utilization == 77 && a.source == "reader" && a.account?.plan == "Reader")
        #expect(b.id == .codex && b.windows.first?.utilization == 77)
        #expect(d.id == .zai && d.source == "gateway")
        #expect(hosts(t) == [gatewayHost], "one snapshot, no upstream")
    }

    @Test func thirtyMinutesIsStillFreshAndAMomentMoreIsNot() async throws {
        let edge = transport(snapshot(entry(.claude, source: "reader", age: 1800)))
        #expect(try await ClaudeProvider(credentials: ClaudeCreds()).fetch(context(edge)).source == "reader")
        let stale = transport(snapshot(entry(.claude, source: "reader", age: 1801)))
        let local = try await ClaudeProvider(credentials: ClaudeCreds()).fetch(context(stale))
        #expect(local.source == nil && local.windows.first?.id == "five_hour")
        #expect(hosts(stale) == [gatewayHost, "api.anthropic.com"])
    }

    @Test func aFailedReadingFallsBackToTheLocalRead() async throws {
        let t = transport(snapshot(entry(.codex, source: "reader", status: "{\"expired\":{\"_0\":\"log in\"}}")))
        let local = try await CodexProvider(credentials: CodexCreds()).fetch(context(t))
        #expect(local.source == nil && local.status == .ok)
        #expect(hosts(t).contains("chatgpt.com"))
    }

    @Test func itsOwnEchoAndAnOlderHubAreNotSomeoneElsesReading() async throws {
        for source in ["mac", nil] as [String?] {
            let t = transport(snapshot(entry(.claude, source: source)))
            let local = try await ClaudeProvider(credentials: ClaudeCreds()).fetch(context(t))
            #expect(local.source == nil && hosts(t).contains("api.anthropic.com"))
        }
    }

    @Test func aGatewayThatIsDownOrRefusesOrLacksTheProviderFallsBack() async throws {
        for t in [transport(nil), transport("{}", status: 401), transport("bad", status: 502), transport("not json"), transport(snapshot())] {
            let local = try await ClaudeProvider(credentials: ClaudeCreds()).fetch(context(t))
            #expect(local.status == .ok && local.source == nil)
            #expect(hosts(t).contains("api.anthropic.com"))
        }
    }

    @Test func zaiFallsBackToItsLocalKey() async throws {
        let t = transport(snapshot())
        let local = try await ZaiProvider().fetch(context(t, env: ["ZAI_API_KEY": "k"]))
        #expect(local.windows.first?.id == "limit_0")
        #expect(hosts(t) == [gatewayHost, "open.bigmodel.cn"])
        do { _ = try await ZaiProvider().fetch(context(transport(snapshot()))); Issue.record("expected throw") }
        catch let e as ProviderError { guard case .notConfigured = e else { Issue.record("got \(e)"); return } }
    }

    @Test func withoutAGatewayNothingAsksIt() async throws {
        let t = transport(snapshot(entry(.claude, source: "reader")))
        let snap = try await ClaudeProvider(credentials: ClaudeCreds()).fetch(FetchContext(transport: t, secrets: InMemorySecretStore(), now: now))
        #expect(snap.source == nil && hosts(t) == ["api.anthropic.com"])
    }

    @Test func sourceSurvivesEncodingAndIsOptional() throws {
        let old = try JSON.decoder.decode(ProviderSnapshot.self, from: Data(entry(.claude, source: nil).utf8))
        #expect(old.source == nil)
        let tagged = try JSON.decoder.decode(ProviderSnapshot.self, from: Data(entry(.claude, source: "reader").utf8))
        #expect(try JSON.decoder.decode(ProviderSnapshot.self, from: JSON.encoder.encode(tagged)).source == "reader")
    }
}

@Suite struct GatewayEchoTests {
    private let fc = Forecast(confidence: .low, rate: 2)

    @Test func aReadingFromTheHubGoesBackAsForecastsOnly() {
        let w = UsageWindow(id: "w", title: "W", utilization: 10, resetsAt: nil, duration: nil)
        let merged = [
            ProviderSnapshot(id: .claude, fetchedAt: now, windows: [w], forecasts: ["w": fc], source: "reader"),
            ProviderSnapshot(id: .codex, fetchedAt: now, windows: [w], source: "reader"),
            ProviderSnapshot(id: .zai, fetchedAt: now, windows: [w], forecasts: ["w": fc], source: "gateway"),
        ]
        let out = GatewayReport.providers(from: merged)
        #expect(out.map(\.id) == [.claude, .zai], "no forecasts, nothing to say")
        #expect(out.allSatisfy { $0.windows.isEmpty && $0.source != nil && $0.forecasts == ["w": fc] })
    }

    @Test func aLocalReadingStillGoesWhole() {
        let w = UsageWindow(id: "w", title: "W", utilization: 10, resetsAt: nil, duration: nil)
        let out = GatewayReport.providers(from: [ProviderSnapshot(id: .claude, fetchedAt: now, windows: [w])])
        #expect(out.first?.windows.count == 1 && out.first?.source == nil)
    }

    @Test func theBodySaysItIsTheMac() throws {
        let body = GatewayReport.body([ProviderSnapshot(id: .claude, fetchedAt: now)])
        let root = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(root["source"] as? String == "mac")
        #expect((root["providers"] as? [Any])?.count == 1)
    }
}

@Suite struct GatewayEngineReadingTests {
    private func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("qp-gwr-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private func engine(_ dir: URL, _ t: StubTransport, providers: [any UsageProvider]) throws -> QuotaEngine {
        try Data("{\"token\":\"test-token\"}".utf8).write(to: DataLocation(root: dir).gatewayURL)
        return QuotaEngine(location: DataLocation(root: dir), providers: providers, secrets: InMemorySecretStore(), transport: t, hubName: "t")
    }
    private struct Report: Decodable { var source: String?; var providers: [ProviderSnapshot] }

    @Test func theEngineShowsTheReadingAndReportsNoReadingBack() async throws {
        let t = transport(snapshot(entry(.claude, source: "reader"), entry(.codex, source: "reader")))
        let e = try engine(tempDir(), t, providers: [ClaudeProvider(credentials: NoClaudeCreds()), CodexProvider(credentials: CodexCreds())])
        let first = await e.refresh(reason: "t", now: now)
        #expect(first.provider(.claude)?.windows.first?.utilization == 77)
        #expect(first.provider(.claude)?.status == .ok)
        #expect(await e.sampleCount() > 0, "history keeps building from the reader's numbers")
        let posts = t.requests.filter { $0.httpMethod == "POST" }
        for post in posts {
            let sent = try JSON.decoder.decode(Report.self, from: try #require(post.httpBody))
            #expect(sent.source == "mac")
            #expect(sent.providers.allSatisfy { $0.windows.isEmpty })
        }
        #expect(!hosts(t).contains("chatgpt.com") && !hosts(t).contains("api.anthropic.com"))
    }

    @Test func theEngineReadsLocallyAndReportsWholeWhenTheGatewayHasNothingFresh() async throws {
        let t = transport(snapshot(entry(.claude, source: "reader", age: 4000)))
        let e = try engine(tempDir(), t, providers: [ClaudeProvider(credentials: ClaudeCreds())])
        _ = await e.refresh(reason: "t", now: now)
        #expect(hosts(t).contains("api.anthropic.com"))
        let post = try #require(t.requests.first { $0.httpMethod == "POST" })
        let sent = try JSON.decoder.decode(Report.self, from: try #require(post.httpBody))
        #expect(sent.providers.first { $0.id == .claude }?.windows.isEmpty == false)
    }

    @Test func glmIsSwitchedOnOnceWhenTheGatewayStartsReadingIt() async throws {
        let without = transport(snapshot())
        let dir = tempDir()
        let e0 = try engine(dir, without, providers: [ZaiProvider()])
        _ = await e0.refresh(reason: "t", now: now)
        #expect(await e0.settings.isEnabled(.zai) == false, "no reading, stays off")

        let with = transport(snapshot(entry(.zai, source: "gateway")))
        let e1 = try engine(dir, with, providers: [ZaiProvider()])
        _ = await e1.refresh(reason: "t", now: now)
        #expect(await e1.settings.isEnabled(.zai) == true)
        await e1.update { $0.providers[.zai] = ProviderSettings(enabled: false) }
        _ = await e1.refresh(reason: "t", force: true, now: now.addingTimeInterval(1))
        #expect(await e1.settings.isEnabled(.zai) == false, "the owner's later choice stands")
        let echo = transport(snapshot(entry(.zai, source: "mac")))
        let dir2 = tempDir()
        let e2 = try engine(dir2, echo, providers: [ZaiProvider()])
        _ = await e2.refresh(reason: "t", now: now)
        #expect(await e2.settings.isEnabled(.zai) == false, "its own echo does not count")
    }
}
