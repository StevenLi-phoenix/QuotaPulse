import Foundation

/// Persisted, non-secret configuration (secrets live in `SecretStore`).
public struct ProviderSettings: Codable, Sendable, Hashable {
    public var enabled: Bool
    public var options: [String: String]

    public init(enabled: Bool, options: [String: String] = [:]) {
        self.enabled = enabled
        self.options = options
    }
}

public struct HubSettings: Codable, Sendable, Hashable {
    public var enabled: Bool
    public var port: UInt16
    /// Bind to all interfaces (reachable over Tailscale) vs. loopback only.
    public var exposeOnNetwork: Bool

    public init(enabled: Bool = true, port: UInt16 = 48422, exposeOnNetwork: Bool = true) {
        self.enabled = enabled
        self.port = port
        self.exposeOnNetwork = exposeOnNetwork
    }
}

public struct AlertSettings: Codable, Sendable, Hashable {
    public var enabled: Bool
    public var thresholds: [Double]

    public init(enabled: Bool = false, thresholds: [Double] = [80, 95]) {
        self.enabled = enabled
        self.thresholds = thresholds
    }
}

public struct AppSettings: Codable, Sendable, Hashable {
    public var providers: [ProviderID: ProviderSettings]
    public var pollInterval: TimeInterval
    public var hub: HubSettings
    public var alerts: AlertSettings
    /// Days of sample history to keep.
    public var retentionDays: Int
    public var launchAtLogin: Bool
    /// Menu-bar label style: "percent" | "icon" | "both".
    public var menuBarStyle: String

    public init(providers: [ProviderID: ProviderSettings]? = nil, pollInterval: TimeInterval = 5 * 60,
                hub: HubSettings = .init(), alerts: AlertSettings = .init(), retentionDays: Int = 30,
                launchAtLogin: Bool = false, menuBarStyle: String = "both") {
        self.providers = providers ?? Dictionary(uniqueKeysWithValues: ProviderID.allCases.map {
            ($0, ProviderSettings(enabled: $0.defaultEnabled))
        })
        self.pollInterval = pollInterval
        self.hub = hub
        self.alerts = alerts
        self.retentionDays = retentionDays
        self.launchAtLogin = launchAtLogin
        self.menuBarStyle = menuBarStyle
    }

    public static let `default` = AppSettings()

    public func isEnabled(_ id: ProviderID) -> Bool { providers[id]?.enabled ?? id.defaultEnabled }
    public func options(_ id: ProviderID) -> [String: String] { providers[id]?.options ?? [:] }

    public var enabledProviders: [ProviderID] { ProviderID.allCases.filter(isEnabled) }
}

/// Settings persistence as JSON next to the data (so the widget / CLI can read it too).
public struct SettingsStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() -> AppSettings {
        guard let data = try? Data(contentsOf: url) else { return .default }
        do { return try JSON.decoder.decode(AppSettings.self, from: data) } catch {
            QPLog.store.error("settings decode failed, using defaults: \(error.localizedDescription, privacy: .public)")
            return .default
        }
    }

    public func save(_ settings: AppSettings) {
        do { try FileIO.writeAtomically(try JSON.prettyEncoder.encode(settings), to: url) } catch {
            QPLog.store.error("settings save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
