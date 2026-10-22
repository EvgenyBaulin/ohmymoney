import AppCore
import SwiftUI

/// The levels and the busiest cells of the heat map, apart from the view so a test reads them.
enum HeatmapReading {
  /// How many shades the map has besides «nothing».
  static let levels = 4

  /// 0 for no spending, then 1…4 in equal steps of the busiest cell. Whole numbers only.
  static func level(of amount: AmountE4, maximum: AmountE4) -> Int {
    guard amount.raw > 0, maximum.raw > 0 else { return 0 }
    let scaled = (amount.raw * Int64(levels) - 1) / maximum.raw
    return 1 + Int(min(scaled, Int64(levels - 1)))
  }

  struct Slot: Hashable {
    var weekday: Int
    var hour: Int
    var amount: AmountE4
    var count: Int
  }

  /// The `limit` cells with the most money, the busiest first; ties go to the earlier slot.
  static func busiest(_ heatmap: HourHeatmap, limit: Int = 3) -> [Slot] {
    var slots: [Slot] = []
    for weekday in 1...7 {
      for hour in 0..<24 {
        let amount = heatmap.amount(weekday: weekday, hour: hour)
        guard amount.raw > 0 else { continue }
        slots.append(
          Slot(
            weekday: weekday, hour: hour, amount: amount,
            count: heatmap.count(weekday: weekday, hour: hour)))
      }
    }
    return Array(
      slots.sorted {
        if $0.amount != $1.amount { return $0.amount > $1.amount }
        if $0.weekday != $1.weekday { return $0.weekday < $1.weekday }
        return $0.hour < $1.hour
      }.prefix(limit))
  }
}

/// Seven rows of weekdays, 24 columns of hours. The shade says how much was spent in that hour;
/// the busiest hours are named in words under the map and every cell says its sum to VoiceOver
/// and on hover, so the picture never rests on shade alone.
struct HourHeatmapView: View {
  @Dependency(\.environment) private var environment
  @Environment(\.themeSurfaces) private var surfaces
  let heatmap: HourHeatmap

  private static let hourLabels = [0, 6, 12, 18]

  var body: some View {
    let maximum = heatmap.maximum
    VStack(alignment: .leading, spacing: 8) {
      Grid(horizontalSpacing: 2, verticalSpacing: 2) {
        GridRow {
          Color.clear.frame(width: 28, height: 1)
          ForEach(0..<24, id: \.self) { hour in
            Text(verbatim: Self.hourLabels.contains(hour) ? String(hour) : "")
              .appFont(.caption2.monospacedDigit())
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .fixedSize()
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        ForEach(1...7, id: \.self) { weekday in
          GridRow {
            Text(verbatim: environment.dates.shortWeekday(weekday))
              .appFont(.caption2)
              .foregroundStyle(.secondary)
              .frame(width: 28, alignment: .leading)
            ForEach(0..<24, id: \.self) { hour in
              cell(weekday: weekday, hour: hour, maximum: maximum)
            }
          }
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("spending.heatmap.grid")
      legend
      ForEach(Array(HeatmapReading.busiest(heatmap).enumerated()), id: \.offset) { _, slot in
        Text(verbatim: busiestLine(slot))
          .appFont(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      if heatmap.withoutTime > 0 {
        Label {
          Text(
            verbatim: SpendingText.counted(
              "spending.heat.withoutTime", environment, count: heatmap.withoutTime))
        } icon: {
          Image(systemName: "clock.badge.questionmark")
        }
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("spending.heatmap.withoutTime")
      }
    }
  }

  private func cell(weekday: Int, hour: Int, maximum: AmountE4) -> some View {
    let amount = heatmap.amount(weekday: weekday, hour: hour)
    let level = HeatmapReading.level(of: amount, maximum: maximum)
    let text = cellText(weekday: weekday, hour: hour, amount: amount)
    return RoundedRectangle(cornerRadius: 3)
      .fill(shade(level))
      .aspectRatio(1, contentMode: .fit)
      .frame(maxWidth: .infinity)
      .help(text)
      .accessibilityElement()
      .accessibilityLabel(Text(verbatim: text))
  }

  private func shade(_ level: Int) -> Color {
    switch level {
    case 0: surfaces.secondary.mix(with: surfaces.card, by: 0.92)
    case 1: surfaces.accent.mix(with: surfaces.card, by: 0.78)
    case 2: surfaces.accent.mix(with: surfaces.card, by: 0.55)
    case 3: surfaces.accent.mix(with: surfaces.card, by: 0.28)
    default: surfaces.accent
    }
  }

  private var legend: some View {
    HStack(spacing: 4) {
      Text(verbatim: SpendingText.t("spending.heat.less", environment))
      ForEach(0...HeatmapReading.levels, id: \.self) { level in
        RoundedRectangle(cornerRadius: 3).fill(shade(level)).frame(width: 12, height: 12)
      }
      Text(verbatim: SpendingText.t("spending.heat.more", environment))
    }
    .appFont(.caption)
    .foregroundStyle(.secondary)
    .accessibilityHidden(true)
  }

  private func cellText(weekday: Int, hour: Int, amount: AmountE4) -> String {
    SpendingText.format(
      "spending.heat.cell", environment, environment.dates.weekday(weekday), hour,
      environment.money.rounded(amount))
  }

  private func busiestLine(_ slot: HeatmapReading.Slot) -> String {
    SpendingText.format(
      "spending.heat.busiest", environment, environment.dates.weekday(slot.weekday), slot.hour,
      environment.money.rounded(slot.amount))
  }
}
