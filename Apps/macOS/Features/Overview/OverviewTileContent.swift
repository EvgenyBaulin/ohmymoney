import AppCore
import SwiftUI

/// What the main tiles of Overview say, word for word, apart from the views: a test reads every
/// title, line and figure of a tile in both languages. Each model only puts into words what the
/// core counted — the summary of the month, the free sum, the payments, the limits — and adds no
/// figure of its own beyond a sum of the lines it lists.

// MARK: - С начала месяца

/// «Расходы на 6 % выше сентября»: spending and income from the 1st, each with the arrow and the
/// percent against the same days of last month, and their difference under a line.
struct MonthToDateTile: Equatable {
  struct Row: Equatable {
    var label: String
    var amount: String
    /// The arrow of the change; `nil` when last month had nothing to compare with.
    var direction: ChangeDirection?
    /// «+6 %», whole per cent with its sign; `nil` with nothing to compare with.
    var percent: String?
  }

  /// What the spending did against last month, or the name of the tile when it says nothing.
  var title: String
  var rows: [Row]
  var netLabel: String
  var net: String

  @MainActor
  static func make(_ summary: OverviewSummary, _ environment: AppEnvironment) -> MonthToDateTile {
    let money = environment.money
    func row(_ key: String, _ change: Change) -> Row {
      let percent = change.basisPoints.map {
        money.signedPercent(basisPoints: $0, fractionDigits: 0)
      }
      return Row(
        label: environment.language(key, table: "Overview"), amount: money.rounded(change.current),
        direction: percent == nil ? nil : money.change(change).direction, percent: percent)
    }
    return MonthToDateTile(
      title: headline(summary, environment)
        ?? OverviewTileText.name(of: .monthToDate, environment),
      rows: [row("overview.expenses", summary.expenses), row("overview.income", summary.income)],
      netLabel: environment.language("common.net"), net: money.signedRounded(summary.net))
  }

  /// «Расходы на 6 % выше сентября» / «… ниже …» — only when last month had spending and the
  /// change is at least one whole per cent; the month is the one of the days compared with.
  @MainActor
  static func headline(_ summary: OverviewSummary, _ environment: AppEnvironment) -> String? {
    guard let bp = summary.expenses.basisPoints else { return nil }
    let whole = DecimalMath.round(Decimal(bp.magnitude) / 100, scale: 0)
    guard whole >= 1 else { return nil }
    return environment.format(
      bp > 0 ? "overview.month.higher" : "overview.month.lower", table: "Overview",
      environment.money.percent(basisPoints: Int(bp.magnitude), fractionDigits: 0),
      environment.dates.monthOfDate(summary.previousSpan.start.month))
  }

  /// The arrow of a change as the tile draws it: straight up, straight down, or level.
  static func arrow(_ direction: ChangeDirection) -> String {
    switch direction {
    case .up: "arrow.up"
    case .down: "arrow.down"
    case .flat: "equal"
    }
  }
}

// MARK: - Деньги на счетах

/// «Деньги на счетах · До вычета платежей и резерва · 126 400 ₽ · Остаток на счетах, не бюджет
/// для трат»: the money on the accounts of the summary — the first part of the free sum, the
/// same figure «Из чего складывается сумма» starts from.
struct MoneyOnAccountsTile: Equatable {
  var subtitle: String
  var figure: String
  var hint: String
  /// The money itself, as the free sum holds it.
  var amount: AmountE4

  @MainActor
  static func make(_ free: FreeMoney, _ environment: AppEnvironment) -> MoneyOnAccountsTile {
    let amount = free.moneyNow ?? .zero
    return MoneyOnAccountsTile(
      subtitle: environment.language("overview.freeMoney.before", table: "Overview"),
      figure: environment.money.rounded(amount),
      hint: environment.language("overview.freeMoney.hint", table: "Overview"), amount: amount)
  }
}

// MARK: - Можно отложить

/// «от 18 000 до 26 000 ₽» and «Уже отложено 7 000 ₽».
struct CanSaveTile: Equatable {
  var figure: String
  var savedLabel: String
  var saved: String
  var shortfall: String? = nil
  var hints: [String] = []

