import Observation
import QuotaCore
import QuotaUI
import WatchConnectivity
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

    private let location = DataLocation.standard()
    private let defaults = UserDefaults(suiteName: DataLocation.appGroupID) ?? .standard
    private var session: WCSession?

    override init() {
        snapshot = SnapshotStore(url: location.snapshotURL).load() ?? .empty
        super.init()
        if let data = defaults.data(forKey: "hub.pairing.v1"), let p = try? JSON.decoder.decode(HubPairing.self, from: data) { pairing = p }
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
        session.sendMessage(["want": "snapshot"], replyHandler: { [weak self] reply in
            let (s, p) = Self.payloads(reply)
            Task { @MainActor in self?.ingest(snapshot: s, pairing: p, source: "iPhone") }
        }, errorHandler: { [weak self] error in
            Task { @MainActor in self?.lastError = error.localizedDescription }
        })
    }

    private func store(_ snap: QuotaSnapshot, source: String) {
        snapshot = snap
        self.source = source
        lastError = nil
        try? SnapshotStore(url: location.snapshotURL).save(snap)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func ingest(snapshot data: Data?, pairing pdata: Data?, source: String) {
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
