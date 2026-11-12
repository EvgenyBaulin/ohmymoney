import AppCore
import SwiftUI

/// What the free sum is made of, as the card «Из чего складывается сумма» says it: the money on
/// the accounts, then each part taken off it, and what is left. Every figure is the free sum's
/// own (`FreeMoney`); nothing is counted here but the sum of the payment lines, so the parts add
/// up to the total the core gives.
struct FreeSumParts: Equatable {
  enum Kind: String, Equatable {
    /// «На счетах»: the money on the accounts in the summary now.
    case accounts
    /// «Обязательные платежи»: every line the free sum takes off before D.
    case payments
    /// «Резерв не трогаем»: the safety cushion kept out.
    case reserve
    /// «В целях»: what is saved in the live goals, kept out.
    case goals
  }

  struct Part: Equatable {
    var kind: Kind
    /// Signed: the accounts plus, the rest minus.
    var amount: AmountE4
  }

  /// What is left: the free sum through D.
  var total: AmountE4
  var days: Int
  /// Whole rubles a day, as the free sum gives them.
  var perDayRubles: Int64
  var reserve: AmountE4
  var parts: [Part]

  /// `nil` while the free sum is not counted.
  static func make(_ free: FreeMoney) -> FreeSumParts? {
    guard free.state == .ready, let now = free.moneyNow, let total = free.grey else { return nil }
    let payments = free.lines.reduce(AmountE4.zero) { $0 + $1.signedAmount }
    var parts = [Part(kind: .accounts, amount: now), Part(kind: .payments, amount: payments)]
    if free.cushion != .zero { parts.append(Part(kind: .reserve, amount: -free.cushion)) }
    if free.goalSavings != .zero { parts.append(Part(kind: .goals, amount: -free.goalSavings)) }
    return FreeSumParts(
      total: total, days: free.days, perDayRubles: free.dailyRubles, reserve: free.cushion,
      parts: parts)
  }

  /// The Mac keeps three plates at most; goals remain an explicit deduction in a line below.
  func plates(for idiom: LayoutIdiom) -> [Part] {
    idiom == .mac ? parts.filter { $0.kind != .goals } : parts
  }

  func goalDeduction(for idiom: LayoutIdiom) -> AmountE4? {
    idiom == .mac ? parts.first { $0.kind == .goals }?.amount : nil
  }

  static let table = "Overview"

  static func labelKey(_ kind: Kind) -> String { "overview.parts.\(kind.rawValue)" }

  /// Every key the card reads, so a test finds each in both languages.
  static let keys =
    [
      "overview.parts.title", "overview.parts.total", "overview.parts.perDay",
      "overview.parts.perDayReserve", "overview.parts.goalDeduction",
    ] + [Kind.accounts, .payments, .reserve, .goals].map(labelKey)
}

/// «Из чего складывается сумма»: the tile beside «Что сделать сейчас», as the design lays it —
/// the title, «41 600 ₽ на 30 дней», the line of the day, and the parts in a row of grey plates.
struct OverviewFreeSumPartsCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.themeSurfaces) private var surfaces
  var fillsHeight = false
  @Environment(\.layoutIdiom) private var idiom

  var body: some View {
    if let snapshot = compute.snapshot,
      case let free = OverviewHeadline.configured(snapshot).free,
      let parts = FreeSumParts.make(free)
    {
      VStack(alignment: .leading, spacing: StyleMetrics.tileGap) {
        Text(verbatim: t("overview.parts.title"))
          .appFont(StyleType.tileTitle)
          .foregroundStyle(surfaces.primary)
          .accessibilityAddTraits(.isHeader)
        Text(
          verbatim: free.dailyReductionRubles == nil
            ? totalLine(parts)
            : environment.format(
              "overview.parts.total", table: FreeSumParts.table,
              environment.money.rounded(free.spendable ?? .zero),
              environment.format(
                "overview.headline.days", table: FreeSumParts.table, counts: parts.days))
        )
        .appFont(StyleType.cardSubtitle)
        .foregroundStyle(surfaces.primary)
        .accessibilityIdentifier("overview.parts.total")
        Text(
          verbatim: free.dailyReductionRubles == nil
            ? perDayLine(parts) : FreeMoneyRecoveryText.explanation(free, environment)
        )
        .appFont(StyleType.tileHint.monospacedDigit())
        .foregroundStyle(surfaces.secondary)
        .fixedSize(horizontal: false, vertical: true)
        ViewThatFits(in: .horizontal) {
          plates(parts, width: StyleMetrics.partWidth)
          plates(parts, width: nil)
        }
        .padding(.vertical, StyleMetrics.partsVertical)
        if let deduction = parts.goalDeduction(for: LayoutIdiom.resolved(idiom)) {
          Text(
            verbatim: environment.format(
              "overview.parts.goalDeduction", table: FreeSumParts.table,
              environment.money.rounded(-deduction))
          )
          .appFont(StyleType.tileHint.monospacedDigit())
          .foregroundStyle(surfaces.secondary)
          .accessibilityIdentifier("overview.parts.goalDeduction")
        }
      }
      .contentCard(fillsHeight: fillsHeight)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("overview.parts")
    }
  }

  /// The plates side by side: 160 pt each where the card holds them, else sharing its width.
  private func plates(_ parts: FreeSumParts, width: CGFloat?) -> some View {
    HStack(alignment: .top, spacing: StyleMetrics.partGap) {
      ForEach(parts.plates(for: LayoutIdiom.resolved(idiom)), id: \.kind) { part in
        Plate(
          figure: environment.money.rounded(part.amount),
          label: t(FreeSumParts.labelKey(part.kind)), width: width
        )
        .accessibilityIdentifier("overview.parts.plate.\(part.kind.rawValue)")
      }
    }
  }

  /// «41 600 ₽ на 30 дней».
  private func totalLine(_ parts: FreeSumParts) -> String {
    environment.format(
      "overview.parts.total", table: FreeSumParts.table, environment.money.rounded(parts.total),
      environment.format("overview.headline.days", table: FreeSumParts.table, counts: parts.days))
  }

  private func perDayLine(_ parts: FreeSumParts) -> String {
    let perDay = environment.money.rubles(parts.perDayRubles)
    return parts.reserve == .zero
      ? environment.format("overview.parts.perDay", table: FreeSumParts.table, perDay)
      : environment.format(
        "overview.parts.perDayReserve", table: FreeSumParts.table, perDay,
        environment.money.rounded(parts.reserve))
  }

  private func t(_ key: String) -> String {
    environment.language(key, table: FreeSumParts.table)
  }

  /// One part: its figure in 16 semibold over its words in 10, on the page's background.
  private struct Plate: View {
    @Environment(\.themeSurfaces) private var surfaces
    @Environment(\.appFontSize) private var fontSize
    let figure: String
    let label: String
    let width: CGFloat?

    var body: some View {
      VStack(alignment: .leading, spacing: StyleMetrics.partLineGap) {
        Text(verbatim: figure)
          .appFont(StyleType.partFigure)
          .foregroundStyle(surfaces.primary)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
        Text(verbatim: label)
          .appFont(StyleType.partLabel)
          .foregroundStyle(surfaces.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(StyleMetrics.partPadding)
      .frame(
        minWidth: width, maxWidth: width ?? .infinity,
        minHeight: fontSize.points(fromRegular: StyleMetrics.partHeight), alignment: .topLeading
      )
      .background(
        surfaces.background, in: .rect(cornerRadius: StyleMetrics.partRadius)
      )
      .accessibilityElement(children: .combine)
    }
  }
}
