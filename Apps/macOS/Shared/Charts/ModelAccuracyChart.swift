import AppCore
import Charts
import SwiftUI

/// Monthly prequential scores, already measured by the model. Shares stay in basis points
/// through the chart, and each series keeps its own marker and line pattern.
struct ModelAccuracyChart: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appAccent) private var accent
  @Environment(\.colorSchemeContrast) private var contrast
  let months: [PrequentialEvaluation.Month]
  @State private var selected: Int?

  var body: some View {
    let lines = Self.series(months, environment)
    let spansYears = Set(months.map { $0.month.year }).count > 1
    let labels = Dictionary(
      uniqueKeysWithValues: months.map {
        (Self.position($0.month), environment.dates.shortMonth($0.month, withYear: spansYears))
      })
    VStack(alignment: .leading, spacing: 6) {
      Chart {
        ForEach(lines) { line in
          ForEach(line.points, id: \.x) { point in
            LineMark(
              x: .value("Month", point.x), y: .value("Accuracy", point.value),
              series: .value("Series", line.id)
            )
            .foregroundStyle(line.style.tint.color(accent))
            .lineStyle(line.style.stroke(contrast))
            .symbol(line.style.symbol.shape)
            .symbolSize(20)
            .accessibilityLabel(Text(verbatim: "\(line.label), \(point.spokenLabel)"))
            .accessibilityValue(Text(verbatim: point.valueText))
          }
        }
        if let selected, let point = lines.first?.points.first(where: { $0.x == selected }) {
          RuleMark(x: .value("Month", selected))
            .foregroundStyle(.secondary)
            .annotation(
              position: .top,
              overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
            ) {
              ChartCallout(
                title: point.spokenLabel,
                lines: lines.compactMap { line in
                  line.points.first { $0.x == selected }.map { "\(line.label): \($0.valueText)" }
                })
            }
            .accessibilityHidden(true)
        }
      }
      .chartYScale(domain: 0...10_000)
      .chartYAxis {
        AxisMarks(values: [0, 3_333, 6_667, 10_000]) { _ in AxisGridLine() }
      }
      .chartXSelection(value: $selected)
      .chartXAxis {
        AxisMarks(values: labels.keys.sorted()) { value in
          AxisValueLabel {
            if let month = value.as(Int.self), let label = labels[month] {
              Text(verbatim: label).appFont(.caption)
            }
          }
        }
      }
      .frame(height: 142)
      ChartLegend(items: lines.map { ChartLegend.series($0.id, $0.label, $0.style) })
    }
  }

  static func series(
    _ months: [PrequentialEvaluation.Month], _ environment: AppEnvironment
  ) -> [ChartLineSeries] {
    [
      (
        "model", "settings.categoryHints.model",
        ChartSeriesStyle(
          symbol: .circle, dash: [], tint: .accent)
      ),
      (
        "history", "settings.categoryHints.history",
        ChartSeriesStyle(
          symbol: .square, dash: [3, 3], tint: .secondary)
      ),
    ].map { id, key, style in
      ChartLineSeries(
        id: id, label: environment.language(key, table: "Settings"), style: style,
        points: months.map { month in
          let value = id == "model" ? month.accuracyBp : month.historyBp
          return ChartLinePoint(
            x: position(month.month), value: Int64(value),
            spokenLabel: environment.dates.monthTitle(month.month),
            valueText: environment.money.percent(basisPoints: value, fractionDigits: 0))
        })
    }
  }

  private static func position(_ month: MonthKey) -> Int { month.year * 12 + month.month - 1 }
}
