import Foundation
import Testing
@testable import QuotaCore

func fixture(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
    return try Data(contentsOf: url)
}

let t0 = Date(timeIntervalSince1970: 1_792_120_000) // 2026-10-16T03:06:40Z

@Suite struct ClaudeParsing {
    @Test func parsesKnownWindowsAndLimits() throws {
        let snap = try ClaudeProvider.parse(fixture("claude_usage"), now: t0)
        #expect(snap.id == .claude)
        #expect(snap.windows.map(\.id) == ["five_hour", "seven_day", "seven_day_opus", "limit_weekly_fable"])
        let five = snap.windows[0]
        #expect(five.utilization == 42.5)
        #expect(five.duration == TimeInterval(18000), "duration=\(String(describing: five.duration))")
        #expect(five.resetsAt == DateParsing.iso8601("2026-10-16T12:00:00Z"))
        #expect(five.startsAt == DateParsing.iso8601("2026-10-16T07:00:00Z"))
        #expect(snap.extraUsage?.monthlyLimit == 50)
        #expect(snap.windows[3].note == "Fable")
        #expect(snap.primaryWindow(now: t0)?.id == "seven_day")
    }

    @Test func rejectsEmptyPayload() {
        #expect(throws: ProviderError.self) { try ClaudeProvider.parse(Data("{}".utf8), now: t0) }
    }

    @Test func credentialsParseAndExpiry() throws {
        let c = try ClaudeCredentials.parse(fixture("claude_credentials"))
        #expect(c.accessToken == "sk-ant-oat01-FIXTURE-TOKEN")
        #expect(c.planLabel == "Max 20x")
        #expect(c.isExpired(now: Date(timeIntervalSince1970: 1_792_000_000)))
        #expect(!c.isExpired(now: Date(timeIntervalSince1970: 1_791_000_000)))
        #expect(throws: ClaudeCredentials.ParseError.missingOAuth) { try ClaudeCredentials.parse(Data("{\"mcpOAuth\":{}}".utf8)) }
    }

    @Test func fetchMapsHTTPStatuses() async throws {
        struct Creds: ClaudeCredentialLoading {
            func load() async throws -> ClaudeCredentialRecord {
                .init(credentials: ClaudeCredentials(accessToken: "tok", refreshToken: nil, expiresAt: nil, scopes: [], rateLimitTier: nil, subscriptionType: nil), source: .file)
            }
        }
        let ok = StubTransport(status: 200, json: String(decoding: try fixture("claude_usage"), as: UTF8.self))
        let snap = try await ClaudeProvider(credentials: Creds()).fetch(FetchContext(transport: ok, secrets: InMemorySecretStore(), now: t0))
        #expect(snap.status == .ok)
        #expect(ok.requests.first?.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(ok.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer tok")

        let limited = StubTransport(status: 429, json: "{}", headers: ["Retry-After": "120"])
        await #expect(throws: ProviderError.rateLimited(retryAfter: t0.addingTimeInterval(120))) {
            try await ClaudeProvider(credentials: Creds()).fetch(FetchContext(transport: limited, secrets: InMemorySecretStore(), now: t0))
        }
        let unauthorized = StubTransport(status: 401, json: "{\"error\":{\"type\":\"authentication_error\"}}")
        do {
            _ = try await ClaudeProvider(credentials: Creds()).fetch(FetchContext(transport: unauthorized, secrets: InMemorySecretStore(), now: t0))
            Issue.record("expected throw")
        } catch let e as ProviderError {
            if case .unauthorized = e {} else { Issue.record("wrong error \(e)") }
        }
    }

    @Test func expiredWithoutRefreshIsReported() async throws {
        struct Creds: ClaudeCredentialLoading {
            func load() async throws -> ClaudeCredentialRecord {
                .init(credentials: ClaudeCredentials(accessToken: "tok", refreshToken: "r", expiresAt: t0.addingTimeInterval(-10), scopes: [], rateLimitTier: nil, subscriptionType: nil), source: .keychain)
            }
        }
        let transport = StubTransport(status: 200, json: "{}")
        do {
            _ = try await ClaudeProvider(credentials: Creds()).fetch(FetchContext(transport: transport, secrets: InMemorySecretStore(), now: t0))
            Issue.record("expected throw")
        } catch let e as ProviderError {
            if case .expired = e {} else { Issue.record("wrong error \(e)") }
        }
        #expect(transport.requests.isEmpty)
    }
}

