import Observation
import QuotaCore
import QuotaUI
import WatchConnectivity
import WatchKit
import WidgetKit

/// Watch side: receives snapshots from the iPhone, or fetches straight from the hub when it can.
@MainActor @Observable
final class WatchModel: NSObject {
    private(set) var snapshot: QuotaSnapshot
    private(set) var pairing: HubPairing?
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    private(set) var source = ""
    let ticker = Ticker(interval: .seconds(20))
    let logger: FileLogger

    private let location = DataLocation.standard()
    private let defaults = UserDefaults(suiteName: DataLocation.appGroupID) ?? .standard
    private var session: WCSession?

    override init() {
        snapshot = SnapshotStore(url: location.snapshotURL).load() ?? .empty
        let defaults0 = UserDefaults.standard
        var short = defaults0.string(forKey: "device.shortID") ?? ""
        if short.isEmpty { short = String(UUID().uuidString.prefix(4)); defaults0.set(short, forKey: "device.shortID") }
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
        let identity = DeviceIdentity(name: "Watch-\(short)", appVersion: version, platform: "watchOS \(WKInterfaceDevice.current().systemVersion)")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        logger = FileLogger(directory: docs.appendingPathComponent("Logs", isDirectory: true), identity: identity, maxTotalBytes: 2 * 1024 * 1024)
        super.init()
        logger.notice("app", "launch", ["device": identity.name, "version": version])
        if let data = defaults.data(forKey: "hub.pairing.v1"), let p = try? JSON.decoder.decode(HubPairing.self, from: data) { pairing = p }
        // Automation hook (simulator / CI): QUOTAPULSE_PAIRING_URL=quotapulse://pair?url=…&token=…
        if let raw = ProcessInfo.processInfo.environment["QUOTAPULSE_PAIRING_URL"], let url = URL(string: raw), let p = HubPairing.parse(url) {
            pairing = p
            defaults.set(try? JSON.encoder.encode(p), forKey: "hub.pairing.v1")
        }
        if WCSession.isSupported() {
            session = WCSession.default
            session?.delegate = self
            session?.activate()
        }
        Task { await refresh() }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // 1. Direct hub fetch (works when the watch has Wi-Fi/cellular on the same network or tailnet).
        if let pairing {
            do {
                let snap = try await HubClient(pairing: pairing).snapshot()
                store(snap, source: "hub")
                return
            } catch {
                lastError = error.localizedDescription
            }
        }
        // 2. Ask the phone.
        guard let session, session.activationState == .activated, session.isReachable else { return }
        // WatchConnectivity calls these on its own queue: keep them nonisolated and hop to the main actor.
        session.sendMessage(["want": "snapshot"], replyHandler: { @Sendable [weak self] reply in
            let (s, p) = Self.payloads(reply)
            Task { @MainActor in self?.ingest(snapshot: s, pairing: p, source: "iPhone") }
        }, errorHandler: { @Sendable [weak self] error in
            let message = error.localizedDescription
            Task { @MainActor in self?.lastError = message }
        })
    }

    private func store(_ snap: QuotaSnapshot, source: String) {
        snapshot = snap
        self.source = source
        lastError = nil
        try? SnapshotStore(url: location.snapshotURL).save(snap)
        WidgetCenter.shared.reloadAllTimelines()
        logger.info("widget", "reload.requested", ["source": source])
    }

    private func ingest(snapshot data: Data?, pairing pdata: Data?, source: String) {
        logger.info("watch", "payload.received", ["source": source, "snapshotBytes": "\(data?.count ?? 0)", "hasPairing": "\(pdata != nil)"])
        if let pdata, let p = try? JSON.decoder.decode(HubPairing.self, from: pdata) {
            pairing = p
            defaults.set(pdata, forKey: "hub.pairing.v1")
        }
        if let data, let snap = try? JSON.decoder.decode(QuotaSnapshot.self, from: data) {
            if snap.generatedAt >= snapshot.generatedAt { store(snap, source: source) }
        }
    }

    /// Pulls the two Data payloads out of a WatchConnectivity dictionary (which isn't Sendable).
    nonisolated static func payloads(_ dict: [String: Any]) -> (Data?, Data?) {
        (dict["snapshot"] as? Data, dict["pairing"] as? Data)
    }
}

extension WatchModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let (s, p) = Self.payloads(session.receivedApplicationContext)
        Task { @MainActor in self.ingest(snapshot: s, pairing: p, source: "iPhone") }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let (s, p) = Self.payloads(applicationContext)
        Task { @MainActor in self.ingest(snapshot: s, pairing: p, source: "iPhone") }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let (s, p) = Self.payloads(userInfo)
        Task { @MainActor in self.ingest(snapshot: s, pairing: p, source: "iPhone") }
    }
}
