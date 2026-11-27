import QuotaCore
import QuotaUI
import SwiftUI

struct WatchHomeView: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        let now = model.ticker.now
        List {
            if model.snapshot.providers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "icloud").font(.title2).foregroundStyle(.secondary)
                    Text(L("Waiting for your Mac")).font(.footnote).multilineTextAlignment(.center)
                    Text(model.cloudAccount == .noAccount ? Present.cloudAccountText(.noAccount) : L("Sign in to the same iCloud account as your Mac."))
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            ForEach(model.snapshot.providers) { p in
                NavigationLink(value: p.id) { WatchProviderRow(provider: p, now: now) }
            }
            if let err = model.lastError, model.snapshot.providers.isEmpty {
                Text(err).font(.caption2).foregroundStyle(.secondary)
            }
            if model.snapshot.generatedAt != .distantPast {
                Text(Present.updatedText(model.snapshot.generatedAt, now: now) + (model.source.isEmpty ? "" : " · \(model.source)"))
                    .font(.caption2).foregroundStyle(.tertiary).listRowBackground(Color.clear)
            }
        }
        .navigationTitle("QuotaPulse")
        .navigationDestination(for: ProviderID.self) { WatchDetailView(provider: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.disabled(model.isRefreshing)
            }
        }
    }
}

struct WatchProviderRow: View {
    let provider: ProviderSnapshot
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            if let w = provider.primaryWindow {
                UsageRing(percent: w.currentUtilization(now: now), color: (provider.health(now: now) ?? .calm).color, lineWidth: 4, showsLabel: false).frame(width: 30, height: 30)
            } else {
                ProviderGlyph(provider, size: 26)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.localizedName).font(.headline)
                if let w = provider.primaryWindow {
                    Text("\(QuotaFormat.percent(w.currentUtilization(now: now))) · \(Present.resetShort(w, now: now))").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                } else if let b = provider.balance {
                    Text(b.formatted).font(.caption2).foregroundStyle(.secondary)
                }
                if provider.status.isError { Text(Present.statusTitle(provider.status)).font(.caption2).foregroundStyle(UsageLevel.hot.color) }
            }
        }
    }
}

struct WatchDetailView: View {
    @Environment(WatchModel.self) private var model
    let provider: ProviderID

    var body: some View {
        let now = model.ticker.now
        ScrollView {
            if let p = model.snapshot.provider(provider) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { ProviderGlyph(p, size: 22); Text(p.localizedName).font(.headline); if let plan = p.account?.plan { PlanBadge(plan) } }
                    ForEach(p.displayWindows) { w in
                        WindowRow(window: w, forecast: p.forecasts[w.id], compact: true, now: now)
                        if let t = Present.forecastText(window: w, forecast: p.forecasts[w.id], now: now) {
                            Text(t).font(.caption2).foregroundStyle(p.forecasts[w.id]?.willExhaustBeforeReset == true ? UsageLevel.critical.color : .secondary)
                        }
                    }
                    if let b = p.balance { BalanceRow(balance: b, forecast: p.forecasts[Sample.balanceWindowID], compact: true) }
                    if p.status.isError { Text(p.status.message).font(.caption2).foregroundStyle(UsageLevel.hot.color) }
                }
                .padding(.horizontal, 4)
            }
        }
        .navigationTitle(model.snapshot.info(provider).localizedName)
    }
}
