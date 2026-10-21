import AppCore
import Foundation

/// Builds the model of a section from the ledger — pure, off the main thread, through
/// `ComputeStore.compute(_:)`. Every figure comes from the slices of `CoreAnalytics` over the
/// same ledger as Overview and Reports, so the three windows cannot disagree; here they are
/// only rounded to whole rubles, laid out for the charts and checked against what a chart
/// needs to be drawn at all: a line needs two points, bars need something that is not zero.
enum AnalyticsBuilder {
  /// Bars of a top: places by amount and by purchases.
  static let topCount = 10
  /// Rows of the places table before «ещё N».
  static let tableCount = 25
  /// Lines of «for whom» month by month; more values leave four and «others».
  static let seriesLimit = 5

  static func model(_ request: AnalyticsRequest, ledger: Ledger) -> AnalyticsModel {
    let period = request.period
    let today = request.today
    let content: AnalyticsModel.Content
    switch request.section {
    case .overview:
      content = .overview(overview(ledger: ledger, period: period, today: today))
    case .quality:
      content = .quality(quality(ledger: ledger, period: period, today: today))
    case .others:
      content = .others(others(ledger: ledger, period: period))
    case .forWhom:
      content = .forWhom(forWhom(ledger: ledger, period: period, today: today))
    case .places:
      content = .places(places(ledger: ledger, period: period))
    case .events:
      content = .events(events(ledger: ledger, period: period))
    case .paymentMethods:
      content = .paymentMethods(paymentMethods(ledger: ledger, period: period))
    case .forecast:
      content = .forecast(forecast(ledger: ledger, today: today, inputs: request.forecast))
    case .anomalies:
      content = .anomalies(anomalies(request.anomalies, period: period))
    case .modelQuality:
      content = .modelQuality(modelQuality(ledger: ledger, today: today))
    }
    return AnalyticsModel(
      request: request, header: AnalyticsHeader(period: period, today: today),
      names: AnalyticsNames(dataset: ledger.dataset), content: content)
  }

  // MARK: - Model quality

  /// Both halves are measured here and not in the pipeline: this is a page the owner opens
  /// now and then, not a number that has to be fresh after every write.
  static func modelQuality(ledger: Ledger, today: DateOnly) -> ModelQualitySectionModel {
    let quality = ModelQuality.build(ledger: ledger, today: today)
    return ModelQualitySectionModel(
      categories: quality.categories.metrics == nil
        ? .notEnoughData(.modelNotReady) : .ready(quality.categories),
      forecast: quality.forecast.isEmpty ? .notEnoughData(.noBacktest) : .ready(quality.forecast))
  }

  // MARK: - Anomalies

  /// The section shows what step 6 found inside the period on screen. The rules themselves
  /// run once over the whole history — a threshold made of one month of a category would
  /// move with the period and say something different every time it was looked at.
  static func anomalies(_ report: AnomalyReport?, period: Period) -> AnomaliesSectionModel {
    guard let report else {
      return AnomaliesSectionModel(found: .notEnoughData(.notStarted), hidden: [])
    }
    let found = report.inside(period)
    return AnomaliesSectionModel(
      found: found.isEmpty ? .notEnoughData(.noAnomalies) : .ready(found),
      hidden: report.hidden.filter { period.range.contains($0.day) })
  }

  // MARK: - Overview

  static func overview(ledger: Ledger, period: Period, today: DateOnly) -> OverviewSectionModel {
    let categories = CategoryBreakdown(ledger: ledger, period: period, kind: .expense)
    let steps = SeriesSteps(
      day: timeSeries(
        TimeSeries(ledger: ledger, period: period, step: .day, today: today), period: period),
      week: timeSeries(
        TimeSeries(ledger: ledger, period: period, step: .week, today: today), period: period),
      month: timeSeries(
        TimeSeries(ledger: ledger, period: period, step: .month, today: today), period: period),
      preferred: period.months.count > 1 ? .month : .day)
    let months = IncomeVsExpense(ledger: ledger, period: period).months.map {
      IncomeExpenseMonth(
        month: $0.month, income: $0.income.wholeRubles, expenses: $0.expenses.wholeRubles)
    }
    // «Операций пока нет» is said of an empty history only; a period of a history that has
    // neither income nor spending says that of the period.
    let noIncomeOrSpending: AnalyticsReason =
      ledger.firstDay == nil ? .noHistory : .noIncomeOrSpending
    return OverviewSectionModel(
      categories: ranked(categories.nodes, else: .noSpending),
      series: steps.month.buckets.contains { $0.value != 0 }
        || steps.day.buckets.contains { $0.value != 0 }
        ? .ready(steps) : .notEnoughData(.noSpending),
      incomeVsExpenses: months.contains { $0.income != 0 || $0.expenses != 0 }
        ? .ready(months) : .notEnoughData(noIncomeOrSpending),
      incomeSources: ranked(IncomeSources(ledger: ledger, period: period).sources, else: .noIncome),
      comparison: comparison(
        PeriodComparison(ledger: ledger, period: period, today: today), period: period),
      weekdays: weekdays(WeekdayProfile(ledger: ledger, period: period, today: today)))
  }