  @MainActor
  static func make(
    _ canSave: CanSave, _ environment: AppEnvironment,
    categoryName: (UUID) -> String? = { _ in nil }
  ) -> CanSaveTile {
    let money = environment.money
    let figure: String
    var shortfall: String?
    if let gap = canSave.shortfall {
      if canSave.cannotSave {
        figure = environment.language("overview.canSave.impossible", table: "Planning")
        shortfall = environment.format(
          "overview.canSave.shortfall", table: "Planning",
          wholeNumber(gap.low, money), money.rounded(gap.high))
      } else {
        figure = "≈\u{00A0}\(money.rounded(canSave.p50 ?? .zero))"
        shortfall = environment.format(
          "overview.canSave.risk", table: "Planning", money.rounded(gap.high))
      }
    } else if let low = canSave.low, let high = canSave.high, low != high {
      // The unit once, after the upper end: «от 18 000 до 26 000 ₽».
      figure = String(
        format: environment.language("overview.canSaveRange", table: "Planning"),
        locale: environment.language.locale, wholeNumber(low, money), money.rounded(high))
    } else {
      figure = "≈\u{00A0}\(money.rounded(canSave.p50 ?? canSave.low ?? .zero))"
    }
    return CanSaveTile(
      figure: figure,
      savedLabel: environment.language("overview.alreadySaved", table: "Planning"),
      saved: money.rounded(canSave.alreadySaved), shortfall: shortfall,
      hints: shortfall == nil
        ? []
        : canSave.fundingHints.compactMap { hint in
          switch hint {
          case .goals(let amount):
            return environment.format(
              "overview.canSave.fromGoals", table: "Planning", money.rounded(amount))
          case .cushion(let amount):
            return environment.format(
              "overview.canSave.fromCushion", table: "Planning", money.rounded(amount))
          case .category(let id, let amount):
            guard let name = categoryName(id) else { return nil }
            return environment.format(
              "overview.canSave.cutCategory", table: "Planning",
              name, money.rounded(amount))
          case .variable(let amount):
            return environment.format(
              "overview.canSave.cutVariable", table: "Planning", money.rounded(amount))
          }
        })
  }
}

// MARK: - Платежи на 7 дней

/// «4 платежа · 68 800 ₽», «просрочен», three payments and «Ещё подписка 600 ₽ · всего
/// 68 800 ₽».
struct UpcomingTile: Equatable {
  struct Row: Equatable {
    /// «Аренда · 15 ноя»; an overdue payment has no day — the chip says it is late.
    var label: String
    var amount: String
    /// «≈ 269 ₽» under a payment in another currency, or «нет курса».
    var approximate: String?
    var isOverdue: Bool
  }

  var title: String
  var hasOverdue: Bool
  var rows: [Row]
  /// What the rows leave out, with the total; `nil` when every payment is listed.
  var footer: String?

  /// How many payments the tile lists.
  static let shown = 3

  @MainActor
  static func make(
    _ payments: [UpcomingPayment], target: CurrencyCode, rubPerUnit: [CurrencyCode: Decimal],
    _ environment: AppEnvironment
  ) -> UpcomingTile {
    let money = environment.money
    let total = Self.total(payments, target: target, rubPerUnit: rubPerUnit)
    let totalText = total.map { money.rounded($0, currency: target) }
    let count = environment.language.format(
      "overview.upcoming.count", table: "Overview", counts: payments.count)
    let title =
      payments.isEmpty
      ? OverviewTileText.name(of: .upcoming, environment)
      : totalText.map { "\(count) · \($0)" } ?? count
    let rows = payments.prefix(shown).map { payment in
      Row(
        label: payment.isOverdue
          ? payment.name
          : "\(payment.name) · \(environment.dates.dayAndShortMonth(payment.due))",
        amount: money.rounded(payment.amount, currency: payment.currency),
        approximate: UpcomingPaymentsCard.approximateText(
          payment.approximate(to: target, rubPerUnit: rubPerUnit), environment),
        isOverdue: payment.isOverdue)
    }
    var footer: String?
    let rest = Array(payments.dropFirst(shown))
    if !rest.isEmpty {
      let what: String
      if rest.count == 1, let only = rest.first {
        what = "\(only.name) \(money.rounded(only.amount, currency: only.currency))"
      } else {
        let restCount = environment.language.format(
          "overview.upcoming.count", table: "Overview", counts: rest.count)
        what =
          Self.total(rest, target: target, rubPerUnit: rubPerUnit).map {
            environment.format(
              "overview.upcoming.moreSum", table: "Overview", restCount,
              money.rounded($0, currency: target))
          } ?? restCount
      }
      footer =
        totalText.map {
          environment.format("overview.upcoming.more", table: "Overview", what, $0)
        } ?? environment.format("overview.upcoming.moreOnly", table: "Overview", what)
    }
    return UpcomingTile(
      title: title, hasOverdue: payments.contains(where: \.isOverdue), rows: rows, footer: footer)
  }

