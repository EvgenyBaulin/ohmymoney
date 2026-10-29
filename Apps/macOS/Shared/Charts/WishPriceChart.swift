import AppCore
import Charts
import SwiftUI

/// The prices of a wish noted over days: a line with a square on every noted price, the lowest
/// one marked with a diamond and the last one with a circle, so the shapes tell what the colour
/// only confirms. It counts nothing: the prices come ready, in 1/10000 of the currency.
struct WishPriceChart: View {
  @Environment(\.appAccent) private var accent
  let prices: [WishPrice]
  let calendar: CalendarContext
  /// What VoiceOver says for a price: the day and the amount in words.
  let describe: (WishPrice) -> String

  var body: some View {
    let values = prices.map(\.priceE4.raw)
    let low = values.min() ?? 0
    let high = values.max() ?? 0
    let pad = max((high - low) / 8, 1)
    let lowest = prices.last { $0.priceE4.raw == low }
    Chart {
      ForEach(prices) { price in
        LineMark(
          x: .value("Day", calendar.startOfDay(price.onDate)),
          y: .value("Price", price.priceE4.raw)
        )
        .foregroundStyle(ChartTint.accent.color(accent))
        .interpolationMethod(.stepEnd)
        .accessibilityLabel(Text(verbatim: describe(price)))
        PointMark(
          x: .value("Day", calendar.startOfDay(price.onDate)),
          y: .value("Price", price.priceE4.raw)
        )
        .foregroundStyle(ChartTint.accent.color(accent))
        .symbol(ChartSymbol.square.shape)
        .symbolSize(18)
      }
      if let lowest {
        PointMark(
          x: .value("Day", calendar.startOfDay(lowest.onDate)),
          y: .value("Price", lowest.priceE4.raw)
        )
        .foregroundStyle(ChartTint.green.color(accent))
        .symbol(ChartSymbol.diamond.shape)
        .symbolSize(70)
      }
      if let last = prices.last {
        PointMark(
          x: .value("Day", calendar.startOfDay(last.onDate)),
          y: .value("Price", last.priceE4.raw)
        )
        .foregroundStyle(ChartTint.accent.color(accent))
        .symbol(ChartSymbol.circle.shape)
        .symbolSize(70)
      }
    }
    .chartYScale(domain: (low - pad)...(high + pad))
    .chartYAxis(.hidden)
    .chartXAxis {
      AxisMarks(values: .automatic(desiredCount: 3))
    }
  }
}
