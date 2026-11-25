import Foundation
import QuotaCore

/// What the menu-bar dropdown lists, derived from the cached snapshot: one group per provider and
/// one short line per window / balance / extra usage, so the numbers are readable without opening
/// the main window. Pure data plus already-formatted strings, so the layout stays a view concern
/// and the formatter is testable.
public enum MenuSummary {
    /// One row in the dropdown, e.g. "5-hour … 62% … 2h 14m".
    public struct Line: Sendable, Hashable, Identifiable {
        /// Stable across refreshes, e.g. `claude.five_hour`.
        public var id: String
        /// Window title from the provider ("5-hour", "Weekly", "Opus"), or "Balance" / "Extra usage".
        public var title: String
        /// "62%", "¥23.45", "$3.20 / $50".
        public var value: String
        /// 0…100 for the colour ramp; nil for money rows.
        public var percent: Double?
        /// Reset countdown ("2h 14m"), "Fresh" once a rolling window cleared, or "—" when unknown.
        public var reset: String
        /// False for a window the API currently omits; drawn dimmed.
        public var isReported: Bool
    }

    /// One provider: a header (name, plan, status) and its lines.
    public struct Group: Sendable, Hashable, Identifiable {
        public var provider: ProviderID
        /// How to draw it, from the snapshot (so a provider added after this build still has a name and colour).
        public var info: ProviderInfo
        public var plan: String?
        public var status: ProviderStatus
        public var lines: [Line]

        public var id: String { provider.rawValue }

        /// Nothing to print for this provider: the view shows the status as one line instead.
        public var hasLines: Bool { !lines.isEmpty }
    }

    public static func groups(for snapshot: QuotaSnapshot, now: Date = Date()) -> [Group] {
        snapshot.providers.map { group(for: $0, now: now) }
    }

    public static func group(for provider: ProviderSnapshot, now: Date) -> Group {
        var lines: [Line] = []
        // `displayWindows` keeps Codex's not-reported placeholder rows and hides not-applicable ones.
        for w in provider.displayWindows {
            let used = w.currentUtilization(now: now)
            lines.append(Line(id: "\(provider.id.rawValue).\(w.id)",
                              title: w.title,
                              value: QuotaFormat.percent(used),
                              percent: w.isReported ? used : nil,
                              reset: Present.resetShort(w, now: now),
                              isReported: w.isReported))
        }
        if let balance = provider.balance {
            lines.append(Line(id: "\(provider.id.rawValue).balance",
                              title: L("Balance"),
                              value: balance.formatted,
                              percent: nil,
                              reset: balanceReset(provider.forecasts[Sample.balanceWindowID]),
                              isReported: true))
        }
        if let extra = provider.extraUsage, extra.isEnabled, let used = extra.usedCredits,
           let limit = extra.monthlyLimit, limit > 0 {
            lines.append(Line(id: "\(provider.id.rawValue).extra",
                              title: L("Extra usage"),
                              value: "\(QuotaFormat.money(used, symbol: "$")) / \(QuotaFormat.money(limit, symbol: "$"))",
                              percent: extra.utilization,
                              reset: "—",
                              isReported: true))
        }
        return Group(provider: provider.id, info: provider.display, plan: provider.account?.plan, status: provider.status, lines: lines)
    }

    /// "≈ 20h left" or, from 72 h on, "≈ 4d left" from the balance forecast; "—" while the pace is still unknown.
    static func balanceReset(_ forecast: Forecast?) -> String {
        guard let f = forecast, f.confidence != .insufficient, f.balanceRatePerHour > 0.0001, let hours = f.balanceHoursRemaining else {
            return "—"
        }
        if hours < 1 { return L("under an hour left") }
        if hours < QuotaFormat.balanceHoursLimit { return L("≈ \(QuotaFormat.wholeHours(hours))h left") }
        let days = hours / 24
        if days > 365 { return L("over a year left") }
        return L("≈ \(QuotaFormat.wholeDays(days))d left")
    }
}