  /// What the payments come to in the default currency at today's rates, rounded once at the
  /// end; `nil` when a payment has no rate — no total is better than a wrong one.
  static func total(
    _ payments: [UpcomingPayment], target: CurrencyCode, rubPerUnit: [CurrencyCode: Decimal]
  ) -> AmountE4? {
    var sum = AmountE4.zero
    for payment in payments {
      if payment.currency == target {
        sum = sum + payment.amount
        continue
      }
      guard case .amount(let amount, _) = payment.approximate(to: target, rubPerUnit: rubPerUnit)
      else { return nil }
      sum = sum + amount
    }
    return sum
  }
}

// MARK: - Лимиты

/// «Кафе — лимит превышен», «превышен 1 из 3», each limit with its bar and status, and «ещё 2 —
/// в «Планировании»».
struct LimitsTile: Equatable {
  struct Row: Equatable {
    var name: String
    /// «9 800 / 8 000 ₽».
    var amounts: String
    /// How much of the bar is filled, in basis points of the available money, at most whole.
    var fillBp: Int
    var status: LimitStatus
    var statusWord: String
  }

  var title: String
  /// «превышен 1 из 3» — of the limits the tile lists —, only while one is over.
  var overLabel: String?
  var rows: [Row]
  var footer: String?

  @MainActor
  static func make(
    shown: [LimitLine], rest: [LimitLine], names: (LimitLine) -> String,
    _ environment: AppEnvironment
  ) -> LimitsTile {
    let money = environment.money
    // The order puts the limits over first, so the ones on the tile hold them; the label counts
    // the tile's own lines — «превышен 1 из 3» over the three it lists.
    let over = shown.filter { $0.status == .over }
    let rows = shown.map { line in
      Row(
        name: names(line),
        amounts: "\(wholeNumber(line.spent, money)) / \(money.rounded(line.available))",
        fillBp: fill(spent: line.spent, available: line.available), status: line.status,
        statusWord: PlanningText.statusWord(line.status, environment))
    }
    let title =
      over.first.map {
        environment.format("overview.limits.overTitle", table: "Overview", names($0))
      } ?? OverviewTileText.name(of: .limits, environment)
    let label =
      over.isEmpty
      ? nil
      : environment.language.format(
        "overview.limits.overCount", table: "Overview", counts: over.count, shown.count)
    let footer =
      rest.isEmpty
      ? nil
      : environment.language.format("overview.limitsMore", table: "Planning", counts: rest.count)
    return LimitsTile(title: title, overLabel: label, rows: rows, footer: footer)
  }

  /// The share of the bar: spent over available, never past the whole; a limit with nothing
  /// available and something spent is full.
  static func fill(spent: AmountE4, available: AmountE4) -> Int {
    guard available.raw > 0 else { return spent.raw > 0 ? Shares.whole : 0 }
    return min(Shares.whole, max(0, Shares.ratio(spent, of: available) ?? 0))
  }

  /// The symbol of a status as the tile draws it: a cross, a warning, a tick.
  static func symbol(_ status: LimitStatus) -> String {
    switch status {
    case .over: "xmark"
    case .warning: "exclamationmark.triangle.fill"
    case .ok: "checkmark"
    }
  }
}

// MARK: - Pieces of the tiles

/// An amount in whole units without its unit — the first of two figures that share one, «от
/// 18 000 до 26 000 ₽», «9 800 / 8 000 ₽» — or the mask while amounts are hidden.
func wholeNumber(_ amount: AmountE4, _ money: MoneyFormatter) -> String {
  if money.hidesAmounts { return MoneyFormatter.mask }
  let whole = DecimalMath.round(amount.decimal, scale: 0)
  let number = money.number(whole < 0 ? -whole : whole, fractionDigits: 0...0)
  return whole < 0 ? "\u{2212}\(number)" : number
}

/// A line of a tile: its words on the left in 12, the figure on the right in 12 medium.
struct TileFigureRow<Trailing: View>: View {
  @Environment(\.themeSurfaces) private var surfaces
  let label: String
  @ViewBuilder var trailing: Trailing

