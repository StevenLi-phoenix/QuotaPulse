import Foundation

/// Codex CLI's `auth.json` (`tokens.{access_token,refresh_token,id_token,account_id}`).
public struct CodexCredentials: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    public let idToken: String?
    public let accountId: String?
    public let lastRefresh: Date?
    /// `exp` claim of the access-token JWT.
    public let expiresAt: Date?
    public let planType: String?

    public init(accessToken: String, refreshToken: String, idToken: String?, accountId: String?, lastRefresh: Date?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountId = accountId
        self.lastRefresh = lastRefresh
        let claims = JWT.claims(of: accessToken)
        self.expiresAt = DateParsing.epoch(JSON.number(claims?["exp"]))
        self.planType = (claims?["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_plan_type"] as? String
    }

    public func isExpired(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return now.addingTimeInterval(leeway) >= expiresAt
    }

    public enum ParseError: Error, Equatable, LocalizedError {
        case invalidJSON, apiKeyMode, missingTokens

        public var errorDescription: String? {
            switch self {
            case .invalidJSON: "Codex auth.json is not valid JSON."
            case .apiKeyMode: "Codex is signed in with an API key; usage limits only exist for ChatGPT sign-in."
            case .missingTokens: "Codex auth.json contains no tokens. Run `codex login`."
            }
        }
    }

    public static func parse(_ data: Data) throws -> CodexCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParseError.invalidJSON }
        guard let tokens = root["tokens"] as? [String: Any] else {
            if let key = root["OPENAI_API_KEY"] as? String, !key.isEmpty { throw ParseError.apiKeyMode }
            throw ParseError.missingTokens
        }
        func str(_ k: String, _ alt: String) -> String? {
            ((tokens[k] as? String) ?? (tokens[alt] as? String))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let access = str("access_token", "accessToken"), !access.isEmpty,
              let refresh = str("refresh_token", "refreshToken"), !refresh.isEmpty else {
            throw ParseError.missingTokens
        }
        return CodexCredentials(
            accessToken: access,
            refreshToken: refresh,
            idToken: str("id_token", "idToken"),
            accountId: str("account_id", "accountId"),
            lastRefresh: DateParsing.iso8601(root["last_refresh"] as? String))
    }

    /// Merges refreshed tokens back into the original auth.json bytes, preserving unknown keys.
    public static func merge(into original: Data, refreshed: CodexCredentials, now: Date = Date()) throws -> Data {
        var root = (try? JSONSerialization.jsonObject(with: original) as? [String: Any]) ?? [:]
        var tokens = root["tokens"] as? [String: Any] ?? [:]
        tokens["access_token"] = refreshed.accessToken
        tokens["refresh_token"] = refreshed.refreshToken
        if let id = refreshed.idToken { tokens["id_token"] = id }
        if let acc = refreshed.accountId { tokens["account_id"] = acc }
        root["tokens"] = tokens
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        root["last_refresh"] = f.string(from: now)
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}

public enum JWT {
    /// Decodes the payload of a JWT without verifying it (we only need `exp` and plan metadata).
    public static func claims(of token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

public protocol CodexCredentialLoading: Sendable {
    func load() async throws -> CodexCredentials
    /// Persists refreshed tokens (no-op for read-only sources).
    func store(_ refreshed: CodexCredentials) async throws
}

public struct CodexCredentialLoader: CodexCredentialLoading {
    public var environment: [String: String]
    public var home: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                home: URL = FileManager.default.qpHomeDirectory) {
        self.environment = environment
        self.home = home
    }

    public var authFileURL: URL {
        if let dir = environment["CODEX_HOME"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent("auth.json")
        }
        return home.appendingPathComponent(".codex/auth.json")
    }

    public func load() async throws -> CodexCredentials {
        let url = authFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProviderError.notConfigured("Codex auth.json not found. Run `codex login`.")
        }
        do {
            let creds = try CodexCredentials.parse(Data(contentsOf: url))
            QPLog.credentials.debug("Codex auth read ok: token \(QPLog.redact(creds.accessToken), privacy: .public) exp \(creds.expiresAt.map { "\($0)" } ?? "n/a", privacy: .public)")
            return creds
        } catch let e as CodexCredentials.ParseError {
            throw ProviderError.notConfigured(e.localizedDescription)
        }
    }

    public func store(_ refreshed: CodexCredentials) async throws {
        let url = authFileURL
        let original = (try? Data(contentsOf: url)) ?? Data("{}".utf8)
        let merged = try CodexCredentials.merge(into: original, refreshed: refreshed)
        try FileIO.writeAtomically(merged, to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        QPLog.credentials.info("Codex auth.json updated after refresh")
    }
}

/// `POST https://auth.openai.com/oauth/token` refresh, same public client id the Codex CLI uses.
public struct CodexTokenRefresher: Sendable {
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let endpoint = URL(string: "https://auth.openai.com/oauth/token")!

    public var transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionTransport()) { self.transport = transport }

    public func refresh(_ creds: CodexCredentials) async throws -> CodexCredentials {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": Self.clientID,
            "grant_type": "refresh_token",
            "refresh_token": creds.refreshToken,
        ])
        let response = try await transport.send(request)
        guard response.statusCode == 200 else {
            let body = (try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]) ?? [:]
            let code = (body["error"] as? String) ?? ((body["error"] as? [String: Any])?["code"] as? String) ?? "HTTP \(response.statusCode)"
            switch code {
            case "refresh_token_expired", "refresh_token_reused", "invalid_grant", "refresh_token_invalidated", "invalid_refresh_token":
                throw ProviderError.expired("Codex session expired (\(code)). Run `codex login`.")
            default:
                throw ProviderError.server(response.statusCode, "Codex token refresh failed: \(code)")
            }
        }
        guard let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty else {
            throw ProviderError.decoding("Codex refresh response had no access_token")
        }
        let idToken = (json["id_token"] as? String) ?? creds.idToken
        // account_id normally lives in the id_token claims when not in the response.
        let accountId = creds.accountId
            ?? (JWT.claims(of: idToken ?? "")?["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String
        QPLog.credentials.info("Codex token refreshed: \(QPLog.redact(access), privacy: .public)")
        return CodexCredentials(
            accessToken: access,
            refreshToken: (json["refresh_token"] as? String) ?? creds.refreshToken,
            idToken: idToken,
            accountId: accountId,
            lastRefresh: Date())
    }
}
