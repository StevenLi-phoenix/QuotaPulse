import Foundation
import Testing
import QuotaCore
@testable import QuotaUI

/// The dropdown formatter: one line per provider window with its percent and reset, one for a
/// balance, one for extra usage — plus the empty and error cases the panel prints as a line.
@Suite struct MenuSummaryTests {
    let now = Date(timeIntervalSince1970: 1_792_120_000)

    private func window(_ id: String, _ title: String, used: Double, resetsIn: TimeInterval? = nil,
                        semantics: ResetSemantics = .fixedCadence,
                        availability: WindowAvailability = .reported) -> UsageWindow {
        UsageWindow(id: id, title: title, utilization: used,
                    resetsAt: resetsIn.map { now.addingTimeInterval($0) },
                    duration: resetsIn, resetSemantics: semantics, availability: availability)
    }

    private func snapshot(_ providers: [ProviderSnapshot]) -> QuotaSnapshot {
        QuotaSnapshot(generatedAt: now, hubName: "Mac", providers: providers)
    }

    @Test func oneLinePerWindowRoundsUsedPercent() {
        let claude = ProviderSnapshot(
            id: .claude, fetchedAt: now, account: AccountInfo(plan: "Max 20x"),
            windows: [window("five_hour", "5-hour", used: 7.2, resetsIn: 7200),
                      window("seven_day", "Weekly", used: 42.4, resetsIn: 7200),
                      window("almost", "Almost", used: 99.97, resetsIn: 7200)])
        let groups = MenuSummary.groups(for: snapshot([claude]), now: now)
        #expect(groups.count == 1)
        let group = groups[0]
        #expect(group.provider == .claude)
        #expect(group.plan == "Max 20x")
        #expect(group.lines.map(\.title) == ["5-hour", "Weekly", "Almost"])
        #expect(group.lines.map(\.value) == ["7.2%", "42%", "100%"])
        #expect(group.lines.map(\.reset) == ["2h", "2h", "2h"])
        #expect(group.lines.map(\.percent) == [7.2, 42.4, 99.97])
        #expect(group.lines.filter { !$0.isReported }.isEmpty)
    }

    @Test func unknownResetReadsAsDash() {
        let codex = ProviderSnapshot(id: .codex, fetchedAt: now,
                                     windows: [window("five_hour", "5-hour", used: 30)])
        let line = MenuSummary.group(for: codex, now: now).lines[0]
        #expect(line.value == "30%")
        #expect(line.reset == "—")
    }

    @Test func emptySnapshotHasNoGroups() {
        #expect(MenuSummary.groups(for: .empty, now: now).isEmpty)
        #expect(MenuSummary.groups(for: snapshot([]), now: now).isEmpty)
    }

    @Test func errorWithoutDataKeepsStatusInOneGroup() {
        let offline = ProviderSnapshot(id: .codex, fetchedAt: now,
                                       status: .network("The Internet connection appears to be offline."))
        let group = MenuSummary.group(for: offline, now: now)
        #expect(group.lines.isEmpty)
        #expect(!group.hasLines)
        #expect(group.status.isError)
        // A stale reading survives the error: the line stays, the status still says why.
        let stale = ProviderSnapshot(id: .claude, fetchedAt: now, status: .unauthorized("Claude rejected the token (401)."),
                                     windows: [window("five_hour", "5-hour", used: 55, resetsIn: 3600)])
        let staleGroup = MenuSummary.group(for: stale, now: now)
        #expect(staleGroup.lines.count == 1)
        #expect(staleGroup.lines[0].value == "55%")
        #expect(staleGroup.status.isError)
    }

    @Test func balanceAndExtraUsageUseUsedOverTotal() {
        let forecast = Forecast(confidence: .medium, rate: 1.2, daysRemaining: 19.6, sampleCount: 20, span: 7200)
        let deepseek = ProviderSnapshot(id: .deepseek, fetchedAt: now,
                                        balance: Balance(currency: "CNY", total: 23.456, granted: 0, toppedUp: 23.456),
                                        forecasts: [Sample.balanceWindowID: forecast])
        let group = MenuSummary.group(for: deepseek, now: now)
        #expect(group.lines.count == 1)
        #expect(group.lines[0].title == L("Balance"))
        #expect(group.lines[0].value == "¥23.46")
        #expect(group.lines[0].percent == nil)
        #expect(group.lines[0].reset == L("≈ 20d left"))

        let claude = ProviderSnapshot(id: .claude, fetchedAt: now,
                                      windows: [window("five_hour", "5-hour", used: 12, resetsIn: 7200)],
                                      extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: 50, usedCredits: 3.2,
                                                             utilization: 6.4, currency: "USD"))
        let extra = MenuSummary.group(for: claude, now: now).lines.last!
        #expect(extra.title == L("Extra usage"))
        #expect(extra.value == "$3.20 / $50.00")
        #expect(extra.percent == 6.4)
    }

    @Test func balanceWithoutPaceHasNoDaysLeft() {
        let deepseek = ProviderSnapshot(id: .deepseek, fetchedAt: now,
                                        balance: Balance(currency: "USD", total: 3.5))
        #expect(MenuSummary.group(for: deepseek, now: now).lines[0].reset == "—")
        let learning = Forecast(confidence: .insufficient, sampleCount: 1)
        let withSamples = ProviderSnapshot(id: .deepseek, fetchedAt: now,
                                           balance: Balance(currency: "USD", total: 3.5),
                                           forecasts: [Sample.balanceWindowID: learning])
        #expect(MenuSummary.group(for: withSamples, now: now).lines[0].reset == "—")
    }

    @Test func notReportedWindowStaysAsDimmedLine() {
        let codex = ProviderSnapshot(id: .codex, fetchedAt: now,
                                     windows: [window("secondary", "Weekly", used: 0, availability: .notReported)])
        let line = MenuSummary.group(for: codex, now: now).lines[0]
        #expect(!line.isReported)
        #expect(line.percent == nil)
        #expect(line.reset == L("n/a"))
    }

    @Test func groupsKeepSnapshotOrder() {
        let a = ProviderSnapshot(id: .claude, fetchedAt: now)
        let b = ProviderSnapshot(id: .deepseek, fetchedAt: now, balance: Balance(currency: "USD", total: 1))
        #expect(MenuSummary.groups(for: snapshot([a, b]), now: now).map(\.id) == ["claude", "deepseek"])
    }
}
