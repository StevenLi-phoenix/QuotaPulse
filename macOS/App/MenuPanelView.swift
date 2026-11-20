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
        .background(.regularMaterial)
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ProviderGlyph(group.info, size: 18)
                Text(group.info.localizedName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if let plan = group.plan, !plan.isEmpty { PlanBadge(plan) }
                Spacer(minLength: 4)
                if group.status.isError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(UsageLevel.hot.color)
                        .help(group.status.message)
                }
            }
            ForEach(group.lines) { line in
                lineRow(line)
            }
            // Error, or a provider that has not answered yet: one line instead of a blank group.
            if !group.hasLines {
                Text(group.status.isError
                     ? "\(Present.statusTitle(group.status)) · \(group.status.message)"
                     : L("Waiting for first refresh…"))
                    .font(.caption)
                    .foregroundStyle(group.status.isError ? UsageLevel.hot.color : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 24)
                    .help(group.status.message)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if let url = group.info.dashboardURL { NSWorkspace.shared.open(url) } }
        .help(L("Open the provider's usage dashboard"))
    }

    private func lineRow(_ line: MenuSummary.Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.title)
                .font(.caption)
                .foregroundStyle(line.isReported ? .secondary : .tertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let percent = line.percent {
                // Window rows: a bar instead of the number (exact value in the tooltip / VoiceOver).
                UsageBar(percent: percent, height: 6)
                    .frame(width: 120)
                    .help(line.value)
                    .accessibilityElement()
                    .accessibilityLabel(Text(line.title))
                    .accessibilityValue(Text(line.value))
            } else {
                Text(line.value)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(valueStyle(line))
                    .contentTransition(.numericText())
            }
            Text(line.reset)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(minWidth: 56, alignment: .trailing)
        }
        .padding(.leading, 24)
    }

    private func valueStyle(_ line: MenuSummary.Line) -> AnyShapeStyle {
        if let percent = line.percent { return AnyShapeStyle(UsageLevel(percent: percent).color) }
        return AnyShapeStyle(line.isReported ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.tertiary)
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
