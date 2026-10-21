import AppCore
import Charts
import SwiftUI

/// One bar of a ranked chart, ready to draw: the id it is plotted by, its name, its length
/// and the words at its end. Built by the section from the core's numbers; the chart itself
/// counts nothing.
struct RankedBar: Identifiable, Hashable {
  var id: String
  var label: String
  /// Whole rubles or a count. A negative bucket — refunds outweighed the spending — keeps
  /// its figure in the words but has no length.
  var value: Int64
  /// What stands at the end of the bar: «12,400 ₽ · 26 %».
  var caption: String
  /// What VoiceOver says after the name.
  var spokenValue: String
  /// A subcategory under its open category: thinner, lighter, indented.
  var isChild = false
  /// A category with subcategories that a click opens or closes.
  var isExpandable = false
  var isExpanded = false
}

/// Horizontal bars, largest first — categories and subcategories, income by source, bad
/// spending by category, places, payment methods, «for whom».
///
/// One series: the name on the axis, the figure at the end of the bar in the colour of text.
/// A bar with lines under it opens them on a click; the open and closed state is a sign in
/// the name (▸ ▾), not a colour, and VoiceOver gets the same as an action.
struct RankedBarChart: View {
  enum Scale {
    case money
    case count
  }

  @Dependency(\.environment) private var environment
  @Environment(\.appAccent) private var accent
  let bars: [RankedBar]
  var scale: Scale = .money
  var tint: ChartTint = .accent
  var onToggle: ((String) -> Void)?

  /// The height of a line; the chart grows with the number of bars instead of squeezing.
  private static let rowHeight: CGFloat = 26

  var body: some View {
    let money = environment.money
    let byId = Dictionary(bars.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    Chart(bars) { bar in
      BarMark(
        x: .value("Amount", max(0, bar.value)), y: .value("Line", bar.id),
        height: .ratio(bar.isChild ? 0.45 : 0.7)
      )
      // A subcategory is the second level of the same colour — a system level, not an opacity
      // of our own (no floating-point number in the charts).
      .foregroundStyle(
        bar.isChild
          ? AnyShapeStyle(tint.color(accent).secondary) : AnyShapeStyle(tint.color(accent))
      )
      .annotation(
        position: .trailing, alignment: .leading, spacing: 6,
        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
      ) {
        Text(verbatim: bar.caption)
          .appFont(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .fixedSize()
      }
      .accessibilityLabel(Text(verbatim: bar.label))
      .accessibilityValue(Text(verbatim: bar.spokenValue))
    }
    .chartXScale(domain: 0...upperBound)
    .chartYAxis {
      AxisMarks(position: .leading, values: bars.map(\.id)) { value in
        AxisValueLabel {
          if let id = value.as(String.self), let bar = byId[id] {
            Text(verbatim: Self.axisName(bar))
              .appFont(bar.isChild ? .caption : .callout)
              .foregroundStyle(bar.isChild ? .secondary : .primary)
              .lineLimit(1)
              .truncationMode(.tail)
              .frame(maxWidth: 200, alignment: .leading)
          }
        }
      }
    }
    .chartXAxis {
      AxisMarks(values: .automatic(desiredCount: 4)) { value in
        AxisGridLine()
        AxisValueLabel {
          Text(
            verbatim: scale == .money
              ? ChartAxis.money(value, money) : ChartAxis.count(value, money)
          )
          .appFont(.caption.monospacedDigit())
        }
      }
    }
    .chartOverlay { proxy in
      if let onToggle {
        GeometryReader { geometry in
          Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .onTapGesture { location in
              guard let frame = proxy.plotFrame else { return }
              let y = location.y - geometry[frame].origin.y
              guard let id = proxy.value(atY: y, as: String.self), byId[id]?.isExpandable == true
              else { return }
              onToggle(id)
            }
        }
      }
    }
    .accessibilityActions {
      if let onToggle {
        ForEach(bars.filter(\.isExpandable)) { bar in
          Button(bar.label) { onToggle(bar.id) }
        }
      }
    }
    .frame(height: CGFloat(bars.count) * Self.rowHeight + 30)
  }

  /// Room past the longest bar for the words at its end.
  private var upperBound: Int64 {
    let top = bars.map(\.value).max() ?? 0
    return max(1, top + top / 3)
  }

  /// «▸ Продукты», «▾ Продукты», «   Супермаркет»: the state of a line is in its name.
  static func axisName(_ bar: RankedBar) -> String {
    if bar.isChild { return "   \(bar.label)" }
    if bar.isExpandable { return "\(bar.isExpanded ? "▾" : "▸") \(bar.label)" }
    return bar.label
  }
}
