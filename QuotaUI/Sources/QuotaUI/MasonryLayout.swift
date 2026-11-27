import SwiftUI

/// Column ("masonry") layout for provider cards: as many columns as fit at `minColumnWidth`, each card dropped into the
/// currently shortest column, so a short card never leaves a hole beside a tall one the way a row-aligned grid does.
/// Columns grow to `maxColumnWidth` and the block is leading-aligned beyond that, like `GridItem(.adaptive)`.
public struct MasonryLayout: Layout {
    public var minColumnWidth: CGFloat
    public var maxColumnWidth: CGFloat
    public var spacing: CGFloat

    public init(minColumnWidth: CGFloat = 340, maxColumnWidth: CGFloat = 520, spacing: CGFloat = 14) {
        self.minColumnWidth = minColumnWidth
        self.maxColumnWidth = maxColumnWidth
        self.spacing = spacing
    }

    public struct Placement: Equatable, Sendable {
        public var column: Int
        public var origin: CGPoint
        public var size: CGSize
    }

    /// Column count and width for an available width.
    public func columns(for width: CGFloat) -> (count: Int, width: CGFloat) {
        let count = max(1, Int(((width + spacing) / (minColumnWidth + spacing)).rounded(.down)))
        let fill = (width - spacing * CGFloat(count - 1)) / CGFloat(count)
        return (count, max(0, min(maxColumnWidth, fill)))
    }

    /// Where each item goes, given its height at the column width. Ties go to the leftmost column.
    public func arrange(heights: [CGFloat], width: CGFloat) -> (placements: [Placement], size: CGSize) {
        let (count, columnWidth) = columns(for: width)
        var tops = Array(repeating: CGFloat(0), count: count)
        var placements: [Placement] = []
        for h in heights {
            let column = tops.indices.min { tops[$0] < tops[$1] || (tops[$0] == tops[$1] && $0 < $1) } ?? 0
            placements.append(Placement(column: column,
                                        origin: CGPoint(x: CGFloat(column) * (columnWidth + spacing), y: tops[column]),
                                        size: CGSize(width: columnWidth, height: h)))
            tops[column] += h + spacing
        }
        let used = min(count, max(1, heights.count))
        let size = CGSize(width: CGFloat(used) * columnWidth + CGFloat(used - 1) * spacing,
                          height: max(0, (tops.max() ?? 0) - (heights.isEmpty ? 0 : spacing)))
        return (placements, size)
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (placements: [Placement], size: CGSize) {
        let columnWidth = columns(for: width).width
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }
        return arrange(heights: heights, width: width)
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (maxColumnWidth * 2 + spacing)
        return arrange(subviews, width: width).size
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placements = arrange(subviews, width: bounds.width).placements
        for (subview, p) in zip(subviews, placements) {
            subview.place(at: CGPoint(x: bounds.minX + p.origin.x, y: bounds.minY + p.origin.y),
                          proposal: ProposedViewSize(p.size))
        }
    }
}
