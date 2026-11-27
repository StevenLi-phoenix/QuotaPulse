import Foundation

// MARK: - Provider identity

/// A provider's stable key (`claude`, `grokbot`, …). Any string is a valid id, so a device decodes and shows providers that
/// were added after it was built. Encodes as a bare string, exactly like the enum it replaced; it is deliberately not
/// `CodingKeyRepresentable`, so `[ProviderID: …]` keeps the array form settings files and iCloud records already use.
public struct ProviderID: RawRepresentable, Codable, Sendable, Identifiable, Hashable, Comparable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    /// For ids from outside (record names, query strings, deep links): 1…32 of `a-z 0-9 _ -`.
    public init?(validating raw: String) {
        guard (1...32).contains(raw.count),
              raw.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-" }) else { return nil }
        self.rawValue = raw
    }

    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var id: String { rawValue }
    public var description: String { rawValue }
    public static func < (a: ProviderID, b: ProviderID) -> Bool { a.rawValue < b.rawValue }

    public static let claude: ProviderID = "claude"
    public static let codex: ProviderID = "codex"
    public static let deepseek: ProviderID = "deepseek"
    public static let opencode: ProviderID = "opencode"
    public static let zai: ProviderID = "zai"

    /// The providers every released build knows. Builds before dynamic providers fail to decode a snapshot that holds any other
    /// id, so the hub sends only these unless the client asks for all of them.
    public static let legacy: [ProviderID] = [.claude, .codex, .deepseek, .opencode, .zai]

    /// What this build can say about the provider when no snapshot carries its own description.
    public var fallbackInfo: ProviderInfo { ProviderInfo.builtIn[self] ?? .generic(self) }

    /// Display order: the original five in their order, then the rest by id.
    public static func displayOrder(_ a: ProviderID, _ b: ProviderID) -> Bool {
        switch (legacy.firstIndex(of: a), legacy.firstIndex(of: b)) {
        case let (x?, y?): x < y
        case (_?, nil): true
        case (nil, _?): false
        case (nil, nil): a < b
        }
    }
}

/// How a provider presents itself. The Mac that reads a provider publishes this inside every snapshot, so other devices draw
/// it without knowing the provider in advance.
public struct ProviderInfo: Codable, Sendable, Hashable {
    public var displayName: String
    public var subtitle: String
    public var kind: ProviderKind
    /// Brand accent colour as 0xRRGGBB.
    public var brandHex: UInt32
    /// SF Symbol name.
    public var symbol: String
    public var dashboardURL: URL?

    public init(displayName: String, subtitle: String = "", kind: ProviderKind = .rateWindows, brandHex: UInt32 = ProviderInfo.neutralHex,
                symbol: String = ProviderInfo.neutralSymbol, dashboardURL: URL? = nil) {
        self.displayName = displayName
        self.subtitle = subtitle
        self.kind = kind
        self.brandHex = brandHex
        self.symbol = symbol
        self.dashboardURL = dashboardURL
    }

