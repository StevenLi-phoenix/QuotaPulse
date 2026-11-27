import Foundation
import QuotaCore

/// What the menu-bar item says, decided from the snapshot alone (no drawing): which window it tracks, how much of it is left,
/// whether that is a problem, and the tooltip. `MenuBarImage` draws it; keeping the decision here makes it testable and
/// keeps the drawing free of rules.
///
/// The item shows what is **left**, not what is used: a full ring labelled "100%" used to mean "limit reached" and read as
/// "plenty". Health uses the app-wide `UsageLevel`, so the colour agrees with the dropdown and the main window.
public struct MenuBarStatus: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A fresh reading of the tracked window.
        case live
        /// Last known value: the provider is failing or has not answered for a while.
        case stale
        /// Nothing to show yet (first launch, nothing enabled, balance-only providers).
        case empty
    }

    public var kind: Kind
    public var level: UsageLevel?
    /// The provider the tracked window belongs to; nil for `.empty`.
    public var provider: ProviderID?
    public var info: ProviderInfo?
    public var windowID: String?
    public var windowTitle: String?
    /// 0…100 left in the tracked window.
    public var remaining: Double?
    /// "62%", "0%" once exhausted, "—" without data. Whole numbers, so the width stays put.
    public var percentText: String
    /// Another provider is failing or out of date (the item keeps tracking the ones that work and flags this).
    public var hasIssues: Bool
    public var tooltip: String
    public var accessibilityLabel: String

    /// One-line summary for the debug log.
    public var logLine: String {
        "kind=\(kind) provider=\(provider?.rawValue ?? "-") window=\(windowID ?? "-") left=\(remaining.map { String(format: "%.1f", $0) } ?? "-") level=\(level.map { "\($0)" } ?? "-") issues=\(hasIssues)"
    }

    /// Fresh readings older than this count as out of date (several missed polls, or a Mac that slept).
    public static func staleAfter(pollInterval: TimeInterval) -> TimeInterval { max(20 * 60, 3 * pollInterval) }

    // MARK: Selection

    struct Candidate {
        var provider: ProviderSnapshot
        var window: UsageWindow
        var level: UsageLevel
        var used: Double
    }

    /// The most constrained window: highest `UsageLevel` (which folds in the forecast), then the least left. Ties keep snapshot order.
    static func pick(_ providers: [ProviderSnapshot], now: Date) -> Candidate? {
        var best: Candidate?
        for p in providers {
            for w in p.reportedWindows {
                let c = Candidate(provider: p, window: w,
                                  level: UsageLevel(window: w, forecast: p.forecasts[w.id], now: now),
                                  used: w.currentUtilization(now: now))
                if let b = best {
                    if c.level > b.level || (c.level == b.level && c.used > b.used) { best = c }
                } else {
                    best = c
                }
            }
        }
        return best
    }

    static func isFresh(_ p: ProviderSnapshot, now: Date, staleAfter: TimeInterval) -> Bool {
        guard p.status.isOK else { return false }
        return now.timeIntervalSince(p.lastSuccessAt ?? p.fetchedAt) < staleAfter
    }

    public static func make(snapshot: QuotaSnapshot, now: Date = Date(), staleAfter: TimeInterval = 20 * 60) -> MenuBarStatus {
        let fresh = snapshot.providers.filter { isFresh($0, now: now, staleAfter: staleAfter) }
        let failing = snapshot.providers.filter { !isFresh($0, now: now, staleAfter: staleAfter) }
        // A provider that was never set up is not a problem to flag; one that stopped answering is.
        let hasIssues = failing.contains { if case .notConfigured = $0.status { false } else { true } }

        let lines = tooltipLines(snapshot: snapshot, now: now, staleAfter: staleAfter)

        // Fresh providers decide; only when none has a window do last-known values stand in (flagged as out of date).
        let live = pick(fresh, now: now)
        guard let chosen = live ?? pick(failing, now: now) else {
            let text = lines.isEmpty ? L("Waiting for first refresh…") : lines.joined(separator: "\n")
            return MenuBarStatus(kind: .empty, level: nil, provider: nil, info: nil, windowID: nil, windowTitle: nil,
                                 remaining: nil, percentText: "—", hasIssues: hasIssues,
                                 tooltip: "QuotaPulse\n" + text, accessibilityLabel: "QuotaPulse")
        }

        let w = chosen.window
        let exhausted = w.isExhausted(now: now)
        let remaining = max(0, 100 - chosen.used)
        let percentText = exhausted ? "0%" : "\(min(100, max(1, Int(remaining.rounded()))))%"
        let kind: Kind = live == nil ? .stale : .live
        let name = chosen.provider.localizedName
        let head = "\(name) · \(w.localizedTitle): \(leftText(percentText))"
        let reset = exhausted ? Present.exhaustedText(w, now: now) : Present.resetText(w, now: now)
        var tip = [head, reset]
        if kind == .stale { tip.append(L("Out of date · showing the last known value")) }
        let rest = lines.filter { $0.hasPrefix(name + " · ") == false }
        if !rest.isEmpty { tip.append(""); tip += rest }
        let label = "\(name) \(w.localizedTitle), \(leftText(percentText))"
            + (kind == .stale ? ", " + L("Out of date") : "")

        return MenuBarStatus(kind: kind, level: chosen.level, provider: chosen.provider.id, info: chosen.provider.display,
                             windowID: w.id, windowTitle: w.localizedTitle, remaining: remaining, percentText: percentText,
                             hasIssues: hasIssues, tooltip: tip.joined(separator: "\n"), accessibilityLabel: label)
    }

    static func leftText(_ percent: String) -> String { L("\(percent) left") }

    /// One line per provider: its tightest window, its balance, or why it has nothing.
    static func tooltipLines(snapshot: QuotaSnapshot, now: Date, staleAfter: TimeInterval) -> [String] {
        snapshot.providers.compactMap { p in
            let name = p.localizedName
            if !p.status.isOK {
                return "\(name) · \(Present.statusTitle(p.status))"
            }
            if let c = pick([p], now: now) {
                let exhausted = c.window.isExhausted(now: now)
                let text = exhausted ? "0%" : "\(min(100, max(1, Int((100 - c.used).rounded()))))%"
                let stale = isFresh(p, now: now, staleAfter: staleAfter) ? "" : " · " + L("Out of date")
                return "\(name) · \(c.window.localizedTitle): \(leftText(text))\(stale)"
            }
            if let b = p.balance { return "\(name) · \(b.formatted)" }
            return nil
        }
    }
}
