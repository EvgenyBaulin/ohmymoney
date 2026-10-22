import CoreAccounting
import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation

/// What the breakdowns of the tiles read: the values the tiles themselves are made of — the data
/// step's summary and planning, the forecast step's remainder, the owed step's figure, the
/// anomalies — and the few pieces the app lays out for a tile (the order and the names of the
/// limits, the week of the calendar, the rates of the chart).
public struct TileInputs: Sendable {
  public var ledger: Ledger
  public var summary: OverviewSummary
  public var planning: PlanningSnapshot
  public var today: DateOnly
  /// The forecast step's remainder of the month; `nil` while it has not come.
  public var remainder: MonthForecast.Remainder?
  /// The plan of the accounts the remainder is laid over (`AccountMonthPlan`).
  public var accountPlan: AccountMonthPlan?
  /// The accounts of the summary in the order the sidebar shows them.
  public var summaryAccountIds: [UUID]
  /// The owed step's figure; `nil` while it has not come.
  public var owed: AmountE4?
  /// The anomalies step's report; `nil` while it has not come.
  public var anomalies: AnomalyReport?
  /// The limits in the order the lists of limits show them, and their names as they name them.
  public var limits: [LimitLine]
  public var limitNames: [UUID: String]
  /// How many lines of «Стоит посмотреть» the tile shows before «и ещё N».
  public var anomaliesShown: Int
  /// The week of the calendar tile.
  public var calendarWeek: SpendingCalendar?
  /// The pair of the chart tile and its rates.
  public var rates: TileRateSeries?
  /// The figures of the tiles of 2.0 that count from the ledger alone.
  public var figures: OverviewFigures?
  /// The state of the copies, the check of the database and the rates.
  public var system: OverviewSystemStatus?

  public init(
    ledger: Ledger, summary: OverviewSummary, planning: PlanningSnapshot, today: DateOnly,
    remainder: MonthForecast.Remainder? = nil, accountPlan: AccountMonthPlan? = nil,
    summaryAccountIds: [UUID] = [], owed: AmountE4? = nil, anomalies: AnomalyReport? = nil,
    limits: [LimitLine] = [], limitNames: [UUID: String] = [:], anomaliesShown: Int = 3,
    calendarWeek: SpendingCalendar? = nil, rates: TileRateSeries? = nil,
    figures: OverviewFigures? = nil, system: OverviewSystemStatus? = nil
  ) {
    self.ledger = ledger
    self.summary = summary
    self.planning = planning
    self.today = today
    self.remainder = remainder
    self.accountPlan = accountPlan
    self.summaryAccountIds = summaryAccountIds
    self.owed = owed
    self.anomalies = anomalies
    self.limits = limits
    self.limitNames = limitNames
    self.anomaliesShown = anomaliesShown
    self.calendarWeek = calendarWeek
    self.rates = rates
    self.figures = figures
    self.system = system
  }
}

/// The rates the chart tile shows for its pair and period: the first and the last point, and
/// the change between them (`CurrencyChart.summary`).
public struct TileRateSeries: Hashable, Sendable {
  public struct Point: Hashable, Sendable {
    public var day: DateOnly
    public var rateE4: Int64

    public init(day: DateOnly, rateE4: Int64) {
      self.day = day
      self.rateE4 = rateE4
    }
  }

  public enum Period: String, Hashable, Sendable {
    case week, month, year
  }

  public var base: CurrencyCode
  public var quote: CurrencyCode
  public var period: Period
  /// `nil` while the rates are loading or fewer than two days have one.
  public var first: Point?
  public var last: Point?
  public var changeE4: Int64
  public var changeBp: Int

  public init(
    base: CurrencyCode, quote: CurrencyCode, period: Period, first: Point?, last: Point?,
    changeE4: Int64, changeBp: Int
  ) {
    self.base = base
    self.quote = quote
    self.period = period
    self.first = first
    self.last = last
    self.changeE4 = changeE4
    self.changeBp = changeBp
  }
}

/// The breakdown of every tile, from the very values the tile shows.
public enum TileExplanations {
  /// The key of the rule sentence of a tile.
  public static func ruleKey(of tile: OverviewTile) -> String { "why.rule.\(tile.rawValue)" }

  public static func explain(_ tile: OverviewTile, _ inputs: TileInputs) -> TileExplanation {
    switch tile {
    case .monthToDate: monthToDate(inputs.summary)
    case .topCategories: topCategories(inputs.summary)
    case .qualities: qualities(inputs.summary)
    case .canSave: canSave(inputs.planning, remainder: inputs.remainder)
    case .spendingForecast:
      spendingForecast(inputs.summary, inputs.planning, remainder: inputs.remainder)
    case .incomeForecast: incomeForecast(inputs.planning.income)
    case .balanceForecast:
      balanceForecast(
        inputs.accountPlan, remainder: inputs.remainder, accountIds: inputs.summaryAccountIds)
    case .limits: limits(inputs.limits, names: inputs.limitNames)
    case .upcoming: upcoming(inputs.planning.upcoming)
    case .expectedIncome:
      expectedIncome(inputs.planning, ledger: inputs.ledger, today: inputs.today)
    case .owedToMe: owedToMe(inputs.ledger, figure: inputs.owed)
    case .iOwe: iOwe(inputs.planning.debts)
    case .event: event(inputs.planning.events)
    case .lastCount: lastCount(inputs.planning, ledger: inputs.ledger, today: inputs.today)
    case .lastRecord: lastRecord(inputs.ledger)
    case .lastCountAndRecord:
      lastCountAndRecord(inputs.planning, ledger: inputs.ledger, today: inputs.today)
    case .worthALook: worthALook(inputs)
    case .freeMoney: freeMoney(inputs.planning.freeMoney)
    case .currencyChart: currencyChart(inputs.rates)
    case .spendingCalendar: spendingCalendar(inputs.calendarWeek)
    case .capital: capital(inputs.planning.capital)
    case .cushion: cushion(inputs.planning.cushion)
    case .installments: installments(inputs.planning.instalments)
    case .selfEmployment: selfEmployment(inputs.planning.npd, today: inputs.today)
    default: explainNew(tile, inputs)
    }
  }

