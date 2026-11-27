import AppKit
import Observation
import QuotaCore
import QuotaUI
import ServiceManagement
import UserNotifications
import WidgetKit

/// Main-actor façade over the engine, hub server and alerts. Views observe this; the engine does the work.
@MainActor @Observable
final class AppModel {
    private(set) var snapshot: QuotaSnapshot = .empty
    private(set) var settings: AppSettings = .default
    private(set) var isRefreshing = false
    private(set) var histories: [ProviderID: [Sample]] = [:]
    private(set) var sparklines: [ProviderID: [Double]] = [:]
    private(set) var hubState = "stopped"
    private(set) var cloudStatus = CloudPublishStatus()
    private(set) var pairing: HubPairing?
    private(set) var hubAddresses: [String] = []
    private(set) var apiKeyPresence: [ProviderID: Bool] = [:]
    /// The providers this Mac can read, in display order (Settings lists these; other devices show whatever iCloud has).
    var lineup: [ProviderDescriptor] { engine.lineup }
    var enabledProviders: [ProviderID] { settings.enabledProviders(in: lineup) }
    func isEnabled(_ id: ProviderID) -> Bool { lineup.first { $0.id == id }.map { settings.isEnabled($0) } ?? false }
    /// `gateway.json` exists: DeepSeek and OpenCode come from the gateway, so no key is asked for.
    private(set) var gatewayActive = false
    private(set) var devices: [TelemetryStore.DeviceRecord] = []
    private(set) var lastRefreshAt: Date?
    private(set) var sampleCount = 0
    /// Section requested via `quotapulse://open?section=history` (deep links, screenshots).
    var requestedSection: String?
    /// True until the user dismisses the "I live in the menu bar" tip.
    var showsMenuBarTip: Bool {
        get { !UserDefaults.standard.bool(forKey: "tip.menuBar.dismissed") }
        set { UserDefaults.standard.set(!newValue, forKey: "tip.menuBar.dismissed") }
    }
    var isFirstLaunch: Bool { !UserDefaults.standard.bool(forKey: "launched.before") }
    var showInDock: Bool {
        get { UserDefaults.standard.bool(forKey: "showInDock") }
        set {
            UserDefaults.standard.set(newValue, forKey: "showInDock")
            Self.applyActivationPolicy(showInDock: newValue)
        }
    }

    static func applyActivationPolicy(showInDock: Bool) {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        if showInDock { NSApp.activate(ignoringOtherApps: true) }
    }

    func markLaunched() { UserDefaults.standard.set(true, forKey: "launched.before") }
    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    var notificationsAuthorized = false

    let ticker = Ticker(interval: .seconds(20))
    private let engine: QuotaEngine
    private let cloud: CloudPublisher?
    private let secrets: any SecretStore
    private let location: DataLocation
    private var hub: HubServer?
    private var alertedThresholds: [String: Double] = [:]

    init() {
        DataLocation.migrateLegacyIfNeeded()
        let location = DataLocation.standard()
        let secrets = KeychainSecretStore()
        self.location = location
        self.secrets = secrets
        let engine = QuotaEngine(location: location, secrets: secrets, hubName: Host.current().localizedName ?? "Mac")
        self.engine = engine
        self.cloud = CloudKitRecordStore.standard().map { store in
            CloudPublisher(store: store,
                           history: { provider, since in await engine.rawHistory(provider: provider, since: since) },
                           absorb: { samples, cutoffs in await engine.absorbSamples(samples, cutoffs: cutoffs) })
        }
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        settings = await engine.settings
        snapshot = await engine.snapshot
        refreshAPIKeyPresence()
        refreshGatewayState()
        await engine.setOnUpdate { [weak self] snap in
            Task { @MainActor in self?.apply(snap) }
        }
        await startHubIfNeeded()
        await engine.start()
        QPLog.ui.info("app bootstrapped")
        if UserDefaults.standard.bool(forKey: "QPCloudProbe") { Task.detached { await Self.probeCloud() } }
    }

