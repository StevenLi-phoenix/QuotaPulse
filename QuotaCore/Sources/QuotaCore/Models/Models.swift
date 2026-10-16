import Foundation

// MARK: - Provider identity

public enum ProviderID: String, Codable, CaseIterable, Sendable, Identifiable, Hashable {
    case claude
    case codex
    case deepseek
    case opencode
    case zai

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .deepseek: "DeepSeek"
        case .opencode: "OpenCode"
        case .zai: "GLM (z.ai)"
        }
    }

    public var subtitle: String {
        switch self {
        case .claude: "Claude Code · OAuth"
        case .codex: "ChatGPT subscription"
        case .deepseek: "API balance"
        case .opencode: "Zen / Go"
        case .zai: "Coding plan"
        }
    }

    public var kind: ProviderKind {
        switch self {
        case .claude, .codex, .opencode, .zai: .rateWindows
        case .deepseek: .balance
        }
    }

    public var dashboardURL: URL {
        switch self {
        case .claude: URL(string: "https://claude.ai/settings/usage")!
        case .codex: URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .deepseek: URL(string: "https://platform.deepseek.com/usage")!
        case .opencode: URL(string: "https://opencode.ai/console")!
        case .zai: URL(string: "https://bigmodel.cn/coding-plan/personal/usage")!
        }
    }

    /// Brand accent colour as 0xRRGGBB.
    public var brandHex: UInt32 {
        switch self {
        case .claude: 0xD97757
        case .codex: 0x10A37F
        case .deepseek: 0x4D6BFE
        case .opencode: 0xF59E0B
        case .zai: 0x6366F1
        }
    }

    /// Whether the provider needs a user-entered API key (vs. reading a CLI's own credentials).
    public var usesAPIKey: Bool {
        switch self {
        case .claude, .codex: false
        case .deepseek, .opencode, .zai: true
        }
    }

    /// Providers enabled on first launch.
    public var defaultEnabled: Bool {
        switch self {
        case .claude, .codex: true
        case .deepseek, .opencode, .zai: false
        }
    }
}

public enum ProviderKind: String, Codable, Sendable {
    /// Percent-used windows that reset on a schedule (5h / weekly …).
    case rateWindows
    /// A prepaid balance that only goes down.
    case balance
}

// MARK: - Usage windows & balances

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

    public init(id: String, title: String, utilization: Double, resetsAt: Date?, duration: TimeInterval?, note: String? = nil) {
        self.id = id
        self.title = title
        self.utilization = min(100, max(0, utilization))
        self.resetsAt = resetsAt
        self.duration = duration
        self.note = note
    }

    public var remaining: Double { max(0, 100 - utilization) }

    /// Window start when both reset and duration are known.
    public var startsAt: Date? {
        guard let resetsAt, let duration else { return nil }
        return resetsAt.addingTimeInterval(-duration)
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
        default: "$"
        }
    }
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

    public init(id: ProviderID, fetchedAt: Date, status: ProviderStatus = .ok, account: AccountInfo? = nil,
                windows: [UsageWindow] = [], balance: Balance? = nil, extraUsage: ExtraUsage? = nil,
                forecasts: [String: Forecast] = [:], lastSuccessAt: Date? = nil) {
        self.id = id
        self.fetchedAt = fetchedAt
        self.status = status
        self.account = account
        self.windows = windows
        self.balance = balance
        self.extraUsage = extraUsage
        self.forecasts = forecasts
        self.lastSuccessAt = lastSuccessAt ?? (status.isOK ? fetchedAt : nil)
    }

    /// The window that is closest to running out (highest utilization), used for the menu bar label.
    public var primaryWindow: UsageWindow? {
        windows.max(by: { $0.utilization < $1.utilization })
    }

    /// Head-line percentage: highest window utilization, or balance-derived "pressure" (nil when unknown).
    public var headlinePercent: Double? {
        if let w = primaryWindow { return w.utilization }
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

    /// The provider/window pair under the most pressure, for the menu bar glyph.
    public var mostConstrained: (provider: ProviderSnapshot, window: UsageWindow)? {
        var best: (ProviderSnapshot, UsageWindow)?
        for p in providers where p.status.isOK {
            for w in p.windows {
                if best == nil || w.utilization > best!.1.utilization { best = (p, w) }
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
}

// MARK: - Forecast

public struct Forecast: Codable, Sendable, Hashable {
    public enum Confidence: String, Codable, Sendable { case insufficient, low, medium, high }

    public var confidence: Confidence
    /// Percent per hour (windows) or currency per day (balances). Positive = consuming.
    public var rate: Double
    /// Predicted utilization at the next reset (windows only), clamped 0…100.
    public var projectedAtReset: Double?
    /// When the window is expected to hit 100 % (nil if not before reset / no consumption).
    public var exhaustionAt: Date?
    /// For windows: current − expected-linear usage (positive = ahead of budget). For balances: nil.
    public var paceDelta: Double?
    /// Balances: days until the balance reaches zero at the current burn rate.
    public var daysRemaining: Double?
    public var sampleCount: Int
    public var span: TimeInterval

    public init(confidence: Confidence, rate: Double = 0, projectedAtReset: Double? = nil, exhaustionAt: Date? = nil,
                paceDelta: Double? = nil, daysRemaining: Double? = nil, sampleCount: Int = 0, span: TimeInterval = 0) {
        self.confidence = confidence
        self.rate = rate
        self.projectedAtReset = projectedAtReset
        self.exhaustionAt = exhaustionAt
        self.paceDelta = paceDelta
        self.daysRemaining = daysRemaining
        self.sampleCount = sampleCount
        self.span = span
    }

    public static let insufficient = Forecast(confidence: .insufficient)

    public var willExhaustBeforeReset: Bool { exhaustionAt != nil }
}
