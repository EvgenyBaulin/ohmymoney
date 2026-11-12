import SwiftUI

/// One column of `MonthBarsChart`: a month's spending in whole rubles and the words that read it.
struct MonthBar: Identifiable, Hashable {
  var id: String
  var value: Int64
  /// The month the period is about: drawn in the accent, the others in the strong grey.
  var isHighlighted: Bool
  /// For VoiceOver: «Октябрь 2026, 21 400 ₽».
  var spokenLabel: String
}

/// «По месяцам» of the first page of Analytics (5:36907): twelve columns over the width of the
/// card, the month of the period in the accent and the others grey, no axes — the figures are
/// in the words for VoiceOver and the line under the chart says which month is picked out.
/// The highlighted column differs in colour and is named in words, never by colour alone.
struct MonthBarsChart: View {
  @Environment(\.appTheme) private var theme
  let bars: [MonthBar]
  /// The height of the plot: 100 in the frames of the Mac, the tablet and the phone.
  var height: CGFloat = MonthBarsMetrics.height
  /// Every column in the accent and none picked out: the average receipt of a place by month.
  var allAccent = false

  var body: some View {
    let top = bars.map(\.value).max() ?? 0
    GeometryReader { proxy in
      let bar = MonthBarsMetrics.barWidth(count: bars.count, width: proxy.size.width)
      HStack(alignment: .bottom, spacing: bar * MonthBarsMetrics.gapRatio) {
        ForEach(bars) { column in
          RoundedRectangle(cornerRadius: MonthBarsMetrics.radius)
            .fill(allAccent || column.isHighlighted ? theme.accentDefault : theme.fillStrong)
            .frame(
              width: bar,
              height: MonthBarsMetrics.barHeight(column.value, top: top, plot: proxy.size.height)
            )
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: column.spokenLabel))
            .accessibilityIdentifier("chart.month.\(column.id)")
            .accessibilityAddTraits(.isStaticText)
            .accessibilityAddTraits(column.isHighlighted && !allAccent ? .isSelected : [])
        }
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
    }
    .frame(height: height)
    .accessibilityElement(children: .contain)
  }
}

/// The numbers of the chart as the frame draws it: a plot of 100, twelve columns of 36.4 with
/// 9.2 between them over 538 (the first and the last flush with the edges), the tallest 86.4 of
/// the plot, radius 6.
enum MonthBarsMetrics {
  static let height: CGFloat = 100
  static let gapRatio: CGFloat = 9.2 / 36.4
  static let topRatio: CGFloat = 0.864
  static let radius: CGFloat = 6

  /// The width of a column: `count` columns and the gaps between them fill `width`.
  static func barWidth(count: Int, width: CGFloat) -> CGFloat {
    guard count > 0 else { return 0 }
    return max(0, width / (CGFloat(count) + CGFloat(count - 1) * gapRatio))
  }

  /// The height of a column: its share of the tallest, the tallest at `topRatio` of the plot;
  /// a month with nothing (or refunds that outweighed it) keeps no column.
  static func barHeight(_ value: Int64, top: Int64, plot: CGFloat) -> CGFloat {
    guard top > 0, value > 0 else { return 0 }
    return plot * topRatio * CGFloat(value) / CGFloat(top)
  }
}
