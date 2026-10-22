import CoreAccounting
import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation

/// The breakdowns of the tiles of 2.0. Each reads the same `OverviewFigures` (or planning
/// figure) the tile does, so the total of a breakdown is the figure of its tile.
extension TileExplanations {
  /// The breakdown of a tile of 2.0.
  static func explainNew(_ tile: OverviewTile, _ inputs: TileInputs) -> TileExplanation {
    switch tile {
    case .spendToday: spendToday(inputs.figures)
    case .weekOverWeek: weekOverWeek(inputs.figures)
    case .averageDaily: averageDaily(inputs.figures)
    case .monthIncome: monthIncome(inputs.figures)
    case .savingsRate: savingsRate(inputs.figures)
    case .weekdaySpending: weekdaySpending(inputs.figures)
    case .monthlySpending: monthlySpending(inputs.figures)
    case .incomeSources: incomeSources(inputs.figures)
    case .topPlaces: topPlaces(inputs.figures, ledger: inputs.ledger)
    case .spendingByPerson: spendingByPerson(inputs.figures)
    case .categoryGrew: categoryMove(inputs.figures, grew: true)
    case .categoryShrank: categoryMove(inputs.figures, grew: false)
    case .smallPurchases: smallPurchases(inputs.figures)
    case .monthRest: monthRest(inputs.planning)
    case .currencyBalances: currencyBalances(inputs.planning.accounts)
    case .backups: backups(inputs.system)
    case .integrity: integrity(inputs.system)
    case .ratesStatus: ratesStatus(inputs.system)
    default: TileExplanation(tile: tile, state: .waiting)
    }
  }

  private static func lines(_ nodes: [BreakdownNode]) -> [TileRow] {
    nodes.map {
      TileRow(
        TilePhrase("why.name", .category($0.key)), money($0.amount), role: .plus, share: $0.share)
    }
  }

  // MARK: - Money

  /// The money of the accounts in the summary by currency, each at the rate of the day.
  public static func currencyBalances(_ accounts: AccountsSnapshot) -> TileExplanation {
    let balances = OverviewCurrencyBalances(accounts)
    guard !balances.lines.isEmpty else {
      return TileExplanation(
        tile: .currencyBalances, state: .empty(TilePhrase("why.currencies.none")))
    }
    let rows = balances.lines.map {
      TileRow(
        TilePhrase("why.name", .text($0.currency.code)), money($0.rub), role: .plus,
        share: Shares.ratio($0.rub, of: balances.totalRub),
        note: $0.currency == .rub
          ? nil : TilePhrase("why.currencies.native", .money($0.amount, $0.currency)))
    }
    return TileExplanation(
      tile: .currencyBalances,
      sections: [
        TileSection(
          rows: rows, total: TileRow(TilePhrase("why.currencies.total"), money(balances.totalRub)))
      ],
      notes: balances.withoutRate.isEmpty
        ? []
        : [
          TilePhrase(
            "why.currencies.withoutRate",
            .text(balances.withoutRate.map(\.code).joined(separator: ", ")))
        ])
  }

  // MARK: - Spending

  /// What I spent today by category, and the day it is held against.
  public static func spendToday(_ figures: OverviewFigures?) -> TileExplanation {
    guard let today = figures?.spendToday else {
      return TileExplanation(tile: .spendToday, state: .waiting)
    }
    guard today.operations > 0 else {
      return TileExplanation(tile: .spendToday, state: .empty(TilePhrase("why.today.none")))
    }
    var details = [TileRow(TilePhrase("why.today.operations"), .count(today.operations))]
    if let usual = today.usual {
      details.append(TileRow(TilePhrase("why.today.usual"), money(usual)))
    }
    if let bp = today.againstUsual {
      details.append(TileRow(TilePhrase("why.today.against"), .percent(bp)))
    }
    return TileExplanation(
      tile: .spendToday,
      sections: [
        TileSection(
          rows: lines(today.byCategory),
          total: TileRow(TilePhrase("why.today.total"), money(today.spent))),
        TileSection(rows: details),
      ],
      notes: today.usual == nil ? [TilePhrase("why.today.noUsual")] : [])
  }

