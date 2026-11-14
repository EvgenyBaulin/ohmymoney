import AppCore
import Charts
import SwiftUI

/// The key rate over time as steps: the rate holds between two decisions, so the line goes flat
/// and then straight up or down on the day of a decision, never in a slope. The last point is
/// marked. It counts nothing: the points come ready (`KeyRatePoint`), in 1/10000 of a percent.
struct KeyRateChart: View {
  @Environment(\.appAccent) private var accent
  let points: [KeyRatePoint]
  let calendar: CalendarContext
  /// What VoiceOver says for a point: the rate and the day it holds from.
  let describe: (KeyRatePoint) -> String

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
        .interpolationMethod(.linear)
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