  /// The buckets of a series with the days each covers inside the period, in whole rubles.
  static func timeSeries(_ series: TimeSeries, period: Period) -> TimeSeriesModel {
    TimeSeriesModel(
      step: series.step,
      buckets: series.points.map { point in
        let end: DateOnly
        switch series.step {
        case .day: end = point.start
        case .week: end = point.start.adding(days: 6)
        case .month: end = point.start.monthKey.lastDay
        }
        return TimeBucket(
          start: max(point.start, period.start), end: min(end, period.end),
          value: point.amount.wholeRubles)
      },
      average: series.average?.wholeRubles)
  }

  /// A line needs two points: a period of one day so far has nothing to draw, and two
  /// flat zeros say nothing either. A period that has not begun says so — the toolbar never
  /// offers one, but a period is not «one day so far» when it has none.
  static func comparison(
    _ comparison: PeriodComparison, period: Period
  ) -> ChartBlock<ComparisonModel> {
    guard !comparison.current.isEmpty else { return .notEnoughData(.notStarted) }
    guard comparison.current.dayCount >= 2 else { return .notEnoughData(.oneDay) }
    let model = ComparisonModel(
      period: period, current: comparison.current, previous: comparison.previous,
      isComplete: comparison.isComplete,
      currentPoints: comparison.currentCumulative.map(\.wholeRubles),
      previousPoints: comparison.previousCumulative.map(\.wholeRubles),
      expenses: comparison.expenses, income: comparison.income)
    guard
      model.currentPoints.contains(where: { $0 != 0 })
        || model.previousPoints.contains(where: { $0 != 0 })
    else { return .notEnoughData(.nothingToCompare) }
    return .ready(model)
  }

  static func weekdays(_ profile: WeekdayProfile) -> ChartBlock<WeekdayModel> {
    let days = profile.days.map {
      WeekdayValue(
        weekday: $0.weekday, average: $0.average?.wholeRubles, occurrences: $0.occurrences)
    }
    guard days.contains(where: { ($0.average ?? 0) != 0 }) else {
      return .notEnoughData(.noSpending)
    }
    return .ready(WeekdayModel(interval: profile.interval, days: days))
  }

  // MARK: - Good vs Bad

  static func quality(ledger: Ledger, period: Period, today: DateOnly) -> QualitySectionModel {
    let report = QualityReport(ledger: ledger, period: period, today: today)
    let columns = report.months.map { shareColumn($0.month, $0.qualities) }
    let split = GoalsSplit(
      goals: report.goals.wholeRubles, rest: report.rest.wholeRubles,
      goalsShare: report.goalsShare, restShare: report.restShare)
    return QualitySectionModel(
      shares: columns.contains { !$0.segments.isEmpty }
        ? .ready(columns) : .notEnoughData(.noSpending),
      badByCategory: ranked(report.badByCategory, else: .noBadSpending),
      streaks: ledger.firstDay.map { $0 <= today } == true
        ? .ready(Streaks(current: report.currentStreak, best: report.bestStreak))
        : .notEnoughData(.noHistory),
      goals: split.goalsShare == nil && split.restShare == nil
        ? .notEnoughData(.noSpending) : .ready(split))
  }

