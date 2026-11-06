import Foundation

// MARK: - Config

/// Where the Mac reads OpenCode and DeepSeek from, and where it reports Claude / Codex / GLM readings.
/// Lives in `gateway.json` (0600) next to `pairing.json`: `{"baseURL": "...", "token": "..."}`.
/// No file means the Mac talks to the upstream providers itself, exactly as before.
public struct GatewayConfig: Codable, Sendable, Equatable {
    public static let defaultBaseURL = URL(string: "https://llm.lishuyu.app/llm/hub")!

    public var baseURL: URL
    public var token: String

    public init(baseURL: URL = GatewayConfig.defaultBaseURL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    enum CodingKeys: String, CodingKey { case baseURL, token }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try c.decodeIfPresent(URL.self, forKey: .baseURL) ?? Self.defaultBaseURL
        token = try c.decode(String.self, forKey: .token)
    }

    /// nil when the file is missing, unreadable or has no token.
    public static func load(from url: URL) -> GatewayConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard var cfg = try? JSONDecoder().decode(GatewayConfig.self, from: data) else {
            QPLog.hub.error("gateway.json present but unreadable; ignoring it")
            return nil
        }
        cfg.token = cfg.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cfg.token.isEmpty else {
            QPLog.hub.error("gateway.json has an empty token; ignoring it")
            return nil
        }
        return cfg
    }
}

// MARK: - Client

/// Talks to the gateway's hub routes and speaks `ProviderError`, so providers can pass failures straight up.
public struct GatewayClient: Sendable {
    public var config: GatewayConfig
    public var transport: any HTTPTransport

    public init(config: GatewayConfig, transport: any HTTPTransport) {
        self.config = config
        self.transport = transport
    }

    private func request(_ path: String, method: String = "GET", timeout: TimeInterval) -> URLRequest {
        var r = URLRequest(url: HubClient.endpoint(base: config.baseURL, path: path))
        r.httpMethod = method
        r.timeoutInterval = timeout
        r.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    public func snapshot(now: Date) async throws -> QuotaSnapshot {
        let req = request(HubProtocol.snapshotPath, timeout: 20)
        let response: HTTPResponse
        do { response = try await transport.send(req) } catch { throw ProviderError.wrap(error) }
        switch response.statusCode {
        case 200:
            do { return try JSON.decoder.decode(QuotaSnapshot.self, from: response.data) } catch {
                throw ProviderError.decoding("Gateway sent a snapshot this app can't read.")
            }
        case 401, 403: throw ProviderError.unauthorized("The gateway rejected its key (\(response.statusCode)).")
        case 429: throw ProviderError.rateLimited(retryAfter: response.retryAfterDate(now: now))
        default: throw ProviderError.server(response.statusCode, response.bodyExcerpt)
        }
    }

    /// POST /v1/report. Returns the accepted count.
    @discardableResult
    public func report(_ providers: [ProviderSnapshot]) async throws -> Int {
        var req = request(HubProtocol.reportPath, method: "POST", timeout: 15)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = GatewayReport.body(providers)
        let response: HTTPResponse
        do { response = try await transport.send(req) } catch { throw ProviderError.wrap(error) }
        guard response.statusCode == 200 else {
            throw ProviderError.server(response.statusCode, response.bodyExcerpt)
        }
        let obj = (try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]) ?? [:]
        return Int(JSON.number(obj["accepted"]) ?? 0)
    }
}

// MARK: - One snapshot per round

/// Shares one `GET /v1/snapshot` between the providers of a refresh round (keyed by the round's `now`).
public actor GatewaySnapshotCache {
    private var key: Date?
    private var task: Task<Result<QuotaSnapshot, ProviderError>, Never>?

    public init() {}

    public func snapshot(client: GatewayClient, now: Date) async -> Result<QuotaSnapshot, ProviderError> {
        if let task, key == now { return await task.value }
        let t = Task<Result<QuotaSnapshot, ProviderError>, Never> {
            do { return .success(try await client.snapshot(now: now)) } catch { return .failure(ProviderError.wrap(error)) }
        }
        key = now
        task = t
        QPLog.providers.info("gateway snapshot requested")
        return await t.value
    }
}

/// What a provider needs to read from the gateway during one refresh.
public struct GatewayLink: Sendable {
    public var config: GatewayConfig
    public var cache: GatewaySnapshotCache

    public init(config: GatewayConfig, cache: GatewaySnapshotCache) {
        self.config = config
        self.cache = cache
    }

    /// The gateway's reading of one provider. A provider the gateway lacks is `notConfigured`; an error status
    /// the gateway reports comes back unchanged inside the snapshot.
    public func provider(_ id: ProviderID, transport: any HTTPTransport, now: Date) async throws -> ProviderSnapshot {
        let result = await cache.snapshot(client: GatewayClient(config: config, transport: transport), now: now)
        switch result {
        case let .failure(e):
            QPLog.providers.notice("gateway read failed for \(id.rawValue, privacy: .public): \(e.status.message, privacy: .public)")
            throw e
        case let .success(snap):
            guard let p = snap.provider(id) else {
                throw ProviderError.notConfigured("The gateway has no \(id.displayName) reading yet.")
            }
            return p
        }
    }
}

// MARK: - Report

public enum GatewayReport {
    /// Providers whose readings only the Mac can take (their credentials stay here).
    static let reported: Set<ProviderID> = [.claude, .codex, .zai]
    /// Providers the gateway reads itself; the Mac contributes only its forecasts.
    static let forecastOnly: Set<ProviderID> = [.opencode, .deepseek]

    /// Selects and sanitizes what to send. Nothing here is a credential, but `account.label` is dropped anyway.
    public static func providers(from merged: [ProviderSnapshot]) -> [ProviderSnapshot] {
        var out: [ProviderSnapshot] = []
        for p in merged {
            if reported.contains(p.id) {
                if case .notConfigured = p.status { continue }
                var copy = p
                copy.account?.label = nil
                out.append(copy)
            } else if forecastOnly.contains(p.id), !p.forecasts.isEmpty {
                out.append(ProviderSnapshot(id: p.id, fetchedAt: p.fetchedAt, status: .ok, forecasts: p.forecasts))
            }
        }
        return out
    }

    public static func body(_ providers: [ProviderSnapshot]) -> Data {
        struct Body: Encodable { var providers: [ProviderSnapshot] }
        return (try? JSON.encoder.encode(Body(providers: providers))) ?? Data("{\"providers\":[]}".utf8)
    }
}
