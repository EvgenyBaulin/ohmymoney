import AppCore
import Charts
import SwiftUI

/// A rate over days: a line with a point a day, in the accent colour, the last point marked. It
/// counts nothing: the points come ready (`CurrencyChartPoint`), in 1/10000 of the quote.
struct RateLineChart: View {
  @Environment(\.appAccent) private var accent
  let points: [CurrencyChartPoint]
  let calendar: CalendarContext
  /// What VoiceOver says for a point: the day and the rate in words.
  let describe: (CurrencyChartPoint) -> String

  var body: some View {
    let low = points.map(\.rateE4).min() ?? 0
    let high = points.map(\.rateE4).max() ?? 0
    let pad = max((high - low) / 10, 1)
    Chart {
      ForEach(points) { point in
        LineMark(
          x: .value("Day", calendar.startOfDay(point.day)), y: .value("Rate", point.rateE4)
        )
        .foregroundStyle(ChartTint.accent.color(accent))
        .interpolationMethod(.monotone)
        .accessibilityLabel(Text(verbatim: describe(point)))
      }
      if let last = points.last {
        PointMark(
          x: .value("Day", calendar.startOfDay(last.day)), y: .value("Rate", last.rateE4)
        )
        .foregroundStyle(ChartTint.accent.color(accent))
        .symbol(.circle)
      }
    }
    .chartYScale(domain: (low - pad)...(high + pad))
    .chartYAxis(.hidden)
    .chartXAxis(.hidden)
  }
}
