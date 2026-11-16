import SwiftUI
import QuotaCore
import QuotaUI

/// The menu-bar dropdown. Renders instantly from the cached snapshot; refresh happens off-main.
struct MenuPanelView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let now = model.ticker.now
        VStack(spacing: 0) {
            header(now: now)
            Divider().padding(.horizontal, 12)
            ScrollView {
                LazyVStack(spacing: 10) {
                    if model.snapshot.providers.isEmpty {
                        EmptyStateView(title: L("Nothing to show yet"),
                                       message: L("Enable a provider in Settings or wait for the first refresh."))
                    }
                    ForEach(model.snapshot.providers) { p in
                        ProviderCard(snapshot: p, sparkline: model.sparklines[p.id] ?? [], style: .menu, now: now)
                            .contentShape(Rectangle())
                            .onTapGesture { if let url = p.dashboardURL { NSWorkspace.shared.open(url) } }
                            .help(L("Open the provider's usage dashboard"))
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(12)
                .animation(QPDesign.spring, value: model.snapshot.providers.map(\.id))
            }
            .frame(maxHeight: 520)
            Divider().padding(.horizontal, 12)
            footer
        }
        .frame(width: 360)
        .background(.regularMaterial)
    }

    private func header(now: Date) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.33percent").font(.title3).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 0) {
                Text("QuotaPulse").font(.headline)
                Text(model.lastRefreshAt.map { Present.updatedText($0, now: now) } ?? L("Waiting for first refresh…"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Spacer()
            Button {
                Task { await model.refreshNow() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(model.isRefreshing ? 360 : 0))
                    .animation(model.isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: model.isRefreshing)
            }
            .buttonStyle(.borderless)
            .disabled(model.isRefreshing)
            .help(L("Refresh now"))
            .keyboardShortcut("r")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Button(L("Open QuotaPulse…")) {
                openWindow(id: MainWindow.id)
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.borderless)
            Spacer()
            if model.settings.cloud.enabled, model.cloudAvailable {
                let failed = model.cloudStatus.lastError != nil
                Image(systemName: failed ? "exclamationmark.icloud" : "icloud")
                    .font(.caption2).foregroundStyle(failed ? UsageLevel.hot.color : .secondary)
                    .help(model.cloudStatus.lastError ?? "iCloud")
            }
            if model.settings.hub.enabled {
                Label(model.hubState.hasPrefix("listening") ? L("Hub on") : model.hubState, systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption2).foregroundStyle(.secondary)
                    .help(model.hubState)
            }
            Button {
                model.quit()
            } label: { Image(systemName: "power") }
                .buttonStyle(.borderless)
                .help(L("Quit QuotaPulse"))
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}
