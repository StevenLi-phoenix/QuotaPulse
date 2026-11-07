import Foundation
#if canImport(Security)
import Security
#endif

/// Where user-entered API keys live. The app's own Keychain items never prompt.
public protocol SecretStore: Sendable {
    func get(_ key: String) throws -> String?
    func set(_ value: String?, for key: String) throws
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    public init(_ values: [String: String] = [:]) { self.values = values }
    public func get(_ key: String) throws -> String? { lock.withLock { values[key] } }
    public func set(_ value: String?, for key: String) throws { lock.withLock { values[key] = value } }
}

#if canImport(Security)
/// Secrets go to iCloud Keychain, so every Mac on the account holds the same keys and tokens. Items are written to the
/// data-protection keychain as synchronizable; the legacy file keychain can't sync, so an item still there is moved on first read.
/// Where the synced write is refused (an unentitled build), the item is kept locally as before rather than lost.
public struct KeychainSecretStore: SecretStore {
    public let service: String
    public init(service: String = "app.lishuyu.quotapulse") { self.service = service }

    /// Matches one item. `synchronizable` nil matches either kind, for reads and deletes.
    static func itemQuery(service: String, key: String, protected: Bool, synchronizable: Bool?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        #if os(macOS)
        if protected { q[kSecUseDataProtectionKeychain as String] = true }
        #endif
        if let synchronizable { q[kSecAttrSynchronizable as String] = synchronizable }
        else { q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny }
        return q
    }

    private func read(_ query: [String: Any]) throws -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return String(data: data, encoding: .utf8)
    }

    public func get(_ key: String) throws -> String? {
        if let value = try? read(Self.itemQuery(service: service, key: key, protected: true, synchronizable: nil)) { return value }
        guard let legacy = try read(Self.itemQuery(service: service, key: key, protected: false, synchronizable: nil)) else { return nil }
        do {
            try set(legacy, for: key)
            QPLog.credentials.notice("moved \(key, privacy: .public) into iCloud Keychain")
        } catch {
            QPLog.credentials.error("could not move \(key, privacy: .public) into iCloud Keychain: \(error.localizedDescription, privacy: .public)")
        }
        return legacy
    }

    public func set(_ value: String?, for key: String) throws {
        // Clears both kinds first, so a stale local copy can't shadow the synced one.
        SecItemDelete(Self.itemQuery(service: service, key: key, protected: true, synchronizable: nil) as CFDictionary)
        SecItemDelete(Self.itemQuery(service: service, key: key, protected: false, synchronizable: false) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = Self.itemQuery(service: service, key: key, protected: true, synchronizable: true)
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { return }
        QPLog.credentials.error("synced keychain write refused (\(status)); keeping \(key, privacy: .public) on this Mac only")
        var local = Self.itemQuery(service: service, key: key, protected: false, synchronizable: false)
        local[kSecValueData as String] = Data(value.utf8)
        local[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let fallback = SecItemAdd(local as CFDictionary, nil)
        guard fallback == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(fallback)) }
    }
}
#endif

/// Secret keys used by providers.
public enum SecretKey {
    public static func apiKey(_ provider: ProviderID) -> String { "apikey.\(provider.rawValue)" }
    public static let hubToken = "hub.token"
    public static let pairedHubToken = "hub.paired.token"
    /// The gateway link as JSON (`GatewayConfig`). Mac side only; `gateway.json` is kept as a copy of it.
    public static let gatewayConfig = "gateway.config"
}
