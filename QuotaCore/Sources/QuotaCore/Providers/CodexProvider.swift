import Foundation

/// OpenAI Codex (ChatGPT subscription) usage via `GET https://chatgpt.com/backend-api/wham/usage`.
public struct CodexProvider: UsageProvider {
    public let id: ProviderID = .codex
    public static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    public static let optionAllowRefresh = "allowRefresh"

    public var credentials: any CodexCredentialLoading
    public var refresher: CodexTokenRefresher?

    public init(credentials: any CodexCredentialLoading = CodexCredentialLoader(), refresher: CodexTokenRefresher? = nil) {
        self.credentials = credentials
        self.refresher = refresher
    }

    public func fetch(_ ctx: FetchContext) async throws -> ProviderSnapshot {
        var creds = try await credentials.load()
        let allowRefresh = ctx.options[Self.optionAllowRefresh] != "false"
        if creds.isExpired(now: ctx.now) {
            guard allowRefresh else {
                throw ProviderError.expired("Codex token expired. Run `codex` to sign in again, or enable auto-refresh.")
            }
            creds = try await refreshAndStore(creds, ctx: ctx)
        }

        var response = try await send(creds, ctx: ctx)
        if response.statusCode == 401, allowRefresh {
            // Token looked valid but the server disagrees → one refresh attempt.
            creds = try await refreshAndStore(creds, ctx: ctx)
            response = try await send(creds, ctx: ctx)
        }
        switch response.statusCode {
        case 200:
            var snap = try Self.parse(response.data, now: ctx.now)
            if snap.account?.plan == nil { snap.account = AccountInfo(plan: creds.planType?.capitalized) }
            QPLog.providers.notice("Codex usage ok: \(snap.windows.map { "\($0.id)=\(Int($0.utilization))%" }.joined(separator: " "), privacy: .public)")
            return snap
        case 401, 403:
            throw ProviderError.unauthorized("Codex rejected the session (\(response.statusCode)). Run `codex login`.")
        case 429:
            throw ProviderError.rateLimited(retryAfter: response.retryAfterDate(now: ctx.now))
        default:
            throw ProviderError.server(response.statusCode, response.bodyExcerpt)
        }
    }

    private func refreshAndStore(_ creds: CodexCredentials, ctx: FetchContext) async throws -> CodexCredentials {
        let r = refresher ?? CodexTokenRefresher(transport: ctx.transport)
        let fresh = try await r.refresh(creds)
        try? await credentials.store(fresh)
        return fresh
    }

    private func send(_ creds: CodexCredentials, ctx: FetchContext) async throws -> HTTPResponse {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("QuotaPulse", forHTTPHeaderField: "User-Agent")
        if let acc = creds.accountId, !acc.isEmpty { request.setValue(acc, forHTTPHeaderField: "ChatGPT-Account-Id") }
        do { return try await ctx.transport.send(request) } catch { throw ProviderError.wrap(error) }
    }

    public static func parse(_ data: Data, now: Date) throws -> ProviderSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.decoding("Codex usage response is not a JSON object")
        }
        var windows: [UsageWindow] = []
        func window(_ obj: [String: Any]?, id: String, title: String, defaultDuration: TimeInterval?, note: String? = nil) -> UsageWindow? {
            guard let obj, let used = JSON.number(obj["used_percent"]) else { return nil }
            let duration = JSON.number(obj["limit_window_seconds"]) ?? defaultDuration
            return UsageWindow(id: id, title: title, utilization: used, resetsAt: DateParsing.epoch(JSON.number(obj["reset_at"])),
                               duration: duration, note: note, resetSemantics: .fixedCadence)
        }
        if let rl = root["rate_limit"] as? [String: Any] {
            if let w = window(rl["primary_window"] as? [String: Any], id: "primary", title: "5-hour", defaultDuration: 5 * 3600) {
                var w = w
                if let d = w.duration, d > 6 * 3600 { w.title = "Weekly" }
                windows.append(w)
            }
            if let w = window(rl["secondary_window"] as? [String: Any], id: "secondary", title: "Weekly", defaultDuration: 7 * 86400) {
                windows.append(w)
            }
        }
        if let extras = root["additional_rate_limits"] as? [[String: Any]] {
            for (i, e) in extras.enumerated() {
                let name = (e["limit_name"] as? String) ?? (e["metered_feature"] as? String) ?? "Extra \(i + 1)"
                guard let rl = e["rate_limit"] as? [String: Any] else { continue }
                if let w = window(rl["primary_window"] as? [String: Any], id: "extra_\(i)_primary", title: "\(name) · 5-hour", defaultDuration: 5 * 3600, note: name) { windows.append(w) }
                if let w = window(rl["secondary_window"] as? [String: Any], id: "extra_\(i)_secondary", title: "\(name) · Weekly", defaultDuration: 7 * 86400, note: name) { windows.append(w) }
            }
        }
        guard !windows.isEmpty else { throw ProviderError.decoding("Codex usage response had no rate_limit windows") }
        // Some plans report a single window (secondary_window: null); say so instead of leaving a gap.
        if windows.count == 1, (root["rate_limit"] as? [String: Any])?["secondary_window"] is NSNull || (root["rate_limit"] as? [String: Any])?["secondary_window"] == nil {
            windows[0].note = windows[0].note ?? "Only window reported for this plan"
        }
        let plan = (root["plan_type"] as? String)?.replacingOccurrences(of: "_", with: " ").capitalized
        var balance: Balance?
        if let credits = root["credits"] as? [String: Any], let bal = JSON.number(credits["balance"]) {
            // `balance` is a credit count, not money; `unlimited` plans have no meaningful balance.
            let unlimited = credits["unlimited"] as? Bool ?? false
            if !unlimited, bal > 0 || (credits["has_credits"] as? Bool) == true {
                balance = Balance(currency: "credits", total: bal, isAvailable: (credits["has_credits"] as? Bool) ?? (bal > 0))
            }
        }
        return ProviderSnapshot(id: .codex, fetchedAt: now, status: .ok, account: AccountInfo(plan: plan), windows: windows, balance: balance)
    }
}
