import Foundation

/// Claude Code's OAuth credential blob (`{"claudeAiOauth": {...}}`).
public struct ClaudeCredentials: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let scopes: [String]
    public let rateLimitTier: String?
    public let subscriptionType: String?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date?, scopes: [String],
                rateLimitTier: String?, subscriptionType: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.rateLimitTier = rateLimitTier
        self.subscriptionType = subscriptionType
    }

    public func isExpired(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return now.addingTimeInterval(leeway) >= expiresAt
    }

    /// Human plan label ("Max 20x", "Pro"…), derived from non-secret metadata.
    public var planLabel: String? {
        if let tier = rateLimitTier {
            // default_claude_max_20x → Max 20x
            let parts = tier.replacingOccurrences(of: "default_claude_", with: "").split(separator: "_")
            if !parts.isEmpty {
                return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            }
        }
        return subscriptionType?.capitalized
    }

    public enum ParseError: Error, Equatable, LocalizedError {
        case invalidJSON
        case missingOAuth
        case missingAccessToken

        public var errorDescription: String? {
            switch self {
            case .invalidJSON: "Claude credentials are not valid JSON."
            case .missingOAuth: "Claude credentials contain no claudeAiOauth entry. Run `claude` to sign in."
            case .missingAccessToken: "Claude credentials contain no access token."
            }
        }
    }

    public static func parse(_ data: Data) throws -> ClaudeCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.invalidJSON
        }
        guard let oauth = root["claudeAiOauth"] as? [String: Any] else { throw ParseError.missingOAuth }
        let token = (oauth["accessToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else { throw ParseError.missingAccessToken }
        return ClaudeCredentials(
            accessToken: token,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: DateParsing.epoch(JSON.number(oauth["expiresAt"])),
            scopes: oauth["scopes"] as? [String] ?? [],
            rateLimitTier: oauth["rateLimitTier"] as? String,
            subscriptionType: oauth["subscriptionType"] as? String)
    }
}

public enum ClaudeCredentialSource: String, Codable, Sendable, CaseIterable {
    case keychain, file, environment
}

public struct ClaudeCredentialRecord: Sendable {
    public let credentials: ClaudeCredentials
    public let source: ClaudeCredentialSource
}

public protocol ClaudeCredentialLoading: Sendable {
    /// Returns the freshest credential available, or throws `ProviderError.notConfigured`.
    func load() async throws -> ClaudeCredentialRecord
}

/// Reads Claude Code credentials: Keychain (via `/usr/bin/security`, the same CLI Claude Code writes with,
/// so no ACL prompt), then `$CLAUDE_CONFIG_DIR/.credentials.json` / `~/.claude/.credentials.json`,
/// then `QUOTAPULSE_CLAUDE_TOKEN`. When several are present the one that expires last wins.
public struct ClaudeCredentialLoader: ClaudeCredentialLoading {
    public static let keychainService = "Claude Code-credentials"
    public static let environmentTokenKey = "QUOTAPULSE_CLAUDE_TOKEN"

    public var environment: [String: String]
    public var home: URL
    public var allowKeychain: Bool
    public var keychainTimeout: TimeInterval

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                allowKeychain: Bool = true,
                keychainTimeout: TimeInterval = 3) {
        self.environment = environment
        self.home = home
        self.allowKeychain = allowKeychain
        self.keychainTimeout = keychainTimeout
    }

    public var credentialsFileURL: URL {
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent(".credentials.json")
        }
        return home.appendingPathComponent(".claude/.credentials.json")
    }

    public func load() async throws -> ClaudeCredentialRecord {
        var candidates: [ClaudeCredentialRecord] = []
        var problems: [String] = []

        if let token = environment[Self.environmentTokenKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            candidates.append(.init(credentials: ClaudeCredentials(accessToken: token, refreshToken: nil, expiresAt: nil,
                                                                    scopes: [], rateLimitTier: nil, subscriptionType: nil),
                                    source: .environment))
        }

        #if os(macOS)
        if allowKeychain {
            do {
                if let data = try await Self.readKeychainViaSecurityCLI(service: Self.keychainService, timeout: keychainTimeout) {
                    let creds = try ClaudeCredentials.parse(data)
                    QPLog.credentials.debug("Claude keychain read ok: token \(QPLog.redact(creds.accessToken), privacy: .public) expires \(creds.expiresAt.map { "\($0)" } ?? "n/a", privacy: .public)")
                    candidates.append(.init(credentials: creds, source: .keychain))
                }
            } catch {
                problems.append("keychain: \(error.localizedDescription)")
                QPLog.credentials.notice("Claude keychain read failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        #endif

        let fileURL = credentialsFileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let creds = try ClaudeCredentials.parse(Data(contentsOf: fileURL))
                QPLog.credentials.debug("Claude file read ok: token \(QPLog.redact(creds.accessToken), privacy: .public)")
                candidates.append(.init(credentials: creds, source: .file))
            } catch {
                problems.append("file: \(error.localizedDescription)")
            }
        }

        guard !candidates.isEmpty else {
            let detail = problems.isEmpty ? "No Claude Code credentials found. Run `claude` and sign in." : problems.joined(separator: "; ")
            throw ProviderError.notConfigured(detail)
        }
        // Prefer the freshest (latest expiry); unknown expiry (env token) sorts last.
        let best = candidates.max { a, b in
            (a.credentials.expiresAt ?? .distantPast) < (b.credentials.expiresAt ?? .distantPast)
        }!
        return best
    }

    #if os(macOS)
    /// Runs `/usr/bin/security find-generic-password -s <service> -w` with a hard timeout so a
    /// hypothetical ACL dialog can never hang the poll loop (killing the process dismisses it).
    static func readKeychainViaSecurityCLI(service: String, timeout: TimeInterval) async throws -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning {
            process.terminate()
            throw ProviderError.network("security CLI timed out after \(Int(timeout))s (possible Keychain prompt)")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            // 44 = item not found; treat as absent rather than an error.
            if process.terminationStatus == 44 { return nil }
            throw ProviderError.network("security CLI exited \(process.terminationStatus)")
        }
        var trimmed = data
        while let last = trimmed.last, last == 0x0A || last == 0x0D { trimmed.removeLast() }
        return trimmed.isEmpty ? nil : trimmed
    }
    #endif
}