@Suite struct CodexParsing {
    @Test func parsesWindowsAndExtras() throws {
        let snap = try CodexProvider.parse(fixture("codex_usage"), now: t0)
        #expect(snap.windows.map(\.id) == ["primary", "secondary", "extra_0_primary", "extra_0_secondary"])
        #expect(snap.windows[0].title == "5-hour")
        #expect(snap.windows[0].utilization == 37)
        #expect(snap.windows[0].resetsAt == Date(timeIntervalSince1970: 1_760_616_000))
        #expect(snap.windows[1].duration == 604_800)
        #expect(snap.account?.plan == "Plus")
        #expect(snap.windows[2].note == "GPT-5.3-Codex-Spark")
    }

    @Test func credentialsParseJWTAndMerge() throws {
        let data = try fixture("codex_auth")
        let c = try CodexCredentials.parse(data)
        #expect(c.accountId == "acc-123")
        #expect(c.planType == "plus")
        #expect(c.expiresAt == Date(timeIntervalSince1970: 1_782_318_033))
        #expect(c.isExpired(now: t0))
        let fresh = CodexCredentials(accessToken: "new-access", refreshToken: "new-refresh", idToken: c.idToken, accountId: c.accountId, lastRefresh: t0)
        let merged = try CodexCredentials.merge(into: data, refreshed: fresh, now: t0)
        let root = try JSONSerialization.jsonObject(with: merged) as! [String: Any]
        #expect(root["custom_key"] as? String == "keep-me")
        #expect(root["auth_mode"] as? String == "chatgpt")
        let tokens = root["tokens"] as! [String: Any]
        #expect(tokens["access_token"] as? String == "new-access")
        #expect(tokens["refresh_token"] as? String == "new-refresh")
        #expect((root["last_refresh"] as? String)?.hasPrefix("2026-10-16") == true)
        #expect(throws: CodexCredentials.ParseError.apiKeyMode) { try CodexCredentials.parse(Data("{\"OPENAI_API_KEY\":\"sk-x\"}".utf8)) }
    }

    @Test func refreshesExpiredTokenThenFetches() async throws {
        final class Store: CodexCredentialLoading, @unchecked Sendable {
            var stored: CodexCredentials?
            func load() async throws -> CodexCredentials { try CodexCredentials.parse(try fixture("codex_auth")) }
            func store(_ refreshed: CodexCredentials) async throws { stored = refreshed }
        }
        let usage = String(decoding: try fixture("codex_usage"), as: UTF8.self)
        let transport = StubTransport { req in
            if req.url?.host == "auth.openai.com" {
                let body = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as! [String: Any]
                #expect(body["grant_type"] as? String == "refresh_token")
                #expect(body["client_id"] as? String == CodexTokenRefresher.clientID)
                return HTTPResponse(statusCode: 200, data: Data("{\"access_token\":\"eyJhbGciOiJSUzI1NiJ9.eyJleHAiOjk5OTk5OTk5OTl9.x\",\"refresh_token\":\"rt2\"}".utf8))
            }
            #expect(req.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acc-123")
            #expect(req.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer eyJhbGciOiJSUzI1NiJ9.eyJleHAiOjk5OTk5OTk5OTl9") == true)
            return HTTPResponse(statusCode: 200, data: Data(usage.utf8))
        }
        let store = Store()
        let snap = try await CodexProvider(credentials: store).fetch(FetchContext(transport: transport, secrets: InMemorySecretStore(), now: t0))
        #expect(snap.status == .ok)
        #expect(store.stored?.refreshToken == "rt2")
        #expect(transport.requests.count == 2)
    }

    @Test func refreshFailureIsExpired() async throws {
        struct Store: CodexCredentialLoading {
            func load() async throws -> CodexCredentials { try CodexCredentials.parse(try fixture("codex_auth")) }
            func store(_ refreshed: CodexCredentials) async throws {}
        }
        let transport = StubTransport(status: 400, json: "{\"error\":\"refresh_token_expired\"}")
        do {
            _ = try await CodexProvider(credentials: Store()).fetch(FetchContext(transport: transport, secrets: InMemorySecretStore(), now: t0))
            Issue.record("expected throw")
        } catch let e as ProviderError {
            if case .expired = e {} else { Issue.record("wrong error \(e)") }
        }
    }
}

