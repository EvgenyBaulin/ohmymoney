import AppCore
import SwiftUI

/// The four cards of the first page of «Траты» as the design draws them (Mac 5:36907, tablet
/// 5:77469, phone 5:6837): «По месяцам» and «Аномалии» in the left column, «Расходы по
/// категориям» and «Хорошие и плохие» in the right one, each column on its own (the cards of
/// one row are not stretched to one height); on a phone one column in the phone's order.
struct OverviewSummaryCards: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  let state: BlockState<AnalyticsModel>
  let retry: () -> Void
  let isWide: Bool
  @State private var failure: String?

  var body: some View {
    let layout = OverviewSummaryLayout(isWide: isWide)
    if isWide {
      HStack(alignment: .top, spacing: OverviewSummaryLayout.columnGap) {
        column(layout.left)
        column(layout.right)
      }
    } else {
      column(layout.left)
    }
  }

  private func column(_ cards: [OverviewSummaryLayout.Card]) -> some View {
    VStack(alignment: .leading, spacing: OverviewSummaryLayout.stackGap) {
      ForEach(cards, id: \.self) { card($0) }
    }
    .frame(maxWidth: .infinity, alignment: .top)
  }

  @ViewBuilder
  private func card(_ card: OverviewSummaryLayout.Card) -> some View {
    switch card {
    case .months: months
    case .categories: categories
    case .quality: quality
    case .anomalies: anomalies
    }
  }

  // MARK: The cards

  private var months: some View {
    let caption = AnalyticsText.format(
      "analytics.months.caption", environment,
      count: state.value?.overview?.months.content?.months.count ?? 12)
    return AnalyticsCard(
      block: AnalyticsBlock.months.rawValue, title: t("analytics.block.months"), caption: caption,
      style: .summary, state: state.block { $0.overview?.months }, retry: retry
    ) { bars in
      VStack(alignment: .leading, spacing: AnalyticsCardMetrics.bodyGap(.summary)) {
        MonthBarsChart(
          bars: bars.months.map { month in
            MonthBar(
              id: month.month.iso, value: month.value,
              isHighlighted: month.month == bars.highlighted,
              spokenLabel:
                "\(environment.dates.monthTitle(month.month)), \(environment.money.rubles(month.value))"
            )
          })
        Text(
          verbatim: AnalyticsText.format(
            "analytics.months.highlighted", environment,
            environment.dates.monthName(bars.highlighted.month))
        )
        .appFont(AnalyticsCardType.subtitle)
        .foregroundStyle(.secondary)
      }
    }
    .accessibilityIdentifier("analytics.overview.months")
  }

  private var categories: some View {
    let total = state.value?.overview?.categories.content.map(OverviewDonut.total)
    return AnalyticsCard(
      block: AnalyticsBlock.categories.rawValue, title: t("analytics.block.categoryShares"),
      caption: total.map { environment.money.rubles($0) }, style: .summary,
      state: state.block { $0.overview?.categories }, retry: retry
    ) { values in
      OverviewDonutView(
        donut: OverviewDonut.make(values), names: state.value?.names ?? AnalyticsNames())
    }
    .accessibilityIdentifier("analytics.overview.categories")
  }

  private var quality: some View {
    AnalyticsCard(
      block: AnalyticsBlock.qualitySummary.rawValue, title: t("analytics.section.quality"),
      style: .summary, state: state.block { $0.overview?.quality }, retry: retry
    ) { totals in
      OverviewQualityView(totals: totals)
    }
    .accessibilityIdentifier("analytics.overview.quality")
  }

  private var anomalies: some View {
    let found = state.value?.overview?.anomalies?.content
    return AnalyticsCard(
      block: AnalyticsBlock.overviewAnomalies.rawValue, title: t("analytics.section.anomalies"),
      caption: found.map { environment.money.count(Int64($0.count)) }, style: .summary,
      state: state.block { $0.overview?.anomalies }, retry: retry
    ) { found in
      VStack(alignment: .leading, spacing: SectionMetrics.rowGap) {
        if let failure {
          Text(verbatim: t(failure))
            .appFont(AnalyticsCardType.subtitle)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(found.prefix(OverviewSummaryLayout.anomalyRows), id: \.id) { anomaly in
          OverviewAnomalyRow(anomaly: anomaly, names: state.value?.names ?? AnalyticsNames()) {
            failure = AnomalyActions(repository: environment.anomalies) { [compute] in
              compute.retry(ComputeStep.data)
            }
            .hide(anomaly, active: compute.states.anomalies.value?.activeKeys)
          }
        }
      }
    }
    .accessibilityIdentifier("analytics.overview.anomalies")
  }

  private func t(_ key: String) -> String { AnalyticsText.t(key, environment) }
}

