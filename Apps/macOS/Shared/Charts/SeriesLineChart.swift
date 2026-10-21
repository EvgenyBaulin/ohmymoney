import AppCore
import Charts
import SwiftUI

/// One point of a line: its place on the axis — a day of the period, a month — and whole
/// rubles.
struct ChartLinePoint: Hashable {
  var x: Int
  var value: Int64
  /// «18 сентября», «сентябрь 2026»: what VoiceOver says for the point.
  var spokenLabel: String
  var valueText: String
}

/// One line with its style and the words at its end.
struct ChartLineSeries: Identifiable, Hashable {
  var id: String
  var label: String
  var style: ChartSeriesStyle
  var points: [ChartLinePoint]
  /// The words at the end of the line — its figure, «48,200 ₽», or its name, «Партнёр» —
  /// so it is named where it ends and not only in the legend.
  var endText: String?
}

/// Lines over a common axis — a period against the one before, «for whom» month by month.
/// Every series has its own shape of point and pattern of line (`ChartSeriesStyle`) and its
/// words at its end; the legend repeats both with the name. Points are drawn while a line has
/// no more than `pointLimit` of them; on a denser line only its end carries the shape, and
/// the pattern tells the lines apart.
struct SeriesLineChart: View {
  @Dependency(\.environment) private var environment
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.appAccent) private var accent
  let series: [ChartLineSeries]
  /// The ticks of the horizontal axis and their words.
  let xLabels: [Int: String]
  @State private var hovered: Int?

  static let pointLimit = 40

  var body: some View {
    let money = environment.money
    let xs = series.flatMap { $0.points.map(\.x) }
    let low = xs.min() ?? 0
    let high = xs.max() ?? 1
    VStack(alignment: .leading, spacing: 8) {
      Chart {
        ForEach(series) { line in
          let dense = line.points.count > Self.pointLimit
          ForEach(line.points, id: \.x) { point in
            LineMark(
              x: .value("Position", point.x), y: .value("Amount", point.value),
              series: .value("Series", line.id)
            )
            .foregroundStyle(line.style.tint.color(accent))
            .lineStyle(line.style.stroke(contrast))
            .symbol(line.style.symbol.shape)
            .symbolSize(dense ? 0 : 28)
            .accessibilityLabel(Text(verbatim: "\(line.label), \(point.spokenLabel)"))
            .accessibilityValue(Text(verbatim: point.valueText))
          }
          if let last = line.points.last {
            PointMark(x: .value("Position", last.x), y: .value("Amount", last.value))
              .foregroundStyle(line.style.tint.color(accent))
              .symbol(line.style.symbol.shape)
              .symbolSize(56)
              .annotation(position: .trailing, alignment: .leading, spacing: 4) {
                if let text = line.endText {
                  Text(verbatim: text)
                    .appFont(.caption.monospacedDigit())
                    .foregroundStyle(.primary)
                    .fixedSize()
                }
              }
              .accessibilityHidden(true)
          }
        }
        if let hovered {
          RuleMark(x: .value("Position", hovered))
            .foregroundStyle(.secondary)
            .annotation(
              position: .top, spacing: 0,
              overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
            ) {
              ChartCallout(title: title(at: hovered), lines: lines(at: hovered))
            }
            .accessibilityHidden(true)
        }
      }
      // Room after the last point for the words at the ends of the lines.
      .chartXScale(domain: low...(high + max(1, (high - low) / 6)))
      .chartXSelection(value: $hovered)
      .chartXAxis {
        AxisMarks(values: xLabels.keys.sorted()) { value in
          AxisGridLine()
          AxisValueLabel {
            if let x = value.as(Int.self), let text = xLabels[x] {
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
      .frame(height: 220)
      ChartLegend(items: series.map { ChartLegend.series($0.id, $0.label, $0.style) })
    }
  }

  private func title(at x: Int) -> String {
    series.lazy.compactMap { $0.points.first { $0.x == x }?.spokenLabel }.first ?? ""
  }

  private func lines(at x: Int) -> [String] {
    series.compactMap { line in
      line.points.first { $0.x == x }.map { "\(line.label): \($0.valueText)" }
    }
  }
}
