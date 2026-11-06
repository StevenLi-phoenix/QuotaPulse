import BackgroundTasks
import Observation
import QuotaCore
import QuotaUI
import WatchConnectivity
import WidgetKit
import os

/// iPhone side: reads iCloud (or a paired hub), caches for widgets and forwards to the watch.
@MainActor @Observable
final class ClientModel: NSObject {
    static let refreshTaskID = "app.lishuyu.quotapulse.refresh"
    static let pairingKey = "hub.pairing.v1"
    /// Push and background handlers have no SwiftUI environment to find the model through.
    private(set) static weak var current: ClientModel?

    private(set) var snapshot: QuotaSnapshot
    private(set) var pairing: HubPairing?
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    private(set) var source: SnapshotSource?
    private(set) var cloudAccount: CloudAccountState = .unknown
    private(set) var cloudAccountID: String?
    private(set) var histories: [ProviderID: [Sample]] = [:]
    private(set) var sparklines: [ProviderID: [Double]] = [:]
    private(set) var lastTelemetryUpload: (at: Date, count: Int, error: String?)?
    let ticker = Ticker(interval: .seconds(20))
    let logger: FileLogger
    private var diagnostics: DiagnosticsCollector?

    private let location = DataLocation.standard()
    private let secrets = KeychainSecretStore()
    private let defaults = UserDefaults(suiteName: DataLocation.appGroupID) ?? .standard
    private let cloud = CloudKitRecordStore.standard().map(CloudReader.init(store:))
    private var cloudPrepared = false
    private var historiesFetchedAt: Date?
    private var inFlight: Task<Bool, Never>?
    private var retry: Task<Void, Never>?
    private var session: WCSession?

    override init() {
        snapshot = SnapshotStore(url: location.snapshotURL).load() ?? .empty
        let identity = DeviceIdentityFactory.current(platform: "iOS")
        logger = FileLogger(directory: DiagnosticsPaths.logs, identity: identity)
        super.init()
        Self.current = self
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
        if cloudAccount != .available {
            // The hub was the only source: don't keep showing its numbers.
            snapshot = .empty
            source = nil
            try? SnapshotStore(url: location.snapshotURL).save(.empty)
            WidgetCenter.shared.reloadAllTimelines()
        }
        Task { await refresh(reason: "unpaired") }
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

    /// Concurrent callers join the refresh in flight: a background launch must not finish while launch's own fetch runs.
    @discardableResult
    func refresh(reason: String) async -> Bool {
        if let inFlight { return await inFlight.value }
        let task = Task { await performRefresh(reason: reason) }
        inFlight = task
        let ok = await task.value
        inFlight = nil
        return ok
    }

    /// iCloud errors often pass on their own, and nothing else refreshes an app that's left open.
    private func scheduleRetry(cloudFailed: Bool) {
        retry?.cancel()
        guard cloudFailed else { return }
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            await self?.refresh(reason: "retry")
        }
    }

    private func performRefresh(reason: String) async -> Bool {
        isRefreshing = true
        defer { isRefreshing = false }
        let hub = pairing.map { HubClient(pairing: $0) }
        let started = Date()
        let result = await SnapshotFetcher(cloud: cloud, hub: hub).fetch()
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        cloudAccount = result.account
        lastError = result.userError
        if result.account == .available { Task { await prepareCloud() } }
        if let e = result.cloudError { logger.error("cloud", "fetch.failed", ["reason": reason, "ms": "\(ms)", "error": e]) }
        scheduleRetry(cloudFailed: result.cloudError != nil)
        if let e = result.hubError { logger.error("hub", "fetch.failed", ["reason": reason, "ms": "\(ms)", "error": e]) }
        // Telemetry only travels over a direct link and must never hold up the numbers.
        if let hub { Task { await syncTelemetry(client: hub) } }
        guard let snap = result.snapshot, let origin = result.source else {
            logger.info("sync", "fetch.empty", ["reason": reason, "ms": "\(ms)", "account": result.account.rawValue])
            return false
        }
        source = origin
        QPLog.cloud.info("refresh ok (\(reason, privacy: .public)) via \(origin.rawValue, privacy: .public): \(snap.providers.count) providers")
        logger.info("sync", "fetch.ok", ["reason": reason, "ms": "\(ms)", "source": origin.rawValue, "providers": "\(snap.providers.count)",
                                         "generatedAt": ISO8601DateFormatter().string(from: snap.generatedAt),
                                         "statuses": snap.providers.map { "\($0.id.rawValue):\($0.status.shortLabel)" }.joined(separator: ",")])
        if snap.generatedAt > snapshot.generatedAt {
            snapshot = snap
            try? SnapshotStore(url: location.snapshotURL).save(snap)
            WidgetCenter.shared.reloadAllTimelines()
            logger.info("widget", "reload.requested", ["reason": reason])
            pushToWatch()
            logForecasts(snap)
        }
        await loadHistories(from: origin, hub: hub)
        return true
    }

    /// Creates the zone and the change subscription once this device has an iCloud account.
    private func prepareCloud() async {
        guard let cloud, !cloudPrepared else { return }
        cloudPrepared = true
        cloudAccountID = await cloud.accountID()
        do {
            try await cloud.store.prepare()
            try await cloud.store.subscribeToChanges()
            logger.notice("cloud", "subscribed", ["account": cloudAccountID ?? "?"])
        } catch {
            cloudPrepared = false // try again on the next refresh
            logger.error("cloud", "subscribe.failed", ["error": error.localizedDescription])
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

    private func loadHistories(from origin: SnapshotSource, hub: HubClient?) async {
        let providers = snapshot.providers.map(\.id)
        var loaded: [ProviderID: [Sample]] = [:]
        if origin == .iCloud, let cloud {
            // The Mac rewrites history at most every 30 minutes; re-reading it on every refresh is wasted work.
            if let at = historiesFetchedAt, Date().timeIntervalSince(at) < 10 * 60, !histories.isEmpty { return }
            do { loaded = try await cloud.histories(for: providers) } catch {
                logger.error("cloud", "history.failed", ["error": error.localizedDescription])
                return
            }
            historiesFetchedAt = Date()
        } else if let hub {
            for p in providers {
                if let hist = try? await hub.history(p, hours: 24) { loaded[p] = hist.samples }
            }
            historiesFetchedAt = nil
        }
        let all = loaded.values.flatMap { $0 }
        logger.info("sync", "history.ok", ["source": origin.rawValue, "samples": "\(all.count)"])
        histories = loaded
        let dayAgo = Date().addingTimeInterval(-24 * 3600)
        sparklines = Derive.sparklines(samples: all.filter { $0.at >= dayAgo }, snapshot: snapshot)
    }

    func history(_ provider: ProviderID, hours: Double) async -> [Sample] {
        if source == .hub, let pairing, let samples = try? await HubClient(pairing: pairing).history(provider, hours: hours).samples {
            return samples
        }
        let since = Date().addingTimeInterval(-hours * 3600)
        if source == .iCloud, let cached = histories[provider] { return cached.filter { $0.at >= since } }
        let fetched = (try? await cloud?.histories(for: [provider]))?[provider] ?? []
        return fetched.filter { $0.at >= since }
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
            let model = current ?? ClientModel()
            model.logger.notice("bg", "refresh.run")
            let ok = await model.refresh(reason: "background")
            boxed.value.setTaskCompleted(success: ok)
            model.scheduleBackgroundRefresh()
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
