import Foundation

public extension ProviderID {
    static let grokbot: ProviderID = "grokbot"
}

/// Grok Bot (xAI's desktop agent, built on Cursor's backend) usage via the app's own Connect RPC
/// `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus`: one percent-used number for a weekly window.
/// Everything the other devices need to draw it travels in its snapshots (`info`): no display code knows this provider.
public struct GrokBotProvider: UsageProvider {
    public let descriptor = ProviderDescriptor(
        id: .grokbot,
        info: ProviderInfo(displayName: "Grok Bot", subtitle: "Desktop app", kind: .rateWindows, brandHex: 0xA855F7, symbol: "scope",
                           dashboardURL: URL(string: "https://cursor.com/dashboard/spending")),
        defaultEnabled: true)
    public static let usageURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")!

    public var credentials: any GrokBotCredentialLoading

    public init(credentials: any GrokBotCredentialLoading = GrokBotCredentialLoader()) {
        self.credentials = credentials
    }

    public func fetch(_ ctx: FetchContext) async throws -> ProviderSnapshot {
        let creds = try await credentials.load()
        if creds.isExpired(now: ctx.now) {
            throw ProviderError.expired("Grok Bot's session has expired. Open Grok Bot to refresh it.")
        }
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("QuotaPulse", forHTTPHeaderField: "User-Agent")
        let response: HTTPResponse
        do { response = try await ctx.transport.send(request) } catch { throw ProviderError.wrap(error) }
        switch response.statusCode {
        case 200:
            let snap = try Self.parse(response.data, now: ctx.now)
            QPLog.providers.notice("Grok Bot usage ok: \(snap.windows.map { "\($0.id)=\(Int($0.utilization))%" }.joined(separator: " "), privacy: .public)")
            return snap
        case 401, 403:
            throw ProviderError.unauthorized("Grok Bot rejected the session (\(response.statusCode)). Open Grok Bot and sign in again.")
        case 429:
            throw ProviderError.rateLimited(retryAfter: response.retryAfterDate(now: ctx.now))
        default:
            throw ProviderError.server(response.statusCode, response.bodyExcerpt)
        }
    }

    /// `usagePercent` is the share of the plan's included usage spent in the current period; the period runs from
    /// `currentPeriodStart` to `nextResetTimestampUtc` and the next one starts right away.
    public static func parse(_ data: Data, now: Date) throws -> ProviderSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.decoding("Grok Bot usage response is not a JSON object")
        }
        guard let used = JSON.number(root["usagePercent"]) else {
            // protobuf JSON drops zero values: a fresh period has no `usagePercent` key. Anything else without it is a different shape.
            guard root["nextResetTimestampUtc"] != nil || root["currentPeriodStart"] != nil else {
                throw ProviderError.decoding("Grok Bot usage response had no usagePercent")
            }
            return snapshot(root, used: 0, now: now)
        }
        return snapshot(root, used: used, now: now)
    }

    private static func snapshot(_ root: [String: Any], used: Double, now: Date) -> ProviderSnapshot {
        let start = DateParsing.iso8601(root["currentPeriodStart"] as? String)
        let reset = DateParsing.iso8601(root["nextResetTimestampUtc"] as? String)
        var duration: TimeInterval = 7 * 86400
        if let start, let reset, reset > start { duration = reset.timeIntervalSince(start) }
        let window = UsageWindow(id: "weekly", title: "Weekly", utilization: used, resetsAt: reset, duration: duration,
                                 resetSemantics: .fixedCadence)
        let plan = (root["cursorPlanName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (root["grokPlanLabel"] as? String)
        var balance: Balance?
        if let cents = JSON.number(root["prepaidAvailableCents"]), cents > 0 {
            balance = Balance(currency: "USD", total: cents / 100, isAvailable: true)
        }
        return ProviderSnapshot(id: .grokbot, fetchedAt: now, status: .ok, account: AccountInfo(plan: plan), windows: [window], balance: balance)
    }
}
