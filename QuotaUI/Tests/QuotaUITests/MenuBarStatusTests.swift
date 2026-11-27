import Foundation
import Testing
import QuotaCore
@testable import QuotaUI

/// The menu-bar bars: one per provider, filled to what is used in its tightest window, with alert / out-of-date / no-data states
/// and a tooltip that carries every number (the item itself has no text).
@Suite struct MenuBarStatusTests {
    let now = Date(timeIntervalSince1970: 1_792_120_000)

    private func window(_ id: String, _ title: String = "5-hour", used: Double, resetsIn: TimeInterval = 7200) -> UsageWindow {
        UsageWindow(id: id, title: title, utilization: used, resetsAt: now.addingTimeInterval(resetsIn), duration: 18000)
    }

    private func provider(_ id: ProviderID, _ windows: [UsageWindow], status: ProviderStatus = .ok, age: TimeInterval = 60,
                          forecasts: [String: Forecast] = [:], balance: Balance? = nil, info: ProviderInfo? = nil) -> ProviderSnapshot {
        ProviderSnapshot(id: id, fetchedAt: now.addingTimeInterval(-age), status: status, windows: windows, balance: balance,
                         forecasts: forecasts, lastSuccessAt: now.addingTimeInterval(-age), info: info)
    }

    private func make(_ p: [ProviderSnapshot], staleAfter: TimeInterval = 20 * 60) -> MenuBarStatus {
        MenuBarStatus.make(snapshot: QuotaSnapshot(generatedAt: now, hubName: "Mac", providers: p), now: now, staleAfter: staleAfter)
    }

    @Test func oneBarPerProviderInSnapshotOrder() {
        let s = make([provider(.claude, [window("a", used: 12)]), provider(.codex, [window("b", used: 30)]), provider(.opencode, [window("c", used: 50)])])
        #expect(s.bars.map(\.provider) == [.claude, .codex, .opencode])
        #expect(s.bars.map(\.remaining) == [88, 70, 50])
    }

    @Test func aProvidersBarTracksItsWindowWithTheLeastLeft() {
        let s = make([provider(.codex, [window("primary", used: 30), window("secondary", "Weekly", used: 71), window("tertiary", used: 5)])])
        #expect(s.bars.count == 1)
        #expect(s.bars[0].windowID == "secondary")
        #expect(s.bars[0].remaining == 29)
        #expect(s.bars[0].windowTitle == "Weekly")
    }

    @Test func barColoursComeFromTheProviderDescription() {
        let acme = ProviderInfo(displayName: "Acme", brandHex: 0x123456)
        let s = make([provider(.claude, [window("a", used: 1)]), provider("acme", [window("b", used: 1)], info: acme)])
        #expect(s.bars[0].colorHex == ProviderInfo.builtIn[.claude]?.brandHex)
        #expect(s.bars[1].colorHex == 0x123456)
    }

    @Test func aProviderWithoutAnyDescriptionStillGetsItsOwnColour() {
        let s = make([provider("new_agent", [window("a", used: 1)]), provider("other_agent", [window("a", used: 1)])])
        #expect(s.bars[0].colorHex == ProviderInfo.defaultHex(for: "new_agent"))
        #expect(s.bars[0].colorHex != s.bars[1].colorHex)
    }

    @Test func runningLowRaisesTheAlertDotNotTheColour() {
        let s = make([provider(.claude, [window("a", used: 79)]), provider(.codex, [window("b", used: 80)]), provider(.opencode, [window("c", used: 100)])])
        #expect(s.bars.map(\.alert) == [false, true, true])
        #expect(s.hasAlert)
        // The bar keeps the provider's colour whatever its health.
        #expect(s.bars[2].colorHex == ProviderInfo.builtIn[.opencode]?.brandHex)
    }

    @Test func aForecastedRunOutAlertsEvenWithPlentyLeft() {
        let forecast = Forecast(confidence: .high, rate: 30, projectedAtReset: 100, exhaustionAt: now.addingTimeInterval(3600), paceDelta: 20)
        let s = make([provider(.claude, [window("a", used: 40)], forecasts: ["a": forecast])])
        #expect(s.bars[0].alert)
        #expect(s.bars[0].remaining == 60)
    }

    @Test func exhaustedBarIsEmptyAndAlerting() {
        let s = make([provider(.codex, [window("primary", used: 100)])])
        #expect(s.bars[0].remaining == 0)
        #expect(s.bars[0].alert)
        #expect(s.tooltip.contains("0% left"))
        #expect(s.tooltip.contains("Limit reached"))
    }

