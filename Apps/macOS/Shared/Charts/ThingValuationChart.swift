import AppCore
import Charts
import SwiftUI

/// One series per currency, supplied already ordered; values remain integer e4 throughout.
struct ThingValuationChart: View {
  @Environment(\.appAccent) private var accent
  let values: [ThingValuation]
  let calendar: CalendarContext
  let describe: (ThingValuation) -> String

  var body: some View {
    Chart(values) { value in
      LineMark(
        x: .value("Day", calendar.startOfDay(value.day)),
        y: .value("Value", value.amountE4.raw)
      )
      .interpolationMethod(.stepEnd)
      .accessibilityLabel(Text(verbatim: describe(value)))
      PointMark(
        x: .value("Day", calendar.startOfDay(value.day)),
        y: .value("Value", value.amountE4.raw)
      )
      .symbol(.square)
      .accessibilityLabel(Text(verbatim: describe(value)))
    }
    .chartYAxis(.hidden)
    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
    .accessibilityIdentifier("purchases.valuation.chart")
  }
}
