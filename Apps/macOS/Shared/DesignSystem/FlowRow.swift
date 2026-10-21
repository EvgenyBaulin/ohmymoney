import SwiftUI

/// Lays its subviews out left to right at their own size and starts a new line where the next
/// one would not fit: buttons of a narrow column wrap instead of running off its edge. A
/// subview wider than the whole width gets a line of its own, offered that width.
struct FlowRow: Layout {
  var spacing: CGFloat = 8
  var lineSpacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let lines = Self.lines(
      sizes: subviews.map { $0.sizeThatFits(.unspecified) }, width: proposal.width,
      spacing: spacing)
    let height =
      lines.map(\.height).reduce(0, +) + CGFloat(max(0, lines.count - 1)) * lineSpacing
    let width = lines.map(\.width).max() ?? 0
    return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
    let lines = Self.lines(sizes: sizes, width: bounds.width, spacing: spacing)
    var y = bounds.minY
    for line in lines {
      var x = bounds.minX
      for index in line.indices {
        let width = min(sizes[index].width, bounds.width)
        subviews[index].place(
          at: CGPoint(x: x, y: y + (line.height - sizes[index].height) / 2), anchor: .topLeading,
          proposal: ProposedViewSize(width: width, height: sizes[index].height))
        x += width + spacing
      }
      y += line.height + lineSpacing
    }
  }

  struct Line: Equatable {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  /// Which subviews stand on which line, for subviews of `sizes` in a row `width` wide.
  static func lines(sizes: [CGSize], width: CGFloat?, spacing: CGFloat) -> [Line] {
    let limit = width ?? .infinity
    var lines: [Line] = []
    var current = Line()
    for (index, size) in sizes.enumerated() {
      let itemWidth = min(size.width, limit)
      let widened = current.indices.isEmpty ? itemWidth : current.width + spacing + itemWidth
      if !current.indices.isEmpty && widened > limit {
        lines.append(current)
        current = Line()
      }
      current.width = current.indices.isEmpty ? itemWidth : current.width + spacing + itemWidth
      current.height = max(current.height, size.height)
      current.indices.append(index)
    }
    if !current.indices.isEmpty { lines.append(current) }
    return lines
  }
}
