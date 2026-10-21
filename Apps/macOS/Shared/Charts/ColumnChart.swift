import AppCore
import Charts
import SwiftUI

/// One column, ready to draw: plotted by its id, named on the axis and to VoiceOver.
struct ChartColumn: Identifiable, Hashable {
  var id: String
  /// The word under the column: «18», «пн», «сент.», «1–6 сент.».
  var axisLabel: String
  /// The same, in full, for VoiceOver and the hover callout: «18 сентября».
  var spokenLabel: String
  /// Whole rubles; negative when refunds outweighed the spending of the bucket.
  var value: Int64
  var valueText: String
}

/// Vertical columns in the order given — spending by day, week or month, the days of the
/// week. One series. Up to twelve columns carry their value above them; more show it on
/// hover, with a line across the column and a callout on the plain background. The average,
/// when given, is a dashed rule with its words.
struct ColumnChart: View {
  @Dependency(\.environment) private var environment
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.appAccent) private var accent
  let columns: [ChartColumn]
  /// The columns labelled on the axis and their words; without it every n-th column is
  /// labelled with its own `axisLabel`.
  var xLabels: [String: String]?
  var average: ChartRule?
  var tint: ChartTint = .accent
  @State private var hovered: String?

  /// Columns that still carry their value above them.
  static let directLabelLimit = 12

  var body: some View {
    let money = environment.money
    let direct = columns.count <= Self.directLabelLimit
    let byId = Dictionary(columns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    Chart {
      ForEach(columns) { column in
        BarMark(x: .value("Bucket", column.id), y: .value("Amount", column.value))
          .foregroundStyle(tint.color(accent))
          .annotation(position: column.value < 0 ? .bottom : .top, spacing: 2) {
            if direct {
              Text(verbatim: column.valueText)
                .appFont(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
            }
          }
          .accessibilityLabel(Text(verbatim: column.spokenLabel))
          .accessibilityValue(Text(verbatim: column.valueText))
      }
      if let average {
        RuleMark(y: .value("Average", average.value))
          .lineStyle(StrokeStyle(lineWidth: contrast == .increased ? 2 : 1, dash: [6, 4]))
          .foregroundStyle(.secondary)
          .annotation(position: .top, alignment: .trailing, spacing: 2) {
            Text(verbatim: average.label)
              .appFont(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          .accessibilityLabel(Text(verbatim: average.label))
      }
      if !direct, let hovered, let column = byId[hovered] {
        RuleMark(x: .value("Bucket", column.id))
          .foregroundStyle(.secondary)
          .annotation(
            position: .top, spacing: 0,
            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
          ) {
            ChartCallout(title: column.spokenLabel, lines: [column.valueText])
          }
          .accessibilityHidden(true)
      }
    }
    .chartXSelection(value: direct ? .constant(nil) : $hovered)
    .chartXAxis {
      AxisMarks(values: ticks) { value in
        AxisValueLabel {
          if let id = value.as(String.self), let text = xLabels?[id] ?? byId[id]?.axisLabel {
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
  }

  /// The ids of the labelled columns, in their order.
  private var ticks: [String] {
    guard let xLabels else { return ChartAxis.thinned(columns.map(\.id), limit: 10) }
    return columns.map(\.id).filter { xLabels[$0] != nil }
  }
}

/// A pair of columns per month, always in the same order and place: income on the left,
/// spending on the right.
struct ChartPair: Identifiable, Hashable {
  var id: String
  var axisLabel: String
  var spokenLabel: String
  var first: Int64
  var second: Int64
  var firstText: String
  var secondText: String
}

/// Income against spending month by month: paired columns (`position(by:)`), the values
/// above them while there are no more than six pairs, on hover after that; a legend with the
/// arrows of income and spending — the order and the symbols tell them apart, not the green.
struct PairedColumnChart: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appAccent) private var accent
  let pairs: [ChartPair]
  let first: SegmentStyle
  let second: SegmentStyle
  @State private var hovered: String?

  /// Pairs that still carry their values: two columns each, twelve in all.
  static let directPairLimit = 6

  var body: some View {
    let money = environment.money
    let direct = pairs.count <= Self.directPairLimit
    let byId = Dictionary(pairs.map { ($0.id, $0) }, uniquingKeysWith: { left, _ in left })
    VStack(alignment: .leading, spacing: 8) {
      Chart {
        ForEach(pairs) { pair in
          bar(pair.id, value: pair.first, text: pair.firstText, style: first, pair, direct)
          bar(pair.id, value: pair.second, text: pair.secondText, style: second, pair, direct)
        }
        if !direct, let hovered, let pair = byId[hovered] {
          RuleMark(x: .value("Month", pair.id))
            .foregroundStyle(.secondary)
            .annotation(
              position: .top, spacing: 0,
              overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
            ) {
              ChartCallout(
                title: pair.spokenLabel,
                lines: [
                  "\(first.label): \(pair.firstText)", "\(second.label): \(pair.secondText)",
                ])
            }
            .accessibilityHidden(true)
        }
      }
      .chartXSelection(value: direct ? .constant(nil) : $hovered)
      .chartXAxis {
        AxisMarks(values: pairs.map(\.id)) { value in
          AxisValueLabel {
            if let id = value.as(String.self), let pair = byId[id] {
              Text(verbatim: pair.axisLabel)
                .appFont(.caption)
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
      ChartLegend(items: [ChartLegend.segment(first), ChartLegend.segment(second)])
    }
  }

  private func bar(
    _ id: String, value: Int64, text: String, style: SegmentStyle, _ pair: ChartPair,
    _ direct: Bool
  ) -> some ChartContent {
    BarMark(x: .value("Month", id), y: .value("Amount", value))
      .position(by: .value("Series", style.id))
      .foregroundStyle(style.tint.color(accent))
      .annotation(position: value < 0 ? .bottom : .top, spacing: 2) {
        if direct {
          Text(verbatim: text)
            .appFont(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
        }
      }
      .accessibilityLabel(Text(verbatim: "\(pair.spokenLabel), \(style.label)"))
      .accessibilityValue(Text(verbatim: text))
  }
}