    /// `open -n QuotaPulse.app --args -QPCloudProbe YES`: reads iCloud the way the iPhone does and logs what it would show.
    /// Read-only; for checking that a provider this Mac publishes reaches the other devices.
    private nonisolated static func probeCloud() async {
        guard let store = CloudKitRecordStore.standard() else { return }
        let reader = CloudReader(store: store)
        try? await Task.sleep(for: .seconds(20)) // let the first refresh publish
        let started = Date()
        do {
            let snap = try await reader.snapshot()
            let shown = snap?.providers.map { "\($0.id.rawValue)=\($0.display.displayName)\($0.info == nil ? "(fallback)" : "")" } ?? []
            QPLog.cloud.notice("cloud probe: a reader shows [\(shown.joined(separator: ", "), privacy: .public)] in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        } catch {
            QPLog.cloud.error("cloud probe: read failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshGatewayState() {
        gatewayActive = GatewayConfigStore.current(file: location.gatewayURL, secrets: secrets) != nil
    }

    private func apply(_ snap: QuotaSnapshot) {
        refreshGatewayState()
        Task { settings = await engine.settings }
        snapshot = snap
        lastRefreshAt = snap.generatedAt == .distantPast ? nil : snap.generatedAt
        WidgetCenter.shared.reloadAllTimelines()
        Task { await reloadHistories() }
        evaluateAlerts(snap)
        publishToCloud(snap)
    }

    private func publishToCloud(_ snap: QuotaSnapshot, force: Bool = false, clearHistory: Bool = false) {
        guard settings.cloud.enabled, let cloud else { return }
        Task {
            cloudStatus = await cloud.publish(snap, force: force, clearHistory: clearHistory)
            await reloadHistories() // the pass may have taken in points other Macs sampled
            // Settings are one set for the account: take iCloud's copy when it is newer, otherwise push ours when we changed them.
            if let adopted = await cloud.reconcileSettings(settings, hubName: snap.hubName) {
                await engine.adopt(adopted)
                settings = adopted
            }
        }
    }

    func reloadHistories() async {
        var h: [ProviderID: [Sample]] = [:]
        for p in snapshot.providers {
            h[p.id] = await engine.history(provider: p.id, hours: 24, maxPoints: 120)
        }
        histories = h
        sparklines = Derive.sparklines(samples: h.values.flatMap { $0 }, snapshot: snapshot)
        sampleCount = await engine.sampleCount()
    }

    func history(for provider: ProviderID, hours: Double) async -> [Sample] {
        await engine.history(provider: provider, hours: hours)
    }

    // MARK: Actions

    func refreshNow() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        _ = await engine.refresh(reason: "user", force: true)
    }

    func setEnabled(_ provider: ProviderID, _ enabled: Bool) {
        Task {
            await engine.update { $0.providers[provider, default: ProviderSettings(enabled: enabled)].enabled = enabled }
            settings = await engine.settings
            if enabled { _ = await engine.refresh(reason: "provider enabled", force: true) }
        }
    }

    func setOption(_ provider: ProviderID, key: String, value: String?) {
        let on = isEnabled(provider) // an option set before the first toggle must not flip the provider
        Task {
            await engine.update {
                var s = $0.providers[provider] ?? ProviderSettings(enabled: on)
                s.options[key] = value
                $0.providers[provider] = s
            }
            settings = await engine.settings
        }
    }

    func setAPIKey(_ provider: ProviderID, _ key: String) {
        Task {
            try? await engine.setAPIKey(key.isEmpty ? nil : key, for: provider)
            refreshAPIKeyPresence()
            if !key.isEmpty {
                await engine.update { $0.providers[provider, default: ProviderSettings(enabled: true)].enabled = true }
                settings = await engine.settings
                _ = await engine.refresh(reason: "key set", force: true)
            }
        }
    }

    private func refreshAPIKeyPresence() {
        var p: [ProviderID: Bool] = [:]
        for id in lineup.filter(\.usesAPIKey).map(\.id) {
            p[id] = ((try? secrets.get(SecretKey.apiKey(id))) ?? nil)?.isEmpty == false
        }
        apiKeyPresence = p
    }

    func setPollInterval(_ seconds: TimeInterval) {
        Task { await engine.update { $0.pollInterval = seconds }; settings = await engine.settings }
    }

    func setRetention(_ days: Int) {
        Task { await engine.update { $0.retentionDays = days }; settings = await engine.settings }
    }

    func clearHistory() {
        Task {
            await engine.clearHistory()
            await reloadHistories()
            publishToCloud(snapshot, clearHistory: true) // deleted history must leave iCloud too, and stay gone on every Mac
        }
    }

    // MARK: iCloud

    /// False in builds without the iCloud entitlement (unsigned dev builds).
    var cloudAvailable: Bool { cloud != nil }

    func setCloudSync(enabled: Bool) {
        Task {
            await engine.update { $0.cloud.enabled = enabled }
            settings = await engine.settings
            if enabled { publishToCloud(snapshot, force: true) }
        }
    }

    func removeCloudData() {
        guard let cloud else { return }
        Task {
            try? await cloud.removeAll()
            cloudStatus = await cloud.status
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            QPLog.ui.error("launch at login failed: \(error.localizedDescription, privacy: .public)")
        }
        Task { await engine.update { $0.launchAtLogin = on }; settings = await engine.settings }
    }

    // MARK: Hub

    var hubToken: String? { (try? secrets.get(SecretKey.hubToken)) ?? nil }

    private func ensureHubToken() -> String {
        if let t = hubToken, !t.isEmpty { return t }
        let t = HubPairing.randomToken()
        try? secrets.set(t, for: SecretKey.hubToken)
        return t
    }

    func regenerateHubToken() {
        try? secrets.set(HubPairing.randomToken(), for: SecretKey.hubToken)
        Task { await startHubIfNeeded() }
    }

    func setHub(enabled: Bool? = nil, port: UInt16? = nil, expose: Bool? = nil) {
        Task {
            await engine.update {
                if let enabled { $0.hub.enabled = enabled }
                if let port { $0.hub.port = port }
                if let expose { $0.hub.exposeOnNetwork = expose }
            }
            settings = await engine.settings
            await startHubIfNeeded()
        }
    }

    private func startHubIfNeeded() async {
        hub?.stop()
        hub = nil
        hubAddresses = HubServer.localIPv4Addresses()
        guard settings.hub.enabled else {
            hubState = "disabled"; pairing = nil
            try? FileManager.default.removeItem(at: location.hubPairingURL)
            return
        }
        let token = ensureHubToken()
        let engine = self.engine
        let store = TelemetryStore(root: telemetryFolder)
        let router = HubRouter(token: token, hubName: snapshot.hubName.isEmpty ? (Host.current().localizedName ?? "Mac") : snapshot.hubName,
                               snapshot: { await engine.snapshot },
                               history: { p, h in await engine.history(provider: p, hours: h) },
                               telemetry: { lines, identity in
                                   do {
                                       let n = try store.ingest(lines: lines, identity: identity)
                                       QPLog.hub.notice("telemetry: \(n) lines from \(identity.name, privacy: .public) (\(identity.platform, privacy: .public) \(identity.appVersion, privacy: .public))")
                                       return n
                                   } catch {
                                       QPLog.hub.error("telemetry ingest failed: \(error.localizedDescription, privacy: .public)")
                                       return nil
                                   }
                               })
        let server = HubServer(port: settings.hub.port, exposeOnNetwork: settings.hub.exposeOnNetwork, router: router)
        do {
            try server.start()
            hub = server
            let host = settings.hub.exposeOnNetwork ? (hubAddresses.first ?? "127.0.0.1") : "127.0.0.1"
            let p = HubPairing(baseURL: URL(string: "http://\(host):\(settings.hub.port)")!, token: token, hubName: router.hubName)
            pairing = p
            // Local pairing file (0600) so scripts on this Mac can call the hub without the GUI.
            if let data = try? JSON.prettyEncoder.encode(p) {
                try? FileIO.writeAtomically(data, to: location.hubPairingURL)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: location.hubPairingURL.path)
            }
            try? await Task.sleep(for: .milliseconds(200))
            hubState = server.state
        } catch {
            hubState = "failed: \(error.localizedDescription)"
        }
    }

    func pairingURL(forHost host: String) -> URL? {
        guard let token = hubToken else { return nil }
        return HubPairing(baseURL: URL(string: "http://\(host):\(settings.hub.port)")!, token: token, hubName: pairing?.hubName ?? "Mac").pairingURL
    }

    // MARK: Alerts

    func setAlerts(enabled: Bool? = nil, thresholds: [Double]? = nil) {
        Task {
            if enabled == true { await requestNotificationPermission() }
            await engine.update {
                if let enabled { $0.alerts.enabled = enabled }
                if let thresholds { $0.alerts.thresholds = thresholds.sorted() }
            }
            settings = await engine.settings
        }
    }

    private func requestNotificationPermission() async {
        do {
            notificationsAuthorized = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            QPLog.ui.error("notification auth failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func evaluateAlerts(_ snap: QuotaSnapshot) {
        guard settings.alerts.enabled else { return }
        for p in snap.providers where p.status.isOK {
            for w in p.windows {
                let key = "\(p.id.rawValue).\(w.id)"
                let last = alertedThresholds[key] ?? 0
                if w.utilization + 5 < last { alertedThresholds[key] = 0 } // window reset
                for t in settings.alerts.thresholds where w.utilization >= t && last < t {
                    alertedThresholds[key] = t
                    let content = UNMutableNotificationContent()
                    content.title = L("\(p.localizedName) \(w.localizedTitle): \(QuotaFormat.percent(w.utilization)) used")
                    content.body = Present.resetText(w)
                    if let out = Present.outText(window: w, forecast: p.forecasts[w.id]) { content.body += " · " + out }
                    content.sound = .default
                    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(key).\(Int(t))", content: content, trigger: nil))
                }
            }
        }
    }

    // MARK: Devices (telemetry from iPhone / Watch)

    var telemetryFolder: URL { location.root.appendingPathComponent("telemetry", isDirectory: true) }

    func reloadDevices() { devices = TelemetryStore(root: telemetryFolder).devices() }

    func revealTelemetry(_ device: TelemetryStore.DeviceRecord? = nil) {
        let url = device.map { telemetryFolder.appendingPathComponent(DeviceIdentity(name: $0.name, appVersion: "", platform: "").folderName, isDirectory: true) } ?? telemetryFolder
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Misc

    var dataFolder: URL { location.root }

    func revealDataFolder() { NSWorkspace.shared.activateFileViewerSelecting([location.snapshotURL]) }

    func quit() { NSApplication.shared.terminate(nil) }
}
