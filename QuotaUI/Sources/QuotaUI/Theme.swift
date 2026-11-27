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

/// Drawing comes from `ProviderInfo`, which the reading Mac publishes with each snapshot: nothing here names a provider, so a
/// provider added after this build still gets its name, colour and symbol.
public extension ProviderInfo {
    var color: Color { Color(hex: brandHex) }
    /// Names are brands and stay as published; subtitles go through the string table, so known ones are translated.
    var localizedName: String { displayName }
    var localizedSubtitle: String { subtitle.isEmpty ? "" : String(localized: String.LocalizationValue(subtitle), bundle: .module) }
}

public extension ProviderSnapshot {
    var color: Color { display.color }
    var symbol: String { display.symbol }
    var localizedName: String { display.localizedName }
    var localizedSubtitle: String { display.localizedSubtitle }
    var dashboardURL: URL? { display.dashboardURL }
}

public extension UsageWindow {
    /// Titles are published by the reading Mac ("Weekly · Opus"); each " · " part goes through the string table, so known
    /// periods are translated and model names pass through.
    var localizedTitle: String {
        title.components(separatedBy: " · ")
            .map { String(localized: String.LocalizationValue($0), bundle: .module) }
            .joined(separator: " · ")
    }

    /// Nothing left until the reset (what `QuotaFormat.percent` prints as 100%).
    func isExhausted(now: Date = Date()) -> Bool { isReported && currentUtilization(now: now) >= 99.95 }
}

/// Semantic colour for a window's health. Health is its own encoding: the provider's brand colour says *which* service,
/// bar length and ring arc say *how much* is used, and this level says *whether that is a problem*.
public enum UsageLevel: Sendable, Comparable {
    case calm, warm, hot, critical

    /// Level from the used share alone (menu panel rows, which carry no forecast).
    public init(percent: Double) {
        switch percent {
        case ..<50: self = .calm
        case ..<80: self = .warm
        case ..<95: self = .hot
        default: self = .critical
        }
    }

