import SwiftUI
import QuotaCore
import QuotaUI

/// The menu-bar dropdown. Renders instantly from the cached snapshot; refresh happens off-main.
///
/// The old body was a `ScrollView` + `LazyVStack` of tall cards, and the panel showed only its
/// header and footer. This is a plain, non-scrolling column instead: a compact group per provider
/// and one line per window, so every number fits without opening the main window.
struct MenuPanelView: View {
    @Environment(AppModel.self) private var model
    @Environment(Updater.self) private var updater
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let now = model.ticker.now
        let groups = MenuSummary.groups(for: model.snapshot, now: now)
        VStack(spacing: 0) {
            header(now: now)
            Divider().padding(.horizontal, 12)
            VStack(alignment: .leading, spacing: 10) {
                if groups.isEmpty {
                    placeholder
                } else {
                    ForEach(groups) { group in
                        providerGroup(group)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider().padding(.horizontal, 12)
            footer
        }
        .frame(width: 340)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Header

    private func header(now: Date) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.33percent").font(.title3).foregroundStyle(.tint)
            Text("QuotaPulse").font(.headline)
            Spacer(minLength: 8)
            Text(model.lastRefreshAt.map { Present.updatedText($0, now: now) } ?? L("Waiting for first refresh…"))
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1)
                .contentTransition(.opacity)
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

    // MARK: Body

    /// One clear line for the two states that have no rows yet: still reading, or nothing enabled.
    @ViewBuilder
    private var placeholder: some View {
        HStack(spacing: 8) {
            if model.lastRefreshAt == nil {
                ProgressView().controlSize(.small)
                Text(L("Reading quotas…")).font(.callout).foregroundStyle(.secondary)
            } else {
                Image(systemName: "tray").foregroundStyle(.secondary)
                Text(L("No data yet — enable a provider in Settings.")).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private func providerGroup(_ group: MenuSummary.Group) -> some View {
        MenuGroupView(group: group)
            .contentShape(Rectangle())
            .onTapGesture { if let url = group.info.dashboardURL { NSWorkspace.shared.open(url) } }
            .help(L("Open the provider's usage dashboard"))
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button(L("Open QuotaPulse…")) {
                openWindow(id: MainWindow.id)
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.borderless)
            // Gentle reminder: a scheduled check found a version while QuotaPulse was in the background.
            if let version = updater.availableVersion {
                Button {
                    updater.checkForUpdates()
                } label: {
                    Label(L("Update available"), systemImage: "arrow.down.circle.fill").font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
                .help(version)
            }
            Spacer()
            if model.settings.cloud.enabled, model.cloudAvailable {
                let failed = model.cloudStatus.lastError != nil
                Image(systemName: failed ? "exclamationmark.icloud" : "icloud")
                    .font(.caption2).foregroundStyle(failed ? UsageLevel.hot.color : .secondary)
                    .help(model.cloudStatus.lastError ?? "iCloud")
            }
            if model.settings.hub.enabled {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.caption2)
                    .foregroundStyle(model.hubState.hasPrefix("listening") ? .secondary : UsageLevel.warm.color)
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