  // MARK: - The month

  /// Income less spending from the 1st to today, each beside the same days of last month.
  public static func monthToDate(_ summary: OverviewSummary) -> TileExplanation {
    let span = TileArgument.span(summary.previousSpan)
    let main = TileSection(
      rows: [
        TileRow(TilePhrase("why.month.income"), money(summary.income.current), role: .plus),
        TileRow(TilePhrase("why.month.expenses"), money(summary.expenses.current), role: .minus),
      ],
      total: TileRow(TilePhrase("why.month.net"), money(summary.net)))
    let before = TileSection(
      title: TilePhrase("why.month.before", span),
      rows: [
        TileRow(TilePhrase("why.month.income"), money(summary.income.previous)),
        TileRow(TilePhrase("why.month.expenses"), money(summary.expenses.previous)),
      ])
    return TileExplanation(
      tile: .monthToDate, sections: [main, before],
      notes: [TilePhrase("why.month.span", .span(summary.span))])
  }

  /// The largest categories of my spending, the rest in one line, and the money they are all
  /// shares of.
  public static func topCategories(_ summary: OverviewSummary) -> TileExplanation {
    guard !summary.topCategories.isEmpty else {
      return TileExplanation(tile: .topCategories, state: .empty(TilePhrase("why.noSpending")))
    }
    var rows = summary.topCategories.map {
      TileRow(
        TilePhrase("why.name", .category($0.key)), money($0.amount), role: .plus, share: $0.share)
    }
    let shown = Set(summary.topCategories.map(\.key))
    let rest = summary.categories.filter { !shown.contains($0.key) }
    let restSpent = rest.filter { $0.amount.raw > 0 }
    if !restSpent.isEmpty {
      rows.append(
        TileRow(
          TilePhrase("why.top.rest", .count(restSpent.count)),
          money(AmountE4.sum(restSpent.map(\.amount))), role: .plus,
          share: Shares.basisPoints(of: restSpent, among: summary.categories)))
    }
    // A category whose refunds outweighed its spending is no share of the money spent.
    for node in rest where node.amount.raw < 0 {
      rows.append(
        TileRow(
          TilePhrase("why.top.refunded", .category(node.key)), money(node.amount),
          note: TilePhrase("why.top.refundedNote")))
    }
    let base = AmountE4.sum(summary.categories.filter { $0.amount.raw > 0 }.map(\.amount))
    return TileExplanation(
      tile: .topCategories,
      sections: [TileSection(rows: rows, total: TileRow(TilePhrase("why.top.total"), money(base)))]
    )
  }

  /// Good, neutral and bad spending, and how bad spending moved.
  public static func qualities(_ summary: OverviewSummary) -> TileExplanation {
    guard summary.qualities.contains(where: { $0.share != nil }) else {
      return TileExplanation(tile: .qualities, state: .empty(TilePhrase("why.noSpending")))
    }
    var rows: [TileRow] = []
    for node in summary.qualities {
      guard case .quality(let quality) = node.key else { continue }
      rows.append(
        TileRow(
          TilePhrase("why.name", .quality(quality)), money(node.amount),
          role: node.amount.raw > 0 ? .plus : .detail, mark: .quality(quality), share: node.share))
    }
    let base = AmountE4.sum(summary.qualities.map(\.amount).filter { $0.raw > 0 })
    let bad = TileSection(
      title: TilePhrase("why.qualities.badTitle", .span(summary.previousSpan)),
      rows: [
        TileRow(TilePhrase("why.qualities.badNow"), money(summary.bad.current)),
        TileRow(TilePhrase("why.qualities.badBefore"), money(summary.bad.previous)),
        TileRow(TilePhrase("why.qualities.badChange"), .change(summary.bad.delta, .rub)),
      ])
    return TileExplanation(
      tile: .qualities,
      sections: [
        TileSection(rows: rows, total: TileRow(TilePhrase("why.qualities.total"), money(base))),
        bad,
      ])
  }

  /// Income less spending, payments and what the rest of the month is likely to cost.
  public static func canSave(
    _ planning: PlanningSnapshot, remainder: MonthForecast.Remainder?
  ) -> TileExplanation {
    guard let remainder else { return TileExplanation(tile: .canSave, state: .waiting) }
    let canSave = planning.canSave(remainder: remainder)
    guard case .ready = canSave.status, let p50 = canSave.p50 else {
      return TileExplanation(tile: .canSave, state: .empty(TilePhrase("why.canSave.noIncome")))
    }
    let rows = canSave.lines.map { line in
      TileRow(
        TilePhrase(canSaveKey(line.key)), money(line.amount),
        role: line.sign == .plus ? .plus : .minus)
    }
    var details = [
      TileRow(TilePhrase("why.canSave.already"), money(canSave.alreadySaved)),
      TileRow(TilePhrase("why.canSave.more"), money(canSave.canSaveMore ?? .zero)),
    ]
    if let low = canSave.low, let high = canSave.high, low != high {
      details.insert(
        TileRow(TilePhrase("why.range", .money(low, .rub), .money(high, .rub))), at: 0)
    }
    return TileExplanation(
      tile: .canSave,
      sections: [
        TileSection(
          rows: rows, total: TileRow(TilePhrase("why.canSave.total"), .approximately(p50, .rub))),
        TileSection(rows: details),
      ],
      notes: canSave.lowData ? [TilePhrase("why.lowData")] : [])
  }

