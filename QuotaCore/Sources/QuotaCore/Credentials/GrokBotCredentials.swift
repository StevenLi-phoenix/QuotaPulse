import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// The Grok Bot desktop app's session. It is an Electron app that keeps its Cursor-account tokens in
/// `~/Library/Application Support/Grok Bot/sand-secrets.json`, each value sealed with Electron `safeStorage`
/// (Chromium's scheme: AES-128-CBC, key = PBKDF2-SHA1 of the Keychain item "Grok Bot Safe Storage").
public struct GrokBotCredentials: Sendable, Equatable {
    public let accessToken: String
    /// `exp` claim of the access-token JWT.
    public let expiresAt: Date?

    public init(accessToken: String) {
        self.accessToken = accessToken
        self.expiresAt = DateParsing.epoch(JSON.number(JWT.claims(of: accessToken)?["exp"]))
    }

    public func isExpired(now: Date = Date(), leeway: TimeInterval = 30) -> Bool {
        guard let expiresAt else { return false }
        return now.addingTimeInterval(leeway) >= expiresAt
    }
}

public protocol GrokBotCredentialLoading: Sendable {
    func load() async throws -> GrokBotCredentials
}

public enum GrokBotSecrets {
    public static let keychainService = "Grok Bot Safe Storage"
    public static let keychainAccount = "Grok Bot Key"

    public enum ParseError: Error, Equatable, LocalizedError {
        case invalidJSON, noSession, undecryptable

        public var errorDescription: String? {
            switch self {
            case .invalidJSON: "Grok Bot's secrets file is not valid JSON."
            case .noSession: "Grok Bot is not signed in. Open Grok Bot and sign in."
            case .undecryptable: "Could not decrypt Grok Bot's session with its Keychain key."
            }
        }
    }

    /// Picks the active account's access token out of `sand-secrets.json` and decrypts it.
    /// Layout: `cursor-accounts` is a JSON string `{active, accounts: {<id>: {"cursor-access-token": <sealed>}}}`;
    /// an older layout keeps `cursor-access-token` at the top level. A sealed value is base64, optionally behind
    /// `scoped:v1:<account hash>:`, or `plaintext:v1:<token>` where the app could not use the Keychain.
    public static func accessToken(secretsFile: Data, safeStoragePassword: @autoclosure () throws -> Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: secretsFile) as? [String: Any] else { throw ParseError.invalidJSON }
        var sealed: String?
        if let accountsJSON = root["cursor-accounts"] as? String,
           let obj = try? JSONSerialization.jsonObject(with: Data(accountsJSON.utf8)) as? [String: Any],
           let accounts = obj["accounts"] as? [String: Any] {
            let active = obj["active"] as? String
            let account = (active.flatMap { accounts[$0] } ?? accounts.values.first) as? [String: Any]
            sealed = account?["cursor-access-token"] as? String
        }
        if sealed == nil { sealed = root["cursor-access-token"] as? String }
        guard let sealed, !sealed.isEmpty else { throw ParseError.noSession }

        if sealed.hasPrefix("plaintext:v1:") { return String(sealed.dropFirst("plaintext:v1:".count)) }
        var body = sealed
        if body.hasPrefix("scoped:v1:") {
            let parts = body.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4 else { throw ParseError.noSession }
            body = String(parts[3])
        }
        guard let blob = Data(base64Encoded: body) else { throw ParseError.undecryptable }
        let plain = try ChromiumSafeStorage.decrypt(blob, password: try safeStoragePassword())
        guard let token = String(data: plain, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw ParseError.undecryptable
        }
        return token
    }
}

/// Chromium / Electron `safeStorage` on macOS: `v10` + AES-128-CBC(PKCS7), key = PBKDF2-HMAC-SHA1(password, "saltysalt", 1003, 16),
/// IV = sixteen spaces.
enum ChromiumSafeStorage {
    static func decrypt(_ blob: Data, password: Data) throws -> Data {
        #if canImport(CommonCrypto)
        guard blob.count > 3, blob.prefix(3) == Data("v10".utf8) else { throw GrokBotSecrets.ParseError.undecryptable }
        let cipher = blob.dropFirst(3)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let derived = password.withUnsafeBytes { pw in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.bindMemory(to: Int8.self).baseAddress, password.count,
                                 salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        }
        guard derived == kCCSuccess else { throw GrokBotSecrets.ParseError.undecryptable }
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var out = [UInt8](repeating: 0, count: cipher.count + kCCBlockSizeAES128)
        var written = 0
        let status = cipher.withUnsafeBytes { src in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    key, key.count, iv, src.baseAddress, cipher.count, &out, out.count, &written)
        }
        guard status == kCCSuccess else { throw GrokBotSecrets.ParseError.undecryptable }
        return Data(out.prefix(written))
        #else
        throw GrokBotSecrets.ParseError.undecryptable
        #endif
    }
}

/// Reads the signed-in session of the local Grok Bot app. The Keychain item belongs to Grok Bot, so it is read through
/// `/usr/bin/security` with a hard timeout (a prompt can never hang the poll loop). Nothing is written back and the token is
/// never refreshed here: Grok Bot rotates its own, and a second refresher could sign it out.
public struct GrokBotCredentialLoader: GrokBotCredentialLoading {
    public var secretsURL: URL
    public var keychainTimeout: TimeInterval

    public init(home: URL = FileManager.default.qpHomeDirectory, keychainTimeout: TimeInterval = 5) {
        self.secretsURL = home.appendingPathComponent("Library/Application Support/Grok Bot/sand-secrets.json")
        self.keychainTimeout = keychainTimeout
    }

    public func load() async throws -> GrokBotCredentials {
        #if os(macOS)
        guard FileManager.default.fileExists(atPath: secretsURL.path) else {
            throw ProviderError.notConfigured("Grok Bot is not installed on this Mac.")
        }
        let file: Data
        do { file = try Data(contentsOf: secretsURL) } catch { throw ProviderError.notConfigured("Cannot read Grok Bot's session file: \(error.localizedDescription)") }
        let password: Data?
        do {
            password = try await ClaudeCredentialLoader.readKeychainViaSecurityCLI(service: GrokBotSecrets.keychainService,
                                                                                   account: GrokBotSecrets.keychainAccount, timeout: keychainTimeout)
        } catch {
            QPLog.credentials.notice("Grok Bot keychain read failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        do {
            let token = try GrokBotSecrets.accessToken(secretsFile: file, safeStoragePassword: try { guard let password else { throw GrokBotSecrets.ParseError.undecryptable }; return password }())
            let creds = GrokBotCredentials(accessToken: token)
            QPLog.credentials.debug("Grok Bot session read ok: token \(QPLog.redact(token), privacy: .public) expires \(creds.expiresAt.map { "\($0)" } ?? "n/a", privacy: .public)")
            return creds
        } catch let e as GrokBotSecrets.ParseError {
            throw e == .noSession ? ProviderError.notConfigured(e.localizedDescription) : ProviderError.unauthorized(e.localizedDescription)
        }
        #else
        throw ProviderError.notConfigured("Grok Bot is read on a Mac; this device gets it through iCloud.")
        #endif
    }
}
