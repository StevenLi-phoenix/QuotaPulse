import Foundation
import Testing
@testable import QuotaCore

@Suite struct ForecastTests {
    let now = Date(timeIntervalSince1970: 1_760_600_000)

    func window(util: Double, resetIn: TimeInterval = 2 * 3600, duration: TimeInterval = 5 * 3600) -> UsageWindow {
        UsageWindow(id: "five_hour", title: "5-hour", utilization: util, resetsAt: now.addingTimeInterval(resetIn), duration: duration)
    }

    func samples(_ points: [(minutesAgo: Double, value: Double)], resetsAt: Date? = nil) -> [Sample] {
        points.map { Sample(provider: .claude, window: "five_hour", at: now.addingTimeInterval(-$0.minutesAgo * 60), value: $0.value, resetsAt: resetsAt) }
    }

    @Test func insufficientWithOneSample() {
        let f = ForecastEngine.forecast(window: window(util: 10), samples: samples([(0, 10)]), now: now)
        #expect(f.confidence == .insufficient)
        #expect(f.sampleCount == 1)
    }

    @Test func insufficientWhenSpanTooShort() {
        let f = ForecastEngine.forecast(window: window(util: 12), samples: samples([(5, 10), (0, 12)]), now: now)
        #expect(f.confidence == .insufficient)
    }

    @Test func linearBurnProjectsExhaustionBeforeReset() {
        // 10 %/h for the last hour, 40 % used now, reset in 2 h → hits 100 % in 6 h, after reset.
        let s = samples([(60, 30), (45, 32.5), (30, 35), (15, 37.5), (0, 40)])
        let f = ForecastEngine.forecast(window: window(util: 40, resetIn: 2 * 3600), samples: s, now: now)
        #expect(abs(f.rate - 10) < 0.01)
        #expect(f.exhaustionAt == nil)
        #expect(abs((f.projectedAtReset ?? 0) - 60) < 0.01)
        #expect(f.confidence == .medium)
        // Faster burn: 40 %/h → full in 1.5 h, before the 2 h reset.
        let fast = samples([(60, 0), (30, 20), (0, 40)])
        let g = ForecastEngine.forecast(window: window(util: 40, resetIn: 2 * 3600), samples: fast, now: now)
        #expect(g.exhaustionAt != nil)
        #expect(abs(g.exhaustionAt!.timeIntervalSince(now) - 1.5 * 3600) < 1)
        #expect(g.projectedAtReset == 100)
    }

    @Test func paceDeltaAgainstLinearBudget() {
        // Window is 5h, 3h elapsed (reset in 2h) → linear budget 60 %. At 40 % we're 20 points under.
        let s = samples([(60, 30), (0, 40)])
        let f = ForecastEngine.forecast(window: window(util: 40, resetIn: 2 * 3600), samples: s, now: now)
        #expect(abs((f.paceDelta ?? 0) + 20) < 0.01)
    }

    @Test func resetInsideHistoryStartsNewCycle() {
        // Old cycle ran to 95 %, reset happened 50 min ago, new cycle climbs 0 → 10.
        let s = samples([(200, 80), (150, 90), (100, 95), (50, 0), (25, 5), (0, 10)])
        let w = UsageWindow(id: "five_hour", title: "5-hour", utilization: 10, resetsAt: now.addingTimeInterval(4 * 3600), duration: nil)
        let cycle = ForecastEngine.currentCycle(samples: s, window: w, now: now)
        #expect(cycle.count == 3)
        let f = ForecastEngine.forecast(window: w, samples: s, now: now)
        #expect(abs(f.rate - 12) < 0.01)
    }

    @Test func windowStartCutsOldSamples() {
        let s = samples([(300, 90), (200, 95), (100, 2), (0, 6)])
        // duration 5h, reset in 3h → start 2h ago (120 min) → only the last two samples count
        let w = window(util: 6, resetIn: 3 * 3600, duration: 5 * 3600)
        #expect(ForecastEngine.currentCycle(samples: s, window: w, now: now).count == 2)
    }

    @Test func staleSamplesAreIgnored() {
        let s = samples([(600, 50), (560, 55)])
        let f = ForecastEngine.forecast(window: window(util: 55), samples: s, now: now)
        #expect(f.confidence == .insufficient)
    }

    @Test func flatUsageHasNoExhaustion() {
        let s = samples([(90, 50), (60, 50), (30, 50), (0, 50)])
        let f = ForecastEngine.forecast(window: window(util: 50), samples: s, now: now)
        #expect(f.rate == 0)
        #expect(f.exhaustionAt == nil)
        #expect(f.projectedAtReset == 50)
    }

    @Test func balanceBurnAndTopUp() {
        let b = Balance(currency: "USD", total: 20)
        let s: [Sample] = [
            Sample(provider: .deepseek, window: "balance", at: now.addingTimeInterval(-3 * 86400), value: 5),
            Sample(provider: .deepseek, window: "balance", at: now.addingTimeInterval(-2 * 86400), value: 50), // top-up → new segment
            Sample(provider: .deepseek, window: "balance", at: now.addingTimeInterval(-1 * 86400), value: 35),
            Sample(provider: .deepseek, window: "balance", at: now, value: 20),
        ]
        let f = ForecastEngine.forecast(balance: b, samples: s, now: now)
        #expect(abs(f.rate - 15) < 0.01)
        #expect(abs((f.daysRemaining ?? 0) - 20.0 / 15.0) < 0.01)
        #expect(f.sampleCount == 3)
    }

    @Test func regressionAndDownsample() {
        #expect(Regression.slope([(0, 0), (1, 2), (2, 4)]) == 2)
        #expect(Regression.slope([(1, 5), (1, 7)]) == 0)
        let many = (0..<1000).map { Sample(provider: .claude, window: "w", at: now.addingTimeInterval(Double($0)), value: Double($0)) }
        let ds = Downsample.samples(many, maxPoints: 100)
        #expect(ds.count <= 100 && ds.count >= 95)
        #expect(ds.first!.value < ds.last!.value)
        #expect(Downsample.samples(Array(many.prefix(10)), maxPoints: 100).count == 10)
    }
}