  /// Good → neutral → bad stacked from the bottom, each as tall as its share; a quality
  /// without a share — nothing, or refunds that outweighed it — gets no segment.
  static func shareColumn(_ month: MonthKey, _ qualities: [BreakdownNode]) -> ShareColumn {
    var start: Int64 = 0
    var segments: [ShareSegment] = []
    for quality in Quality.allCases {
      guard let node = qualities.first(where: { $0.key == .quality(quality) }),
        let share = node.share, share > 0
      else { continue }
      segments.append(
        ShareSegment(
          quality: quality, basisPoints: share, start: start, end: start + Int64(share),
          value: node.amount.wholeRubles))
      start += Int64(share)
    }
    return ShareColumn(month: month, segments: segments)
  }

  // MARK: - Paid for others

  static func others(ledger: Ledger, period: Period) -> OthersSectionModel {
    let report = OthersReport(ledger: ledger, period: period)
    let totals = report.totals
    let figures = OthersFigures(
      paid: totals.paid.wholeRubles, returned: totals.returned.wholeRubles,
      writtenOff: totals.writtenOff.wholeRubles, waiting: totals.waiting.wholeRubles,
      shortfall: totals.shortfall.wholeRubles, surplus: report.surplus.wholeRubles)
    let people = report.byPerson.map { personStack(personId: $0.personId, totals: $0.totals) }
      .filter { !$0.segments.isEmpty }
    let subscriptions = report.bySubscription
      .map {
        SubscriptionStack(
          paymentId: $0.paymentId, paid: $0.totals.paid.wholeRubles, charges: $0.charges,
          segments: segments(of: $0.totals))
      }
      .filter { !$0.segments.isEmpty }
    return OthersSectionModel(
      totals: totals.paid.isZero && report.surplus.isZero
        ? .notEnoughData(.nothingPaidForOthers) : .ready(figures),
      bySubscription: subscriptions.isEmpty
        ? .notEnoughData(.noSubscriptionsForOthers) : .ready(subscriptions),
      byPerson: people.isEmpty ? .notEnoughData(.nothingPaidForOthers) : .ready(people))
  }

  /// A person's bar, from the same segments a subscription's bar is made of.
  static func personStack(personId: UUID?, totals: OthersReport.Totals) -> PersonStack {
    PersonStack(
      personId: personId, paid: totals.paid.wholeRubles, segments: segments(of: totals))
  }

  /// returned → shortfall → written off → waiting, each segment starting where the one before
  /// ended. A figure that is not positive keeps no length. One function, so the two bars of
  /// the section can never be drawn to different rules.
  static func segments(of totals: OthersReport.Totals) -> [StatusSegment] {
    let values: [(OthersSegment, AmountE4)] = [
      (.returned, totals.returned), (.shortfall, totals.shortfall),
      (.writtenOff, totals.writtenOff), (.waiting, totals.waiting),
    ]
    var start: Int64 = 0
    var segments: [StatusSegment] = []
    for (kind, amount) in values {
      let value = amount.wholeRubles
      guard value > 0 else { continue }
      segments.append(StatusSegment(kind: kind, value: value, start: start, end: start + value))
      start += value
    }
    return segments
  }

  // MARK: - For whom

  /// Month by month, the lines stop at the month of today: the months after it have not
  /// happened, and a line that falls to zero in October would say they cost nothing — the
  /// core counts such days nowhere either (`WeekdayProfile`, `TimeSeries.average`).
  static func forWhom(ledger: Ledger, period: Period, today: DateOnly) -> ForWhomSectionModel {
    let report = ForWhomReport(ledger: ledger, period: period)
    let begun = report.months.filter { $0.month <= today.monthKey }
    let months = begun.map(\.month)
    let series = dynamicsSeries(
      ForWhom.allCases.map { value in
        (value, begun.map { $0.amounts[value] ?? .zero })
      })
    let dynamics: ChartBlock<DynamicsModel>
    if months.isEmpty {
      dynamics = .notEnoughData(.notStarted)
    } else if months.count < 2 {
      // A year or twelve months with one month so far are not a month: «choose a year»
      // would not help.
      dynamics = .notEnoughData(period.months.count > 1 ? .oneMonthSoFar : .oneMonth)
    } else if series.isEmpty {
      dynamics = .notEnoughData(.noSpending)
    } else {
      dynamics = .ready(DynamicsModel(months: months, series: series))
    }
    return ForWhomSectionModel(
      values: ranked(report.values, else: .noSpending),
      // Spending that names nobody is the owner's own and has no line here; a period with
      // spending and nobody named says that, not «no spending».
      people: ranked(
        report.people, else: report.values.contains { $0.amount.raw > 0 } ? .noPeople : .noSpending),
      dynamics: dynamics)
  }

