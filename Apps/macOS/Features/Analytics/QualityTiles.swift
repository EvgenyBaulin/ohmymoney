import AppCore
import SwiftUI

/// What the three tiles under the shares chart of «Good vs Bad» say: for each rating, the money
/// of the whole period and its share of all the rated spending. Worked out from the columns the
/// chart draws, so the tiles and the chart never disagree.
struct QualityTotals: Equatable {
  struct Tile: Equatable {
    var quality: Quality
    var value: Int64
    /// Basis points of the whole; `nil` when nothing was spent.
    var basisPoints: Int?
  }

  var tiles: [Tile]

  /// Good, neutral, bad in that order, always all three: a rating with no spending shows zero.
  static func make(columns: [ShareColumn]) -> QualityTotals {
    var sums: [Quality: Int64] = [:]
    for segment in columns.flatMap(\.segments) {
      sums[segment.quality, default: 0] += segment.value
    }
    let total = sums.values.reduce(0, +)
    let tiles = Quality.allCases.map { quality -> Tile in
      let value = sums[quality] ?? 0
      guard total > 0 else { return Tile(quality: quality, value: value, basisPoints: nil) }
      // Half up, in integers: the shares of three tiles are read side by side.
      let points = (value * 10_000 * 2 + total) / (total * 2)
      return Tile(quality: quality, value: value, basisPoints: Int(points))
    }
    return QualityTotals(tiles: tiles)
  }
}

/// Three small cards in a row — «Хорошие», «Обычные», «Плохие» — each with its symbol and its
/// word (never colour alone), the sum and the share.
struct QualityTiles: View {
  @Dependency(\.environment) private var environment
  let totals: QualityTotals

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      ForEach(totals.tiles, id: \.quality) { tile in
        let style = AnalyticsText.qualityStyle(tile.quality, environment)
        VStack(alignment: .leading, spacing: 4) {
          Label(style.label, systemImage: style.systemImage)
            .appFont(.callout.weight(.semibold))
          Text(verbatim: environment.money.rubles(tile.value))
            .appFont(.title3.bold().monospacedDigit())
            .minimumScaleFactor(0.7).lineLimit(1)
          Text(
            verbatim: tile.basisPoints.map {
              environment.money.percent(basisPoints: $0, fractionDigits: 0)
            } ?? "—"
          )
          .appFont(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        }
        .contentCard()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("analytics.quality.tile.\(tile.quality.rawValue)")
      }
    }
  }
}