  static func canSaveKey(_ key: String) -> String {
    switch key {
    case CanSave.Key.income: "why.canSave.income"
    case CanSave.Key.spent: "why.canSave.spent"
    case CanSave.Key.planned: "why.canSave.planned"
    default: "why.canSave.variable"
    }
  }

  /// Spent so far, the payments still due, and what the days left are likely to add.
  public static func spendingForecast(
    _ summary: OverviewSummary, _ planning: PlanningSnapshot, remainder: MonthForecast.Remainder?
  ) -> TileExplanation {
    guard let remainder else { return TileExplanation(tile: .spendingForecast, state: .waiting) }
    let planned = planning.planned
    let forecast = MonthForecast(
      spent: summary.expenses.current, planned: planned.total, remainder: remainder)
    var rows = [
      TileRow(TilePhrase("why.forecast.spent"), money(summary.expenses.current), role: .plus)
    ]
    rows.append(
      TileRow(TilePhrase("why.forecast.scheduled"), money(planned.scheduled), role: .plus))
    rows.append(TileRow(TilePhrase("why.forecast.debts"), money(planned.debts), role: .plus))
    rows.append(TileRow(TilePhrase("why.forecast.goals"), money(planned.goals), role: .plus))
    rows.append(
      TileRow(
        TilePhrase("why.forecast.variable", .count(remainder.daysLeft)),
        .approximately(remainder.middle, .rub), role: .plus))
    var details: [TileRow] = []
    if forecast.p10 != forecast.p90 {
      details.append(
        TileRow(TilePhrase("why.range", .money(forecast.p10, .rub), .money(forecast.p90, .rub))))
    }
    details.append(
      TileRow(TilePhrase("why.forecast.window", .count(remainder.windowDays)), nil))
    return TileExplanation(
      tile: .spendingForecast,
      sections: [
        TileSection(
          rows: rows,
          total: TileRow(TilePhrase("why.forecast.total"), .approximately(forecast.p50, .rub))),
        TileSection(rows: details),
      ],
      notes: forecast.lowData ? [TilePhrase("why.lowData")] : [])
  }

  /// What came, and what the month is still expected to bring and why.
  public static func incomeForecast(_ income: MonthIncomeEstimate) -> TileExplanation {
    guard let value = income.value else {
      return TileExplanation(
        tile: .incomeForecast, state: .empty(TilePhrase("why.income.none")))
    }
    var rows = [TileRow(TilePhrase("why.income.received"), money(income.received), role: .plus)]
    var details: [TileRow] = []
    switch income.source {
    case .expectations:
      rows.append(
        TileRow(TilePhrase("why.income.expected"), money(value - income.received), role: .plus))
    case .median:
      rows.append(
        TileRow(TilePhrase("why.income.toMedian"), money(value - income.received), role: .plus))
      if let median = income.median3 {
        details.append(
          TileRow(TilePhrase("why.income.median", .count(income.monthsInMedian)), money(median)))
      }
    case .receivedOnly:
      break
    }
    return TileExplanation(
      tile: .incomeForecast,
      sections: [
        TileSection(
          rows: rows, total: TileRow(TilePhrase("why.income.total"), .approximately(value, .rub))),
        TileSection(rows: details),
      ],
      notes: [TilePhrase("why.income.source.\(income.source.rawValue)")]
        + (income.expectationsWithoutRate.isEmpty ? [] : [TilePhrase("why.noRate")]))
  }

  /// Each counted balance of the summary at the end of the month, added up by currency.
  public static func balanceForecast(
    _ plan: AccountMonthPlan?, remainder: MonthForecast.Remainder?, accountIds: [UUID]
  ) -> TileExplanation {
    guard let plan, let remainder else {
      return TileExplanation(tile: .balanceForecast, state: .waiting)
    }
    let model = BalanceForecastModel(
      forecast: plan.forecast(remainder: remainder), accountIds: accountIds)
    guard !model.totals.isEmpty else {
      return TileExplanation(
        tile: .balanceForecast, state: .empty(TilePhrase("why.balance.none")))
    }
    let sections = model.totals.map { total in
      TileSection(
        title: model.totals.count > 1
          ? TilePhrase("why.currency", .text(total.currency.code))
          : nil,
        rows: model.lines.filter { $0.currency == total.currency }.map { line in
          TileRow(
            TilePhrase("why.name", .text(line.name)), .approximately(line.middle, line.currency),
            role: .plus, note: TilePhrase("why.balance.now", .money(line.now, line.currency)))
        },
        total: TileRow(
          TilePhrase("why.balance.total", .day(model.through)),
          .approximately(total.middle, total.currency)))
    }
    var notes: [TilePhrase] = []
    if model.leftOut { notes.append(TilePhrase("why.balance.leftOut")) }
    if model.lowData { notes.append(TilePhrase("why.lowData")) }
    return TileExplanation(tile: .balanceForecast, sections: sections, notes: notes)
  }

  // MARK: - Planning