  /// This week up to today by day, and the same days of the week before.
  public static func weekOverWeek(_ figures: OverviewFigures?) -> TileExplanation {
    guard let week = figures?.week else {
      return TileExplanation(tile: .weekOverWeek, state: .waiting)
    }
    let rows = week.days.map {
      TileRow(TilePhrase("why.week.day", .day($0.day)), money($0.amount), role: .plus)
    }
    var before = [
      TileRow(TilePhrase("why.week.before", .span(week.previous)), money(week.change.previous))
    ]
    before.append(TileRow(TilePhrase("why.week.change"), .change(week.change.delta, .rub)))
    if let bp = week.change.basisPoints {
      before.append(TileRow(TilePhrase("why.week.changeShare"), .percent(bp)))
    }
    return TileExplanation(
      tile: .weekOverWeek,
      sections: [
        TileSection(
          rows: rows, total: TileRow(TilePhrase("why.week.total"), money(week.change.current))),
        TileSection(rows: before),
      ])
  }

  /// The spending of the month so far over the days it has had.
  public static func averageDaily(_ figures: OverviewFigures?) -> TileExplanation {
    guard let average = figures?.average else {
      return TileExplanation(tile: .averageDaily, state: .waiting)
    }
    return TileExplanation(
      tile: .averageDaily,
      sections: [
        TileSection(
          rows: [
            TileRow(TilePhrase("why.average.expenses"), money(average.expenses)),
            TileRow(TilePhrase("why.average.days"), .count(average.days)),
          ], total: TileRow(TilePhrase("why.average.total"), money(average.perDay)))
      ])
  }

  // MARK: - Income and saving

  /// What came this month by source, and what is still expected.
  public static func monthIncome(_ figures: OverviewFigures?) -> TileExplanation {
    guard let income = figures?.income else {
      return TileExplanation(tile: .monthIncome, state: .waiting)
    }
    var sections = [
      TileSection(
        rows: lines(income.bySource),
        total: TileRow(TilePhrase("why.income.received"), money(income.received)))
    ]
    if income.expected.raw > 0 {
      sections.append(
        TileSection(rows: [TileRow(TilePhrase("why.income.expected"), money(income.expected))]))
    }
    return TileExplanation(tile: .monthIncome, sections: sections)
  }

  /// What was put aside this month and the income it is a share of.
  public static func savingsRate(_ figures: OverviewFigures?) -> TileExplanation {
    guard let savings = figures?.savings else {
      return TileExplanation(tile: .savingsRate, state: .waiting)
    }
    guard let rate = savings.basisPoints else {
      return TileExplanation(tile: .savingsRate, state: .empty(TilePhrase("why.savings.noIncome")))
    }
    return TileExplanation(
      tile: .savingsRate,
      sections: [
        TileSection(
          rows: [
            TileRow(TilePhrase("why.savings.goals"), money(savings.goals), role: .plus),
            TileRow(TilePhrase("why.savings.accounts"), money(savings.accounts), role: .plus),
          ], total: TileRow(TilePhrase("why.savings.total"), money(savings.saved))),
        TileSection(
          rows: [
            TileRow(TilePhrase("why.savings.income"), money(savings.income)),
            TileRow(TilePhrase("why.savings.rate"), .percent(rate)),
          ]),
      ],
      notes: savings.leftOutForeign > 0
        ? [TilePhrase("why.savings.foreign", .count(savings.leftOutForeign))] : [])
  }

  // MARK: - Charts and lists

  /// The last weeks by weekday: a total and an average of each.
  public static func weekdaySpending(_ figures: OverviewFigures?) -> TileExplanation {
    guard let weekdays = figures?.weekdays else {
      return TileExplanation(tile: .weekdaySpending, state: .waiting)
    }
    guard weekdays.total.raw > 0 else {
      return TileExplanation(tile: .weekdaySpending, state: .empty(TilePhrase("why.noSpending")))
    }
    let rows = weekdays.days.map { day in
      TileRow(
        TilePhrase("why.weekday.\(day.weekday)"), money(day.total), role: .plus,
        share: Shares.ratio(day.total, of: weekdays.total),
        note: day.average.map { TilePhrase("why.weekday.average", .money($0, .rub)) })
    }
    return TileExplanation(
      tile: .weekdaySpending,
      sections: [
        TileSection(
          title: TilePhrase("why.weekday.title", .span(weekdays.interval)), rows: rows,
          total: TileRow(TilePhrase("why.weekday.total"), money(weekdays.total)))
      ])
  }

