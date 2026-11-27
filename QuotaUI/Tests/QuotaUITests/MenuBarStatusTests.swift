import Foundation
import Testing
import QuotaCore
@testable import QuotaUI

/// What the menu-bar chip tracks and how it reads: the window closest to running out, shown as what is left, with health
/// colour, an out-of-date state for failing providers and an empty state.
@Suite struct MenuBarStatusTests {
    let now = Date(timeIntervalSince1970: 1_792_120_000)

    private func window(_ id: String, _ title: String = "5-hour", used: Double, resetsIn: TimeInterval = 7200) -> UsageWindow {
        UsageWindow(id: id, title: title, utilization: used, resetsAt: now.addingTimeInterval(resetsIn), duration: 18000)
    }

    private func provider(_ id: ProviderID, _ windows: [UsageWindow], status: ProviderStatus = .ok, age: TimeInterval = 60,
                          forecasts: [String: Forecast] = [:], balance: Balance? = nil) -> ProviderSnapshot {
        ProviderSnapshot(id: id, fetchedAt: now.addingTimeInterval(-age), status: status, windows: windows, balance: balance,
                         forecasts: forecasts, lastSuccessAt: now.addingTimeInterval(-age))
    }

    private func snap(_ p: [ProviderSnapshot]) -> QuotaSnapshot { QuotaSnapshot(generatedAt: now, hubName: "Mac", providers: p) }
    private func make(_ p: [ProviderSnapshot]) -> MenuBarStatus { MenuBarStatus.make(snapshot: snap(p), now: now) }

    @Test func tracksTheWindowWithTheLeastLeft() {
        let s = make([provider(.claude, [window("seven_day", "Weekly", used: 12)]),
                      provider(.codex, [window("primary", used: 30), window("secondary", "Weekly", used: 71)])])
        #expect(s.provider == .codex)
        #expect(s.windowID == "secondary")
        #expect(s.percentText == "29%")
        #expect(s.kind == .live)
        #expect(s.level == .warm)
    }

    @Test func showsLeftNotUsed() {
        let s = make([provider(.claude, [window("five_hour", used: 62)])])
        #expect(s.percentText == "38%")
        #expect(s.remaining == 38)
        #expect(s.tooltip.contains("38% left"))
    }

    @Test func exhaustedWindowReadsZeroAndCritical() {
        let s = make([provider(.codex, [window("primary", used: 100), window("secondary", "Weekly", used: 42)])])
        #expect(s.percentText == "0%")
        #expect(s.level == .critical)
        #expect(s.windowID == "primary")
        #expect(s.tooltip.contains("Limit reached"))
    }

    @Test func nearlyOutNeverRoundsToZero() {
        // 99.6 % used is not exhausted (that starts at 99.95), so it must not print "0%".
        let s = make([provider(.claude, [window("five_hour", used: 99.6)])])
        #expect(s.percentText == "1%")
        #expect(s.level == .critical)
    }

    @Test func forecastRunOutOutranksSmallerUsedShare() {
        // Claude is only 40 % used but the confident forecast says it runs out before the reset: hot beats warm.
        let forecast = Forecast(confidence: .high, rate: 30, projectedAtReset: 100, exhaustionAt: now.addingTimeInterval(3600), paceDelta: 20)
        let s = make([provider(.claude, [window("five_hour", used: 40)], forecasts: ["five_hour": forecast]),
                      provider(.codex, [window("primary", used: 70)])])
        #expect(s.provider == .claude)
        #expect(s.level == .hot)
    }

    @Test func tieOnLevelAndUsedKeepsSnapshotOrder() {
        let s = make([provider(.claude, [window("a", used: 20)]), provider(.codex, [window("b", used: 20)])])
        #expect(s.provider == .claude)
    }

    @Test func failingProviderIsFlaggedButDoesNotHideTheWorkingOnes() {
        let s = make([provider(.claude, [window("five_hour", used: 10)], status: .network("down")),
                      provider(.codex, [window("primary", used: 20)])])
        #expect(s.kind == .live)
        #expect(s.provider == .codex)
        #expect(s.hasIssues)
        #expect(s.tooltip.contains("Claude"))
    }

    @Test func onlyFailingProvidersLeftShowsLastKnownValueAsStale() {
        let s = make([provider(.claude, [window("five_hour", used: 55)], status: .expired("token"))])
        #expect(s.kind == .stale)
        #expect(s.percentText == "45%")
        #expect(s.provider == .claude)
        #expect(s.hasIssues)
    }

    @Test func oldReadingCountsAsStale() {
        let s = make([provider(.claude, [window("five_hour", used: 55)], age: 3 * 3600)])
        #expect(s.kind == .stale)
        // A longer poll interval widens the window: 30-minute polling tolerates a 1 h old reading.
        let wide = MenuBarStatus.make(snapshot: snap([provider(.claude, [window("five_hour", used: 55)], age: 3600)]), now: now,
                                      staleAfter: MenuBarStatus.staleAfter(pollInterval: 1800))
        #expect(wide.kind == .live)
    }

    @Test func staleAfterHasAFloor() {
        #expect(MenuBarStatus.staleAfter(pollInterval: 120) == 20 * 60)
        #expect(MenuBarStatus.staleAfter(pollInterval: 600) == 30 * 60)
    }

    @Test func noProvidersIsEmpty() {
        let s = MenuBarStatus.make(snapshot: .empty, now: now)
        #expect(s.kind == .empty)
        #expect(s.percentText == "—")
        #expect(s.level == nil)
        #expect(!s.hasIssues)
    }

    @Test func balanceOnlyProvidersAreEmptyButListedInTheTooltip() {
        let s = make([provider(.deepseek, [], balance: Balance(currency: "CNY", total: 23.45))])
        #expect(s.kind == .empty)
        #expect(s.tooltip.contains("DeepSeek"))
        #expect(s.tooltip.contains("¥23.45"))
    }

    @Test func notConfiguredProviderDoesNotRaiseTheBadge() {
        let s = make([provider(.claude, [window("five_hour", used: 10)]), provider(.codex, [], status: .notConfigured("no login"))])
        #expect(!s.hasIssues)
    }

    @Test func rollingWindowPastItsResetCountsAsFull() {
        let rolled = UsageWindow(id: "five_hour", title: "5-hour", utilization: 90, resetsAt: now.addingTimeInterval(-60), duration: 18000,
                                 resetSemantics: .rollingFromFirstUse)
        let s = make([provider(.claude, [rolled])])
        #expect(s.percentText == "100%")
        #expect(s.level == .calm)
    }

    @Test func tooltipListsEveryProviderOnce() {
        let s = make([provider(.claude, [window("five_hour", used: 10)]), provider(.codex, [window("primary", used: 60)]),
                      provider(.deepseek, [], balance: Balance(currency: "CNY", total: 5))])
        let lines = s.tooltip.split(separator: "\n").map(String.init)
        #expect(lines.first?.hasPrefix("Codex · 5-hour") == true) // the tracked window leads
        #expect(lines.filter { $0.hasPrefix("Codex") }.count == 1)
        #expect(lines.contains { $0.hasPrefix("Claude · 5-hour") })
        #expect(lines.contains { $0.hasPrefix("DeepSeek") })
    }

    @Test func logLineNamesProviderWindowAndLevel() {
        let s = make([provider(.codex, [window("primary", used: 100)])])
        #expect(s.logLine.contains("provider=codex"))
        #expect(s.logLine.contains("window=primary"))
        #expect(s.logLine.contains("level=critical"))
    }
}
