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

public struct CloudSettings: Codable, Sendable, Hashable {
    /// Publish snapshots and history to the user's private iCloud database.
    public var enabled: Bool

    public init(enabled: Bool = true) {
        self.enabled = enabled
    }
}

public struct AppSettings: Codable, Sendable, Hashable {
    public var providers: [ProviderID: ProviderSettings]
    public var pollInterval: TimeInterval
    public var hub: HubSettings
    public var cloud: CloudSettings
    public var alerts: AlertSettings
    /// Days of sample history to keep.
    public var retentionDays: Int
    public var launchAtLogin: Bool
    /// Menu-bar label style: "percent" | "icon" | "both".
    public var menuBarStyle: String
    /// The first refresh with a gateway link turned DeepSeek and OpenCode on; after that the user's toggles rule.
    public var gatewaySeeded: Bool
    /// GLM was switched on because the gateway started reading it. Once only, so turning it off again stays off.
    public var gatewayZaiSeeded: Bool

    public init(providers: [ProviderID: ProviderSettings]? = nil, pollInterval: TimeInterval = 5 * 60,
                hub: HubSettings = .init(), cloud: CloudSettings = .init(), alerts: AlertSettings = .init(), retentionDays: Int = 30,
                launchAtLogin: Bool = false, menuBarStyle: String = "both", gatewaySeeded: Bool = false, gatewayZaiSeeded: Bool = false) {
        self.providers = providers ?? Dictionary(uniqueKeysWithValues: ProviderID.allCases.map {
            ($0, ProviderSettings(enabled: $0.defaultEnabled))
        })
        self.pollInterval = pollInterval
        self.hub = hub
        self.cloud = cloud
        self.alerts = alerts
        self.retentionDays = retentionDays
        self.launchAtLogin = launchAtLogin
        self.menuBarStyle = menuBarStyle
        self.gatewaySeeded = gatewaySeeded
        self.gatewayZaiSeeded = gatewayZaiSeeded
    }

    enum CodingKeys: String, CodingKey { case providers, pollInterval, hub, cloud, alerts, retentionDays, launchAtLogin, menuBarStyle, gatewaySeeded, gatewayZaiSeeded }

    /// `cloud` arrived in 0.3: settings written before it must keep every other value.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providers = try c.decode([ProviderID: ProviderSettings].self, forKey: .providers)
        pollInterval = try c.decode(TimeInterval.self, forKey: .pollInterval)
        hub = try c.decode(HubSettings.self, forKey: .hub)
        cloud = try c.decodeIfPresent(CloudSettings.self, forKey: .cloud) ?? CloudSettings()
        alerts = try c.decode(AlertSettings.self, forKey: .alerts)
        retentionDays = try c.decode(Int.self, forKey: .retentionDays)
        launchAtLogin = try c.decode(Bool.self, forKey: .launchAtLogin)
        menuBarStyle = try c.decode(String.self, forKey: .menuBarStyle)
        gatewaySeeded = try c.decodeIfPresent(Bool.self, forKey: .gatewaySeeded) ?? false
        gatewayZaiSeeded = try c.decodeIfPresent(Bool.self, forKey: .gatewayZaiSeeded) ?? false
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