  var body: some View {
    HStack(alignment: .center, spacing: StyleMetrics.tileInlineGap) {
      Text(verbatim: label)
        .appFont(StyleType.tileRow)
        .foregroundStyle(surfaces.primary)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 8)
      trailing
    }
    .accessibilityElement(children: .combine)
  }
}

extension TileFigureRow where Trailing == TileFigureText {
  init(label: String, figure: String) {
    self.init(label: label) { TileFigureText(text: figure) }
  }
}

/// The figure of a line: 12 medium, never wrapped.
struct TileFigureText: View {
  @Environment(\.themeSurfaces) private var surfaces
  let text: String

  var body: some View {
    Text(verbatim: text)
      .appFont(StyleType.tileRowFigure)
      .foregroundStyle(surfaces.primary)
      .lineLimit(1)
      .fixedSize()
  }
}

/// A bar of a tile: the neutral track, filled to `fillBp` in `ink`, 6 tall and fully rounded.
struct TileBar: View {
  @Environment(\.appTheme) private var theme
  let fillBp: Int
  let ink: Color

  var body: some View {
    let share = min(max(fillBp, 0), Shares.whole)
    Capsule()
      .fill(theme.fillNeutral)
      .overlay(alignment: .leading) {
        ProportionalRow(weights: [share, Shares.whole - share]) {
          Capsule().fill(ink)
          Color.clear
        }
      }
      .clipShape(Capsule())
      .frame(height: StyleMetrics.tileBarHeight)
      .accessibilityHidden(true)
  }
}

/// «просрочен»: the negative tint, a warning symbol and the word — never the colour alone.
struct TileOverdueChip: View {
  @Environment(\.appTheme) private var theme
  let text: String

  var body: some View {
    HStack(spacing: StyleMetrics.tileInlineGap) {
      Image(systemName: "exclamationmark.triangle.fill")
        .appFont(.system(size: 10, weight: .semibold))
        .foregroundStyle(theme.statusNegative)
        .frame(width: StyleMetrics.tileIcon, height: StyleMetrics.tileIcon)
        .accessibilityHidden(true)
      Text(verbatim: text)
        .appFont(StyleType.tileHintMedium)
        .foregroundStyle(theme.contentPrimary)
        .lineLimit(1)
    }
    .padding(.horizontal, StyleMetrics.chipHorizontal)
    .padding(.vertical, StyleMetrics.chipVertical)
    .background(theme.statusNegativeTint, in: Capsule())
    .fixedSize()
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Остаток месяца

/// «Остаток месяца» as the design lays its tile: what was left of the month that ended, the
/// figure in 24 bold, and «Распределить…» — the sheet that puts it away. Compact, it is the figure
/// alone, like any other tile of one figure.
struct MonthRestTileCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.themeSurfaces) private var surfaces
  @Environment(\.dependencies) private var dependencies
  var compact = false
  @State private var opened: MonthRestOffer?

  var body: some View {
    if compact {
      FigureTileCard(tile: .monthRest, compact: true)
    } else {
      ComputedBlock(
        title: OverviewTileText.name(of: .monthRest, environment),
        state: compute.states.data.flatMap { snapshot, at in
          snapshot.planning.monthRest.map { .ready($0, at: at) } ?? .notEnoughData
        },
        fillsHeight: true,
        emptyReason: environment.language("overview.monthRest.none", table: "Overview"),
        retry: { compute.retry(ComputeStep.data) }
      ) { offer in
        VStack(alignment: .leading, spacing: StyleMetrics.tileGap) {
          Text(
            verbatim: environment.format(
              "overview.monthRest.of", table: "Overview",
              environment.dates.monthTitle(offer.month))
          )
          .appFont(StyleType.tileRow)
          .foregroundStyle(surfaces.secondary)
          Text(verbatim: environment.money.rounded(offer.amountE4))
            .appFont(StyleType.mainFigure)
            .foregroundStyle(surfaces.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
          Button(environment.language("look.action.allocate", table: "Overview")) {
            opened = offer
          }
          .buttonStyle(.rowAction)
          .accessibilityIdentifier("overview.monthRest.allocate")
        }
      }
      .sheet(
        isPresented: Binding(get: { opened != nil }, set: { if !$0 { opened = nil } })
      ) {
        if let offer = opened {
          MonthRestSheet(offer: offer).handingOver(dependencies)
        }
      }
    }
  }
}