  /// The last twelve months of my spending.
  public static func monthlySpending(_ figures: OverviewFigures?) -> TileExplanation {
    guard let months = figures?.months else {
      return TileExplanation(tile: .monthlySpending, state: .waiting)
    }
    guard months.total.raw > 0 else {
      return TileExplanation(tile: .monthlySpending, state: .empty(TilePhrase("why.noSpending")))
    }
    let rows = months.months.map {
      TileRow(TilePhrase("why.months.row", .text($0.month.iso)), money($0.amount), role: .plus)
    }
    return TileExplanation(
      tile: .monthlySpending,
      sections: [
        TileSection(
          rows: rows, total: TileRow(TilePhrase("why.months.total"), money(months.total)))
      ],
      notes: [TilePhrase("why.months.current")])
  }

  /// Where the income of the month comes from.
  public static func incomeSources(_ figures: OverviewFigures?) -> TileExplanation {
    guard let sources = figures?.sources else {
      return TileExplanation(tile: .incomeSources, state: .waiting)
    }
    guard !sources.sources.isEmpty else {
      return TileExplanation(tile: .incomeSources, state: .empty(TilePhrase("why.sources.none")))
    }
    return TileExplanation(
      tile: .incomeSources,
      sections: [
        TileSection(
          rows: lines(sources.sources),
          total: TileRow(TilePhrase("why.sources.total"), money(sources.total)))
      ])
  }