/// Where the four cards stand: on a wide page «По месяцам» over «Аномалии» on the left and
/// «Расходы по категориям» over «Хорошие и плохие» on the right, 16 apart, 14 between the cards
/// of a column; on a narrow one (the phone) one column — categories, months, ratings, anomalies.
struct OverviewSummaryLayout: Equatable {
  enum Card: Hashable { case months, categories, quality, anomalies }

  static let columnGap: CGFloat = 16
  static let stackGap: CGFloat = 14
  /// The anomalies shown on the card: the first ones of the period; all of them under the tab.
  static let anomalyRows = 3

  var left: [Card]
  var right: [Card]

  init(isWide: Bool) {
    if isWide {
      left = [.months, .anomalies]
      right = [.categories, .quality]
    } else {
      left = [.categories, .months, .quality, .anomalies]
      right = []
    }
  }
}

/// The ring of «Расходы по категориям»: the four largest top categories and the rest as
/// «Прочее», each with its whole percent — the shares of the breakdown itself, so the ring and
/// the reports agree.
struct OverviewDonut: Equatable {
  struct Part: Equatable {
    /// `nil` for «Прочее».
    var key: ReportKey?
    var value: Int64
    var basisPoints: Int
  }

  static let shown = 4

  var parts: [Part]
  var total: Int64

  static func total(_ values: [RankedValue]) -> Int64 {
    values.map(\.value).filter { $0 > 0 }.reduce(0, +)
  }

  static func make(_ values: [RankedValue]) -> OverviewDonut {
    let positive = values.filter { $0.value > 0 }.sorted { $0.value > $1.value }
    let total = Self.total(values)
    guard total > 0 else { return OverviewDonut(parts: [], total: 0) }
    func points(_ value: Int64) -> Int {
      Int((value * 10_000 * 2 + total) / (total * 2))
    }
    var parts = positive.prefix(shown).map {
      Part(key: $0.key, value: $0.value, basisPoints: points($0.value))
    }
    let rest = positive.dropFirst(shown).map(\.value).reduce(0, +)
    if rest > 0 {
      // The rest takes what the shown parts leave of the whole, so the ring is always 100 %.
      let left = 10_000 - parts.map(\.basisPoints).reduce(0, +)
      parts.append(Part(key: nil, value: rest, basisPoints: max(0, left)))
    }
    return OverviewDonut(parts: parts, total: total)
  }
}