    /// Health of a window: the used share, raised by the forecast. Exhausted is critical; a confident forecast that
    /// runs out before the reset is hot; ahead of the linear budget (or a tentative run-out) is warm.
    public init(window: UsageWindow, forecast: Forecast?, now: Date = Date()) {
        let used = window.currentUtilization(now: now)
        if window.isExhausted(now: now) { self = .critical; return }
        var level = UsageLevel(percent: used)
        if case .awaitingFirstUse = window.phase(now: now) { self = level; return }
        if let f = forecast, f.confidence != .insufficient {
            if f.willExhaustBeforeReset {
                level = max(level, f.confidence == .low ? .warm : .hot)
            } else if (f.paceDelta ?? 0) >= Present.paceTolerance {
                level = max(level, .warm)
            }
        }
        self = level
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

public extension ProviderSnapshot {
    /// Worst health across the reported windows (drives the header ring); nil when there are none.
    func health(now: Date = Date()) -> UsageLevel? {
        reportedWindows.map { UsageLevel(window: $0, forecast: forecasts[$0.id], now: now) }.max()
    }

    /// Sparkline scale: percent windows draw on 0–100, balances (money, credits) on their own range.
    var sparklineMax: Double? { primaryWindow == nil ? nil : 100 }
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

    /// A point in time with its preposition, ready to drop into a sentence: "at 15:44", "tomorrow at 15:44",
    /// "on Tue at 02:13", "on Dec 5 at 02:13" (zh: "15:44", "明天 15:44", "周二 02:13", "12月5日 02:13").
    public static func whenText(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDate(date, inSameDayAs: now) { return String(localized: "at \(time)", bundle: .module) }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: tomorrow) {
            return String(localized: "tomorrow at \(time)", bundle: .module)
        }
        // A weekday is only unambiguous within the coming week.
        let day = date.timeIntervalSince(now) < 6 * 86400
            ? date.formatted(.dateTime.weekday(.abbreviated))
            : date.formatted(.dateTime.month(.abbreviated).day())
        return String(localized: "on \(day) at \(time)", bundle: .module)
    }

    /// "Limit reached · Resets in 1h 32m" for an exhausted window.
    public static func exhaustedText(_ window: UsageWindow, now: Date = Date()) -> String {
        String(localized: "Limit reached · \(resetText(window, now: now))", bundle: .module)
    }

    /// Short run-out note for widgets and alerts: "Limit reached" once exhausted, "Out tomorrow at 15:44" when the
    /// forecast runs out before the reset, nil otherwise.
    public static func outText(window: UsageWindow, forecast: Forecast?, now: Date = Date()) -> String? {
        if window.isExhausted(now: now) { return L("Limit reached") }
        guard let f = forecast, f.willExhaustBeforeReset, let ex = f.exhaustionAt, ex > now else { return nil }
        return String(localized: "Out \(whenText(ex, now: now))", bundle: .module)
    }

    /// One-line forecast sentence for a window.
    public static func forecastText(window: UsageWindow, forecast: Forecast?, now: Date = Date()) -> String? {
        // Nothing to forecast once the quota is gone: say so instead of predicting a run-out that already happened.
        if window.isExhausted(now: now) { return exhaustedText(window, now: now) }
        guard let f = forecast, f.confidence != .insufficient else {
            return (forecast?.sampleCount ?? 0) > 0 ? L("Learning your pace…") : nil
        }
        // A handful of samples over a few minutes is a guess, not a verdict: say so.
        let early = f.confidence == .low
        if let ex = f.exhaustionAt {
            return early
                ? String(localized: "Early estimate: 100% \(whenText(ex, now: now)) (\(QuotaFormat.rate(f.rate)))", bundle: .module)
                : String(localized: "At this pace you hit 100% \(whenText(ex, now: now))", bundle: .module)
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

    /// Points either side of the linear budget that still count as "on pace".
    public static let paceTolerance = 3.0

    public static func paceText(_ forecast: Forecast?) -> (text: String, isOver: Bool)? {
        guard let d = forecast?.paceDelta, forecast?.confidence != .insufficient else { return nil }
        if abs(d) < paceTolerance { return (L("On pace"), false) }
        let pts = Int(abs(d).rounded())
        return d > 0 ? (String(localized: "\(pts) pts ahead of budget", bundle: .module), true)
                     : (String(localized: "\(pts) pts under budget", bundle: .module), false)
    }

    public static func balanceForecastText(balance: Balance, forecast: Forecast?) -> String? {
        guard let f = forecast, f.confidence != .insufficient else { return (forecast?.sampleCount ?? 0) > 0 ? L("Learning your spend…") : nil }
        guard f.balanceRatePerHour > 0.0001, let hours = f.balanceHoursRemaining else { return L("No spend observed yet") }
        let perHour = QuotaFormat.money(f.balanceRatePerHour, symbol: balance.symbol)
        if hours < 1 { return String(localized: "\(perHour)/h — less than an hour left", bundle: .module) }
        if hours < QuotaFormat.balanceHoursLimit {
            return String(localized: "\(perHour)/h — about \(QuotaFormat.wholeHours(hours)) hours left", bundle: .module)
        }
        let days = hours / 24
        if days > 365 { return String(localized: "\(perHour)/h — over a year left", bundle: .module) }
        return String(localized: "\(perHour)/h — about \(QuotaFormat.wholeDays(days)) days left", bundle: .module)
    }

    public static func updatedText(_ date: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        if s < 60 { return L("Updated just now") }
        if s < 3600 { return String(localized: "Updated \(Int(s / 60)) min ago", bundle: .module) }
        if s < 86400 { return String(localized: "Updated \(Int(s / 3600)) h ago", bundle: .module) }
        return String(localized: "Updated \(date.formatted(date: .abbreviated, time: .shortened))", bundle: .module)
    }

    public static func cloudAccountText(_ state: CloudAccountState) -> String {
        switch state {
        case .unknown: L("Checking iCloud…")
        case .available: L("Connected")
        case .noAccount: L("Not signed in to iCloud")
        case .restricted: L("iCloud is restricted on this device")
        case .temporarilyUnavailable: L("iCloud is temporarily unavailable")
        case .notEntitled: L("This build isn't signed for iCloud")
        }
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
