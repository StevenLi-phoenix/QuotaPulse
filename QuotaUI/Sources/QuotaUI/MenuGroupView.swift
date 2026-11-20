import SwiftUI
import QuotaCore

/// One provider in the menu-bar dropdown: header (glyph, name, plan, status) and one row per window / balance.
/// Lives in QuotaUI so `WidgetRender` can draw the real thing headlessly for contrast checks.
public struct MenuGroupView: View {
    public var group: MenuSummary.Group

    public init(group: MenuSummary.Group) { self.group = group }

    public var body: some View {
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
    }

    private func lineRow(_ line: MenuSummary.Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.title)
                .font(.caption)
                .foregroundStyle(line.isReported ? Color.primary.opacity(0.75) : Color.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let percent = line.percent {
                // Window rows: a bar instead of the number (exact value in the tooltip / VoiceOver).
                UsageBar(percent: percent, height: 9, neutralTrack: true)
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
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 56, alignment: .trailing)
        }
        .padding(.leading, 24)
    }

    private func valueStyle(_ line: MenuSummary.Line) -> AnyShapeStyle {
        if let percent = line.percent { return AnyShapeStyle(UsageLevel(percent: percent).color) }
        return AnyShapeStyle(line.isReported ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.secondary)
    }
}
