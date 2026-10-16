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
public struct KeychainSecretStore: SecretStore {
    public let service: String
    public init(service: String = "app.lishuyu.quotapulse") { self.service = service }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    public func get(_ key: String) throws -> String? {
        var q = query(key)
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

    public func set(_ value: String?, for key: String) throws {
        let q = query(key)
        SecItemDelete(q as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
#endif

/// Secret keys used by providers.
public enum SecretKey {
    public static func apiKey(_ provider: ProviderID) -> String { "apikey.\(provider.rawValue)" }
    public static let hubToken = "hub.token"
    public static let pairedHubToken = "hub.paired.token"
}