  /// Every limit of the month in the order of the lists, spent against what is available.
  public static func limits(_ lines: [LimitLine], names: [UUID: String]) -> TileExplanation {
    guard !lines.isEmpty else {
      return TileExplanation(tile: .limits, state: .empty(TilePhrase("why.limits.none")))
    }
    let rows = lines.map { line in
      TileRow(
        TilePhrase(
          "why.limits.line", .limitStatus(line.status), .text(names[line.budget.id] ?? "—")),
        .spentOf(line.spent, line.available), mark: .limit(line.status),
        note: line.carry.isZero
          ? nil : TilePhrase("why.limits.carry", .money(line.carry, .rub)))
    }
    return TileExplanation(tile: .limits, sections: [TileSection(rows: rows)])
  }

  /// The payments due within a week, the overdue ones first.
  public static func upcoming(_ payments: [UpcomingPayment]) -> TileExplanation {
    guard !payments.isEmpty else {
      return TileExplanation(tile: .upcoming, state: .empty(TilePhrase("why.upcoming.none")))
    }
    let rows = payments.map { payment in
      TileRow(
        TilePhrase(
          payment.kind == .debt ? "why.upcoming.debt" : "why.upcoming.scheduled",
          .day(payment.due), .text(payment.name)),
        .money(payment.amount, payment.currency), mark: payment.isOverdue ? .overdue : nil)
    }
    return TileExplanation(
      tile: .upcoming,
      sections: [
        TileSection(
          rows: rows,
          total: TileRow(TilePhrase("why.upcoming.count"), .count(payments.count)))
      ])
  }

  /// What each due date of this month still brings.
  public static func expectedIncome(
    _ planning: PlanningSnapshot, ledger: Ledger, today: DateOnly
  ) -> TileExplanation {
    let open = planning.expected.filter { !$0.isFulfilled }
    guard !open.isEmpty else {
      return TileExplanation(
        tile: .expectedIncome, state: .empty(TilePhrase("why.expected.none")))
    }
    let income = planning.income
    // The very function the figure is the total of, with the arguments the planning gave it.
    let items = IncomeEstimate.expectedThisMonth(
      ledger: ledger, statuses: planning.expected, today: today
    ).items
    let rows = items.map { item in
      TileRow(
        TilePhrase("why.expected.item", .day(item.due), .text(item.name)), money(item.rub),
        role: .plus)
    }
    let thisMonth = Set(items.map(\.incomeId))
    let later = open.filter { !thisMonth.contains($0.id) }.map { status in
      TileRow(
        TilePhrase("why.expected.later", .text(status.income.name)),
        .money(status.remaining, status.income.currency))
    }
    var sections = [
      TileSection(
        rows: rows,
        total: TileRow(TilePhrase("why.expected.total"), money(income.expectedRemaining)))
    ]
    if !later.isEmpty {
      sections.append(TileSection(title: TilePhrase("why.expected.laterTitle"), rows: later))
    }
    return TileExplanation(
      tile: .expectedIncome, sections: sections,
      notes: income.expectationsWithoutRate.isEmpty ? [] : [TilePhrase("why.noRate")])
  }