  /// The places my spending went to, the rest in one line.
  public static func topPlaces(_ figures: OverviewFigures?, ledger: Ledger) -> TileExplanation {
    guard let places = figures?.places else {
      return TileExplanation(tile: .topPlaces, state: .waiting)
    }
    guard !places.top.isEmpty else {
      return TileExplanation(tile: .topPlaces, state: .empty(TilePhrase("why.places.none")))
    }
    let names = Dictionary(
      ledger.dataset.places.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    var rows: [TileRow] = places.top.map { node in
      var name = "—"
      if case .place(let id) = node.key { name = names[id] ?? "—" }
      return TileRow(
        TilePhrase("why.name", .text(name)), money(node.amount), role: .plus,
        share: Shares.ratio(node.amount, of: places.total))
    }
    if places.rest.raw != 0 {
      rows.append(TileRow(TilePhrase("why.places.rest"), money(places.rest), role: .plus))
    }
    return TileExplanation(
      tile: .topPlaces,
      sections: [
        TileSection(rows: rows, total: TileRow(TilePhrase("why.places.total"), money(places.total)))
      ])
  }

  /// My spending of the month by «на кого».
  public static func spendingByPerson(_ figures: OverviewFigures?) -> TileExplanation {
    guard let people = figures?.people else {
      return TileExplanation(tile: .spendingByPerson, state: .waiting)
    }
    guard !people.values.isEmpty else {
      return TileExplanation(tile: .spendingByPerson, state: .empty(TilePhrase("why.noSpending")))
    }
    return TileExplanation(
      tile: .spendingByPerson,
      sections: [
        TileSection(
          rows: lines(people.values),
          total: TileRow(TilePhrase("why.people.total"), money(people.total)))
      ])
  }

  // MARK: - A category that moved

  /// The category that grew (or shrank) most against the same days of last month.
  public static func categoryMove(_ figures: OverviewFigures?, grew: Bool) -> TileExplanation {
    let tile: OverviewTile = grew ? .categoryGrew : .categoryShrank
    guard let figures else { return TileExplanation(tile: tile, state: .waiting) }
    guard let move = grew ? figures.grew : figures.shrank else {
      return TileExplanation(
        tile: tile, state: .empty(TilePhrase(grew ? "why.grew.none" : "why.shrank.none")))
    }
    var rows = [
      TileRow(TilePhrase("why.move.now"), money(move.current), role: .plus),
      TileRow(TilePhrase("why.move.before"), money(move.previous), role: .minus),
    ]
    if let bp = move.basisPoints {
      rows.append(TileRow(TilePhrase("why.move.share"), .percent(bp)))
    }
    return TileExplanation(
      tile: tile,
      sections: [
        TileSection(
          title: TilePhrase("why.name", .category(move.key)), rows: rows,
          total: TileRow(TilePhrase("why.move.total"), .change(move.delta, .rub)))
      ])
  }

  // MARK: - Small purchases

  /// The small purchases of the month by category.
  public static func smallPurchases(_ figures: OverviewFigures?) -> TileExplanation {
    guard let figures else { return TileExplanation(tile: .smallPurchases, state: .waiting) }
    guard let small = figures.small else {
      return TileExplanation(tile: .smallPurchases, state: .empty(TilePhrase("why.small.notSet")))
    }
    guard small.count > 0 else {
      return TileExplanation(tile: .smallPurchases, state: .empty(TilePhrase("why.small.none")))
    }
    return TileExplanation(
      tile: .smallPurchases,
      sections: [
        TileSection(
          rows: lines(small.byCategory),
          total: TileRow(TilePhrase("why.small.total"), money(small.total))),
        TileSection(
          rows: [
            TileRow(TilePhrase("why.small.limit"), money(small.limit)),
            TileRow(TilePhrase("why.small.count"), .count(small.count)),
          ]),
      ])
  }

  // MARK: - What is left of the month

  /// The rest of the month just past: what can be spent less the payments and the dues.
  public static func monthRest(_ planning: PlanningSnapshot) -> TileExplanation {
    let free = planning.freeMoney
    guard let offer = planning.monthRest, let main = free.main else {
      return TileExplanation(tile: .monthRest, state: .empty(TilePhrase("why.monthRest.none")))
    }
    return TileExplanation(
      tile: .monthRest,
      sections: [
        TileSection(
          title: TilePhrase("why.monthRest.of", .text(offer.month.iso)),
          rows: [
            TileRow(TilePhrase("why.monthRest.main"), money(main), role: .plus),
            TileRow(
              TilePhrase("why.monthRest.scheduled"), money(free.plan.scheduled), role: .minus),
            TileRow(TilePhrase("why.monthRest.debts"), money(free.plan.debts), role: .minus),
          ], total: TileRow(TilePhrase("why.monthRest.total"), money(offer.amountE4)))
      ])
  }

  // MARK: - The state of the books

  public static func backups(_ system: OverviewSystemStatus?) -> TileExplanation {
    guard let system else { return TileExplanation(tile: .backups, state: .waiting) }
    guard let moment = system.backupAt else {
      return TileExplanation(tile: .backups, state: .empty(TilePhrase("why.backups.none")))
    }
    return TileExplanation(
      tile: .backups,
      sections: [
        TileSection(
          rows: [
            TileRow(TilePhrase("why.backups.last"), .moment(moment)),
            TileRow(TilePhrase("why.backups.age"), .count(system.backupAgeDays ?? 0)),
            TileRow(TilePhrase("why.backups.count"), .count(system.backupCount)),
          ])
      ],
      notes: system.backup == .stale
        ? [TilePhrase("why.backups.stale", .count(OverviewSystemStatus.backupStaleDays))] : [])
  }

  public static func integrity(_ system: OverviewSystemStatus?) -> TileExplanation {
    guard let system else { return TileExplanation(tile: .integrity, state: .waiting) }
    guard let moment = system.checkedAt else {
      return TileExplanation(tile: .integrity, state: .empty(TilePhrase("why.integrity.none")))
    }
    return TileExplanation(
      tile: .integrity,
      sections: [
        TileSection(
          rows: [
            TileRow(TilePhrase("why.integrity.last"), .moment(moment)),
            TileRow(
              TilePhrase("why.integrity.problems"), .count(system.problems),
              mark: system.problems > 0 ? .warning : nil),
          ])
      ])
  }

  public static func ratesStatus(_ system: OverviewSystemStatus?) -> TileExplanation {
    guard let system else { return TileExplanation(tile: .ratesStatus, state: .waiting) }
    guard let day = system.ratesDay else {
      return TileExplanation(tile: .ratesStatus, state: .empty(TilePhrase("why.rates.none")))
    }
    return TileExplanation(
      tile: .ratesStatus,
      sections: [
        TileSection(
          rows: [
            TileRow(TilePhrase("why.rates.day"), .day(day)),
            TileRow(TilePhrase("why.rates.age"), .count(system.ratesAgeDays ?? 0)),
          ])
      ],
      notes: system.rates == .stale
        ? [TilePhrase("why.rates.stale", .count(OverviewSystemStatus.ratesStaleDays))] : [])
  }
}
