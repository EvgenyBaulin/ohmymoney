import Charts
import SwiftUI

/// One part of a whole on a ring: its share in basis points (100 % = 10,000) and its colour.
/// Whole numbers only — the ring draws shares, never money.
struct ShareDonutSlice: Hashable, Identifiable {
  var id: String
  var name: String
  var basisPoints: Int
  var tint: Color
}

/// A ring of shares with a figure and a word in its hole («2.6 млн ₽», «есть»), as the design
/// draws «Из чего складывается»: the parts clockwise from the top in the given order, a thin gap
/// between them. The ring never carries the meaning alone — the legend beside it names every
/// part with its percent.
struct ShareDonutChart: View {
  let slices: [ShareDonutSlice]
  let figure: String
  let caption: String
  /// The side of the ring: 120 on every frame.
  var side: CGFloat = 120

  /// The hole: the ring is 16 % of the side wide, as the frames draw it.
  static let innerRatio: CGFloat = 0.68
  /// The gap between two parts, in degrees.
  static let gap: CGFloat = 1.5

  var body: some View {
    Chart(slices) { slice in
      SectorMark(
        angle: .value("Share", slice.basisPoints),
        innerRadius: .ratio(Self.innerRatio),
        angularInset: Self.gap
      )
      .foregroundStyle(slice.tint)
      .accessibilityLabel(Text(verbatim: slice.name))
    }
    .chartLegend(.hidden)
    .frame(width: side, height: side)
    .overlay {
      VStack(spacing: 0) {
        Text(verbatim: figure)
          .appFont(.system(size: 15, weight: .bold).monospacedDigit())
          .lineLimit(1)
          .minimumScaleFactor(0.6)
        Text(verbatim: caption)
          .appFont(.system(size: 11))
          .foregroundStyle(.secondary)
      }
      .frame(width: side * Self.innerRatio - 8)
    }
  }
}
