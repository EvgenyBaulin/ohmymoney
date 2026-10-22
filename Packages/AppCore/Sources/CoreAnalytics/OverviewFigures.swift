import CoreAccounting
import CoreKit
import Foundation

/// The figures of the tiles of 2.0 that count from the ledger alone — «Расход сегодня»,
/// «Неделя к неделе», «Средний расход в день», «Доход месяца», «Норма сбережений», the charts
/// and lists of spending and income, the two moves of a category and the small purchases — for
/// one «today». Each part carries its lines beside its figure, and the lines add up to the figure
/// exactly: the tile shows the figure, «Почему так» the lines, and one value stands behind both.
public struct OverviewFigures: Hashable, Sendable {
  public var today: DateOnly
  public var spendToday: SpendToday
  public var week: WeekOverWeek
  public var average: AverageDaily
  public var income: MonthIncome
  public var savings: SavingsRate
  public var weekdays: WeekdaySpending
  public var months: MonthlySpending
  public var sources: IncomeSources
  public var places: PlaceSpending
  public var people: PeopleSpending
  public var grew: CategoryMove?
  public var shrank: CategoryMove?
  /// `nil` while the owner has not said how small a small purchase is.
  public var small: SmallPurchases?

  /// How many lines a top shows.
  public static let topCount = 5
  /// How many days «a usual day» looks back over.
  public static let usualDays = 28
  /// How many weeks the weekdays are counted over.
  public static let weekdayWeeks = 12

  /// - Parameters:
  ///   - smallLimit: the most a purchase may cost to be small; `nil` — not set.
  ///   - expectedIncome: what the month still expects (`MonthIncomeEstimate.expectedRemaining`).
  public init(
    ledger: Ledger, today: DateOnly, smallLimit: AmountE4? = nil,
    expectedIncome: AmountE4 = .zero
  ) {
    self.today = today
    let month = today.monthKey
    let span = Period.monthToDate(today: today).range
    spendToday = SpendToday(ledger: ledger, today: today)
    week = WeekOverWeek(ledger: ledger, today: today)
    average = AverageDaily(ledger: ledger, today: today)
    income = MonthIncome(ledger: ledger, today: today, expected: expectedIncome)
    savings = SavingsRate(ledger: ledger, today: today, income: income.received)
    weekdays = WeekdaySpending(ledger: ledger, today: today)
    months = MonthlySpending(ledger: ledger, today: today)
    sources = IncomeSources(ledger: ledger, period: .month(month))
    places = PlaceSpending(ledger: ledger, span: span)
    people = PeopleSpending(ledger: ledger, span: span)
    let moves = CategoryMove.moves(ledger: ledger, today: today)
    grew = moves.grew
    shrank = moves.shrank
    small = smallLimit.map { SmallPurchases(ledger: ledger, span: span, limit: $0) }
  }

  // MARK: - Today

  /// «Расход сегодня»: what I spent today, and an ordinary day for comparison.
  public struct SpendToday: Hashable, Sendable {
    public var day: DateOnly
    public var spent: AmountE4
    /// How many operations today's spending is of.
    public var operations: Int
    /// The average of the days before today over the last `usualDays`, not before the first day
    /// of the books; `nil` with no day behind.
    public var usual: AmountE4?
    /// Today's spending by top-level category; the lines add up to `spent`.
    public var byCategory: [BreakdownNode]

    init(ledger: Ledger, today: DateOnly) {
      day = today
      let rows = ledger.rows(in: DayRange(today, today)).filter { !$0.contribution.isZero }
      spent = ledger.expenses(in: DayRange(today, today))
      operations = Set(rows.map(\.transactionId)).count
      byCategory = Tabulation.oneLevel(
        rows.map { (ReportGrouping.category.outerKey(of: $0), $0.contribution) })
      // No books, no usual day: the days before the first operation are not zeros.
      var start = today.adding(days: -OverviewFigures.usualDays)
      if let first = ledger.firstDay, first > start { start = first }
      let before = DayRange(start, today.adding(days: -1))
      usual =
        ledger.firstDay == nil || before.isEmpty
        ? nil
        : AmountE4.rounded(ledger.expenses(in: before).decimal / Decimal(before.dayCount))
    }

    /// Today against the usual day, in basis points; `nil` without a usual day or when it was
    /// zero.
    public var againstUsual: Int? {
      guard let usual, usual.raw > 0 else { return nil }
      return Shares.ratio(spent - usual, of: usual)
    }
  }

  // MARK: - The week

  /// «Неделя к неделе»: this week up to today and the same days of the week before.
  public struct WeekOverWeek: Hashable, Sendable {
    public var current: DayRange
    public var previous: DayRange
    public var change: Change
    /// This week's spending by day, up to today; the lines add up to `change.current`.
    public var days: [Day]