    @Test func failingProviderKeepsItsBarHollowWithTheLastValue() {
        let s = make([provider(.claude, [window("a", used: 55)], status: .expired("token")), provider(.codex, [window("b", used: 20)])])
        #expect(s.bars.map(\.kind) == [.stale, .live])
        #expect(s.bars[0].remaining == 45)
        #expect(s.tooltip.contains("Claude"))
        #expect(s.tooltip.contains(Present.statusTitle(.expired("token"))))
    }

    @Test func anOldReadingIsOutOfDateAndALongerPollIntervalTolerance() {
        let old = [provider(.claude, [window("a", used: 55)], age: 3600)]
        #expect(make(old).bars[0].kind == .stale)
        #expect(make(old, staleAfter: MenuBarStatus.staleAfter(pollInterval: 1800)).bars[0].kind == .live)
        #expect(make(old).tooltip.contains("Out of date"))
        #expect(MenuBarStatus.staleAfter(pollInterval: 120) == 20 * 60)
        #expect(MenuBarStatus.staleAfter(pollInterval: 600) == 30 * 60)
    }

    @Test func aProviderWithoutNumbersYetIsAHollowNoDataBar() {
        let s = make([provider(.codex, [], status: .network("down"))])
        #expect(s.bars.count == 1)
        #expect(s.bars[0].kind == .noData)
        #expect(s.bars[0].remaining == nil)
        #expect(!s.bars[0].alert)
    }

    @Test func notSetUpProvidersAndBalancesDrawNoBarButStayInTheTooltip() {
        let s = make([provider(.claude, [window("a", used: 10)]),
                      provider(.codex, [], status: .notConfigured("no login")),
                      provider(.deepseek, [], balance: Balance(currency: "CNY", total: 23.45), info: ProviderInfo.builtIn[.deepseek])])
        #expect(s.bars.map(\.provider) == [.claude])
        #expect(s.tooltip.contains("DeepSeek"))
        #expect(s.tooltip.contains("¥23.45"))
    }

    @Test func rollingWindowPastItsResetCountsAsFull() {
        let rolled = UsageWindow(id: "a", title: "5-hour", utilization: 90, resetsAt: now.addingTimeInterval(-60), duration: 18000,
                                 resetSemantics: .rollingFromFirstUse)
        let s = make([provider(.claude, [rolled])])
        #expect(s.bars[0].remaining == 100)
        #expect(!s.bars[0].alert)
    }

    @Test func noProvidersHasNoBarsAndSaysSoInTheTooltip() {
        let s = MenuBarStatus.make(snapshot: .empty, now: now)
        #expect(s.bars.isEmpty)
        #expect(!s.hasAlert)
        #expect(s.tooltip.hasPrefix("QuotaPulse"))
    }

    @Test func barCountIsCapped() {
        let many = (0..<9).map { provider(ProviderID("p\($0)"), [window("a", used: 10)]) }
        #expect(make(many).bars.count == MenuBarStatus.maxBars)
    }

    /// The bar's height is what is used (same direction as the dropdown's usage bars), so a used-up window is a full bar.
    @Test func barHeightFollowsUsedNotLeft() {
        let s = make([provider(.claude, [window("a", used: 12)]), provider(.codex, [window("b", used: 100)]),
                      provider(.opencode, [], status: .network("down"))])
        #expect(s.bars.map(\.used) == [12, 100, nil])
    }

    #if os(macOS)
    /// Every bar keeps a stub of its provider's colour at 0 % used; full use fills the whole bar.
    @Test func fillHeightKeepsAColourStubAndFillsToTheTop() {
        let full = MenuBarImage.barTop - MenuBarImage.barBottom
        #expect(MenuBarImage.fillHeight(used: 0) == MenuBarImage.minFill)
        #expect(MenuBarImage.fillHeight(used: 50) == full / 2)
        #expect(MenuBarImage.fillHeight(used: 100) == full)
        #expect(MenuBarImage.fillHeight(used: 140) == full)
    }
    #endif

    @Test func tooltipHasOneLineWithProviderWindowLeftAndResetPerProvider() {
        let s = make([provider(.claude, [window("a", "Weekly", used: 38)]), provider(.codex, [window("b", used: 60)])])
        let lines = s.tooltip.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("Claude · Weekly: 62% left · Resets in"))
        #expect(lines[1].hasPrefix("Codex · 5-hour: 40% left"))
    }

    @Test func logLineNamesEveryBar() {
        let s = make([provider(.codex, [window("primary", used: 100)]), provider(.claude, [window("a", used: 55)], status: .network("x"))])
        #expect(s.logLine == "bars=codex:primary:0:live:ALERT,claude:a:45:stale")
    }
}
