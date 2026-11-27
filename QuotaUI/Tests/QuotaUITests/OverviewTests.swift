import Foundation
import Testing
import QuotaCore
@testable import QuotaUI

/// The overview card: health colours that agree with the forecast, the exhausted state, the masonry grid, and string
/// catalogs whose keys the runtime can actually find.
@Suite struct OverviewTests {
    let now = Date(timeIntervalSince1970: 1_792_120_000)

    private func window(_ used: Double, resetsIn: TimeInterval, duration: TimeInterval) -> UsageWindow {
        UsageWindow(id: "w", title: "Weekly", utilization: used, resetsAt: now.addingTimeInterval(resetsIn), duration: duration)
    }

    // MARK: Health

    @Test func exhaustedWindowIsCriticalAndSaysSoInsteadOfForecasting() {
        // Codex 5-hour at 100% with 1h32m left: the old card said "At this pace you hit 100% at 21:25".
        let w = window(100, resetsIn: 92 * 60, duration: 5 * 3600)
        let f = Forecast(confidence: .high, rate: 28.7, projectedAtReset: 100, exhaustionAt: now, paceDelta: 31)
        #expect(w.isExhausted(now: now))
        #expect(UsageLevel(window: w, forecast: f, now: now) == .critical)
        let text = Present.forecastText(window: w, forecast: f, now: now)
        #expect(text == Present.exhaustedText(w, now: now))
        #expect(text?.contains("1h 32m") == true)
        #expect(Present.outText(window: w, forecast: f, now: now) == L("Limit reached"))
    }

    @Test func lowUsageThatRunsOutBeforeResetIsNotGreen() {
        // Codex weekly: 16% used, but the forecast runs out tomorrow.
        let w = window(16, resetsIn: 6 * 86400, duration: 7 * 86400)
        let f = Forecast(confidence: .high, rate: 4.6, projectedAtReset: 100, exhaustionAt: now.addingTimeInterval(18 * 3600), paceDelta: 14)
        #expect(UsageLevel(window: w, forecast: f, now: now) == .hot)
        let early = Forecast(confidence: .low, rate: 4.6, projectedAtReset: 100, exhaustionAt: now.addingTimeInterval(18 * 3600), paceDelta: 14)
        #expect(UsageLevel(window: w, forecast: early, now: now) == .warm)
    }

    @Test func aheadOfBudgetIsWarmAndUnderBudgetStaysCalm() {
        // Claude weekly: 12% used, 5 points ahead of the linear budget, lands at 99% by reset.
        let w = window(12, resetsIn: 156 * 3600, duration: 7 * 86400)
        let ahead = Forecast(confidence: .high, rate: 0.55, projectedAtReset: 98.9, paceDelta: 5.2)
        #expect(UsageLevel(window: w, forecast: ahead, now: now) == .warm)
        let under = Forecast(confidence: .high, rate: 0.5, projectedAtReset: 82, paceDelta: -13.6)
        #expect(UsageLevel(window: window(45, resetsIn: 69 * 3600, duration: 7 * 86400), forecast: under, now: now) == .calm)
        // Absolute level still applies with no forecast.
        #expect(UsageLevel(window: window(85, resetsIn: 3600, duration: 5 * 3600), forecast: nil, now: now) == .hot)
    }

    @Test func providerHealthIsTheWorstWindow() {
        let five = UsageWindow(id: "primary", title: "5-hour", utilization: 100, resetsAt: now.addingTimeInterval(3600), duration: 5 * 3600)
        let week = UsageWindow(id: "secondary", title: "Weekly", utilization: 16, resetsAt: now.addingTimeInterval(6 * 86400), duration: 7 * 86400)
        let codex = ProviderSnapshot(id: .codex, fetchedAt: now, windows: [five, week])
        #expect(codex.health(now: now) == .critical)
        #expect(codex.sparklineMax == 100)
        let deepseek = ProviderSnapshot(id: .deepseek, fetchedAt: now, balance: Balance(currency: "CNY", total: 233))
        #expect(deepseek.health(now: now) == nil)
        #expect(deepseek.sparklineMax == nil)
    }

    // MARK: Masonry

    @Test func masonryFillsTheShortestColumnInsteadOfAligningRows() {
        let layout = MasonryLayout(minColumnWidth: 340, maxColumnWidth: 520, spacing: 14)
        // The screenshot's order: Claude (short), Codex (tall), DeepSeek (short), OpenCode (tall), Grok (short).
        let (placements, size) = layout.arrange(heights: [130, 250, 100, 270, 110], width: 900)
        #expect(placements.map(\.column) == [0, 1, 0, 0, 1])
        // DeepSeek sits right under Claude, not under the taller Codex card.
        #expect(placements[2].origin.y == CGFloat(130 + 14))
        let leftColumn: CGFloat = 130 + 14 + 100 + 14 + 270  // Claude, DeepSeek, OpenCode
        #expect(size.height == leftColumn)
        #expect(placements.allSatisfy { $0.size.width == CGFloat(443) })
    }

    @Test func masonryColumnCountFollowsWidth() {
        let layout = MasonryLayout()
        #expect(layout.columns(for: 300).count == 1)
        #expect(layout.columns(for: 694).count == 2)
        #expect(layout.columns(for: 1100).count == 3)
        #expect(layout.columns(for: 1000).width == CGFloat(493))
        // A single column stops growing at the maximum width.
        #expect(layout.columns(for: 600).count == 1)
        #expect(layout.columns(for: 600).width == CGFloat(520))
    }

    // MARK: Formatting & strings

    @Test func whenTextCarriesItsOwnPreposition() {
        let cal = Calendar.current
        let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: now)!
        #expect(Present.whenText(noon.addingTimeInterval(3600), now: noon).hasPrefix("at "))
        #expect(Present.whenText(noon.addingTimeInterval(86400), now: noon).hasPrefix("tomorrow at "))
        #expect(Present.whenText(noon.addingTimeInterval(3 * 86400), now: noon).hasPrefix("on "))
    }

    @Test func catalogKeysAreRuntimeKeys() throws {
        // Interpolated keys must be stored as `Resets in %@`, never as the source text `Resets in \(…)`, or every string
        // with a value in it silently stays English.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["Sources/QuotaUI/Resources/Localizable.xcstrings", "../Shared/Resources/Localizable.xcstrings"] {
            let data = try Data(contentsOf: root.appendingPathComponent(path))
            let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let strings = try #require(catalog["strings"] as? [String: Any])
            #expect(strings.keys.contains { $0.contains("\\(") } == false, "source-form key in \(path)")
            for key in ["Resets in %@", "%lld pts ahead of budget", "Updated %lld min ago", "Weekly"] where path.hasPrefix("Sources") {
                #expect(strings[key] != nil, "missing \(key)")
            }
        }
    }
}
