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

@Suite struct ResetSemanticsTests {
    let now = Date(timeIntervalSince1970: 1_792_120_000)

    @Test func claudeExpiredWindowAwaitsFirstUse() {
        // Reset passed 10 minutes ago: quota is fresh, no countdown, no forecast, utilization reads 0.
        let w = UsageWindow(id: "five_hour", title: "5-hour", utilization: 87, resetsAt: now.addingTimeInterval(-600), duration: 5 * 3600, resetSemantics: .rollingFromFirstUse)
        #expect(w.effectiveResetsAt(now: now) == nil)
        #expect(w.phase(now: now) == .awaitingFirstUse)
        #expect(w.currentUtilization(now: now) == 0)
        var samples: [Sample] = []
        for i in 0..<6 {
            let offset: TimeInterval = -3600 + Double(i) * 500
            samples.append(Sample(provider: .claude, window: "five_hour", at: now.addingTimeInterval(offset), value: 60 + Double(i) * 5))
        }
        #expect(ForecastEngine.forecast(window: w, samples: samples, now: now).confidence == .insufficient)
        // The API also drops the reset time once the window is cleared.
        let cleared = UsageWindow(id: "five_hour", title: "5-hour", utilization: 0, resetsAt: nil, duration: 5 * 3600, resetSemantics: .rollingFromFirstUse)
        #expect(cleared.phase(now: now) == .awaitingFirstUse)
        let inUseUnknown = UsageWindow(id: "five_hour", title: "5-hour", utilization: 12, resetsAt: nil, duration: 5 * 3600, resetSemantics: .rollingFromFirstUse)
        #expect(inUseUnknown.phase(now: now) == .unknown)
    }

    @Test func codexExpiredWindowRollsForward() {
        // Reset passed 2h10m ago on a 5-hour cadence → next reset is 2h50m from now, utilization unchanged.
        let w = UsageWindow(id: "primary", title: "5-hour", utilization: 20, resetsAt: now.addingTimeInterval(-(2 * 3600 + 600)), duration: 5 * 3600, resetSemantics: .fixedCadence)
        let next = w.effectiveResetsAt(now: now)
        #expect(next == now.addingTimeInterval(2 * 3600 + 3000))
        #expect(w.phase(now: now) == .active(resetsAt: next!))
        #expect(w.cycleStart(now: now) == next!.addingTimeInterval(-5 * 3600))
        #expect(w.currentUtilization(now: now) == 20)
        // Two cycles behind still lands in the current one.
        let old = UsageWindow(id: "primary", title: "5-hour", utilization: 20, resetsAt: now.addingTimeInterval(-(11 * 3600)), duration: 5 * 3600, resetSemantics: .fixedCadence)
        #expect(old.effectiveResetsAt(now: now) == now.addingTimeInterval(4 * 3600))
        // Pace uses the rolled cycle: 2h10m into a 5h cycle → linear budget 43.3 %, at 20 % we're ~23 under.
        let samples = [Sample(provider: .codex, window: "primary", at: now.addingTimeInterval(-1800), value: 15), Sample(provider: .codex, window: "primary", at: now, value: 20)]
        let f = ForecastEngine.forecast(window: w, samples: samples, now: now)
        let elapsed: Double = 2 * 3600 + 600
        let expectedPace: Double = 20 - elapsed / 18000 * 100
        #expect(abs((f.paceDelta ?? 0) - expectedPace) < 0.01)
        let hoursToReset: Double = 2 + 3000 / 3600
        let expectedProjected: Double = 20 + 10 * hoursToReset
        #expect(abs((f.projectedAtReset ?? 0) - expectedProjected) < 0.01)
    }

    @Test func claudeNewWindowResetsSampleSeries() {
        // Old window climbed to 90 %, was cleared, and a new window started 40 min ago at a new reset time.
        let oldReset = now.addingTimeInterval(-3000)
        let newReset = now.addingTimeInterval(5 * 3600 - 2400)
        var samples: [Sample] = []
        for i in 0..<5 {
            let offset: TimeInterval = -7200 + Double(i) * 600
            samples.append(Sample(provider: .claude, window: "five_hour", at: now.addingTimeInterval(offset), value: 50 + Double(i) * 10, resetsAt: oldReset))
        }
        samples += [
            Sample(provider: .claude, window: "five_hour", at: now.addingTimeInterval(-2400), value: 3, resetsAt: newReset),
            Sample(provider: .claude, window: "five_hour", at: now.addingTimeInterval(-1200), value: 8, resetsAt: newReset),
            Sample(provider: .claude, window: "five_hour", at: now, value: 13, resetsAt: newReset),
        ]
        let w = UsageWindow(id: "five_hour", title: "5-hour", utilization: 13, resetsAt: newReset, duration: 5 * 3600, resetSemantics: .rollingFromFirstUse)
        let cycle = ForecastEngine.currentCycle(samples: samples, window: w, now: now)
        #expect(cycle.count == 3)
        let f = ForecastEngine.forecast(window: w, samples: samples, now: now)
        #expect(abs(f.rate - 15) < 0.01)
        #expect(f.exhaustionAt == nil)
    }

    @Test func windowCodableDefaultsSemantics() throws {
        let json = Data("{\"id\":\"w\",\"title\":\"W\",\"utilization\":5}".utf8)
        let w = try JSON.decoder.decode(UsageWindow.self, from: json)
        #expect(w.resetSemantics == .fixedCadence)
        let claude = UsageWindow(id: "x", title: "X", utilization: 1, resetsAt: nil, duration: nil, resetSemantics: .rollingFromFirstUse)
        let back = try JSON.decoder.decode(UsageWindow.self, from: try JSON.encoder.encode(claude))
        #expect(back == claude)
    }

    @Test func codexCreditsAndSingleWindow() throws {
        let json = """
        {"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":604800,"reset_at":1792649646},"secondary_window":null},
         "credits":{"has_credits":true,"unlimited":false,"balance":"62484.4310550000"}}
        """
        let snap = try CodexProvider.parse(Data(json.utf8), now: now)
        #expect(snap.windows.count == 1)
        #expect(snap.windows[0].title == "Weekly")
        #expect(snap.windows[0].note == "Only window reported for this plan")
        #expect(snap.windows[0].resetSemantics == .fixedCadence)
        #expect(snap.balance?.isCredits == true)
        #expect(snap.balance?.formatted == "62,484 credits")
    }

    @Test func claudeLimitsKindsAreNotDuplicated() throws {
        let json = """
        {"five_hour":{"utilization":43,"resets_at":"2026-10-16T15:29:59.890327+00:00"},"seven_day":{"utilization":28,"resets_at":"2026-10-22T14:59:59.890352+00:00"},
         "limits":[{"kind":"session","group":"session","percent":43,"resets_at":"2026-10-16T15:29:59.890327+00:00"},
                   {"kind":"weekly_all","group":"weekly","percent":28,"resets_at":"2026-10-22T14:59:59.890352+00:00"},
                   {"kind":"weekly_scoped","group":"weekly","percent":15,"resets_at":"2026-10-22T14:59:59.890572+00:00"}]}
        """
        let snap = try ClaudeProvider.parse(Data(json.utf8), now: now)
        #expect(snap.windows.map(\.id) == ["five_hour", "seven_day", "limit_weekly_weekly_scoped"])
        #expect(snap.windows[2].title == "Weekly · Model-scoped")
        #expect(snap.windows.allSatisfy { $0.resetSemantics == .rollingFromFirstUse })
    }
}