private struct OverviewDonutView: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appTheme) private var theme
  let donut: OverviewDonut
  let names: AnalyticsNames

  var body: some View {
    HStack(alignment: .center, spacing: OverviewDonutMetrics.ringToLegend) {
      ShareDonutChart(
        slices: donut.parts.indices.map { index in
          ShareDonutSlice(
            id: "\(index)", name: name(donut.parts[index]),
            basisPoints: donut.parts[index].basisPoints, tint: tint(index))
        },
        figure: AnalyticsText.thousands(donut.total, environment),
        caption: AnalyticsText.t("analytics.donut.caption", environment),
        side: OverviewDonutMetrics.ring)
      VStack(alignment: .leading, spacing: OverviewDonutMetrics.legendGap) {
        ForEach(donut.parts.indices, id: \.self) { index in
          let part = donut.parts[index]
          HStack(spacing: OverviewDonutMetrics.legendWordGap) {
            RoundedRectangle(cornerRadius: OverviewDonutMetrics.squareRadius)
              .fill(tint(index))
              .frame(width: OverviewDonutMetrics.square, height: OverviewDonutMetrics.square)
              .accessibilityHidden(true)
            Text(verbatim: name(part))
              .appFont(.system(size: 12))
              .lineLimit(1)
            Text(
              verbatim: environment.money.percent(basisPoints: part.basisPoints, fractionDigits: 0)
            )
            .appFont(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
        }
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .contain)
  }

  private func name(_ part: OverviewDonut.Part) -> String {
    guard let key = part.key else { return AnalyticsText.t("analytics.donut.other", environment) }
    return AnalyticsText.name(of: key, names, environment)
  }

  /// The colours of the frame: the accent, then the third, second, fourth and fifth colours of
  /// the charts — «Прочее» always last, in the grey fifth.
  private func tint(_ index: Int) -> Color {
    let tints = [theme.accentDefault, theme.chart3, theme.chart2, theme.chart4]
    if index < donut.parts.count - 1 || donut.parts.last?.key != nil {
      return index < tints.count ? tints[index] : theme.chart5
    }
    return theme.chart5
  }
}

/// The ring and its legend as the frame draws them: the ring 120, the legend 14 to its right,
/// its rows 5 apart, a square of 9 rounded 3, 7 before the words.
enum OverviewDonutMetrics {
  static let ring: CGFloat = 120
  static let ringToLegend: CGFloat = 14
  static let legendGap: CGFloat = 5
  static let square: CGFloat = 9
  static let squareRadius: CGFloat = 3
  static let legendWordGap: CGFloat = 7
}

/// «Хорошие и плохие» of the first page: one bar of the three ratings over a grey track and a
/// line for each with its symbol, its word, its share and its money. The word and the symbol
/// carry the meaning; the colour only repeats it.
private struct OverviewQualityView: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appTheme) private var theme
  let totals: QualityTotals

  var body: some View {
    VStack(alignment: .leading, spacing: AnalyticsCardMetrics.bodyGap(.summary)) {
      GeometryReader { proxy in
        HStack(spacing: 0) {
          ForEach(totals.tiles, id: \.quality) { tile in
            Rectangle()
              .fill(ink(tile.quality))
              .frame(width: proxy.size.width * CGFloat(tile.basisPoints ?? 0) / 10_000)
          }
          Spacer(minLength: 0)
        }
      }
      .frame(height: OverviewQualityMetrics.bar)
      .background(theme.fillNeutral)
      .clipShape(.rect(cornerRadius: OverviewQualityMetrics.bar / 2))
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: OverviewQualityMetrics.rowGap) {
        ForEach(totals.tiles, id: \.quality) { tile in
          HStack(spacing: AnalyticsCardMetrics.captionGap) {
            Label {
              Text(verbatim: environment.language(Palette.qualityKey(tile.quality)))
            } icon: {
              Image(systemName: Palette.qualitySymbol(tile.quality))
            }
            .labelStyle(OverviewQualityLabelStyle())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: figure(tile))
              .appFont(.system(size: 12, weight: .semibold).monospacedDigit())
              .foregroundStyle(figureInk(tile.quality))
              .lineLimit(1)
              .fixedSize()
          }
          .appFont(.system(size: 12))
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("analytics.overview.quality.\(tile.quality.rawValue)")
        }
      }
    }
  }

  private func figure(_ tile: QualityTotals.Tile) -> String {
    let money = environment.money.rubles(tile.value)
    guard let points = tile.basisPoints else { return money }
    return "\(environment.money.percent(basisPoints: points, fractionDigits: 0)) · \(money)"
  }

  private func ink(_ quality: Quality) -> Color {
    switch quality {
    case .good: theme.statusPositive
    case .neutral: theme.contentSecondary
    case .bad: theme.statusNegative
    }
  }

  private func figureInk(_ quality: Quality) -> Color {
    quality == .neutral ? theme.contentPrimary : ink(quality)
  }
}

/// The symbol of a rating as small as the word beside it, 4 before the word.
private struct OverviewQualityLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 4) {
      configuration.icon.imageScale(.small)
      configuration.title
    }
  }
}

/// The bar and the lines of «Хорошие и плохие»: the bar 14 tall, rounded 7; the lines 7 apart.
enum OverviewQualityMetrics {
  static let bar: CGFloat = 14
  static let rowGap: CGFloat = 7
}

/// A line of «Аномалии» on the first page: the rule's badge, the rule over the day and its two
/// numbers, and «Это нормально» at the right.
private struct OverviewAnomalyRow: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appTheme) private var theme
  let anomaly: Anomaly
  let names: AnalyticsNames
  let hide: () -> Void

  var body: some View {
    let warm = anomaly.rule == .largeExpense
    SectionRow(
      badge: SectionBadge(
        symbol: warm ? "exclamationmark.triangle" : "doc.text",
        tint: warm ? theme.statusNegative : theme.accentDefault,
        fill: warm ? theme.statusNegativeTint : theme.accentTint),
      title: AnalyticsText.t("analytics.anomaly.\(anomaly.rule.rawValue)", environment),
      detail:
        "\(environment.dates.dayAndMonth(anomaly.day)) · \(AnalyticsText.anomalyDetail(anomaly, names: names, environment))"
    ) {
      Button(AnalyticsText.t("analytics.anomaly.normal", environment), action: hide)
        .buttonStyle(.plain)
        .appFont(.system(size: 13, weight: .semibold))
        .fixedSize()
    }
  }
}
