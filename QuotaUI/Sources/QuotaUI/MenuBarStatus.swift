import Foundation
import QuotaCore

/// What the menu-bar item says, decided from the snapshot alone (no drawing): one narrow bar per provider, coloured by
/// provider, filled to how much is **left** in that provider's tightest window. No text appears in the menu bar; the
/// tooltip carries the words. `MenuBarImage` draws it; keeping the decision here makes it testable.
public struct MenuBarStatus: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A fresh reading: solid bar.
        case live
        /// Last known value: the provider is failing or has not answered for a while. Drawn hollow with a dashed edge.
        case stale
        /// A provider that has nothing to show yet. Hollow, dashed, no level.
        case noData
    }

    public struct Bar: Sendable, Equatable, Identifiable {
        public var id: ProviderID { provider }
        public var provider: ProviderID
        /// The provider's own colour (`ProviderInfo.brandHex`), published by the Mac that reads it.
        public var colorHex: UInt32
        public var kind: Kind
        /// The tracked window: the provider's one with the least left.
        public var windowID: String?
        public var windowTitle: String?
        /// 0…100 left in that window; nil for `.noData`.
        public var remaining: Double?
        /// Running low (80 % used, or a forecast that runs out before the reset) or exhausted. Shown as a dot, never as colour,
        /// because colour already means "which provider".
        public var alert: Bool
    }

    /// At most this many bars; the item stays about as wide as a handful of system icons.
    public static let maxBars = 6

    public var bars: [Bar]
    public var tooltip: String
    public var accessibilityLabel: String

    public var hasAlert: Bool { bars.contains { $0.alert } }

    /// One-line summary for the debug log.
    public var logLine: String {
        guard !bars.isEmpty else { return "bars=0" }
        return "bars=" + bars.map { b in
            "\(b.provider.rawValue):\(b.windowID ?? "-"):\(b.remaining.map { String(format: "%.0f", $0) } ?? "-"):\(b.kind == .live ? "live" : b.kind == .stale ? "stale" : "nodata")\(b.alert ? ":ALERT" : "")"
        }.joined(separator: ",")
    }

    /// Fresh readings older than this count as out of date (several missed polls, or a Mac that slept).
    public static func staleAfter(pollInterval: TimeInterval) -> TimeInterval { max(20 * 60, 3 * pollInterval) }

    // MARK: Selection

    struct Tightest {
        var window: UsageWindow
        var level: UsageLevel
        var used: Double
    }

    /// The window with the least left (highest used); on equal use the worse health, then the first listed.
    static func tightest(_ p: ProviderSnapshot, now: Date) -> Tightest? {
        var best: Tightest?
        for w in p.reportedWindows {
            let c = Tightest(window: w, level: UsageLevel(window: w, forecast: p.forecasts[w.id], now: now), used: w.currentUtilization(now: now))
            if let b = best {
                if c.used > b.used || (c.used == b.used && c.level > b.level) { best = c }
            } else {
                best = c
            }
        }
        return best
    }

    static func isFresh(_ p: ProviderSnapshot, now: Date, staleAfter: TimeInterval) -> Bool {
        guard p.status.isOK else { return false }
        return now.timeIntervalSince(p.lastSuccessAt ?? p.fetchedAt) < staleAfter
    }

    /// Balances (money, credits) have no "how full" to draw; their providers appear in the tooltip only.
    static func drawsBar(_ p: ProviderSnapshot) -> Bool {
        if p.display.kind == .balance { return false }
        if case .notConfigured = p.status, p.reportedWindows.isEmpty { return false }
        return true
    }

    static func percentLeft(used: Double) -> String {
        used >= 99.95 ? "0%" : "\(min(100, max(1, Int((100 - used).rounded()))))%"
    }

    static func leftText(_ percent: String) -> String { L("\(percent) left") }

    public static func make(snapshot: QuotaSnapshot, now: Date = Date(), staleAfter: TimeInterval = 20 * 60) -> MenuBarStatus {
        var bars: [Bar] = []
        var lines: [String] = []
        var spoken: [String] = []

        for p in snapshot.providers {
            let name = p.localizedName
            let fresh = isFresh(p, now: now, staleAfter: staleAfter)
            let t = tightest(p, now: now)

            // Tooltip: one line per provider, bar or not.
            var line = name
            if let t {
                let w = t.window
                let exhausted = w.isExhausted(now: now)
                line += " · \(w.localizedTitle): \(leftText(percentLeft(used: t.used)))"
                line += " · " + (exhausted ? Present.exhaustedText(w, now: now) : Present.resetText(w, now: now))
                if t.level >= .hot, !exhausted { line += " · " + t.level.label }
                if !p.status.isOK { line += " · " + Present.statusTitle(p.status) } else if !fresh { line += " · " + L("Out of date") }
                spoken.append("\(name) \(leftText(percentLeft(used: t.used)))")
            } else if !p.status.isOK {
                line += " · " + Present.statusTitle(p.status)
            } else if let b = p.balance {
                line += " · \(b.formatted)"
            } else {
                line += " · " + L("Waiting for first refresh…")
            }
            lines.append(line)

            guard drawsBar(p) else { continue }
            if let t {
                bars.append(Bar(provider: p.id, colorHex: p.display.brandHex, kind: fresh ? .live : .stale,
                                windowID: t.window.id, windowTitle: t.window.localizedTitle,
                                remaining: max(0, 100 - t.used), alert: t.level >= .hot))
            } else {
                bars.append(Bar(provider: p.id, colorHex: p.display.brandHex, kind: .noData, windowID: nil, windowTitle: nil,
                                remaining: nil, alert: false))
            }
        }

        if bars.count > maxBars { bars = Array(bars.prefix(maxBars)) }
        let tip = lines.isEmpty ? "QuotaPulse\n" + L("Waiting for first refresh…") : lines.joined(separator: "\n")
        return MenuBarStatus(bars: bars, tooltip: tip,
                             accessibilityLabel: spoken.isEmpty ? "QuotaPulse" : "QuotaPulse: " + spoken.joined(separator: ", "))
    }
}
