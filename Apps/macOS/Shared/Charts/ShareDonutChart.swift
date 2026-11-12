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
  @Dependency(\.environment) private var environment
  let slices: [ShareDonutSlice]
  let figure: String
  let caption: String
  /// The side of the ring: 120 on the frames of Capital, 160 on those of «Итоги».
  var side: CGFloat = 120
  /// The figure and the word in the hole: 15 bold and 11 in Capital, 13 and 9 in «Итоги».
  var figureType: AppFont = .system(size: 15, weight: .bold)
  var captionType: AppFont = .system(size: 11)

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
      .accessibilityValue(
        Text(verbatim: environment.money.percent(basisPoints: slice.basisPoints, fractionDigits: 0))
      )
      .accessibilityIdentifier("chart.native.share.\(slice.id)")
    }
    .chartLegend(.hidden)
    .frame(width: side, height: side)
    .overlay {
      VStack(spacing: 0) {
        Text(verbatim: figure)
          .appFont(figureType.monospacedDigit())
          .lineLimit(1)
          .minimumScaleFactor(0.6)
        Text(verbatim: caption)
          .appFont(captionType)
          .foregroundStyle(.secondary)
      }
      .frame(width: side * Self.innerRatio - 8)
    }
  }
}