  /// The lines of «for whom» month by month: every value with money, largest total first
  /// (equal totals in the order of the values), each with the next style of
  /// `ChartSeriesStyle.ordered`. More than `limit` leave the `limit − 1` largest and put the
  /// rest together as «others», which takes the next free style — a form of its own, never
  /// the dash of the second line.
  static func dynamicsSeries(
    _ candidates: [(ForWhom, [AmountE4])], limit: Int = seriesLimit
  ) -> [DynamicsSeries] {
    let order = Dictionary(
      uniqueKeysWithValues: ForWhom.allCases.enumerated().map { ($1, $0) })
    let withMoney =
      candidates
      .map { (value: $0.0, amounts: $0.1, total: AmountE4.sum($0.1)) }
      .filter { !$0.total.isZero }
      .sorted { left, right in
        left.total != right.total
          ? left.total > right.total : (order[left.value] ?? 0) < (order[right.value] ?? 0)
      }
    var lines: [(key: DynamicsKey, amounts: [AmountE4])] = []
    if withMoney.count > limit {
      lines = withMoney.prefix(limit - 1).map { (.value($0.value), $0.amounts) }
      let rest = withMoney.dropFirst(limit - 1)
      let length = rest.map(\.amounts.count).max() ?? 0
      let merged = (0..<length).map { index in
        AmountE4.sum(rest.map { index < $0.amounts.count ? $0.amounts[index] : .zero })
      }
      lines.append((.others, merged))
    } else {
      lines = withMoney.map { (.value($0.value), $0.amounts) }
    }
    return lines.enumerated().map { index, line in
      DynamicsSeries(
        key: line.key, styleIndex: index, points: line.amounts.map(\.wholeRubles),
        total: AmountE4.sum(line.amounts).wholeRubles)
    }
  }

  // MARK: - Places

  static func places(ledger: Ledger, period: Period) -> PlacesSectionModel {
    let report = PlacesReport(ledger: ledger, period: period)
    let rows = report.places.map(placeRow)
    let byAmount = rows.filter { $0.spent > 0 }.prefix(topCount).map {
      RankedValue(key: .place($0.placeId), value: $0.spent)
    }
    let byPurchases = report.byPurchases.filter { $0.purchases > 0 }.prefix(topCount).map {
      RankedValue(key: .place($0.placeId), value: Int64($0.purchases))
    }
    let newPlaces = rows.filter(\.isNew)
    return PlacesSectionModel(
      byAmount: byAmount.isEmpty ? .notEnoughData(.noPlaces) : .ready(Array(byAmount)),
      byPurchases: byPurchases.isEmpty ? .notEnoughData(.noPlaces) : .ready(Array(byPurchases)),
      table: rows.isEmpty
        ? .notEnoughData(.noPlaces)
        : .ready(
          PlacesTable(
            rows: Array(rows.prefix(tableCount)), hidden: max(0, rows.count - tableCount))),
      newPlaces: newPlaces.isEmpty ? .notEnoughData(.noNewPlaces) : .ready(newPlaces))
  }

  static func placeRow(_ place: PlacesReport.Place) -> PlaceRow {
    PlaceRow(
      placeId: place.placeId, spent: place.mySpending.wholeRubles, purchases: place.purchases,
      averageReceipt: place.averageReceipt?.wholeRubles, firstDay: place.firstDay,
      isNew: place.isNew)
  }

  // MARK: - Events