    public struct Day: Hashable, Sendable {
      public var day: DateOnly
      public var amount: AmountE4
    }

    init(ledger: Ledger, today: DateOnly) {
      let start = today.weekStart
      current = DayRange(start, today)
      previous = DayRange(start.adding(days: -7), today.adding(days: -7))
      change = Change(
        current: ledger.expenses(in: current), previous: ledger.expenses(in: previous))
      days = current.days.map { Day(day: $0, amount: ledger.expenses(in: DayRange($0, $0))) }
    }
  }

  // MARK: - The month per day

  /// «Средний расход в день»: the month so far divided by the days it has had.
  public struct AverageDaily: Hashable, Sendable {
    public var expenses: AmountE4
    /// The days from the 1st through today.
    public var days: Int
    public var perDay: AmountE4

    init(ledger: Ledger, today: DateOnly) {
      expenses = ledger.expenses(in: Period.monthToDate(today: today).range)
      days = max(today.day, 1)
      perDay = AmountE4.rounded(expenses.decimal / Decimal(days))
    }
  }

  // MARK: - Income

  /// «Доход месяца»: what came and what is still expected.
  public struct MonthIncome: Hashable, Sendable {
    public var received: AmountE4
    public var expected: AmountE4
    /// What came, by top-level category; the lines add up to `received`.
    public var bySource: [BreakdownNode]

    init(ledger: Ledger, today: DateOnly, expected: AmountE4) {
      self.expected = expected
      let rows = ledger.rows(attributedTo: [today.monthKey])
        .filter { $0.kind == .income && $0.day <= today && !$0.amountRubE4.isZero }
      received = AmountE4.sum(rows.map(\.amountRubE4))
      bySource = Tabulation.oneLevel(
        rows.map { (ReportGrouping.category.outerKey(of: $0), $0.amountRubE4) })
    }
  }

  /// «Норма сбережений»: what was put aside this month — contributions to goals and the net of
  /// ruble transfers into and out of the cushion and the deposits — as a share of the income.
  public struct SavingsRate: Hashable, Sendable {
    public var goals: AmountE4
    /// Rubles moved into the accounts that save, less the rubles moved out of them.
    public var accounts: AmountE4
    public var income: AmountE4
    /// Money moved in a currency other than rubles, left out: no rate is applied here.
    public var leftOutForeign: Int

    public var saved: AmountE4 { goals + accounts }

    /// Basis points of the income; `nil` with no income to be a share of.
    public var basisPoints: Int? { Shares.ratio(saved, of: income) }

    init(ledger: Ledger, today: DateOnly, income: AmountE4) {
      self.income = income
      let span = Period.monthToDate(today: today).range
      goals = AmountE4.sum(
        ledger.rows(in: span).filter { $0.isGoalContribution }.map(\.contribution))
      let dataset = ledger.dataset
      let savers = Set(
        dataset.paymentMethods.filter { $0.cushion || $0.interest != nil }.map(\.id))
      var net = AmountE4.zero
      var foreign = 0
      for transfer in dataset.transfers
      where span.contains(ledger.calendar.day(of: transfer.occurredAt)) {
        let into = savers.contains(transfer.toAccountId)
        let out = savers.contains(transfer.fromAccountId)
        guard into != out else { continue }
        if into {
          if transfer.toCurrency == .rub { net += transfer.toAmountE4 } else { foreign += 1 }
        } else {
          if transfer.fromCurrency == .rub {
            net = net - transfer.fromAmountE4
          } else {
            foreign += 1
          }
        }
      }
      accounts = net
      leftOutForeign = foreign
    }
  }

  // MARK: - Spending in time

  /// «Расходы по дням недели»: the last `weekdayWeeks` weeks, a total and an average per
  /// occurrence for every day of the week.
  public struct WeekdaySpending: Hashable, Sendable {
    public var interval: DayRange
    /// Monday through Sunday.
    public var days: [WeekdayProfile.Day]
    /// The lines add up to this.
    public var total: AmountE4 { AmountE4.sum(days.map(\.total)) }

    init(ledger: Ledger, today: DateOnly) {
      let range = DayRange(today.adding(days: -(OverviewFigures.weekdayWeeks * 7 - 1)), today)
      let profile = WeekdayProfile(ledger: ledger, period: .days(range), today: today)
      interval = profile.interval
      days = profile.days
    }
  }

  /// «Расходы по месяцам»: the last twelve months, the current one so far.
  public struct MonthlySpending: Hashable, Sendable {
    public struct Month: Hashable, Sendable {
      public var month: MonthKey
      public var amount: AmountE4
    }

    public var months: [Month]
    public var total: AmountE4 { AmountE4.sum(months.map(\.amount)) }