    /// Unknown fields and values are dropped instead of failing the whole snapshot: a newer Mac may describe more.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try c.decode(String.self, forKey: .displayName)
        subtitle = (try? c.decodeIfPresent(String.self, forKey: .subtitle)) ?? ""
        kind = (try? c.decodeIfPresent(ProviderKind.self, forKey: .kind)) ?? .rateWindows
        brandHex = (try? c.decodeIfPresent(UInt32.self, forKey: .brandHex)) ?? Self.neutralHex
        let symbol = (try? c.decodeIfPresent(String.self, forKey: .symbol)) ?? nil
        self.symbol = symbol.flatMap { $0.isEmpty ? nil : $0 } ?? Self.neutralSymbol
        dashboardURL = try? c.decodeIfPresent(URL.self, forKey: .dashboardURL)
    }

    enum CodingKeys: String, CodingKey { case displayName, subtitle, kind, brandHex, symbol, dashboardURL }

    public static let neutralHex: UInt32 = 0x8E8E93
    public static let neutralSymbol = "gauge.with.dots.needle.33percent"

    /// A stable colour for a provider that publishes none: the id's hash picks the hue (FNV-1a), saturation and brightness are fixed so
    /// it reads on light and dark backgrounds. The same id gets the same colour on every device.
    public static func defaultHex(for id: ProviderID) -> UInt32 {
        var h: UInt32 = 2166136261
        for b in id.rawValue.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        let hue = Double(h % 360) / 360, s = 0.62, v = 0.9
        let i = Int(hue * 6) % 6, f = hue * 6 - Double(Int(hue * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let rgb: (Double, Double, Double) = [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)][i]
        func byte(_ x: Double) -> UInt32 { UInt32((x * 255).rounded()) }
        return byte(rgb.0) << 16 | byte(rgb.1) << 8 | byte(rgb.2)
    }

    /// A provider nothing describes: its id, title-cased, in neutral colours.
    public static func generic(_ id: ProviderID) -> ProviderInfo {
        let hex = defaultHex(for: id)
        let name = id.rawValue.split(whereSeparator: { $0 == "_" || $0 == "-" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return ProviderInfo(displayName: name.isEmpty ? id.rawValue : name, brandHex: hex)
    }

    /// The original five, for snapshots written before providers described themselves (older Macs, the gateway).
    public static let builtIn: [ProviderID: ProviderInfo] = [
        .claude: ProviderInfo(displayName: "Claude", subtitle: "Claude Code · OAuth", brandHex: 0xD97757, symbol: "sparkles",
                              dashboardURL: URL(string: "https://claude.ai/settings/usage")),
        .codex: ProviderInfo(displayName: "Codex", subtitle: "ChatGPT subscription", brandHex: 0x10A37F, symbol: "chevron.left.forwardslash.chevron.right",
                             dashboardURL: URL(string: "https://chatgpt.com/codex/settings/usage")),
        .deepseek: ProviderInfo(displayName: "DeepSeek", subtitle: "API balance", kind: .balance, brandHex: 0x4D6BFE, symbol: "water.waves",
                                dashboardURL: URL(string: "https://platform.deepseek.com/usage")),
        .opencode: ProviderInfo(displayName: "OpenCode", subtitle: "Zen / Go", brandHex: 0xF59E0B, symbol: "terminal",
                                dashboardURL: URL(string: "https://opencode.ai/console")),
        .zai: ProviderInfo(displayName: "GLM (z.ai)", subtitle: "Coding plan", brandHex: 0x6366F1, symbol: "brain.head.profile",
                           dashboardURL: URL(string: "https://bigmodel.cn/coding-plan/personal/usage")),
    ]
}

public enum ProviderKind: String, Codable, Sendable {
    /// Percent-used windows that reset on a schedule (5h / weekly …).
    case rateWindows
    /// A prepaid balance that only goes down.
    case balance
}

// MARK: - Usage windows & balances

/// How a provider's window behaves when `resetsAt` passes.
public enum ResetSemantics: String, Codable, Sendable, Hashable {
    /// Claude: the window starts with the first request; at `resetsAt` the quota is cleared but no new
    /// window begins until the next request (the API then reports utilization 0 and/or no reset time).
    case rollingFromFirstUse
    /// Codex: quota and cycle reset together at `resetsAt`; the next cycle starts immediately and
    /// reset times advance by the fixed window length.
    case fixedCadence
}

/// Whether the provider actually returned numbers for this window.
public enum WindowAvailability: String, Codable, Sendable, Hashable {
    case reported
    /// The API is known to omit this window right now (e.g. Codex's `secondary_window: null` bug on
    /// Plus/Team plans); the row stays as a placeholder so the layout doesn't change when it comes back.
    case notReported
    /// The plan simply doesn't have this window (Codex Pro has no 5-hour window); hidden in every UI.
    case notApplicable
}

/// What a window is doing right now.
public enum WindowPhase: Sendable, Hashable {
    /// Counting down to `resetsAt` (already rolled forward for fixed-cadence windows).
    case active(resetsAt: Date)
    /// Rolling window whose reset passed: quota is fresh, the next window starts on the first request.
    case awaitingFirstUse
    /// No reset time known.
    case unknown
}

public struct UsageWindow: Codable, Sendable, Identifiable, Hashable {
    /// Stable key, e.g. `five_hour`, `seven_day`, `seven_day_opus`.
    public var id: String
    public var title: String
    /// 0…100 percent used.
    public var utilization: Double
    public var resetsAt: Date?
    /// Length of the window in seconds when known (18000 for 5h, 604800 for 7d).
    public var duration: TimeInterval?
    /// Optional scoping note ("Opus", "Sonnet", "GPT-5.3 Spark"…).
    public var note: String?
    public var resetSemantics: ResetSemantics
    public var availability: WindowAvailability

    public init(id: String, title: String, utilization: Double, resetsAt: Date?, duration: TimeInterval?, note: String? = nil,
                resetSemantics: ResetSemantics = .fixedCadence, availability: WindowAvailability = .reported) {
        self.id = id
        self.title = title
        self.utilization = min(100, max(0, utilization))
        self.resetsAt = resetsAt
        self.duration = duration
        self.note = note
        self.resetSemantics = resetSemantics
        self.availability = availability
    }

    public var isReported: Bool { availability == .reported }

    enum CodingKeys: String, CodingKey { case id, title, utilization, resetsAt, duration, note, resetSemantics, availability }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        utilization = try c.decode(Double.self, forKey: .utilization)
        resetsAt = try c.decodeIfPresent(Date.self, forKey: .resetsAt)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        resetSemantics = try c.decodeIfPresent(ResetSemantics.self, forKey: .resetSemantics) ?? .fixedCadence
        availability = try c.decodeIfPresent(WindowAvailability.self, forKey: .availability) ?? .reported
    }

    public var remaining: Double { max(0, 100 - utilization) }

    /// Raw window start (reset − duration), regardless of whether the reset already passed.
    public var startsAt: Date? {
        guard let resetsAt, let duration else { return nil }
        return resetsAt.addingTimeInterval(-duration)
    }

    /// The reset the countdown should target at `now`: fixed-cadence windows roll forward by whole
    /// cycles once `resetsAt` passes; rolling windows have no next reset until a request starts one.
    public func effectiveResetsAt(now: Date = Date()) -> Date? {
        guard let resetsAt else { return nil }
        if resetsAt > now { return resetsAt }
        switch resetSemantics {
        case .rollingFromFirstUse:
            return nil
        case .fixedCadence:
            guard let duration, duration > 0 else { return nil }
            let cycles = floor(now.timeIntervalSince(resetsAt) / duration) + 1
            return resetsAt.addingTimeInterval(cycles * duration)
        }
    }

    /// Start of the cycle that contains `now` (for pace and forecasting).
    public func cycleStart(now: Date = Date()) -> Date? {
        guard let duration, let reset = effectiveResetsAt(now: now) else { return nil }
        return reset.addingTimeInterval(-duration)
    }

    public func phase(now: Date = Date()) -> WindowPhase {
        if let r = effectiveResetsAt(now: now) { return .active(resetsAt: r) }
        if resetSemantics == .rollingFromFirstUse, resetsAt != nil || utilization < 0.5 { return .awaitingFirstUse }
        return .unknown
    }

    /// Utilization as it stands now: a rolling window past its reset has been cleared.
    public func currentUtilization(now: Date = Date()) -> Double {
        if case .awaitingFirstUse = phase(now: now) { return 0 }
        return utilization
    }
}

public struct Balance: Codable, Sendable, Hashable {
    public var currency: String
    public var total: Double
    public var granted: Double?
    public var toppedUp: Double?
    public var isAvailable: Bool

    public init(currency: String, total: Double, granted: Double? = nil, toppedUp: Double? = nil, isAvailable: Bool = true) {
        self.currency = currency
        self.total = total
        self.granted = granted
        self.toppedUp = toppedUp
        self.isAvailable = isAvailable
    }

    public var symbol: String {
        switch currency.uppercased() {
        case "CNY", "RMB": "¥"
        case "EUR": "€"
        case "GBP": "£"
        case "CREDITS": ""
        default: "$"
        }
    }

    /// True for non-monetary balances (Codex credits).
    public var isCredits: Bool { currency.uppercased() == "CREDITS" }

    /// "¥23.45" / "$1,234" / "62,484 credits".
    public var formatted: String { QuotaFormat.amount(total, balance: self) }
}

public struct ExtraUsage: Codable, Sendable, Hashable {
    public var isEnabled: Bool
    public var monthlyLimit: Double?
    public var usedCredits: Double?
    public var utilization: Double?
    public var currency: String?

    public init(isEnabled: Bool, monthlyLimit: Double?, usedCredits: Double?, utilization: Double?, currency: String?) {
        self.isEnabled = isEnabled
        self.monthlyLimit = monthlyLimit
        self.usedCredits = usedCredits
        self.utilization = utilization
        self.currency = currency
    }
}

// MARK: - Status

public enum ProviderStatus: Codable, Sendable, Hashable {
    case ok
    /// Nothing to fetch with: no credentials file / API key.
    case notConfigured(String)
    /// Credentials present but rejected (401/403).
    case unauthorized(String)
    /// Credentials are present but expired and could not be refreshed.
    case expired(String)
    case rateLimited(retryAfter: Date?)
    case network(String)
    case decoding(String)
    case server(code: Int, String)

    public var isOK: Bool { if case .ok = self { return true } else { return false } }

    public var isError: Bool { !isOK }

    public var message: String {
        switch self {
        case .ok: "OK"
        case let .notConfigured(m): m
        case let .unauthorized(m): m
        case let .expired(m): m
        case let .rateLimited(retryAfter):
            if let retryAfter { "Rate limited until \(retryAfter.formatted(date: .omitted, time: .shortened))" } else { "Rate limited" }
        case let .network(m): m
        case let .decoding(m): m
        case let .server(code, m): "HTTP \(code): \(m)"
        }
    }

    /// Short label for a badge.
    public var shortLabel: String {
        switch self {
        case .ok: "OK"
        case .notConfigured: "Not set up"
        case .unauthorized: "Sign in"
        case .expired: "Expired"
        case .rateLimited: "429"
        case .network: "Offline"
        case .decoding: "Bad data"
        case .server: "Error"
        }
    }
}

// MARK: - Snapshots

public struct AccountInfo: Codable, Sendable, Hashable {
    public var plan: String?
    /// Masked e-mail / identifier, never a secret.
    public var label: String?

    public init(plan: String? = nil, label: String? = nil) {
        self.plan = plan
        self.label = label
    }
}

public struct ProviderSnapshot: Codable, Sendable, Identifiable, Hashable {
    public var id: ProviderID
    public var fetchedAt: Date
    public var status: ProviderStatus
    public var account: AccountInfo?
    public var windows: [UsageWindow]
    public var balance: Balance?
    public var extraUsage: ExtraUsage?
    /// Forecasts keyed by window id (or `balance`).
    public var forecasts: [String: Forecast]
    /// Last time this provider was fetched successfully (survives errors).
    public var lastSuccessAt: Date?
    /// Who took this reading, set only by the gateway hub: `reader` (phm), `gateway` (the Worker), `mac` (this app's own report coming back).
    /// nil is a reading this app took itself.
    public var source: String?
    /// How to draw this provider, stamped by the Mac that read it. Absent in snapshots from older Macs and the gateway; see `display`.
    public var info: ProviderInfo?

    public init(id: ProviderID, fetchedAt: Date, status: ProviderStatus = .ok, account: AccountInfo? = nil,
                windows: [UsageWindow] = [], balance: Balance? = nil, extraUsage: ExtraUsage? = nil,
                forecasts: [String: Forecast] = [:], lastSuccessAt: Date? = nil, source: String? = nil, info: ProviderInfo? = nil) {
        self.id = id
        self.fetchedAt = fetchedAt
        self.status = status
        self.account = account
        self.windows = windows
        self.balance = balance
        self.extraUsage = extraUsage
        self.forecasts = forecasts
        self.lastSuccessAt = lastSuccessAt ?? (status.isOK ? fetchedAt : nil)
        self.source = source
        self.info = info
    }

    /// What the UI draws: the description the reading Mac published, else what this build knows, else a neutral style.
    public var display: ProviderInfo { info ?? id.fallbackInfo }

    /// The window that is closest to running out (highest utilization), used for the menu bar label.
    public var primaryWindow: UsageWindow? { primaryWindow(now: Date()) }

    /// Same as `primaryWindow`, evaluated at `now` (tests pass a fixed clock so fixture reset dates never rot).
    public func primaryWindow(now: Date) -> UsageWindow? {
        reportedWindows.max(by: { $0.currentUtilization(now: now) < $1.currentUtilization(now: now) })
    }

    /// Windows that carry real numbers (placeholders excluded).
    public var reportedWindows: [UsageWindow] { windows.filter(\.isReported) }

    /// Windows the UI should draw: real ones plus `.notReported` placeholders, never `.notApplicable`.
    public var displayWindows: [UsageWindow] { windows.filter { $0.availability != .notApplicable } }

    /// Head-line percentage: highest window utilization, or balance-derived "pressure" (nil when unknown).
    public var headlinePercent: Double? {
        if let w = primaryWindow { return w.currentUtilization() }
        return nil
    }

    /// Primary window first, then the rest in their natural order.
    public var orderedWindows: [UsageWindow] { windows }
}

public struct QuotaSnapshot: Codable, Sendable, Hashable {
    public static let formatVersion = 1

    public var version: Int
    public var generatedAt: Date
    public var hubName: String
    public var providers: [ProviderSnapshot]

    public init(generatedAt: Date, hubName: String, providers: [ProviderSnapshot]) {
        self.version = Self.formatVersion
        self.generatedAt = generatedAt
        self.hubName = hubName
        self.providers = providers
    }

    public static let empty = QuotaSnapshot(generatedAt: .distantPast, hubName: "", providers: [])

    public func provider(_ id: ProviderID) -> ProviderSnapshot? {
        providers.first { $0.id == id }
    }

    /// How to draw a provider known only by id (a picker, a navigation title): its snapshot's description when there is one.
    public func info(_ id: ProviderID) -> ProviderInfo { provider(id)?.display ?? id.fallbackInfo }

    /// Only the providers every released build can decode. Older builds fail on the whole snapshot when one id is new to them.
    public var legacyCompatible: QuotaSnapshot {
        var copy = self
        copy.providers = providers.filter { ProviderID.legacy.contains($0.id) }
        return copy
    }

    /// The provider/window pair under the most pressure, for the menu bar glyph.
    public var mostConstrained: (provider: ProviderSnapshot, window: UsageWindow)? {
        var best: (ProviderSnapshot, UsageWindow)?
        let now = Date()
        for p in providers where p.status.isOK {
            for w in p.reportedWindows {
                if best == nil || w.currentUtilization(now: now) > best!.1.currentUtilization(now: now) { best = (p, w) }
            }
        }
        return best
    }
}

// MARK: - Samples (history)

public struct Sample: Codable, Sendable, Hashable {
    public var provider: ProviderID
    /// Window id, or `balance`.
    public var window: String
    public var at: Date
    /// Percent used for windows; currency amount for balances.
    public var value: Double
    public var resetsAt: Date?

    public init(provider: ProviderID, window: String, at: Date, value: Double, resetsAt: Date? = nil) {
        self.provider = provider
        self.window = window
        self.at = at
        self.value = value
        self.resetsAt = resetsAt
    }

    public static let balanceWindowID = "balance"

    /// The same point on two Macs. JSON keeps whole seconds while memory keeps fractions, so the key rounds down to the second;
    /// the provider is part of it because `balance` is a window id for more than one provider.
    public var identity: String { "\(provider.rawValue)|\(window)|\(Int(at.timeIntervalSince1970.rounded(.down)))" }
}

// MARK: - Forecast

public struct Forecast: Codable, Sendable, Hashable {
    public enum Confidence: String, Codable, Sendable { case insufficient, low, medium, high }

    public var confidence: Confidence
    /// Percent per hour (windows) or currency per day (balances); older apps read it that way, so it keeps its unit. Positive = consuming.
    public var rate: Double
    /// Predicted utilization at the next reset (windows only), clamped 0…100.
    public var projectedAtReset: Double?
    /// When the window is expected to hit 100 % (nil if not before reset / no consumption).
    public var exhaustionAt: Date?
    /// For windows: current − expected-linear usage (positive = ahead of budget). For balances: nil.
    public var paceDelta: Double?
    /// Balances: days until the balance reaches zero at the current burn rate.
    public var daysRemaining: Double?
    /// Balances: the same burn per hour (`rate / 24`), added next to the per-day pair so readers can quote hours.
    public var ratePerHour: Double?
    /// Balances: the same remaining time in hours.
    public var hoursRemaining: Double?
    /// Balances: 2 when both unit pairs above are present. Absent in a forecast from 0.4.5 or earlier (0.4.4 sent a per-hour `rate` with
    /// `hoursRemaining` and no version; before that, days only).
    public var schemaVersion: Int?
    public static let balanceSchema = 2
    public var sampleCount: Int
    public var span: TimeInterval

    public init(confidence: Confidence, rate: Double = 0, projectedAtReset: Double? = nil, exhaustionAt: Date? = nil,
                paceDelta: Double? = nil, daysRemaining: Double? = nil, ratePerHour: Double? = nil, hoursRemaining: Double? = nil, schemaVersion: Int? = nil,
                sampleCount: Int = 0, span: TimeInterval = 0) {
        self.confidence = confidence
        self.rate = rate
        self.projectedAtReset = projectedAtReset
        self.exhaustionAt = exhaustionAt
        self.paceDelta = paceDelta
        self.daysRemaining = daysRemaining
        self.ratePerHour = ratePerHour
        self.hoursRemaining = hoursRemaining
        self.schemaVersion = schemaVersion
        self.sampleCount = sampleCount
        self.span = span
    }

    public static let insufficient = Forecast(confidence: .insufficient)

    public var willExhaustBeforeReset: Bool { exhaustionAt != nil }

    /// Balances: burn per hour. A forecast from an app that only knew days has `daysRemaining` and a per-day `rate`; 0.4.4 briefly
    /// sent a per-hour `rate` and `hoursRemaining` without `ratePerHour`.
    public var balanceRatePerHour: Double {
        if let ratePerHour { return ratePerHour }
        if (schemaVersion ?? 1) >= Self.balanceSchema { return rate / 24 }
        return daysRemaining == nil && hoursRemaining != nil ? rate : rate / 24
    }

    /// Balances: hours until zero, from either pair.
    public var balanceHoursRemaining: Double? { hoursRemaining ?? daysRemaining.map { $0 * 24 } }
}
