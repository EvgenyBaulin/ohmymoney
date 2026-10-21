import AppCore
import Charts
import SwiftUI

/// The spending of the month so far and where it is likely to end: the running total by day,
/// solid with circles; the projection to the last day, dashed, ending with a diamond and
/// «≈ P50»; the interval from P10 to P90 as a light band between two thin lines, which stay
/// visible with «Увеличить контраст» and without colour, with «от P10 до P90» at its end. The
/// band is a fill, not a material: «Уменьшить прозрачность» leaves it as it is.
struct ForecastChart: View {
  /// A day of the band: the interval from P10 to P90 in whole rubles.
  struct BandPoint: Hashable {
    var day: Int
    var low: Int64
    var high: Int64
    var spokenLabel: String
    var valueText: String
  }

  @Dependency(\.environment) private var environment
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.appAccent) private var accent
  let actual: [ChartLinePoint]
  let projection: [ChartLinePoint]
  let band: [BandPoint]
  let dayCount: Int
  let xLabels: [Int: String]
  /// «≈ 48,200 ₽» at the diamond.
  let middleText: String
  /// «от 44,000 до 53,000 ₽» at the end of the band; `nil` when the interval is a point.
  let rangeText: String?
  let legend: [ChartLegend.Item]

  var body: some View {
    let money = environment.money
    let thin: CGFloat = contrast == .increased ? 1.5 : 1
    let actualStyle = ChartSeriesStyle.current
    let projectionStyle = ChartSeriesStyle.projection
    VStack(alignment: .leading, spacing: 8) {
      Chart {
        ForEach(band, id: \.day) { point in
          AreaMark(
            x: .value("Day", point.day), yStart: .value("P10", point.low),
            yEnd: .value("P90", point.high)
          )
          // The third level of the accent: a light fill of the system's own, not an opacity
          // of ours (no floating-point number in the charts).
          .foregroundStyle(ChartTint.accent.color(accent).tertiary)
          .accessibilityLabel(Text(verbatim: point.spokenLabel))
          .accessibilityValue(Text(verbatim: point.valueText))
        }
        ForEach(band, id: \.day) { point in
          LineMark(
            x: .value("Day", point.day), y: .value("Amount", point.low),
            series: .value("Series", "p10")
          )
          .foregroundStyle(ChartTint.accent.color(accent))
          .lineStyle(StrokeStyle(lineWidth: thin))
          .accessibilityHidden(true)
        }
        ForEach(band, id: \.day) { point in
          LineMark(
            x: .value("Day", point.day), y: .value("Amount", point.high),
            series: .value("Series", "p90")
          )
          .foregroundStyle(ChartTint.accent.color(accent))
          .lineStyle(StrokeStyle(lineWidth: thin))
          .accessibilityHidden(true)
        }
        ForEach(actual, id: \.x) { point in
          LineMark(
            x: .value("Day", point.x), y: .value("Amount", point.value),
            series: .value("Series", "actual")
          )
          .foregroundStyle(actualStyle.tint.color(accent))
          .lineStyle(actualStyle.stroke(contrast))
          .symbol(actualStyle.symbol.shape)
          .symbolSize(24)
          .accessibilityLabel(Text(verbatim: point.spokenLabel))
          .accessibilityValue(Text(verbatim: point.valueText))
        }
        ForEach(projection, id: \.x) { point in
          LineMark(
            x: .value("Day", point.x), y: .value("Amount", point.value),
            series: .value("Series", "projection")
          )
          .foregroundStyle(projectionStyle.tint.color(accent))
          .lineStyle(projectionStyle.stroke(contrast))
          .symbolSize(0)
          .accessibilityHidden(true)
        }
        if let end = projection.last {
          PointMark(x: .value("Day", end.x), y: .value("Amount", end.value))
            .foregroundStyle(projectionStyle.tint.color(accent))
            .symbol(projectionStyle.symbol.shape)
            .symbolSize(70)
            .annotation(position: .trailing, alignment: .leading, spacing: 4) {
              Text(verbatim: middleText)
                .appFont(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize()
            }
            .accessibilityLabel(Text(verbatim: end.spokenLabel))
            .accessibilityValue(Text(verbatim: end.valueText))
        }
        if let rangeText, let end = band.last {
          PointMark(x: .value("Day", end.day), y: .value("Amount", end.high))
            .symbolSize(0)
            .annotation(position: .topTrailing, alignment: .leading, spacing: 2) {
              Text(verbatim: rangeText)
                .appFont(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
            }
            .accessibilityHidden(true)
        }
      }
      // The words at the end of the month need room after its last day.
      .chartXScale(domain: 1...(dayCount + max(2, dayCount / 5)))
      .chartXAxis {
        AxisMarks(values: xLabels.keys.sorted()) { value in
          AxisGridLine()
          AxisValueLabel {
            if let day = value.as(Int.self), let text = xLabels[day] {
              Text(verbatim: text)
                .appFont(.caption.monospacedDigit())
            }
          }
        }
      }
      .chartYAxis {
        AxisMarks(values: .automatic(desiredCount: 4)) { value in
          AxisGridLine()
          AxisValueLabel {
            Text(verbatim: ChartAxis.money(value, money))
              .appFont(.caption.monospacedDigit())
          }
        }
      }
      .frame(height: 240)
      ChartLegend(items: legend)
    }
  }
}
