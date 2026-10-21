import AppCore
import Charts
import SwiftUI

/// What an event cost against its budget and against the same event a year before:
/// a bar of what is spent, the budget as a dashed vertical rule with its words, last year as
/// a thinner grey bar below with its year. The bars are told apart by their place, thickness
/// and names, the budget by its pattern and words.
struct BudgetChart: View {
  struct Bar: Identifiable, Hashable {
    var id: String
    var label: String
    var value: Int64
    var text: String
    /// The event itself; the year before is the thinner bar.
    var isMain: Bool
  }

  @Dependency(\.environment) private var environment
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.appAccent) private var accent
  let bars: [Bar]
  var budget: ChartRule?

  var body: some View {
    let money = environment.money
    let byId = Dictionary(bars.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let top = max(bars.map(\.value).max() ?? 0, budget?.value ?? 0)
    Chart {
      ForEach(bars) { bar in
        BarMark(
          x: .value("Amount", max(0, bar.value)), y: .value("Line", bar.id),
          height: .ratio(bar.isMain ? 0.7 : 0.35)
        )
        .foregroundStyle(
          bar.isMain ? ChartTint.accent.color(accent) : ChartTint.secondary.color(accent)
        )
        .annotation(
          position: .trailing, alignment: .leading, spacing: 6,
          overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
        ) {
          Text(verbatim: bar.text)
            .appFont(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
        }
        .accessibilityLabel(Text(verbatim: bar.label))
        .accessibilityValue(Text(verbatim: bar.text))
      }
      if let budget {
        RuleMark(x: .value("Budget", budget.value))
          .lineStyle(StrokeStyle(lineWidth: contrast == .increased ? 3 : 2, dash: [6, 4]))
          .foregroundStyle(.primary)
          .annotation(
            position: .top, alignment: .center, spacing: 2,
            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
          ) {
            Text(verbatim: budget.label)
              .appFont(.caption.monospacedDigit())
              .foregroundStyle(.primary)
              .fixedSize()
          }
          .accessibilityLabel(Text(verbatim: budget.label))
      }
    }
    .chartXScale(domain: 0...max(1, top + top / 3))
    .chartYAxis {
      AxisMarks(position: .leading, values: bars.map(\.id)) { value in
        AxisValueLabel {
          if let id = value.as(String.self), let bar = byId[id] {
            Text(verbatim: bar.label)
              .appFont(bar.isMain ? .callout : .caption)
              .foregroundStyle(bar.isMain ? .primary : .secondary)
          }
        }
      }
    }
    .chartXAxis {
      AxisMarks(values: .automatic(desiredCount: 4)) { value in
        AxisGridLine()
        AxisValueLabel {
          Text(verbatim: ChartAxis.money(value, money))
            .appFont(.caption.monospacedDigit())
        }
      }
    }
    .frame(height: CGFloat(bars.count) * 30 + 56)
  }
}
