import Foundation
import Testing
@testable import QuotaCore

/// A fresh data folder per test; nothing here touches the real keychain.
private func scratchLocation() throws -> DataLocation {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("qp-creds-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return DataLocation(root: root)
}

private func gatewayJSON(_ config: GatewayConfig) throws -> String {
    String(decoding: try JSON.encoder.encode(config), as: UTF8.self)
}

private func permissions(_ url: URL) throws -> Int? {
    try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
}

@Suite struct GatewayConfigStoreTests {
    @Test func aGatewayFileWithNoKeychainCopyIsImportedAndKept() throws {
        let location = try scratchLocation()
        let config = GatewayConfig(token: "file-token")
        try JSON.encoder.encode(config).write(to: location.gatewayURL)
        let secrets = InMemorySecretStore()

        #expect(GatewayConfigStore.current(file: location.gatewayURL, secrets: secrets) == config)
        #expect(try secrets.get(SecretKey.gatewayConfig).map { try JSON.decoder.decode(GatewayConfig.self, from: Data($0.utf8)) } == config)
        #expect(GatewayConfig.load(from: location.gatewayURL) == config, "the file stays for scripts and Windows")
    }

    /// The second Mac has no file; the synced keychain copy is enough to become a gateway client, and gets its file too.
    @Test func aKeychainCopyWritesTheFileOwnerOnly() throws {
        let location = try scratchLocation()
        let config = GatewayConfig(token: "synced-token")
        let secrets = InMemorySecretStore([SecretKey.gatewayConfig: try gatewayJSON(config)])

        #expect(GatewayConfigStore.current(file: location.gatewayURL, secrets: secrets) == config)
        #expect(GatewayConfig.load(from: location.gatewayURL) == config)
        #expect(try permissions(location.gatewayURL) == 0o600)
    }

    @Test func theKeychainCopyWinsOverAStaleFile() throws {
        let location = try scratchLocation()
        let synced = GatewayConfig(token: "synced-token")
        try JSON.encoder.encode(GatewayConfig(token: "old-token")).write(to: location.gatewayURL)
        let secrets = InMemorySecretStore([SecretKey.gatewayConfig: try gatewayJSON(synced)])

        #expect(GatewayConfigStore.current(file: location.gatewayURL, secrets: secrets) == synced)
        #expect(GatewayConfig.load(from: location.gatewayURL) == synced, "the file is rewritten from the keychain copy")
    }

    @Test func noCopyAnywhereMeansNoGatewayAndNoFile() throws {
        let location = try scratchLocation()
        #expect(GatewayConfigStore.current(file: location.gatewayURL, secrets: InMemorySecretStore()) == nil)
        #expect(!FileManager.default.fileExists(atPath: location.gatewayURL.path))
    }
}

@Suite struct KeychainQueryTests {
    @Test func writesAskForSynchronizedItems() throws {
        let q = KeychainSecretStore.itemQuery(service: "s", key: "apikey.deepseek", protected: true, synchronizable: true)
        #expect(q[kSecAttrSynchronizable as String] as? Bool == true)
        #expect(q[kSecAttrService as String] as? String == "s")
        #expect(q[kSecAttrAccount as String] as? String == "apikey.deepseek")
        #if os(macOS)
        #expect(q[kSecUseDataProtectionKeychain as String] as? Bool == true, "only the data-protection keychain syncs on macOS")
        #endif
    }

    @Test func readsMatchEitherKindSoALocalCopyIsStillFound() {
        let q = KeychainSecretStore.itemQuery(service: "s", key: "hub.token", protected: true, synchronizable: nil)
        #expect(q[kSecAttrSynchronizable as String] as? String == kSecAttrSynchronizableAny as String)
    }

    @Test func aLegacyLocalItemIsNotAskedToSync() {
        let q = KeychainSecretStore.itemQuery(service: "s", key: "hub.token", protected: false, synchronizable: false)
        #expect(q[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(q[kSecUseDataProtectionKeychain as String] == nil)
    }
}
