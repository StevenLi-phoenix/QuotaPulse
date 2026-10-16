import BackgroundTasks
import Observation
import QuotaCore
import QuotaUI
import WatchConnectivity
import WidgetKit
import os

/// Carries non-Sendable framework objects (BGTask, reply handlers) across an actor hop we control.
struct UncheckedBox<T>: @unchecked Sendable { let value: T }

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
    private(set) var lastTelemetryUpload: (at: Date, count: Int, error: String?)?
    let ticker = Ticker(interval: .seconds(20))
    let logger: FileLogger
    private var diagnostics: DiagnosticsCollector?

    private let location = DataLocation.standard()
    private let secrets = KeychainSecretStore()
    private let defaults = UserDefaults(suiteName: DataLocation.appGroupID) ?? .standard
    private var session: WCSession?

    override init() {
        snapshot = SnapshotStore(url: location.snapshotURL).load() ?? .empty
        let identity = DeviceIdentityFactory.current(platform: "iOS")
        logger = FileLogger(directory: DiagnosticsPaths.logs, identity: identity)
        super.init()
        diagnostics = DiagnosticsCollector(logger: logger)
        logger.notice("app", "launch", ["device": identity.name, "version": identity.appVersion])
        pairing = Self.loadPairing(defaults: defaults, secrets: secrets)
        // Automation hook (simulator / CI): QUOTAPULSE_PAIRING_URL=quotapulse://pair?url=…&token=…
        if let raw = ProcessInfo.processInfo.environment["QUOTAPULSE_PAIRING_URL"], let url = URL(string: raw), let p = HubPairing.parse(url) {
            var stored = p
            try? secrets.set(p.token, for: SecretKey.pairedHubToken)
            stored.token = ""
            defaults.set(try? JSON.encoder.encode(stored), forKey: Self.pairingKey)
            pairing = p
        }
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
        logger.notice("pairing", "paired", ["hub": p.hubName, "url": p.baseURL.absoluteString])
        pushToWatch()
        Task { await refresh(reason: "paired") }
    }

    func unpair() {
        logger.notice("pairing", "unpaired", ["hub": pairing?.hubName ?? "-"])
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
            if !h.ok { logger.error("pairing", "test.failed", ["hub": p.hubName, "reason": "not ok"]) }
            return h.ok ? nil : "Hub reported not OK"
        } catch {
            logger.error("pairing", "test.failed", ["hub": p.hubName, "url": p.baseURL.absoluteString, "error": error.localizedDescription])
            return error.localizedDescription
        }
    }

    // MARK: Refresh

    func refresh(reason: String) async {
        guard let pairing, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let client = HubClient(pairing: pairing)
        let started = Date()
        do {
            let snap = try await client.snapshot()
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            snapshot = snap
            lastSuccessAt = Date()
            lastError = nil
            try? SnapshotStore(url: location.snapshotURL).save(snap)
            WidgetCenter.shared.reloadAllTimelines()
            logger.info("widget", "reload.requested", ["reason": reason])
            pushToWatch()
            QPLog.hub.info("refresh ok (\(reason, privacy: .public)): \(snap.providers.count) providers")
            logger.info("hub", "fetch.ok", ["reason": reason, "ms": "\(ms)", "providers": "\(snap.providers.count)",
                                           "generatedAt": ISO8601DateFormatter().string(from: snap.generatedAt),
                                           "statuses": snap.providers.map { "\($0.id.rawValue):\($0.status.shortLabel)" }.joined(separator: ",")])
            logForecasts(snap)
            await loadSparklines(client: client)
            await syncTelemetry(client: client)
        } catch {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            lastError = error.localizedDescription
            QPLog.hub.notice("refresh failed (\(reason, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            logger.error("hub", "fetch.failed", ["reason": reason, "ms": "\(ms)", "error": error.localizedDescription])
        }
    }

    private func logForecasts(_ snap: QuotaSnapshot) {
        for p in snap.providers {
            var f: [String: String] = [:]
            for (w, fc) in p.forecasts {
                f[w] = "\(fc.confidence.rawValue) rate=\(String(format: "%.2f", fc.rate))" + (fc.exhaustionAt.map { " out=\(ISO8601DateFormatter().string(from: $0))" } ?? "")
            }
            if !f.isEmpty { f["provider"] = p.id.rawValue; logger.info("forecast", "summary", f) }
        }
    }

    /// Ships pending log lines to the hub; failures are recorded locally, never thrown at the UI.
    func syncTelemetry(client: HubClient? = nil) async {
        guard let client = client ?? pairing.map({ HubClient(pairing: $0) }) else { return }
        let r = await client.syncTelemetry(from: logger)
        lastTelemetryUpload = (Date(), r.uploaded, r.error)
        if let e = r.error { logger.error("hub", "telemetry.upload.failed", ["error": e]) }
    }

    var pendingTelemetryLines: Int { logger.pendingLineCount }

    private func loadSparklines(client: HubClient) async {
        var all: [Sample] = []
        var h: [ProviderID: [Sample]] = [:]
        for p in snapshot.providers {
            if let hist = try? await client.history(p.id, hours: 24) {
                h[p.id] = hist.samples
                all += hist.samples
            }
        }
        logger.info("hub", "history.ok", ["samples": "\(all.count)"])
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
        do {
            try BGTaskScheduler.shared.submit(req)
            logger.info("bg", "refresh.scheduled", ["earliest": "+15m"])
        } catch {
            QPLog.hub.notice("bg schedule failed: \(error.localizedDescription, privacy: .public)")
            logger.error("bg", "refresh.schedule.failed", ["error": error.localizedDescription])
        }
    }

    nonisolated static func handleBackgroundRefresh(_ bgTask: BGAppRefreshTask) {
        let boxed = UncheckedBox(value: bgTask)
        let work = Task { @MainActor in
            let task = boxed.value
            let location = DataLocation.standard()
            let logger = FileLogger(directory: DiagnosticsPaths.logs, identity: DeviceIdentityFactory.current(platform: "iOS"))
            logger.notice("bg", "refresh.run")
            guard let pairing = loadPairing(defaults: UserDefaults(suiteName: DataLocation.appGroupID) ?? .standard, secrets: KeychainSecretStore()) else {
                logger.error("bg", "refresh.skipped", ["reason": "not paired"])
                task.setTaskCompleted(success: false); return
            }
            let started = Date()
            do {
                let client = HubClient(pairing: pairing)
                let snap = try await client.snapshot()
                try? SnapshotStore(url: location.snapshotURL).save(snap)
                WidgetCenter.shared.reloadAllTimelines()
                logger.info("bg", "refresh.ok", ["ms": "\(Int(Date().timeIntervalSince(started) * 1000))", "providers": "\(snap.providers.count)"])
                _ = await client.syncTelemetry(from: logger)
                task.setTaskCompleted(success: true)
            } catch {
                logger.error("bg", "refresh.failed", ["error": error.localizedDescription])
                task.setTaskCompleted(success: false)
            }
            let req = BGAppRefreshTaskRequest(identifier: refreshTaskID)
            req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
            try? BGTaskScheduler.shared.submit(req)
        }
        bgTask.expirationHandler = { work.cancel() }
    }

    // MARK: Watch

    func pushToWatch() {
        guard let session, session.activationState == .activated else { return }
        var context: [String: Any] = [:]
        if let data = try? JSON.encoder.encode(snapshot) { context["snapshot"] = data }
        if let pairing, let data = try? JSON.encoder.encode(pairing) { context["pairing"] = data }
        do {
            try session.updateApplicationContext(context)
            var f: [String: String] = ["bytes": "\((context["snapshot"] as? Data)?.count ?? 0)", "reachable": "\(session.isReachable)"]
            if session.isComplicationEnabled, let data = context["snapshot"] {
                session.transferCurrentComplicationUserInfo(["snapshot": data])
                f["complication"] = "true"
            }
            logger.info("watch", "context.sent", f)
        } catch {
            QPLog.hub.notice("watch push failed: \(error.localizedDescription, privacy: .public)")
            logger.error("watch", "context.failed", ["error": error.localizedDescription])
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
        let boxed = UncheckedBox(value: replyHandler)
        let keys = message.keys.sorted().joined(separator: ",")
        Task { @MainActor in
            self.logger.info("watch", "message.received", ["keys": keys])
            var reply: [String: Any] = [:]
            if let data = try? JSON.encoder.encode(self.snapshot) { reply["snapshot"] = data }
            if let p = self.pairing, let data = try? JSON.encoder.encode(p) { reply["pairing"] = data }
            boxed.value(reply)
        }
    }
}
