import Foundation

/// Wire protocol between the Mac hub and iOS / watchOS clients.
public enum HubProtocol {
    public static let version = 1
    public static let healthPath = "/v1/health"
    public static let snapshotPath = "/v1/snapshot"
    public static let historyPath = "/v1/history"
    public static let telemetryPath = "/v1/telemetry"
    public static let reportPath = "/v1/report"
    public static let deviceHeader = "X-Device-Name"
    public static let appVersionHeader = "X-App-Version"
    public static let platformHeader = "X-Platform"
    public static let urlScheme = "quotapulse"
    /// `?providers=all` on the snapshot route: the client decodes provider ids it doesn't know. Without it the hub sends only
    /// `ProviderID.legacy`, because builds from before dynamic providers reject the whole snapshot over one unknown id.
    public static let providersQuery = "providers"
    public static let allProviders = "all"

    public struct Health: Codable, Sendable, Equatable {
        public var ok: Bool
        public var version: Int
        public var hubName: String
        public var generatedAt: Date?
        public init(ok: Bool, version: Int = HubProtocol.version, hubName: String, generatedAt: Date?) {
            self.ok = ok; self.version = version; self.hubName = hubName; self.generatedAt = generatedAt
        }
    }

    public struct History: Codable, Sendable, Equatable {
        public var provider: ProviderID
        public var hours: Double
        public var samples: [Sample]
        public init(provider: ProviderID, hours: Double, samples: [Sample]) {
            self.provider = provider; self.hours = hours; self.samples = samples
        }
    }
}

/// What a client needs to talk to a hub. Encoded as `quotapulse://pair?url=…&token=…&name=…` for QR codes.
public struct HubPairing: Codable, Sendable, Equatable {
    public var baseURL: URL
    public var token: String
    public var hubName: String

    public init(baseURL: URL, token: String, hubName: String) {
        self.baseURL = baseURL
        self.token = token
        self.hubName = hubName
    }

    public var pairingURL: URL {
        var c = URLComponents()
        c.scheme = HubProtocol.urlScheme
        c.host = "pair"
        c.queryItems = [.init(name: "url", value: baseURL.absoluteString), .init(name: "token", value: token), .init(name: "name", value: hubName)]
        return c.url!
    }

    public static func parse(_ url: URL) -> HubPairing? {
        guard url.scheme == HubProtocol.urlScheme, url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func q(_ n: String) -> String? { items.first { $0.name == n }?.value }
        guard let u = q("url"), let base = URL(string: u), let token = q("token"), !token.isEmpty else { return nil }
        return HubPairing(baseURL: base, token: token, hubName: q("name") ?? base.host ?? "Hub")
    }

    /// A hub behind a path prefix is the gateway (`https://host/llm/hub`); it has no telemetry route.
    public var supportsTelemetry: Bool {
        baseURL.path.split(separator: "/").isEmpty
    }

    public static func randomToken() -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<32).map { _ in alphabet.randomElement()! })
    }
}

/// Client side: fetch from a hub.
public struct HubClient: Sendable {
    public var pairing: HubPairing
    public var transport: any HTTPTransport

    public init(pairing: HubPairing, transport: any HTTPTransport = URLSessionTransport()) {
        self.pairing = pairing
        self.transport = transport
    }

    public enum ClientError: Error, LocalizedError, Sendable {
        case unauthorized, unreachable(String), badResponse(Int), decoding

        public var errorDescription: String? {
            switch self {
            case .unauthorized: "Hub rejected the pairing token."
            case let .unreachable(m): "Hub unreachable: \(m)"
            case let .badResponse(c): "Hub returned HTTP \(c)."
            case .decoding: "Hub sent data this app can't read (version mismatch?)."
            }
        }
    }

    /// `base` + `path`, keeping any path the base already has (`https://host/llm/hub` + `/v1/health`).
    public static func endpoint(base: URL, path: String, query: [URLQueryItem] = []) -> URL {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        var prefix = c.path
        while prefix.hasSuffix("/") { prefix.removeLast() }
        c.path = prefix + (path.hasPrefix("/") ? path : "/" + path)
        if !query.isEmpty { c.queryItems = query }
        return c.url!
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as: T.Type) async throws -> T {
        var request = URLRequest(url: Self.endpoint(base: pairing.baseURL, path: path, query: query))
        request.timeoutInterval = 10
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response: HTTPResponse
        do { response = try await transport.send(request) } catch { throw ClientError.unreachable(error.localizedDescription) }
        switch response.statusCode {
        case 200: break
        case 401, 403: throw ClientError.unauthorized
        default: throw ClientError.badResponse(response.statusCode)
        }
        do { return try JSON.decoder.decode(T.self, from: response.data) } catch { throw ClientError.decoding }
    }

    public func health() async throws -> HubProtocol.Health { try await get(HubProtocol.healthPath, as: HubProtocol.Health.self) }
    public func snapshot() async throws -> QuotaSnapshot {
        try await get(HubProtocol.snapshotPath, query: [.init(name: HubProtocol.providersQuery, value: HubProtocol.allProviders)], as: QuotaSnapshot.self)
    }
    public func history(_ provider: ProviderID, hours: Double) async throws -> HubProtocol.History {
        try await get(HubProtocol.historyPath, query: [.init(name: "provider", value: provider.rawValue), .init(name: "hours", value: "\(Int(hours))")],
                      as: HubProtocol.History.self)
    }
}

