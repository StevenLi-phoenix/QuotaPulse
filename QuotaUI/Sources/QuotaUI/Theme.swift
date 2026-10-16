import SwiftUI
import QuotaCore

/// Localized string lookup for this module.
public func L(_ key: String.LocalizationValue) -> String { String(localized: key, bundle: .module) }

public extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

public extension ProviderID {
    var color: Color { Color(hex: brandHex) }

    var symbol: String {
        switch self {
        case .claude: "sparkles"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .deepseek: "water.waves"
        case .opencode: "terminal"
        case .zai: "brain.head.profile"
        }
    }

    var localizedName: String { displayName }
}

/// Semantic colour for how close a window is to exhaustion.
public enum UsageLevel: Sendable {
    case calm, warm, hot, critical

    public init(percent: Double) {
        switch percent {
        case ..<50: self = .calm
        case ..<80: self = .warm
        case ..<95: self = .hot
        default: self = .critical
        }
    }

    public var color: Color {
        switch self {
        case .calm: Color(hex: 0x34C759)
        case .warm: Color(hex: 0xFFB020)
        case .hot: Color(hex: 0xFF7A1A)
        case .critical: Color(hex: 0xFF3B30)
        }
    }

    public var label: String {
        switch self {
        case .calm: L("Plenty left")
        case .warm: L("Halfway")
        case .hot: L("Running low")
        case .critical: L("Almost out")
        }
    }
}

public enum QPDesign {
    public static let cardRadius: CGFloat = 16
    public static let spring = Animation.spring(response: 0.55, dampingFraction: 0.82)
    public static let quick = Animation.spring(response: 0.3, dampingFraction: 0.9)

    public static var cardBackground: some ShapeStyle {
        #if os(macOS)
        return AnyShapeStyle(.quaternary.opacity(0.35))
        #elseif os(watchOS)
        return AnyShapeStyle(Color.white.opacity(0.08))
        #else
        return AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground))
        #endif
    }
}

// MARK: - Presentation helpers (pure, testable-by-eye strings)

public enum Present {
    public static func resetText(_ window: UsageWindow, now: Date = Date()) -> String {
        if !window.isReported { return L("Not reported by Codex API (known bug)") }
        switch window.phase(now: now) {
        case let .active(r):
            return String(localized: "Resets in \(QuotaFormat.countdown(to: r, from: now))", bundle: .module)
        case .awaitingFirstUse:
            return L("Fresh · next window starts on first request")
        case .unknown:
            return window.resetSemantics == .rollingFromFirstUse ? L("In use · reset time pending") : L("No reset time")
        }
    }

    /// Few-character variant for widgets / complications.
    public static func resetShort(_ window: UsageWindow, now: Date = Date()) -> String {
        if !window.isReported { return L("n/a") }
        switch window.phase(now: now) {
        case let .active(r): return QuotaFormat.countdown(to: r, from: now)
        case .awaitingFirstUse: return L("Fresh")
        case .unknown: return "—"
        }
    }

    public static func resetClock(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInTomorrow(date) { return String(localized: "tomorrow \(date.formatted(date: .omitted, time: .shortened))", bundle: .module) }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// One-line forecast sentence for a window.
    public static func forecastText(window: UsageWindow, forecast: Forecast?, now: Date = Date()) -> String? {
        guard let f = forecast, f.confidence != .insufficient else {
            return (forecast?.sampleCount ?? 0) > 0 ? L("Learning your pace…") : nil
        }
        // A handful of samples over a few minutes is a guess, not a verdict: say so.
        let early = f.confidence == .low
        if let ex = f.exhaustionAt {
            return early
                ? String(localized: "Early estimate: 100% around \(resetClock(ex)) (\(QuotaFormat.rate(f.rate)))", bundle: .module)
                : String(localized: "At this pace you hit 100% at \(resetClock(ex))", bundle: .module)
        }
        if f.rate < 0.05 {
            return L("Idle — no usage in this window")
        }
        if let p = f.projectedAtReset {
            return early
                ? String(localized: "Early estimate: \(QuotaFormat.percent(p)) by reset (\(QuotaFormat.rate(f.rate)))", bundle: .module)
                : String(localized: "At this pace: \(QuotaFormat.percent(p)) by reset (\(QuotaFormat.rate(f.rate)))", bundle: .module)
        }
        return QuotaFormat.rate(f.rate)
    }

    public static func paceText(_ forecast: Forecast?) -> (text: String, isOver: Bool)? {
        guard let d = forecast?.paceDelta, forecast?.confidence != .insufficient else { return nil }
        if abs(d) < 3 { return (L("On pace"), false) }
        let pts = Int(abs(d).rounded())
        return d > 0 ? (String(localized: "\(pts) pts ahead of budget", bundle: .module), true)
                     : (String(localized: "\(pts) pts under budget", bundle: .module), false)
    }

    public static func balanceForecastText(balance: Balance, forecast: Forecast?) -> String? {
        guard let f = forecast, f.confidence != .insufficient else { return (forecast?.sampleCount ?? 0) > 0 ? L("Learning your spend…") : nil }
        guard f.rate > 0.0001, let days = f.daysRemaining else { return L("No spend observed yet") }
        let perDay = QuotaFormat.money(f.rate, symbol: balance.symbol)
        if days < 1 { return String(localized: "\(perDay)/day — less than a day left", bundle: .module) }
        if days > 365 { return String(localized: "\(perDay)/day — over a year left", bundle: .module) }
        return String(localized: "\(perDay)/day — about \(Int(days.rounded())) days left", bundle: .module)
    }

    public static func updatedText(_ date: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        if s < 60 { return L("Updated just now") }
        if s < 3600 { return String(localized: "Updated \(Int(s / 60)) min ago", bundle: .module) }
        if s < 86400 { return String(localized: "Updated \(Int(s / 3600)) h ago", bundle: .module) }
        return String(localized: "Updated \(date.formatted(date: .abbreviated, time: .shortened))", bundle: .module)
    }

    public static func statusTitle(_ status: ProviderStatus) -> String {
        switch status {
        case .ok: L("OK")
        case .notConfigured: L("Not set up")
        case .unauthorized: L("Sign in needed")
        case .expired: L("Session expired")
        case .rateLimited: L("Rate limited")
        case .network: L("Offline")
        case .decoding: L("Unreadable data")
        case .server: L("Server error")
        }
    }
}
