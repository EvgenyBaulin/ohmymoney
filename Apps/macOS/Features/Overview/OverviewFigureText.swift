import AppCore
import Foundation

/// What a tile that is one figure says: the figure, a caption under it, and lines of detail the
/// regular card adds under them. The compact card — two to a cell — shows the figure and the
/// caption alone.
struct OverviewTileFigure: Equatable {
  var value: String
  var caption: String?
  /// A symbol that says what the figure means, so the meaning never rests on a colour.
  var symbol: String?
  var details: [String] = []
}

/// What a figure tile has to say: a figure, or why there is none.
enum OverviewFigureResult: Equatable {
  case figure(OverviewTileFigure)
  /// The key of the sentence in the Overview catalog that says there is nothing to show.
  case empty(String)

  var figure: OverviewTileFigure? {
    if case .figure(let figure) = self { return figure }
    return nil
  }

  var emptyKey: String? {
    if case .empty(let key) = self { return key }
    return nil
  }
}

/// The words of the figure tiles, from the very values the core counted
/// (`OverviewFigures`, `OverviewSystemStatus`, the planning snapshot) — apart from the views so a
/// test reads them in both languages.
@MainActor
enum OverviewFigureText {
  static let table = "Overview"

  /// Every tile that is one figure, compact or regular.
  static let tiles: [OverviewTile] = [
    .owedToMe, .iOwe, .lastCount, .lastRecord, .upcoming, .spendToday, .weekOverWeek,
    .averageDaily, .monthIncome, .savingsRate, .monthRest, .smallPurchases, .backups,
    .integrity, .ratesStatus,
  ]

