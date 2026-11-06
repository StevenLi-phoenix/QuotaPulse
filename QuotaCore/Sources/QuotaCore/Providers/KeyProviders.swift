import Foundation

// MARK: - DeepSeek (prepaid balance)

public struct DeepSeekProvider: UsageProvider {
    public let id: ProviderID = .deepseek
    public static let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!
    public static let envKeys = ["DEEPSEEK_API_KEY", "DEEPSEEK_KEY"]

    public init() {}

    public func fetch(_ ctx: FetchContext) async throws -> ProviderSnapshot {
        if let gateway = ctx.gateway { return try await gateway.provider(.deepseek, transport: ctx.transport, now: ctx.now) }
        let key = try ctx.apiKey(for: .deepseek, envKeys: Self.envKeys)
        var request = URLRequest(url: Self.balanceURL)
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response: HTTPResponse
        do { response = try await ctx.transport.send(request) } catch { throw ProviderError.wrap(error) }
        switch response.statusCode {
        case 200:
            let snap = try Self.parse(response.data, now: ctx.now)
            QPLog.providers.notice("DeepSeek balance ok: \(snap.balance.map { "\($0.currency) \($0.total)" } ?? "-", privacy: .public)")
            return snap
        case 401, 403: throw ProviderError.unauthorized("DeepSeek rejected the API key (\(response.statusCode)).")
        case 429: throw ProviderError.rateLimited(retryAfter: response.retryAfterDate(now: ctx.now))
        default: throw ProviderError.server(response.statusCode, response.bodyExcerpt)
        }
    }

    public static func parse(_ data: Data, now: Date) throws -> ProviderSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let infos = root["balance_infos"] as? [[String: Any]], var info = infos.first else {
            throw ProviderError.decoding("DeepSeek balance response malformed")
        }
        // One entry per currency wallet, in no fixed order and including empty ones: use the fullest.
        for candidate in infos.dropFirst() where (JSON.number(candidate["total_balance"]) ?? 0) > (JSON.number(info["total_balance"]) ?? 0) {
            info = candidate
        }
        let wallets = infos.map { "\($0["currency"] as? String ?? "?") \(JSON.number($0["total_balance"]) ?? 0)" }.joined(separator: ", ")
        QPLog.providers.notice("DeepSeek wallets: \(wallets, privacy: .public)")
        let available = root["is_available"] as? Bool ?? true
        let currency = (info["currency"] as? String) ?? "USD"
        let balance = Balance(currency: currency,
                              total: JSON.number(info["total_balance"]) ?? 0,
                              granted: JSON.number(info["granted_balance"]),
                              toppedUp: JSON.number(info["topped_up_balance"]),
                              isAvailable: available)
        return ProviderSnapshot(id: .deepseek, fetchedAt: now, status: .ok, windows: [], balance: balance)
    }
}

// MARK: - OpenCode Zen / Go

public struct OpenCodeProvider: UsageProvider {
    public let id: ProviderID = .opencode
    public static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    public static let envKeys = ["OPENCODE_API_KEY", "OPENCODE_GO_API_KEY", "OPENCODE_ZEN_API_KEY"]

    public init() {}

    public func fetch(_ ctx: FetchContext) async throws -> ProviderSnapshot {
        if let gateway = ctx.gateway { return try await gateway.provider(.opencode, transport: ctx.transport, now: ctx.now) }
        let key = try resolveKey(ctx)
        var request = URLRequest(url: Self.usageURL)
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("QuotaPulse", forHTTPHeaderField: "User-Agent")
        let response: HTTPResponse
        do { response = try await ctx.transport.send(request) } catch { throw ProviderError.wrap(error) }
        switch response.statusCode {
        case 200:
            let snap = try Self.parse(response.data, now: ctx.now)
            QPLog.providers.notice("OpenCode usage ok: \(snap.windows.map { "\($0.id)=\(Int($0.utilization))%" }.joined(separator: " "), privacy: .public)")
            return snap
        case 401, 403: throw ProviderError.unauthorized("OpenCode rejected the API key (\(response.statusCode)).")
        case 404: throw ProviderError.notConfigured("No OpenCode Go subscription on this key (404).")
        case 429: throw ProviderError.rateLimited(retryAfter: response.retryAfterDate(now: ctx.now))
        default: throw ProviderError.server(response.statusCode, response.bodyExcerpt)
        }
    }

    /// Settings key → env → opencode's own auth.json (`opencode-go.key`).
    func resolveKey(_ ctx: FetchContext) throws -> String {
        if let k = try? ctx.apiKey(for: .opencode, envKeys: Self.envKeys) { return k }
        let home = FileManager.default.qpHomeDirectory
        let xdg = ctx.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".local/share")
        let authURL = xdg.appendingPathComponent("opencode/auth.json")
        if let data = try? Data(contentsOf: authURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let entry = root["opencode-go"] as? [String: Any] ?? root["opencode"] as? [String: Any],
           let key = entry["key"] as? String, !key.isEmpty {
            return key
        }
        throw ProviderError.notConfigured("OpenCode API key not set. Add it in Settings (opencode.ai/console).")
    }

    static let percentKeys = ["usagePercent", "usedPercent", "percentUsed", "percent", "usage_percent", "used_percent", "utilization", "utilizationPercent", "usage"]
    static let resetInKeys = ["resetInSec", "resetInSeconds", "resetSeconds", "reset_sec", "reset_in_sec", "resetsInSec", "resetIn", "resetSec"]
    static let resetAtKeys = ["resetAt", "resetsAt", "reset_at", "resets_at", "nextReset", "next_reset", "renewAt", "renew_at"]