  /// Who owes what of the parts paid for others that have not come back.
  public static func owedToMe(_ ledger: Ledger, figure: AmountE4?) -> TileExplanation {
    let owed = OwedParts(ledger)
    guard !owed.parts.isEmpty else {
      return TileExplanation(tile: .owedToMe, state: .empty(TilePhrase("why.owed.none")))
    }
    let people = Dictionary(
      ledger.dataset.people.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    let rows = owed.byPerson.map { group in
      TileRow(
        group.personId.flatMap { people[$0] }.map { TilePhrase("why.name", .text($0)) }
          ?? TilePhrase("why.owed.nobody"),
        money(group.amount), role: .plus, note: TilePhrase("why.owed.parts", .count(group.count)))
    }
    let returned = AmountE4.sum(owed.parts.map(\.returnedRub))
    var notes: [TilePhrase] = []
    if returned.raw > 0 { notes.append(TilePhrase("why.owed.returned", .money(returned, .rub))) }
    // The tile's figure is the owed step's: counted from an older read, it can trail the lists
    // for a moment, and the breakdown says so rather than show another total under it.
    if let figure, figure != owed.total { notes.append(TilePhrase("why.refreshing")) }
    return TileExplanation(
      tile: .owedToMe,
      sections: [
        TileSection(rows: rows, total: TileRow(TilePhrase("why.owed.total"), money(owed.total)))
      ],
      notes: notes)
  }

  /// What is left of each open debt I owe, in rubles, and what they take a month.
  public static func iOwe(_ debts: DebtsOverview) -> TileExplanation {
    guard !debts.iOwe.isEmpty else {
      return TileExplanation(tile: .iOwe, state: .empty(TilePhrase("why.iOwe.none")))
    }
    let rows = debts.iOwe.map { line in
      let note: TilePhrase? =
        line.debt.currency == .rub
        ? nil : TilePhrase("why.iOwe.inCurrency", .money(line.balance, line.debt.currency))
      if let rub = line.balanceRub {
        return TileRow(
          TilePhrase("why.name", .text(line.debt.name)), money(rub), role: .plus, note: note)
      }
      return TileRow(
        TilePhrase("why.name", .text(line.debt.name)), .money(line.balance, line.debt.currency),
        mark: .warning, note: TilePhrase("why.iOwe.noRate"))
    }
    var details: [TileRow] = []
    if debts.monthlyPaymentsRub.raw > 0 {
      details.append(TileRow(TilePhrase("why.iOwe.monthly"), money(debts.monthlyPaymentsRub)))
    }
    return TileExplanation(
      tile: .iOwe,
      sections: [
        TileSection(
          rows: rows, total: TileRow(TilePhrase("why.iOwe.total"), money(debts.totalIOweRub))),
        TileSection(rows: details),
      ],
      notes: [TilePhrase("why.iOwe.notInOverview")])
  }

  /// The event on the tile: what it cost, by category, against its budget.
  public static func event(_ events: EventsPlanning) -> TileExplanation {
    guard let plan = events.active.first ?? events.upcoming.first else {
      return TileExplanation(tile: .event, state: .empty(TilePhrase("why.event.none")))
    }
    let rows = plan.byCategory.map { line in
      TileRow(
        TilePhrase(
          "why.name", .category(line.categoryId.map(ReportKey.category) ?? .uncategorized)),
        money(line.amount), role: .plus)
    }
    var details = [
      TileRow(
        TilePhrase(
          "why.event.days", .text(plan.event.name),
          .span(DayRange(plan.event.startDate, plan.event.endDate))))
    ]
    if let budget = plan.budget {
      details.append(TileRow(TilePhrase("why.event.budget"), money(budget)))
      if let remaining = plan.remaining {
        details.append(
          TileRow(
            TilePhrase(remaining.raw < 0 ? "why.event.over" : "why.event.left"),
            money(remaining.magnitude), mark: remaining.raw < 0 ? .warning : nil))
      }
    } else if let last = plan.lastTimeTotal {
      details.append(TileRow(TilePhrase("why.event.lastTime"), money(last)))
    }
    return TileExplanation(
      tile: .event,
      sections: [
        TileSection(rows: rows, total: TileRow(TilePhrase("why.event.spent"), money(plan.spent))),
        TileSection(rows: details),
      ])
  }

  // MARK: - Up to date

  /// The last count: its day, how long ago, and what each balance of it found.
  public static func lastCount(
    _ planning: PlanningSnapshot, ledger: Ledger, today: DateOnly
  ) -> TileExplanation {
    TileExplanation(
      tile: .lastCount, sections: countSections(planning, ledger: ledger, today: today))
  }

  static func countSections(
    _ planning: PlanningSnapshot, ledger: Ledger, today: DateOnly
  ) -> [TileSection] {
    guard let last = planning.lastReconciliation else {
      return [TileSection(rows: [TileRow(TilePhrase("why.count.none"))])]
    }
    let names = Dictionary(
      ledger.dataset.paymentMethods.map { ($0.id, $0.name) },
      uniquingKeysWith: { first, _ in first })
    var rows = [
      TileRow(
        TilePhrase("why.count.ago", .count(max(0, last.date.days(to: today)))), .day(last.date))
    ]
    if last.kind == .total {
      rows.append(TileRow(TilePhrase("why.count.oneTotal"), money(last.actualTotalRubE4)))
      if let difference = last.differenceE4 {
        rows.append(TileRow(TilePhrase("why.count.difference"), .change(difference, .rub)))
      }
    } else {
      for balance in ledger.dataset.planning.reconciledBalances
      where balance.reconciliationId == last.id {
        let name = names[balance.accountId] ?? "—"
        let note: TilePhrase =
          balance.isStartingPoint
          ? TilePhrase("why.count.start")
          : TilePhrase(
            "why.count.found", .money(balance.differenceE4 ?? .zero, balance.currency))
        rows.append(
          TileRow(
            TilePhrase("why.count.balance", .text(name), .text(balance.currency.code)),
            .money(balance.actualE4, balance.currency), note: note))
      }
    }
    return [TileSection(title: TilePhrase("why.count.title"), rows: rows)]
  }

  /// The newest operation the owner wrote, and when.
  public static func lastRecord(_ ledger: Ledger) -> TileExplanation {
    TileExplanation(tile: .lastRecord, sections: recordSections(ledger))
  }

  static func recordSections(_ ledger: Ledger) -> [TileSection] {
    guard let moment = OverviewSummary.lastRecordedAt(ledger.dataset) else {
      return [TileSection(rows: [TileRow(TilePhrase("why.record.none"))])]
    }
    var rows = [TileRow(TilePhrase("why.record.when"), .moment(moment))]
    if let entry = OverviewSummary.lastOperation(in: ledger.dataset) {
      let title = OverviewSummary.title(of: entry, tree: ledger.tree) ?? "—"
      rows.append(
        TileRow(
          TilePhrase("why.name", .text(title)),
          .money(entry.transaction.amountE4, entry.transaction.currency),
          mark: .kind(entry.transaction.kind)))
    } else {
      rows.append(TileRow(TilePhrase("why.record.transfer")))
    }
    return [TileSection(title: TilePhrase("why.record.title"), rows: rows)]
  }

  /// Both answers to «are the figures up to date».
  public static func lastCountAndRecord(
    _ planning: PlanningSnapshot, ledger: Ledger, today: DateOnly
  ) -> TileExplanation {
    TileExplanation(
      tile: .lastCountAndRecord,
      sections: countSections(planning, ledger: ledger, today: today) + recordSections(ledger))
  }

  /// What is worth a look, each line with why.
  public static func worthALook(_ inputs: TileInputs) -> TileExplanation {
    guard let report = inputs.anomalies else {
      return TileExplanation(tile: .worthALook, state: .waiting)
    }
    let archived = WorthALook.archivedMoney(
      accounts: inputs.ledger.dataset.paymentMethods,
      balances: inputs.planning.accounts.balances)
    let recent = WorthALook.recent(report, today: inputs.today)
    var rows: [TileRow] = noteRows(
      WorthALook.notes(planning: inputs.planning, ledger: inputs.ledger, today: inputs.today))
    for line in WorthALook.lines(
      report, today: inputs.today, free: inputs.planning.freeMoney, shown: recent.count,
      archived: archived)
    {
      switch line {
      case .goalsExceed(let goals, let money):
        rows.append(
          TileRow(
            TilePhrase("why.look.goals", .money(goals, .rub), .money(money, .rub)), mark: .warning)
        )
      case .archivedMoney(let holder):
        for leftover in holder.leftovers {
          rows.append(
            TileRow(
              TilePhrase("why.look.archived", .text(holder.account.name)),
              .money(leftover.shownAmount, leftover.key.currency), mark: .warning))
        }
      case .anomaly(let anomaly):
        rows.append(
          TileRow(
            TilePhrase("why.look.anomaly", .anomalyRule(anomaly.rule), .text(anomaly.subject)),
            .day(anomaly.day),
            note: TilePhrase(
              "why.look.reference", .money(anomaly.amount, .rub), .money(anomaly.reference, .rub))
          ))
      case .more, .nothingUnusual:
        break
      }
    }
    guard !rows.isEmpty else {
      return TileExplanation(tile: .worthALook, state: .empty(TilePhrase("why.look.none")))
    }
    return TileExplanation(
      tile: .worthALook,
      sections: [
        TileSection(
          rows: rows, total: TileRow(TilePhrase("why.look.count"), .count(recent.count)))
      ],
      notes: recent.count > inputs.anomaliesShown
        ? [TilePhrase("why.look.more", .count(recent.count - inputs.anomaliesShown))] : [])
  }

  /// The lines of 1.9 of «Стоит посмотреть», each with its figure.
  static func noteRows(_ notes: [WorthALookNote]) -> [TileRow] {
    notes.compactMap { note -> TileRow? in
      switch note {
      case .debt:
        return TileRow(TilePhrase("why.look.debtReminder"), mark: .warning)
      case .npdDue(let month):
        return TileRow(
          TilePhrase("why.look.npdDue", .day(month.month.firstDay), .day(month.due)),
          .money(month.toPayE4, .rub), mark: month.state == .overdue ? .overdue : nil)
      case .salaryLate(let half):
        return TileRow(TilePhrase("why.look.salaryLate"), .day(half.nextIncomeDay), mark: .warning)
      case .allocate(_, let left, let currency):
        return TileRow(TilePhrase("why.look.allocate"), .money(left, currency))
      case .monthRest(let offer):
        return TileRow(
          TilePhrase("why.look.monthRest", .day(offer.month.firstDay)), .money(offer.amountE4, .rub)
        )
      case .npdLimit(let year):
        return TileRow(
          TilePhrase(year.exceeded ? "why.look.npdLimitExceeded" : "why.look.npdLimit"),
          .money(year.leftRub, .rub), mark: .warning, share: year.shareBp)
      case .burnout(let signal):
        return TileRow(
          TilePhrase("why.look.burnout", .count(signal.lastWeekCount), .count(signal.usualCount)))
      case .lowCopySpace, .databaseProblems:
        // About the disk, not about the money: the tile counts what happened in the book.
        return nil
      }
    }
  }

  /// The money now, what of it is not free, and what the plans to the end of the month take.
  public static func freeMoney(_ free: FreeMoney) -> TileExplanation {
    guard let main = free.main, let moneyNow = free.moneyNow, let grey = free.grey else {
      return TileExplanation(
        tile: .freeMoney, state: .empty(TilePhrase("why.free.noReconciliation")))
    }
    var nowRows = [TileRow(TilePhrase("why.free.moneyNow"), money(moneyNow), role: .plus)]
    if free.goalSavings.raw != 0 {
      nowRows.append(TileRow(TilePhrase("why.free.goals"), money(free.goalSavings), role: .minus))
    }
    if free.cushion.raw != 0 {
      nowRows.append(TileRow(TilePhrase("why.free.cushion"), money(free.cushion), role: .minus))
    }
    var planRows = [TileRow(TilePhrase("why.free.main"), money(main), role: .plus)]
    for line in free.lines {
      planRows.append(
        TileRow(
          TilePhrase(freeKey(line.key)), money(line.amount),
          role: line.sign == .plus ? .plus : .minus))
    }
    var notes: [TilePhrase] = []
    if !free.unanchored.isEmpty {
      notes.append(TilePhrase("why.free.unanchored", .count(free.unanchored.count)))
    }
    if !free.mainWithoutRate.isEmpty || !free.planWithoutRate.isEmpty {
      notes.append(TilePhrase("why.noRate"))
    }
    if free.overdue.raw > 0 {
      notes.append(TilePhrase("why.free.overdue", .money(free.overdue, .rub)))
    }
    if let expected = free.info.first, expected.amount.raw > 0 {
      notes.append(TilePhrase("why.free.expected", .money(expected.amount, .rub)))
    }
    return TileExplanation(
      tile: .freeMoney,
      sections: [
        TileSection(rows: nowRows, total: TileRow(TilePhrase("why.free.main"), money(main))),
        TileSection(
          title: TilePhrase("why.free.untilTitle", .day(free.until)), rows: planRows,
          total: TileRow(
            TilePhrase("why.free.grey"), money(grey), mark: grey.raw < 0 ? .warning : nil)),
        TileSection(rows: [
          TileRow(
            TilePhrase("why.free.perDay", .count(free.days)), money(free.dailyGuide))
        ]),
      ],
      notes: notes)
  }

  static func freeKey(_ key: String) -> String {
    switch key {
    case FreeMoney.Key.scheduled: "why.free.scheduled"
    case FreeMoney.Key.debts: "why.free.debts"
    case FreeMoney.Key.goalPlans: "why.free.goalPlans"
    case FreeMoney.Key.events: "why.free.events"
    case FreeMoney.Key.npdTax: "why.free.npdTax"
    case FreeMoney.Key.creditCards: "why.free.creditCards"
    default: "why.free.other"
    }
  }

  // MARK: - The other tiles

  /// The rate at the start of the period, its change, and the rate now.
  public static func currencyChart(_ rates: TileRateSeries?) -> TileExplanation {
    guard let rates else { return TileExplanation(tile: .currencyChart, state: .waiting) }
    guard let first = rates.first, let last = rates.last else {
      return TileExplanation(tile: .currencyChart, state: .empty(TilePhrase("why.rates.none")))
    }
    let pair = TileArgument.text("\(rates.base.code)/\(rates.quote.code)")
    return TileExplanation(
      tile: .currencyChart,
      sections: [
        TileSection(
          title: TilePhrase("why.rates.title.\(rates.period.rawValue)", pair),
          rows: [
            TileRow(
              TilePhrase("why.rates.first", .day(first.day)), .rate(first.rateE4, rates.quote),
              role: .plus),
            TileRow(
              TilePhrase("why.rates.change", .percent(rates.changeBp)),
              .rateChange(rates.changeE4, rates.quote), role: .plus),
          ],
          total: TileRow(
            TilePhrase("why.rates.last", .day(last.day)), .rate(last.rateE4, rates.quote)))
      ])
  }

  /// The days of the week, what each cost, and what the usual day is.
  public static func spendingCalendar(_ calendar: SpendingCalendar?) -> TileExplanation {
    guard let calendar else { return TileExplanation(tile: .spendingCalendar, state: .waiting) }
    let currency = calendar.currency
    let rows = calendar.days.map { day -> TileRow in
      if let spent = day.spent {
        let mark: TileMark? = day.level.flatMap { $0 == .usual ? nil : .spendingLevel($0) }
        return TileRow(
          TilePhrase("why.calendar.day", .day(day.day)), .money(spent, currency), mark: mark)
      }
      return TileRow(
        TilePhrase("why.calendar.day", .day(day.day)), day.plannedOut.map { .money($0, currency) },
        note: day.plannedOut == nil
          ? TilePhrase("why.calendar.ahead") : TilePhrase("why.calendar.planned"))
    }
    var details: [TileRow] = []
    if let usual = calendar.usual {
      details.append(TileRow(TilePhrase("why.calendar.usual"), .money(usual, currency)))
    }
    return TileExplanation(
      tile: .spendingCalendar,
      sections: [
        TileSection(
          rows: rows,
          total: TileRow(TilePhrase("why.calendar.total"), .money(calendar.spent, currency))),
        TileSection(rows: details),
      ],
      notes: [TilePhrase("why.calendar.rounding")]
        + (calendar.lowData ? [TilePhrase("why.calendar.lowData")] : []))
  }

  /// What there is, by kind, less what is owed.
  public static func capital(_ capital: CapitalSnapshot) -> TileExplanation {
    guard !(capital.breakdown.have.isEmpty && capital.breakdown.owe.isEmpty) else {
      return TileExplanation(tile: .capital, state: .empty(TilePhrase("why.capital.none")))
    }
    let now = capital.now
    var rows: [TileRow] = []
    func add(_ key: String, _ amount: AmountE4, _ role: TileRow.Role) {
      guard !amount.isZero || key == "why.capital.accounts" else { return }
      rows.append(TileRow(TilePhrase(key), money(amount), role: role))
    }
    add("why.capital.accounts", now.accountsRub, .plus)
    add("why.capital.deposits", now.depositsRub, .plus)
    add("why.capital.outOfSummary", now.outOfSummaryRub, .plus)
    add("why.capital.assets", now.assetsRub, .plus)
    add("why.capital.owedToMe", now.owedToMeRub, .plus)
    add("why.capital.iOwe", now.iOweRub, .minus)
    var details: [TileRow] = []
    if let change = capital.changeThisMonth {
      details.append(TileRow(TilePhrase("why.capital.change"), .change(change, .rub)))
    }
    var notes: [TilePhrase] = []
    let missing = now.unanchored.count + now.withoutRate.count + now.unvalued.count
    if missing > 0 { notes.append(TilePhrase("why.capital.missing", .count(missing))) }
    return TileExplanation(
      tile: .capital,
      sections: [
        TileSection(rows: rows, total: TileRow(TilePhrase("why.capital.total"), money(now.netRub))),
        TileSection(rows: details),
      ],
      notes: notes)
  }

  /// The money of the cushion over the obligatory spending of a month.
  public static func cushion(_ status: CushionStatus) -> TileExplanation {
    guard status.state != .noAccounts else {
      return TileExplanation(tile: .cushion, state: .empty(TilePhrase("why.cushion.noAccounts")))
    }
    var rows = [TileRow(TilePhrase("why.cushion.money"), money(status.moneyRub))]
    if let monthly = status.obligatory.monthlyRub {
      rows.append(TileRow(TilePhrase("why.cushion.monthly"), money(monthly)))
    }
    if let median = status.obligatory.medianRub, median != status.obligatory.monthlyRub {
      rows.append(
        TileRow(TilePhrase("why.cushion.median"), money(median)))
    }
    if !status.obligatory.committedRub.isZero {
      rows.append(
        TileRow(TilePhrase("why.cushion.committed"), money(status.obligatory.committedRub)))
    }
    var sections = [
      TileSection(
        rows: rows,
        total: status.months.map { TileRow(TilePhrase("why.cushion.months"), .months($0)) })
    ]
    if let goal = status.goal {
      var goalRows = [
        TileRow(TilePhrase("why.cushion.target", .count(goal.targetMonths)), money(goal.targetRub)),
        TileRow(TilePhrase("why.cushion.missing"), money(goal.missingRub)),
      ]
      if let perMonth = goal.perMonthRub ?? (goal.reached ? nil : goal.defaultPerMonthRub) {
        goalRows.append(TileRow(TilePhrase("why.cushion.perMonth"), money(perMonth)))
      }
      sections.append(TileSection(title: TilePhrase("why.cushion.goalTitle"), rows: goalRows))
    }
    var notes: [TilePhrase] = []
    if status.state == .notEnoughData { notes.append(TilePhrase("why.cushion.notEnoughData")) }
    if !status.unanchored.isEmpty {
      notes.append(TilePhrase("why.cushion.unanchored", .count(status.unanchored.count)))
    }
    return TileExplanation(tile: .cushion, sections: sections, notes: notes)
  }

  /// What hangs in instalment plans and purchases on credit, and the payments coming first.
  public static func installments(_ summary: InstalmentsSummary) -> TileExplanation {
    guard summary.count > 0 else {
      return TileExplanation(tile: .installments, state: .empty(TilePhrase("why.instalments.none")))
    }
    let rows = summary.next.map { payment in
      TileRow(
        TilePhrase("why.instalments.payment", .day(payment.due)),
        .money(payment.amountE4, payment.currency))
    }
    var notes: [TilePhrase] = []
    if !summary.withoutRate.isEmpty { notes.append(TilePhrase("why.noRate")) }
    return TileExplanation(
      tile: .installments,
      sections: [
        TileSection(
          rows: [TileRow(TilePhrase("why.instalments.count"), .count(summary.count))],
          total: TileRow(TilePhrase("why.instalments.total"), money(summary.totalRub))),
        TileSection(title: TilePhrase("why.instalments.nextTitle"), rows: rows),
      ],
      notes: notes)
  }

  /// The tax to pay: the income of its month less what the deduction took, and the year
  /// against its limit.
  public static func selfEmployment(_ npd: NPDState?, today: DateOnly) -> TileExplanation {
    guard let npd, let block = SelfEmploymentBlock.build(npd: npd, today: today) else {
      return TileExplanation(
        tile: .selfEmployment, state: .empty(TilePhrase("why.selfEmployed.off")))
    }
    var sections: [TileSection] = []
    if let month = npd.nextDue ?? npd.months.first(where: { $0.month == today.monthKey }) {
      var rows = [
        TileRow(
          TilePhrase("why.selfEmployed.taxBefore"), money(month.taxBeforeDeductionE4), role: .plus)
      ]
      if !month.deductionUsedE4.isZero {
        rows.append(
          TileRow(
            TilePhrase("why.selfEmployed.deduction"), money(month.deductionUsedE4), role: .minus))
      }
      if !month.carriedInE4.isZero {
        rows.append(
          TileRow(TilePhrase("why.selfEmployed.carried"), money(month.carriedInE4), role: .plus))
      }
      // The tax of another rate, kept apart from the minimum: what rounds the lines to the sum.
      let rest =
        month.toPayE4 - month.taxBeforeDeductionE4 + month.deductionUsedE4
        - month.carriedInE4
      if !rest.isZero {
        rows.append(
          TileRow(
            TilePhrase("why.selfEmployed.rounding"), money(rest.magnitude),
            role: rest.isNegative ? .minus : .plus))
      }
      rows.append(
        TileRow(TilePhrase("why.selfEmployed.income"), money(month.incomeRub)))
      sections.append(
        TileSection(
          title: TilePhrase("why.selfEmployed.monthTitle", .day(month.month.firstDay)),
          rows: rows,
          total: TileRow(
            TilePhrase("why.selfEmployed.toPay", .day(month.due)), money(month.toPayE4),
            mark: month.state == .overdue ? .overdue : nil)))
    }
    var year = [
      TileRow(TilePhrase("why.selfEmployed.yearIncome"), money(npd.year.incomeRub)),
      TileRow(TilePhrase("why.selfEmployed.yearLimit"), money(npd.year.limitRub)),
    ]
    year.append(
      TileRow(
        TilePhrase("why.selfEmployed.yearLeft"), money(block.yearLeftRub),
        mark: npd.year.exceeded ? .warning : nil, share: npd.year.shareBp))
    sections.append(TileSection(title: TilePhrase("why.selfEmployed.yearTitle"), rows: year))
    var notes = [TilePhrase("why.selfEmployed.rates")]
    if let left = npd.deductionLeftE4 {
      notes.append(TilePhrase("why.selfEmployed.deductionLeft", .money(left, .rub)))
    } else {
      notes.append(TilePhrase("why.selfEmployed.deductionUnknown"))
    }
    return TileExplanation(tile: .selfEmployment, sections: sections, notes: notes)
  }

  // MARK: - Pieces

  static func money(_ amount: AmountE4) -> TileValue { .money(amount, .rub) }
}

extension Shares {
  /// The share of the money spent in `nodes` among the positive lines of `all`.
  static func basisPoints(of nodes: [BreakdownNode], among all: [BreakdownNode]) -> Int? {
    let positive = all.filter { $0.amount.raw > 0 }
    let shares = basisPoints(positive.map(\.amount))
    let keys = Set(nodes.map(\.key))
    var sum = 0
    var any = false
    for (index, node) in positive.enumerated() where keys.contains(node.key) {
      if let share = shares[index] {
        sum += share
        any = true
      }
    }
    return any ? sum : nil
  }
}