  static func events(ledger: Ledger, period: Period) -> EventsSectionModel {
    let report = EventsReport(ledger: ledger, period: period)
    let events = Dictionary(
      ledger.dataset.events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let items = report.events.compactMap { item -> EventItem? in
      guard let event = events[item.eventId] else { return nil }
      return EventItem(
        eventId: item.eventId, start: event.startDate, end: event.endDate,
        total: item.total.wholeRubles, budget: item.budget?.wholeRubles,
        left: item.budgetLeft?.wholeRubles, lastYearTotal: item.lastYearTotal?.wholeRubles,
        lastYear: item.lastYearEventId.flatMap { events[$0]?.startDate.year },
        byCategory: item.byCategory.map(RankedValue.init))
    }
    return EventsSectionModel(events: items.isEmpty ? .notEnoughData(.noEvents) : .ready(items))
  }

  // MARK: - Payment methods

  static func paymentMethods(ledger: Ledger, period: Period) -> PaymentMethodsSectionModel {
    let report = PaymentMethodsReport(ledger: ledger, period: period)
    let cashback = CashbackReport(ledger: ledger, period: period)
    let lines = Dictionary(grouping: cashback.byHolder(), by: \.holder.accountId)
    let rows = report.methods.map { method in
      let accountId: UUID? =
        if case .paymentMethod(let id) = method.key { id } else { nil }
      let own = lines[accountId] ?? []
      return MethodRow(
        key: method.key, mySpending: method.mySpending.wholeRubles,
        turnover: method.turnover.wholeRubles, cashback: method.cashback.wholeRubles,
        cashbackShare: method.cashbackShare,
        expectedCashback: method.expectedCashback.wholeRubles,
        cards: own.count > 1
          ? own.map {
            CardMethodRow(
              cardId: $0.holder.cardId, mySpending: $0.mySpending.wholeRubles,
              turnover: $0.turnover.wholeRubles, expected: $0.expectedRub.wholeRubles,
              received: $0.receivedRub.wholeRubles)
          } : [])
    }
    let bars = rows.filter { $0.mySpending > 0 }.map {
      RankedValue(key: $0.key, value: $0.mySpending)
    }
    return PaymentMethodsSectionModel(
      spending: bars.isEmpty ? .notEnoughData(.noSpending) : .ready(bars),
      table: rows.isEmpty ? .notEnoughData(.noPayments) : .ready(rows),
      cashbackMonths: cashbackMonths(cashback, cards: ledger.dataset.cards))
  }

  /// «Кэшбэк по месяцам» of every line of `report`: all accounts, each account with a line,
  /// each card with a line. Nothing to show while there are no rules and nothing came.
  static func cashbackMonths(
    _ report: CashbackReport, cards: [PaymentCard]
  ) -> ChartBlock<CashbackMonthsModel> {
    let received = report.cells.contains { !$0.receivedRub.isZero }
    guard report.hasRules || received else { return .notEnoughData(.noCashbackRules) }
    func months(accountId: UUID? = nil, cardId: UUID? = nil) -> [CashbackMonthsModel.Month] {
      report.byMonth(accountId: accountId, cardId: cardId).map {
        CashbackMonthsModel.Month(
          month: $0.month, expected: $0.expectedRub.wholeRubles,
          received: $0.receivedRub.wholeRubles,
          difference: ($0.receivedRub - $0.expectedRub).wholeRubles)
      }
    }
    // Every month over all accounts, so every choice lists the same months.
    let all = months()
    func filled(_ rows: [CashbackMonthsModel.Month]) -> [CashbackMonthsModel.Month] {
      let byMonth = Dictionary(rows.map { ($0.month, $0) }, uniquingKeysWith: { a, _ in a })
      return all.map {
        byMonth[$0.month]
          ?? CashbackMonthsModel.Month(month: $0.month, expected: 0, received: 0, difference: 0)
      }
    }
    var choices: [CashbackMonthsModel.Choice] = [.all]
    var result: [CashbackMonthsModel.Choice: [CashbackMonthsModel.Month]] = [.all: all]
    var seenAccounts: Set<UUID> = []
    for line in report.byHolder() {
      guard let accountId = line.holder.accountId else { continue }
      if seenAccounts.insert(accountId).inserted {
        choices.append(.account(accountId))
        result[.account(accountId)] = filled(months(accountId: accountId))
      }
      if let cardId = line.holder.cardId {
        choices.append(.card(cardId))
        result[.card(cardId)] = filled(months(cardId: cardId))
      }
    }
    let offered = Set(choices.compactMap { if case .card(let id) = $0 { id } else { nil } })
    return .ready(
      CashbackMonthsModel(
        choices: choices, months: result,
        cardAccounts: Dictionary(
          cards.filter { offered.contains($0.id) }.map { ($0.id, $0.accountId) },
          uniquingKeysWith: { a, _ in a })))
  }

  // MARK: - Forecast

  /// The current month, whatever the period of the toolbar: what the Overview card says,
  /// drawn day by day. Only a month with nothing spent and nothing expected has nothing to
  /// draw; a short history is drawn with its ±50 % and the mark «мало данных».
  static func forecast(
    ledger: Ledger, today: DateOnly, inputs: ForecastInputs?
  ) -> ForecastSectionModel {
    let month = today.monthKey
    guard let inputs else {
      return ForecastSectionModel(month: month, chart: .notEnoughData(.noSpendingThisMonth))
    }
    let plot = forecastPlot(
      ledger: ledger, today: today, planned: inputs.planned, remainder: inputs.remainder)
    return ForecastSectionModel(
      month: month,
      chart: plot.spent == 0 && plot.p90 == 0
        ? .notEnoughData(.noSpendingThisMonth) : .ready(plot),
      accounts: accountBalances(inputs.accounts, remainder: inputs.remainder))
  }

  /// The balance of every account at the end of the month: the plan of the data with the
  /// forecast's remainder laid over it. Nothing to show while no pair of any account — in the
  /// summary or out of it — was counted. A pair counted but without a rate today is shown with
  /// «нет курса» and its currency listed, never said to be uncounted.
  static func accountBalances(
    _ plan: AccountMonthPlan, remainder: MonthForecast.Remainder
  ) -> ChartBlock<AccountForecast> {
    let forecast = plan.forecast(remainder: remainder)
    let counted = forecast.sections.contains { section in
      section.lines.contains { $0.status != .notCounted }
    }
    return counted ? .ready(forecast) : .notEnoughData(.noCountedBalance)
  }

  /// The running total of my expenses from the 1st through today; from today straight lines
  /// to P50 and to P10 and P90 on the last day. The figures are `MonthForecast`'s — the
  /// remainder of the pipeline over what is spent and planned — and every point
  /// is rounded from the exact amount, so the last point of the projection is P50 itself.
  static func forecastPlot(
    ledger: Ledger, today: DateOnly, planned: AmountE4, remainder: MonthForecast.Remainder
  ) -> ForecastPlot {
    let month = today.monthKey
    var daily: [Int: AmountE4] = [:]
    for row in ledger.rows(in: DayRange(month.firstDay, today)) {
      daily[row.day.day, default: .zero] += row.contribution
    }
    var running = AmountE4.zero
    var actual: [DayValue] = []
    for day in 1...today.day {
      running += daily[day] ?? .zero
      actual.append(DayValue(day: day, value: running.wholeRubles))
    }
    let spent = running
    let forecast = MonthForecast(spent: spent, planned: planned, remainder: remainder)
    let daysLeft = month.dayCount - today.day

    func along(_ target: AmountE4, _ step: Int) -> Int64 {
      guard daysLeft > 0 else { return target.wholeRubles }
      let value =
        spent.decimal + (target.decimal - spent.decimal) * Decimal(step) / Decimal(daysLeft)
      return whole(value)
    }
    let steps = 0...daysLeft
    return ForecastPlot(
      dayCount: month.dayCount, today: today.day, actual: actual,
      projection: steps.map { DayValue(day: today.day + $0, value: along(forecast.p50, $0)) },
      band: steps.map {
        DayBand(
          day: today.day + $0, low: along(forecast.p10, $0), high: along(forecast.p90, $0))
      },
      spent: spent.wholeRubles, planned: planned.wholeRubles, p10: forecast.p10.wholeRubles,
      p50: forecast.p50.wholeRubles, p90: forecast.p90.wholeRubles, lowData: forecast.lowData,
      daysLeft: daysLeft)
  }

  // MARK: - Pieces

  /// Lines of a ranked chart, or «Мало данных» when none has a positive whole ruble to
  /// draw — nothing at all, or refunds that outweighed every bucket.
  static func ranked(
    _ nodes: [BreakdownNode], else reason: AnalyticsReason
  ) -> ChartBlock<[RankedValue]> {
    let values = nodes.map(RankedValue.init)
    return values.contains { $0.value > 0 } ? .ready(values) : .notEnoughData(reason)
  }

  /// Rubles rounded half away from zero; out of range, which money never is,
  /// clamps.
  static func whole(_ rubles: Decimal) -> Int64 {
    (try? DecimalMath.int64(rounding: rubles)) ?? (rubles < 0 ? .min : .max)
  }
}
