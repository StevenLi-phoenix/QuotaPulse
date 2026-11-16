import Foundation

public enum ProviderError: Error, LocalizedError, Sendable, Equatable {
    case notConfigured(String)
    case unauthorized(String)
    case expired(String)
    case rateLimited(retryAfter: Date?)
    case network(String)
    case decoding(String)
    case server(Int, String)

    public var errorDescription: String? { status.message }

    public var status: ProviderStatus {
        switch self {
        case let .notConfigured(m): .notConfigured(m)
        case let .unauthorized(m): .unauthorized(m)
        case let .expired(m): .expired(m)
        case let .rateLimited(r): .rateLimited(retryAfter: r)
        case let .network(m): .network(m)
        case let .decoding(m): .decoding(m)
        case let .server(c, m): .server(code: c, m)
        }
    }

    public static func wrap(_ error: Error) -> ProviderError {
        if let e = error as? ProviderError { return e }
        if let u = error as? URLError { return .network(u.localizedDescription) }
        if error is DecodingError { return .decoding(String(describing: error)) }
        return .network(error.localizedDescription)
    }
}

/// Everything a provider needs at fetch time.
public struct FetchContext: Sendable {
    public var transport: any HTTPTransport
    public var secrets: any SecretStore
    public var environment: [String: String]
    public var now: Date
    /// Per-provider options from settings (e.g. "allowRefresh").
    public var options: [String: String]
    /// Set when `gateway.json` exists: OpenCode and DeepSeek are read from the gateway instead of upstream, and Claude, Codex and GLM
    /// use the gateway's reading while it is good and fresh, reading upstream only when it is not.
    public var gateway: GatewayLink?

    public init(transport: any HTTPTransport = URLSessionTransport(), secrets: any SecretStore,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                now: Date = Date(), options: [String: String] = [:], gateway: GatewayLink? = nil) {
        self.transport = transport
        self.secrets = secrets
        self.environment = environment
        self.now = now
        self.options = options
        self.gateway = gateway
    }

    /// API key resolution: secret store first, then environment variables.
    public func apiKey(for provider: ProviderID, envKeys: [String]) throws -> String {
        if let v = try secrets.get(SecretKey.apiKey(provider))?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
        for k in envKeys {
            if let v = environment[k]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
        }
        throw ProviderError.notConfigured("\(provider.displayName) API key not set. Add it in Settings.")
    }
}

public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func fetch(_ context: FetchContext) async throws -> ProviderSnapshot
}

public extension HTTPResponse {
    /// Retry-After header as a Date (seconds or HTTP-date).
    func retryAfterDate(now: Date = Date()) -> Date? {
        guard let raw = header("Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let s = TimeInterval(raw), s >= 0 { return now.addingTimeInterval(s) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return f.date(from: raw)
    }

    var bodyExcerpt: String {
        let s = String(data: data, encoding: .utf8) ?? ""
        let one = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return one.count > 300 ? String(one.prefix(300)) + "…" : one
    }
}

public enum ProviderRegistry {
    /// All built-in providers, in display order.
    public static func all(claude: any ClaudeCredentialLoading = ClaudeCredentialLoader(),
                           codex: any CodexCredentialLoading = CodexCredentialLoader(),
                           grokBot: any GrokBotCredentialLoading = GrokBotCredentialLoader()) -> [any UsageProvider] {
        [ClaudeProvider(credentials: claude), CodexProvider(credentials: codex),
         DeepSeekProvider(), OpenCodeProvider(), ZaiProvider(), GrokBotProvider(credentials: grokBot)]
    }
}