  static func result(
    of tile: OverviewTile, snapshot: DataSnapshot, figures: OverviewFigures,
    system: OverviewSystemStatus, _ environment: AppEnvironment
  ) -> OverviewFigureResult {
    let money = environment.money
    func t(_ key: String) -> String { environment.language(key, table: table) }
    func counted(_ key: String, _ count: Int) -> String {
      environment.language.format(key, table: table, counts: count)
    }
    switch tile {
    case .owedToMe:
      let owed = snapshot.owed
      guard owed.count > 0 else { return .empty("overview.compact.owedNone") }
      return .figure(
        .init(
          value: money.rounded(owed.amount),
          caption: counted("overview.compact.owedParts", owed.count),
          symbol: "person.crop.circle.badge.clock"))
    case .iOwe:
      let debts = snapshot.planning.debts
      guard !debts.iOwe.isEmpty else { return .empty("overview.iOwe.none") }
      let monthly =
        debts.monthlyPaymentsRub.raw > 0
        ? environment.format(
          "overview.compact.iOweMonthly", table: table, money.rounded(debts.monthlyPaymentsRub))
        : nil
      return .figure(
        .init(value: money.rounded(debts.totalIOweRub), caption: monthly, symbol: "creditcard"))
    case .lastCount:
      guard let last = snapshot.planning.lastReconciliation else {
        return .empty("overview.lastCount.none")
      }
      return .figure(
        .init(
          value: environment.dates.longDay(last.date),
          caption: environment.language.format(
            "overview.reconciliationAgo", table: "Planning",
            counts: max(0, last.date.days(to: snapshot.today))),
          symbol: "checkmark.seal"))
    case .lastRecord:
      guard let moment = OverviewSummary.lastRecordedAt(snapshot.dataset) else {
        return .empty("overview.lastRecord.none")
      }
      let entry = OverviewTileText.lastOperation(in: snapshot.dataset)
      return .figure(
        .init(
          value: OverviewText.lastRecord(moment, environment),
          caption: entry.map { OverviewTileText.title(of: $0, tree: snapshot.ledger.tree) },
          symbol: entry.map { OverviewTileText.symbol(of: $0.transaction.kind) }))
    case .upcoming:
      let upcoming = snapshot.planning.upcoming
      guard let first = upcoming.first else { return .empty("overview.upcomingNone.compact") }
      return .figure(
        .init(
          value: counted("overview.compact.upcoming", upcoming.count),
          caption: "\(environment.dates.dayAndMonth(first.due)) · \(first.name)",
          symbol: first.isOverdue ? "exclamationmark.circle" : "calendar"))
    case .spendToday:
      let today = figures.spendToday
      guard today.operations > 0 else { return .empty("overview.today.none") }
      var details: [String] = []
      if let usual = today.usual {
        details.append(
          environment.format("overview.today.usual", table: table, money.rounded(usual)))
      }
      if let bp = today.againstUsual {
        details.append(
          environment.format(
            "overview.today.against", table: table, money.signedPercent(basisPoints: bp)))
      }
      return .figure(
        .init(
          value: money.rounded(today.spent),
          caption: counted("overview.today.operations", today.operations),
          symbol: "arrow.down.circle", details: details))
    case .weekOverWeek:
      let week = figures.week
      let text = money.change(week.change)
      let against: String =
        text.percent.map {
          String(
            format: t("overview.comparison"), locale: environment.language.locale, text.delta, $0,
            environment.dates.span(week.previous))
        } ?? environment.format("overview.comparisonNoBase", table: table, text.delta)
      return .figure(
        .init(
          value: money.rounded(week.change.current), caption: against,
          symbol: Palette.changeSymbol(text.direction)))
    case .averageDaily:
      let average = figures.average
      return .figure(
        .init(
          value: money.rounded(average.perDay),
          caption: counted("overview.average.days", average.days), symbol: "divide.circle"))
    case .monthIncome:
      let income = figures.income
      guard income.received.raw > 0 || income.expected.raw > 0 else {
        return .empty("overview.income.none")
      }
      let expected =
        income.expected.raw > 0
        ? environment.format(
          "overview.income.expected", table: table, money.rounded(income.expected))
        : t("overview.income.received")
      return .figure(
        .init(value: money.rounded(income.received), caption: expected, symbol: "arrow.up.circle"))
    case .savingsRate:
      let savings = figures.savings
      guard let bp = savings.basisPoints else { return .empty("overview.savings.noIncome") }
      var details: [String] = []
      if savings.leftOutForeign > 0 {
        details.append(counted("overview.savings.foreign", savings.leftOutForeign))
      }
      return .figure(
        .init(
          value: money.percent(basisPoints: bp),
          caption: environment.format(
            "overview.savings.saved", table: table, money.rounded(savings.saved)),
          symbol: "banknote", details: details))
    case .monthRest:
      guard let offer = snapshot.planning.monthRest else {
        return .empty("overview.monthRest.none")
      }
      return .figure(
        .init(
          value: money.rounded(offer.amountE4),
          caption: environment.format(
            "overview.monthRest.of", table: table, environment.dates.monthTitle(offer.month)),
          symbol: "tray.and.arrow.down"))
    case .smallPurchases:
      guard let small = figures.small else { return .empty("overview.small.notSet") }
      guard small.count > 0 else { return .empty("overview.small.none") }
      return .figure(
        .init(
          value: money.rounded(small.total),
          caption: environment.language.format(
            "overview.small.count", table: table, counts: small.count),
          symbol: "cart",
          details: [
            environment.format("overview.small.limit", table: table, money.rounded(small.limit))
          ]))
    case .backups:
      guard let age = system.backupAgeDays else { return .empty("overview.backups.none") }
      let stale = system.backup == .stale
      return .figure(
        .init(
          value: age == 0 ? t("overview.backups.today") : counted("overview.backups.ago", age),
          caption: stale
            ? environment.format(
              "overview.backups.stale", table: table,
              NumberText.integer(Int64(OverviewSystemStatus.backupStaleDays)))
            : counted("overview.backups.count", system.backupCount),
          symbol: stale ? "exclamationmark.triangle" : "externaldrive.badge.checkmark"))
    case .integrity:
      guard system.checkedAt != nil else { return .empty("overview.integrity.none") }
      let broken = system.problems > 0
      let word = t(broken ? "overview.integrity.problems" : "overview.integrity.healthy")
      let when = system.checkAgeDays.map { counted("overview.integrity.ago", $0) }
      return .figure(
        .init(
          value: word, caption: when,
          symbol: broken ? "exclamationmark.triangle" : "checkmark.shield",
          details: broken ? [counted("overview.integrity.rows", system.problems)] : []))
    case .ratesStatus:
      guard let day = system.ratesDay else { return .empty("overview.rates.none") }
      let stale = system.rates == .stale
      return .figure(
        .init(
          value: environment.dates.longDay(day),
          caption: stale
            ? environment.format(
              "overview.rates.stale", table: table,
              NumberText.integer(Int64(OverviewSystemStatus.ratesStaleDays)))
            : t("overview.rates.fresh"),
          symbol: stale ? "exclamationmark.triangle" : "chart.line.uptrend.xyaxis"))
    default:
      return .empty("overview.noData")
    }
  }
}