@Suite struct KeyProviderParsing {
    @Test func deepseek() throws {
        let snap = try DeepSeekProvider.parse(fixture("deepseek_balance"), now: t0)
        #expect(snap.balance?.currency == "CNY")
        #expect(snap.balance?.total == 23.45)
        #expect(snap.balance?.symbol == "¥")
        #expect(snap.windows.isEmpty)
    }

    @Test func deepseekNeedsKey() async {
        let ctx = FetchContext(transport: StubTransport(status: 200, json: "{}"), secrets: InMemorySecretStore(), environment: [:], now: t0)
        do { _ = try await DeepSeekProvider().fetch(ctx); Issue.record("expected throw") }
        catch let e as ProviderError { if case .notConfigured = e {} else { Issue.record("wrong \(e)") } }
        catch { Issue.record("wrong \(error)") }
    }

    @Test func deepseekUsesStoredKey() async throws {
        let secrets = InMemorySecretStore([SecretKey.apiKey(.deepseek): "sk-ds"])
        let transport = StubTransport(status: 200, json: String(decoding: try fixture("deepseek_balance"), as: UTF8.self))
        _ = try await DeepSeekProvider().fetch(FetchContext(transport: transport, secrets: secrets, environment: [:], now: t0))
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-ds")
    }

    @Test func opencode() throws {
        let snap = try OpenCodeProvider.parse(fixture("opencode_usage"), now: t0)
        #expect(snap.windows.map(\.id) == ["rolling", "weekly", "monthly"])
        #expect(snap.windows[0].utilization == 18.5)
        #expect(snap.windows[0].resetsAt == t0.addingTimeInterval(9000))
        #expect(snap.windows[2].resetsAt == DateParsing.iso8601("2026-11-01T00:00:00Z"))
    }

    @Test func opencodeFractionNormalisation() throws {
        let snap = try OpenCodeProvider.parse(Data("{\"usage\":{\"rolling\":{\"utilization\":0.25,\"resetInSec\":10}}}".utf8), now: t0)
        #expect(snap.windows[0].utilization == 25)
    }

    @Test func zai() throws {
        let snap = try ZaiProvider.parse(fixture("zai_quota"), now: t0)
        #expect(snap.windows.count == 2)
        #expect(snap.windows[0].title == "5-hour")
        #expect(snap.windows[0].utilization == 63)
        #expect(snap.windows[0].resetsAt == Date(timeIntervalSince1970: 1_760_616_000))
        #expect(snap.windows[1].title == "MCP")
    }
}

@Suite struct SnapshotModel {
    @Test func mostConstrainedIgnoresErrors() throws {
        let a = ProviderSnapshot(id: .claude, fetchedAt: t0, windows: [UsageWindow(id: "x", title: "x", utilization: 90, resetsAt: nil, duration: nil)])
        let b = ProviderSnapshot(id: .codex, fetchedAt: t0, status: .network("down"), windows: [UsageWindow(id: "y", title: "y", utilization: 99, resetsAt: nil, duration: nil)])
        let snap = QuotaSnapshot(generatedAt: t0, hubName: "h", providers: [a, b])
        #expect(snap.mostConstrained?.provider.id == .claude)
        let data = try JSON.encoder.encode(snap)
        let back = try JSON.decoder.decode(QuotaSnapshot.self, from: data)
        #expect(back == snap)
    }

    @Test func formatting() {
        #expect(QuotaFormat.percent(0) == "0.0%")
        #expect(QuotaFormat.percent(42.4) == "42%")
        #expect(QuotaFormat.percent(99.97) == "100%")
        #expect(QuotaFormat.countdown(to: t0.addingTimeInterval(2 * 3600 + 14 * 60), from: t0) == "2h 14m")
        #expect(QuotaFormat.countdown(to: t0.addingTimeInterval(3 * 86400 + 60), from: t0) == "3d")
        #expect(QuotaFormat.countdown(to: t0.addingTimeInterval(-5), from: t0) == "now")
        #expect(QuotaFormat.money(3.456, symbol: "$") == "$3.46")
        #expect(QuotaFormat.money(1234, symbol: "¥") == "¥1234")
        #expect(QuotaFormat.wholeDays(19.5) == 20)
        #expect(QuotaFormat.wholeDays(6.96e25) == QuotaFormat.maxWholeDays)
        #expect(QuotaFormat.wholeDays(.infinity) == QuotaFormat.maxWholeDays)
        #expect(QuotaFormat.wholeDays(.nan) == 0)
        #expect(QuotaFormat.wholeDays(-3) == 0)
    }
}
