import Foundation

/// Claude Code subscription usage via `GET https://api.anthropic.com/api/oauth/usage`.
public struct ClaudeProvider: UsageProvider {
    public let descriptor = ProviderDescriptor(id: .claude, defaultEnabled: true)
    public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let betaHeader = "oauth-2025-04-20"
    public static let refreshURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let optionAllowRefresh = "allowRefresh"

    public var credentials: any ClaudeCredentialLoading

    public init(credentials: any ClaudeCredentialLoading = ClaudeCredentialLoader()) {
        self.credentials = credentials
    }

    public func fetch(_ ctx: FetchContext) async throws -> ProviderSnapshot {
        if let reading = await ctx.gateway?.reading(.claude, transport: ctx.transport, now: ctx.now) { return reading }
        let record = try await credentials.load()
        var creds = record.credentials
        if creds.isExpired(now: ctx.now) {
            if ctx.options[Self.optionAllowRefresh] == "true", let refresh = creds.refreshToken {
                creds = try await Self.refresh(refreshToken: refresh, transport: ctx.transport)
            } else {
                throw ProviderError.expired("Claude token expired \(creds.expiresAt.map { QuotaFormat.countdown(to: ctx.now, from: $0) } ?? "")ago. Open Claude Code once — it refreshes the token automatically.")
            }
        }

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-cli/2.1.0 (external, cli)", forHTTPHeaderField: "User-Agent")

        let response: HTTPResponse
        do { response = try await ctx.transport.send(request) } catch { throw ProviderError.wrap(error) }
        switch response.statusCode {
        case 200:
            let parsed = try Self.parse(response.data, now: ctx.now)
            var snap = parsed
            snap.account = AccountInfo(plan: creds.planLabel, label: record.source.rawValue)
            QPLog.providers.notice("Claude usage ok: \(snap.windows.map { "\($0.id)=\(Int($0.utilization))%" }.joined(separator: " "), privacy: .public)")
            return snap
        case 401:
            throw ProviderError.unauthorized("Claude rejected the token (401). Open Claude Code to refresh, or run `claude login`.")
        case 403:
            throw ProviderError.unauthorized("Claude returned 403: \(response.bodyExcerpt)")
        case 429:
            throw ProviderError.rateLimited(retryAfter: response.retryAfterDate(now: ctx.now))
        default:
            throw ProviderError.server(response.statusCode, response.bodyExcerpt)
        }
    }

    static func refresh(refreshToken: String, transport: any HTTPTransport) async throws -> ClaudeCredentials {
        var request = URLRequest(url: Self.refreshURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": Self.clientID,
        ])
        let response = try await transport.send(request)
        guard response.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw ProviderError.expired("Claude token refresh failed (HTTP \(response.statusCode)). Open Claude Code to sign in again.")
        }
        let expires = (json["expires_in"] as? Double).map { Date().addingTimeInterval($0) }
        return ClaudeCredentials(accessToken: access, refreshToken: json["refresh_token"] as? String ?? refreshToken,
                                 expiresAt: expires, scopes: [], rateLimitTier: nil, subscriptionType: nil)
    }

    /// Parses the usage payload. Known keys: five_hour, seven_day, seven_day_opus, seven_day_sonnet,
    /// seven_day_oauth_apps, extra_usage, limits[] (newer scoped shape).
    public static func parse(_ data: Data, now: Date) throws -> ProviderSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.decoding("Claude usage response is not a JSON object")
        }
        var windows: [UsageWindow] = []
        let known: [(key: String, title: String, duration: TimeInterval, note: String?)] = [
            ("five_hour", "5-hour", 5 * 3600, nil),
            ("seven_day", "Weekly", 7 * 86400, nil),
            ("seven_day_opus", "Weekly · Opus", 7 * 86400, "Opus"),
            ("seven_day_sonnet", "Weekly · Sonnet", 7 * 86400, "Sonnet"),
            ("seven_day_oauth_apps", "Weekly · Apps", 7 * 86400, "OAuth apps"),
        ]
        for k in known {
            guard let obj = root[k.key] as? [String: Any], let util = JSON.number(obj["utilization"]) else { continue }
            windows.append(UsageWindow(id: k.key, title: k.title, utilization: util,
                                       resetsAt: DateParsing.iso8601(obj["resets_at"] as? String),
                                       duration: k.duration, note: k.note, resetSemantics: .rollingFromFirstUse))
        }
        // Newer `limits` entries add scoped windows (e.g. a model-specific weekly cap).
        if let limits = root["limits"] as? [[String: Any]] {
            for (i, entry) in limits.enumerated() {
                guard let pct = JSON.number(entry["percent"]) else { continue }
                if let active = entry["is_active"] as? Bool, !active { continue }
                let kind = (entry["kind"] as? String) ?? ""
                let group = (entry["group"] as? String) ?? kind
                // `session` and `weekly_all` mirror the flat five_hour / seven_day windows above.
                if kind == "session" || kind == "weekly_all", !windows.isEmpty { continue }
                let model = ((entry["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                let id = "limit_\(group)_\(model ?? (kind.isEmpty ? String(i) : kind))".lowercased().replacingOccurrences(of: " ", with: "_")
                if windows.contains(where: { $0.id == id }) { continue }
                let duration: TimeInterval? = group.contains("week") ? 7 * 86400 : (group.contains("session") || group.contains("five") ? 5 * 3600 : nil)
                let note = model ?? (kind.contains("scoped") ? "Model-scoped" : nil)
                let title = note.map { "\(group.capitalized) · \($0)" } ?? group.capitalized
                // Skip duplicates of the flat windows (same percent + reset).
                if windows.contains(where: { abs($0.utilization - pct) < 0.01 && $0.resetsAt == DateParsing.iso8601(entry["resets_at"] as? String) }) { continue }
                windows.append(UsageWindow(id: id, title: title, utilization: pct,
                                           resetsAt: DateParsing.iso8601(entry["resets_at"] as? String),
                                           duration: duration, note: note, resetSemantics: .rollingFromFirstUse))
            }
        }
        var extra: ExtraUsage?
        if let e = root["extra_usage"] as? [String: Any] {
            extra = ExtraUsage(isEnabled: e["is_enabled"] as? Bool ?? false, monthlyLimit: JSON.number(e["monthly_limit"]),
                               usedCredits: JSON.number(e["used_credits"]), utilization: JSON.number(e["utilization"]),
                               currency: e["currency"] as? String)
        }
        guard !windows.isEmpty else { throw ProviderError.decoding("Claude usage response had no windows") }
        return ProviderSnapshot(id: .claude, fetchedAt: now, status: .ok, windows: windows, extraUsage: extra)
    }
}
