import BackgroundTasks
import Observation
import QuotaCore
import QuotaUI
import WatchConnectivity
import WidgetKit
import os

/// iPhone side: holds the hub pairing, polls the hub, caches for widgets and forwards to the watch.
@MainActor @Observable
final class ClientModel: NSObject {
    static let refreshTaskID = "app.lishuyu.quotapulse.refresh"
    static let pairingKey = "hub.pairing.v1"

    private(set) var snapshot: QuotaSnapshot
    private(set) var pairing: HubPairing?
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    private(set) var lastSuccessAt: Date?
    private(set) var histories: [ProviderID: [Sample]] = [:]
    private(set) var sparklines: [ProviderID: [Double]] = [:]
    let ticker = Ticker(interval: .seconds(20))

    private let location = DataLocation.standard()
    private let secrets = KeychainSecretStore()
    private let defaults = UserDefaults(suiteName: DataLocation.appGroupID) ?? .standard
    private var session: WCSession?

    override init() {
        snapshot = SnapshotStore(url: location.snapshotURL).load() ?? .empty
        super.init()
        pairing = Self.loadPairing(defaults: defaults, secrets: secrets)
        if WCSession.isSupported() {
            session = WCSession.default
            session?.delegate = self
            session?.activate()
        }
        Task { await refresh(reason: "launch") }
    }

    // MARK: Pairing

    static func loadPairing(defaults: UserDefaults, secrets: any SecretStore) -> HubPairing? {
        guard let data = defaults.data(forKey: pairingKey),
              var p = try? JSON.decoder.decode(HubPairing.self, from: data) else { return nil }
        if let t = try? secrets.get(SecretKey.pairedHubToken), !t.isEmpty { p.token = t }
        return p.token.isEmpty ? nil : p
    }

    func pair(_ p: HubPairing) {
        var stored = p
        try? secrets.set(p.token, for: SecretKey.pairedHubToken)
        stored.token = "" // never on disk in plaintext
        defaults.set(try? JSON.encoder.encode(stored), forKey: Self.pairingKey)
        pairing = p
        lastError = nil
        QPLog.hub.info("paired with \(p.hubName, privacy: .public) at \(p.baseURL.absoluteString, privacy: .public)")
        pushToWatch()
        Task { await refresh(reason: "paired") }
    }

    func unpair() {
        defaults.removeObject(forKey: Self.pairingKey)
        try? secrets.set(nil, for: SecretKey.pairedHubToken)
        pairing = nil
        snapshot = .empty
        try? SnapshotStore(url: location.snapshotURL).save(.empty)
        WidgetCenter.shared.reloadAllTimelines()
    }

    func handle(url: URL) {
        if let p = HubPairing.parse(url) { pair(p) }
    }

    /// Validates a pairing by hitting /v1/health; returns an error message or nil.
    func test(_ p: HubPairing) async -> String? {
        do {
            let h = try await HubClient(pairing: p).health()
            return h.ok ? nil : "Hub reported not OK"
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Refresh

    func refresh(reason: String) async {
        guard let pairing, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let client = HubClient(pairing: pairing)
        do {
            let snap = try await client.snapshot()
            snapshot = snap
            lastSuccessAt = Date()
            lastError = nil
            try? SnapshotStore(url: location.snapshotURL).save(snap)
            WidgetCenter.shared.reloadAllTimelines()
            pushToWatch()
            QPLog.hub.info("refresh ok (\(reason, privacy: .public)): \(snap.providers.count) providers")
            await loadSparklines(client: client)
        } catch {
            lastError = error.localizedDescription
            QPLog.hub.notice("refresh failed (\(reason, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadSparklines(client: HubClient) async {
        var all: [Sample] = []
        var h: [ProviderID: [Sample]] = [:]
        for p in snapshot.providers {
            if let hist = try? await client.history(p.id, hours: 24) {
                h[p.id] = hist.samples
                all += hist.samples
            }
        }
        histories = h
        sparklines = Derive.sparklines(samples: all, snapshot: snapshot)
    }

    func history(_ provider: ProviderID, hours: Double) async -> [Sample] {
        guard let pairing else { return [] }
        return (try? await HubClient(pairing: pairing).history(provider, hours: hours).samples) ?? []
    }

    // MARK: Background refresh

    func scheduleBackgroundRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do { try BGTaskScheduler.shared.submit(req) } catch {
            QPLog.hub.notice("bg schedule failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated static func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        let work = Task { @MainActor in
            let location = DataLocation.standard()
            guard let pairing = loadPairing(defaults: UserDefaults(suiteName: DataLocation.appGroupID) ?? .standard, secrets: KeychainSecretStore()) else {
                task.setTaskCompleted(success: false); return
            }
            do {
                let snap = try await HubClient(pairing: pairing).snapshot()
                try? SnapshotStore(url: location.snapshotURL).save(snap)
                WidgetCenter.shared.reloadAllTimelines()
                task.setTaskCompleted(success: true)
            } catch {
                task.setTaskCompleted(success: false)
            }
            let req = BGAppRefreshTaskRequest(identifier: refreshTaskID)
            req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
            try? BGTaskScheduler.shared.submit(req)
        }
        task.expirationHandler = { work.cancel() }
    }

    // MARK: Watch

    func pushToWatch() {
        guard let session, session.activationState == .activated else { return }
        var context: [String: Any] = [:]
        if let data = try? JSON.encoder.encode(snapshot) { context["snapshot"] = data }
        if let pairing, let data = try? JSON.encoder.encode(pairing) { context["pairing"] = data }
        do {
            try session.updateApplicationContext(context)
            if session.isComplicationEnabled, let data = context["snapshot"] {
                session.transferCurrentComplicationUserInfo(["snapshot": data])
            }
        } catch {
            QPLog.hub.notice("watch push failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension ClientModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.pushToWatch() }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        // Watch asks for the latest data.
        Task { @MainActor in
            var reply: [String: Any] = [:]
            if let data = try? JSON.encoder.encode(self.snapshot) { reply["snapshot"] = data }
            if let p = self.pairing, let data = try? JSON.encoder.encode(p) { reply["pairing"] = data }
            replyHandler(reply)
        }
    }
}
