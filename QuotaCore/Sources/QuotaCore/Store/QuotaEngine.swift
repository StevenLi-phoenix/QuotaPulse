import Foundation

/// The hub's brain: polls enabled providers, records samples, computes forecasts, persists the snapshot.
/// Runs anywhere credentials live (the Mac). Platform apps observe `snapshot` via the `onUpdate` hook.
public actor QuotaEngine {
    public let location: DataLocation
    public private(set) var settings: AppSettings
    public private(set) var snapshot: QuotaSnapshot
    public private(set) var isRefreshing = false
    public private(set) var lastRefreshStarted: Date?

    private let providers: [ProviderID: any UsageProvider]
    private let secrets: any SecretStore
    private let transport: any HTTPTransport
    private let samples: SampleStore
    private let snapshotStore: SnapshotStore
    private let settingsStore: SettingsStore
    private var gate = BackoffGate()
    private var onUpdate: (@Sendable (QuotaSnapshot) -> Void)?
    private var loopTask: Task<Void, Never>?
    private let hubName: String
    private let gatewayCache = GatewaySnapshotCache()
    private var reportBlockedUntil: Date?
    /// After a failed report, wait this long before trying again (no retry storms).
    static let reportCooldown: TimeInterval = 300

    public init(location: DataLocation = .standard(),
                providers: [any UsageProvider] = ProviderRegistry.all(),
                secrets: any SecretStore,
                transport: any HTTPTransport = URLSessionTransport(),
                hubName: String = ProcessInfo.processInfo.hostName) {
        self.location = location
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        self.secrets = secrets
        self.transport = transport
        self.hubName = hubName
        self.settingsStore = SettingsStore(url: location.settingsURL)
        self.snapshotStore = SnapshotStore(url: location.snapshotURL)
        let s = settingsStore.load()
        self.settings = s
        self.samples = SampleStore(url: location.samplesURL, retentionDays: s.retentionDays)
        self.snapshot = snapshotStore.load() ?? .empty
        QPLog.engine.notice("engine init: data at \(location.root.path, privacy: .public), \(s.enabledProviders.count) providers enabled")
    }

    public func setOnUpdate(_ handler: @escaping @Sendable (QuotaSnapshot) -> Void) {
        onUpdate = handler
        handler(snapshot)
    }

    // MARK: Settings

    public func update(_ mutate: @Sendable (inout AppSettings) -> Void) {
        var s = settings
        mutate(&s)
        settings = s
        settingsStore.save(s)
        QPLog.engine.debug("settings updated")
    }

    public func setAPIKey(_ value: String?, for provider: ProviderID) throws {
        try secrets.set(value, for: SecretKey.apiKey(provider))
        QPLog.engine.info("api key for \(provider.rawValue, privacy: .public) \(value == nil ? "cleared" : "set", privacy: .public)")
    }

    public func hasAPIKey(_ provider: ProviderID) -> Bool {
        (try? secrets.get(SecretKey.apiKey(provider)))?.isEmpty == false
    }

    // MARK: Polling loop

    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(reason: "timer")
                let interval = await self.settings.pollInterval
                try? await Task.sleep(for: .seconds(max(60, interval)))
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Fetches every enabled provider concurrently. `force` ignores backoff (user-initiated refresh).
    @discardableResult
    public func refresh(reason: String, force: Bool = false, now: Date = Date()) async -> QuotaSnapshot {
        if isRefreshing { return snapshot }
        isRefreshing = true
        lastRefreshStarted = now
        defer { isRefreshing = false }
        QPLog.engine.info("refresh start (\(reason, privacy: .public), force=\(force))")

        let gatewayConfig = GatewayConfig.load(from: location.gatewayURL)
        let gateway = gatewayConfig.map { GatewayLink(config: $0, cache: gatewayCache) }
        if gateway != nil, !settings.gatewaySeeded {
            update {
                for id in [ProviderID.deepseek, .opencode] where !$0.isEnabled(id) {
                    $0.providers[id, default: ProviderSettings(enabled: true)].enabled = true
                }
                $0.gatewaySeeded = true
            }
            QPLog.engine.notice("gateway link found: DeepSeek and OpenCode enabled")
        }

        let enabled = settings.enabledProviders
        let previous = snapshot
        var results: [ProviderSnapshot] = []

        await withTaskGroup(of: ProviderSnapshot?.self) { group in
            for id in enabled {
                guard let provider = providers[id] else { continue }
                if !force, gate.isBlocked(id, now: now) {
                    QPLog.engine.debug("\(id.rawValue, privacy: .public) skipped: backoff")
                    continue
                }
                let ctx = FetchContext(transport: transport, secrets: secrets, now: now, options: settings.options(id), gateway: gateway)
                group.addTask {
                    do {
                        return try await provider.fetch(ctx)
                    } catch {
                        let pe = ProviderError.wrap(error)
                        QPLog.providers.notice("\(id.rawValue, privacy: .public) failed: \(pe.status.message, privacy: .public)")
                        return ProviderSnapshot(id: id, fetchedAt: now, status: pe.status)
                    }
                }
            }
            for await r in group { if let r { results.append(r) } }
        }

        // Merge: providers that were skipped keep their previous snapshot; failures keep last-good data.
        var merged: [ProviderSnapshot] = []
        var newSamples: [Sample] = []
        for id in enabled {
            let prev = previous.provider(id)
            if var fresh = results.first(where: { $0.id == id }) {
                switch fresh.status {
                case .ok:
                    gate.recordSuccess(id)
                    for w in fresh.reportedWindows {
                        newSamples.append(Sample(provider: id, window: w.id, at: now, value: w.utilization, resetsAt: w.resetsAt))
                    }
                    if let b = fresh.balance {
                        newSamples.append(Sample(provider: id, window: Sample.balanceWindowID, at: now, value: b.total))
                    }
                case let .rateLimited(retryAfter):
                    gate.recordRateLimit(id, retryAfter: retryAfter, now: now)
                case .network, .server:
                    gate.recordTransient(id, now: now)
                default:
                    gate.recordSuccess(id) // configuration errors: no backoff, user will fix
                }
                if fresh.status.isError, let prev {
                    // keep last known numbers so the UI never blanks out
                    fresh.windows = prev.windows
                    fresh.balance = prev.balance
                    fresh.extraUsage = prev.extraUsage
                    fresh.account = fresh.account ?? prev.account
                    fresh.lastSuccessAt = prev.lastSuccessAt
                }
                merged.append(fresh)
            } else if let prev {
                merged.append(prev)
            } else {
                merged.append(ProviderSnapshot(id: id, fetchedAt: now, status: .notConfigured("Waiting for first fetch…")))
            }
        }

        await samples.append(newSamples, now: now)
        try? await samples.flush()

        // Forecasts
        for i in merged.indices {
            var forecasts: [String: Forecast] = [:]
            for w in merged[i].reportedWindows {
                let hist = await samples.samples(provider: merged[i].id, window: w.id)
                forecasts[w.id] = ForecastEngine.forecast(window: w, samples: hist, now: now)
            }
            if let b = merged[i].balance {
                let hist = await samples.samples(provider: merged[i].id, window: Sample.balanceWindowID)
                forecasts[Sample.balanceWindowID] = ForecastEngine.forecast(balance: b, samples: hist, now: now)
            }
            merged[i].forecasts = forecasts
        }

        let snap = QuotaSnapshot(generatedAt: now, hubName: hubName, providers: merged)
        snapshot = snap
        do { try snapshotStore.save(snap) } catch {
            QPLog.store.error("snapshot save failed: \(error.localizedDescription, privacy: .public)")
        }
        QPLog.engine.notice("refresh done: \(merged.map { "\($0.id.rawValue):\($0.status.shortLabel)" }.joined(separator: " "), privacy: .public)")
        onUpdate?(snap)
        if let gatewayConfig { await report(merged, to: gatewayConfig, now: now) }
        return snap
    }

    /// Sends the Mac-only readings to the gateway. Failures are logged and cool down; the UI never sees them.
    private func report(_ merged: [ProviderSnapshot], to config: GatewayConfig, now: Date) async {
        if let until = reportBlockedUntil, now < until {
            QPLog.hub.debug("gateway report skipped: cooling down")
            return
        }
        let payload = GatewayReport.providers(from: merged)
        guard !payload.isEmpty else { return }
        do {
            let n = try await GatewayClient(config: config, transport: transport).report(payload)
            reportBlockedUntil = nil
            QPLog.hub.info("gateway report ok: sent \(payload.count), accepted \(n)")
        } catch {
            reportBlockedUntil = now.addingTimeInterval(Self.reportCooldown)
            QPLog.hub.error("gateway report failed: \(ProviderError.wrap(error).status.message, privacy: .public)")
        }
    }

    // MARK: History access

    public func history(provider: ProviderID, hours: Double, now: Date = Date(), maxPoints: Int = 400) async -> [Sample] {
        let since = now.addingTimeInterval(-hours * 3600)
        let raw = await samples.samples(provider: provider, since: since)
        // downsample per window
        let byWindow = Dictionary(grouping: raw, by: \.window)
        return byWindow.values.flatMap { Downsample.samples($0, maxPoints: maxPoints) }.sorted { $0.at < $1.at }
    }

    /// Every stored sample since a date, for callers that do their own downsampling.
    public func rawHistory(provider: ProviderID, since: Date) async -> [Sample] {
        await samples.samples(provider: provider, since: since)
    }

    public func clearHistory() async {
        await samples.clear()
    }

    public func sampleCount() async -> Int { await samples.count }
}