    static func parseWindow(_ obj: [String: Any]?, id: String, title: String, duration: TimeInterval, now: Date) -> UsageWindow? {
        guard let obj, let pct = JSON.number(JSON.first(obj, keys: percentKeys)) else { return nil }
        var resetsAt: Date?
        if let sec = JSON.number(JSON.first(obj, keys: resetInKeys)) { resetsAt = now.addingTimeInterval(sec) }
        else if let raw = JSON.first(obj, keys: resetAtKeys) {
            resetsAt = DateParsing.epoch(JSON.number(raw)) ?? DateParsing.iso8601(raw as? String)
        }
        // Fractions (0…1) vs percents (0…100).
        let normalized = pct <= 1.0 && JSON.first(obj, keys: ["usagePercent", "usedPercent", "used_percent", "usage_percent"]) == nil ? pct * 100 : pct
        return UsageWindow(id: id, title: title, utilization: normalized, resetsAt: resetsAt, duration: duration)
    }

    public static func parse(_ data: Data, now: Date) throws -> ProviderSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = (root["usage"] as? [String: Any]) ?? root as [String: Any]? else {
            throw ProviderError.decoding("OpenCode usage response malformed")
        }
        var windows: [UsageWindow] = []
        if let w = parseWindow(usage["rolling"] as? [String: Any], id: "rolling", title: "5-hour", duration: 5 * 3600, now: now) { windows.append(w) }
        if let w = parseWindow(usage["weekly"] as? [String: Any], id: "weekly", title: "Weekly", duration: 7 * 86400, now: now) { windows.append(w) }
        if let w = parseWindow(usage["monthly"] as? [String: Any], id: "monthly", title: "Monthly", duration: 30 * 86400, now: now) { windows.append(w) }
        guard !windows.isEmpty else { throw ProviderError.decoding("OpenCode usage response had no windows") }
        var balance: Balance?
        if let b = JSON.number(JSON.first(root, keys: ["balance", "balanceUSD", "credits"])) {
            balance = Balance(currency: "USD", total: b)
        }
        return ProviderSnapshot(id: .opencode, fetchedAt: now, status: .ok, windows: windows, balance: balance)
    }
}

// MARK: - z.ai / BigModel coding plan

public struct ZaiProvider: UsageProvider {
    public let id: ProviderID = .zai
    public static let envKeys = ["ZAI_API_KEY", "Z_AI_API_KEY", "ZHIPU_API_KEY", "ZHIPUAI_API_KEY", "ZHI_PU_API"]
    public static let optionRegion = "region"   // "global" | "cn"

    public init() {}

    public static func quotaURL(region: String?) -> URL {
        region == "global" ? URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
            : URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!
    }

    public func fetch(_ ctx: FetchContext) async throws -> ProviderSnapshot {
        let key = try ctx.apiKey(for: .zai, envKeys: Self.envKeys)
        var request = URLRequest(url: Self.quotaURL(region: ctx.options[Self.optionRegion]))
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response: HTTPResponse
        do { response = try await ctx.transport.send(request) } catch { throw ProviderError.wrap(error) }
        switch response.statusCode {
        case 200: return try Self.parse(response.data, now: ctx.now)
        case 401, 403: throw ProviderError.unauthorized("z.ai rejected the API key (\(response.statusCode)).")
        case 429: throw ProviderError.rateLimited(retryAfter: response.retryAfterDate(now: ctx.now))
        default: throw ProviderError.server(response.statusCode, response.bodyExcerpt)
        }
    }

    public static func parse(_ data: Data, now: Date) throws -> ProviderSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.decoding("z.ai quota response malformed")
        }
        if let code = JSON.number(root["code"]), code != 200, code != 0 {
            throw ProviderError.server(Int(code), (root["msg"] as? String) ?? "z.ai error")
        }
        guard let d = root["data"] as? [String: Any], let limits = d["limits"] as? [[String: Any]] else {
            throw ProviderError.decoding("z.ai quota response had no limits")
        }
        var windows: [UsageWindow] = []
        for (i, raw) in limits.enumerated() {
            let type = (raw["type"] as? String) ?? ""
            var pct = JSON.number(raw["percentage"])
            if pct == nil, let usage = JSON.number(raw["usage"]), usage > 0 {
                let used = JSON.number(raw["currentValue"]) ?? (JSON.number(raw["remaining"]).map { usage - $0 })
                if let used { pct = used / usage * 100 }
            }
            guard let percent = pct else { continue }
            let unit = Int(JSON.number(raw["unit"]) ?? 0), number = Int(JSON.number(raw["number"]) ?? 0)
            // unit: 1=minute 2=hour 3=day 4=week 5=month (per CodexBar's zai plugin)
            let minutes: Double? = switch unit {
            case 1: Double(number)
            case 2: Double(number) * 60
            case 3: Double(number) * 1440
            case 4: Double(number) * 10080
            case 5: Double(number) * 43200
            default: nil
            }
            let title: String = type == "TIME_LIMIT" ? "MCP" : (minutes == 300 ? "5-hour" : (minutes.map { $0 >= 10080 ? "Weekly" : "\(Int($0 / 60))h" } ?? "Plan"))
            windows.append(UsageWindow(id: "limit_\(i)", title: title, utilization: percent,
                                       resetsAt: DateParsing.epoch(JSON.number(raw["nextResetTime"])),
                                       duration: minutes.map { $0 * 60 }))
        }
        guard !windows.isEmpty else { throw ProviderError.decoding("z.ai quota response had no usable limits") }
        return ProviderSnapshot(id: .zai, fetchedAt: now, status: .ok, windows: windows)
    }
}