    init(ledger: Ledger, today: DateOnly) {
      months = MonthKey.range(today.monthKey.adding(months: -11), through: today.monthKey).map {
        Month(month: $0, amount: ledger.expenses(in: DayRange($0.firstDay, $0.lastDay)))
      }
    }
  }

  // MARK: - Where and for whom

  /// «Топ мест»: the places my spending of the month went to.
  public struct PlaceSpending: Hashable, Sendable {
    /// The largest places, a place with money in it each.
    public var top: [BreakdownNode]
    /// Everything else: the smaller places and the spending with no place.
    public var rest: AmountE4
    public var total: AmountE4

    init(ledger: Ledger, span: DayRange) {
      let rows = ledger.rows(in: span).filter { !$0.contribution.isZero }
      total = AmountE4.sum(rows.map(\.contribution))
      let nodes = Tabulation.oneLevel(
        rows.map { (ReportGrouping.place.outerKey(of: $0), $0.contribution) })
      top = Array(
        nodes.filter { $0.key != .noPlace && $0.amount.raw > 0 }.prefix(OverviewFigures.topCount))
      rest = total - AmountE4.sum(top.map(\.amount))
    }
  }

  /// «Траты по людям»: my spending of the month by «на кого».
  public struct PeopleSpending: Hashable, Sendable {
    public var values: [BreakdownNode]
    public var total: AmountE4 { AmountE4.sum(values.map(\.amount)) }

    init(ledger: Ledger, span: DayRange) {
      values = ForWhomReport(ledger: ledger, period: .days(span)).values
    }
  }

  // MARK: - A category that moved

  /// A top-level category's spending of the month so far against the same days of the last
  /// month.
  public struct CategoryMove: Hashable, Sendable {
    public var key: ReportKey
    public var current: AmountE4
    public var previous: AmountE4
    public var delta: AmountE4 { current - previous }
    /// The change in basis points; `nil` when last month had nothing in it.
    public var basisPoints: Int? { Change(current: current, previous: previous).basisPoints }

    /// The category that grew the most and the one that shrank the most, in rubles; `nil` for
    /// a side nothing moved on. «Сверка» and what a count wrote are not spending.
    static func moves(
      ledger: Ledger, today: DateOnly
    ) -> (grew: CategoryMove?, shrank: CategoryMove?) {
      let counts = ledger.dataset.planning.settings.limitlessCategoryIds
      func totals(_ range: DayRange) -> [ReportKey: AmountE4] {
        var sums: [ReportKey: AmountE4] = [:]
        for row in ledger.rows(in: range)
        where !row.contribution.isZero
          && !OverviewSummary.isCountDifference(row, countCategories: counts)
        {
          sums[ReportGrouping.category.outerKey(of: row), default: .zero] += row.contribution
        }
        return sums
      }
      let now = totals(Period.monthToDate(today: today).range)
      let before = totals(Period.sameSpanOfPreviousMonth(today: today).range)
      let moves = Set(now.keys).union(before.keys).map {
        CategoryMove(key: $0, current: now[$0] ?? .zero, previous: before[$0] ?? .zero)
      }
      func better(_ a: CategoryMove, _ b: CategoryMove, grew: Bool) -> Bool {
        if a.delta != b.delta { return grew ? a.delta > b.delta : a.delta < b.delta }
        return a.key.description < b.key.description
      }
      let up = moves.filter { $0.delta.raw > 0 }.min { better($0, $1, grew: true) }
      let down = moves.filter { $0.delta.raw < 0 }.min { better($0, $1, grew: false) }
      return (up, down)
    }
  }

  // MARK: - Small purchases

  /// «Мелкие покупки»: the parts of my spending this month that cost no more than `limit`, in
  /// categories that are not essential, no goal contributions and no count differences.
  public struct SmallPurchases: Hashable, Sendable {
    public var limit: AmountE4
    public var count: Int
    public var total: AmountE4
    /// By top-level category; the lines add up to `total`.
    public var byCategory: [BreakdownNode]

    init(ledger: Ledger, span: DayRange, limit: AmountE4) {
      self.limit = limit
      let counts = ledger.dataset.planning.settings.limitlessCategoryIds
      let rows = ledger.rows(in: span).filter { row in
        row.contribution.raw > 0 && row.contribution <= limit && row.kind == .expense
          && !row.isGoalContribution
          && !OverviewSummary.isCountDifference(row, countCategories: counts)
          && !(row.categoryId.map { ledger.tree.isEssential($0) } ?? false)
      }
      count = rows.count
      total = AmountE4.sum(rows.map(\.contribution))
      byCategory = Tabulation.oneLevel(
        rows.map { (ReportGrouping.category.outerKey(of: $0), $0.contribution) })
    }
  }
}
