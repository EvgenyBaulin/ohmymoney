import SwiftUI

/// Lays its subviews out in one row, each as wide as its weight's part of the row: the bars
/// of shares on the cards of Overview. A weight of zero or less — a bucket that has no
/// share because refunds outweighed the spending — gets no width and no gap beside it.
///
/// The weights are whole basis points, and the widths come from them alone: nothing here
/// turns money into a floating-point number.
struct ProportionalRow: Layout {
  var weights: [Int]
  var spacing: CGFloat = 0

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let height =
      proposal.height ?? subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
    return CGSize(width: proposal.width ?? 0, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let widths = Self.widths(of: bounds.width, weights: weights, spacing: spacing)
    var x = bounds.minX
    for (index, subview) in subviews.enumerated() {
      let width = index < widths.count ? widths[index] : 0
      subview.place(
        at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
        proposal: ProposedViewSize(width: width, height: bounds.height))
      if width > 0 { x += width + spacing }
    }
  }

  /// The width of each weight: what the gaps between the visible segments leave, shared in
  /// proportion.
  static func widths(of total: CGFloat, weights: [Int], spacing: CGFloat) -> [CGFloat] {
    let positive = weights.map { max(0, $0) }
    let sum = positive.reduce(0, +)
    guard sum > 0, total > 0 else { return weights.map { _ in 0 } }
    let gaps = CGFloat(max(0, positive.filter { $0 > 0 }.count - 1)) * spacing
    let room = max(0, total - gaps)
    return positive.map { room * CGFloat($0) / CGFloat(sum) }
  }
}