/// Pure request router used by the server (testable without sockets).
public struct HubRouter: Sendable {
    public struct Request: Sendable { public var method: String; public var path: String; public var query: [String: String]; public var headers: [String: String]; public var body: Data
        public init(method: String, path: String, query: [String: String], headers: [String: String], body: Data = Data()) {
            self.method = method; self.path = path; self.query = query; self.headers = headers; self.body = body
        }
        public func header(_ name: String) -> String? { headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value }
    }
    public struct Response: Sendable { public var status: Int; public var body: Data; public var contentType: String
        public init(status: Int, body: Data, contentType: String = "application/json") { self.status = status; self.body = body; self.contentType = contentType }
    }

    public var token: String
    public var hubName: String
    public var snapshot: @Sendable () async -> QuotaSnapshot
    public var history: @Sendable (ProviderID, Double) async -> [Sample]
    /// Receives uploaded JSON Lines; returns the accepted count or nil on failure.
    public var telemetry: @Sendable ([Substring], DeviceIdentity) async -> Int?

    public init(token: String, hubName: String,
                snapshot: @escaping @Sendable () async -> QuotaSnapshot,
                history: @escaping @Sendable (ProviderID, Double) async -> [Sample],
                telemetry: @escaping @Sendable ([Substring], DeviceIdentity) async -> Int? = { _, _ in nil }) {
        self.token = token; self.hubName = hubName; self.snapshot = snapshot; self.history = history; self.telemetry = telemetry
    }

    public func handle(_ req: Request) async -> Response {
        func json<T: Encodable>(_ v: T, status: Int = 200) -> Response {
            Response(status: status, body: (try? JSON.encoder.encode(v)) ?? Data("{}".utf8))
        }
        guard req.method == "GET" || (req.method == "POST" && req.path == HubProtocol.telemetryPath) else {
            return Response(status: 405, body: Data("{\"error\":\"method\"}".utf8))
        }
        let auth = req.headers.first { $0.key.lowercased() == "authorization" }?.value ?? ""
        let presented = auth.hasPrefix("Bearer ") ? String(auth.dropFirst(7)) : (req.query["token"] ?? "")
        guard constantTimeEquals(presented, token) else {
            return Response(status: 401, body: Data("{\"error\":\"unauthorized\"}".utf8))
        }
        switch req.path {
        case HubProtocol.telemetryPath:
            guard req.body.count <= 4 * 1024 * 1024, let text = String(data: req.body, encoding: .utf8) else {
                return Response(status: 413, body: Data("{\"error\":\"body\"}".utf8))
            }
            let identity = DeviceIdentity(name: req.header(HubProtocol.deviceHeader) ?? "unknown",
                                          appVersion: req.header(HubProtocol.appVersionHeader) ?? "?",
                                          platform: req.header(HubProtocol.platformHeader) ?? "?")
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            guard let accepted = await telemetry(lines, identity) else {
                return Response(status: 500, body: Data("{\"error\":\"store\"}".utf8))
            }
            return Response(status: 200, body: Data("{\"accepted\":\(accepted)}".utf8))
        case HubProtocol.healthPath:
            let s = await snapshot()
            return json(HubProtocol.Health(ok: true, hubName: hubName, generatedAt: s.generatedAt == .distantPast ? nil : s.generatedAt))
        case HubProtocol.snapshotPath:
            let s = await snapshot()
            if req.query[HubProtocol.providersQuery] == HubProtocol.allProviders { return json(s) }
            let legacy = s.legacyCompatible
            if legacy.providers.count < s.providers.count {
                QPLog.hub.info("snapshot for an older client: left out \(s.providers.filter { !ProviderID.legacy.contains($0.id) }.map(\.id.rawValue).joined(separator: ","), privacy: .public)")
            }
            return json(legacy)
        case HubProtocol.historyPath:
            guard let p = req.query["provider"].flatMap(ProviderID.init(validating:)) else {
                return Response(status: 400, body: Data("{\"error\":\"provider\"}".utf8))
            }
            let hours = min(24 * 30, max(1, Double(req.query["hours"] ?? "") ?? 24))
            return json(HubProtocol.History(provider: p, hours: hours, samples: await history(p, hours)))
        default:
            return Response(status: 404, body: Data("{\"error\":\"not found\"}".utf8))
        }
    }

    func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count, !x.isEmpty else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}

/// Minimal HTTP/1.1 request parser: GET without body, POST with Content-Length.
public enum HTTPParser {
    /// nil until the whole request (headers + declared body) has arrived.
    public static func parse(_ data: Data) -> HubRouter.Request? {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let text = String(data: data[..<sep.lowerBound], encoding: .utf8) else { return nil }
        let head = text[...]
        var lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])
        var headers: [String: String] = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[String(l[..<i]).trimmingCharacters(in: .whitespaces)] = String(l[l.index(after: i)...]).trimmingCharacters(in: .whitespaces)
        }
        let comps = URLComponents(string: target)
        var query: [String: String] = [:]
        for q in comps?.queryItems ?? [] { query[q.name] = q.value ?? "" }
        let declared = Int(headers.first { $0.key.lowercased() == "content-length" }?.value ?? "0") ?? 0
        let body = data[sep.upperBound...]
        guard body.count >= declared else { return nil }
        return HubRouter.Request(method: method, path: comps?.path ?? target, query: query, headers: headers, body: Data(body.prefix(declared)))
    }

    public static func serialize(_ r: HubRouter.Response) -> Data {
        let reason: String = switch r.status { case 200: "OK"; case 400: "Bad Request"; case 401: "Unauthorized"; case 404: "Not Found"; case 405: "Method Not Allowed"; default: "Error" }
        var head = "HTTP/1.1 \(r.status) \(reason)\r\n"
        head += "Content-Type: \(r.contentType)\r\nContent-Length: \(r.body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nServer: QuotaPulse/\(HubProtocol.version)\r\n\r\n"
        return Data(head.utf8) + r.body
    }
}
