import CoreKit
import Foundation

/// Which money a series follows.
public enum SeriesMeasure: String, Hashable, Sendable, CaseIterable {
  /// My expenses, by the date of the operation.
  case expenses
  /// Income. Monthly steps over whole months take it by the month it is for; daily and
  /// weekly steps, and every step of a span that cuts a month, by the date it arrived — the
  /// chart says «by date received» under it.
  case income
}

extension Ledger {
  /// The days of a month that lie inside a period.
  func slice(of month: MonthKey, in period: Period) -> DayRange {
    DayRange(month.firstDay, month.lastDay).clamped(to: period.range)
  }

  /// Income of the part of `month` inside `period`, by the rule of the whole period:
  /// by the month it is for when the period is made of whole months, by
  /// date when it cuts a month — in every bucket, the month lying whole inside it too, so
  /// one income never lands in two buckets or in none.
  func income(of month: MonthKey, in period: Period) -> AmountE4 {
    period.isWholeMonths
      ? income(attributedTo: [month]) : income(byDateIn: slice(of: month, in: period))
  }

  func amount(of measure: SeriesMeasure, of month: MonthKey, in period: Period) -> AmountE4 {
    switch measure {
    case .expenses: expenses(in: slice(of: month, in: period))
    case .income: income(of: month, in: period)
    }
  }

  /// The days of a period that have already happened and that the history covers:
  /// [max(start, first day with operations), min(end, today)].
  func elapsed(_ period: Period, today: DateOnly) -> DayRange {
    DayRange(max(period.start, firstDay ?? period.end.adding(days: 1)), min(period.end, today))
  }
}

/// Spending or income by day, week (from Monday) or month.
public struct TimeSeries: Hashable, Sendable {
  public enum Step: String, Hashable, Sendable, CaseIterable {
    case day, week, month
  }

  public struct Point: Hashable, Sendable {
    /// The first day of the bucket: the day, the Monday of the week, the 1st of the month.
    public var start: DateOnly
    public var amount: AmountE4
  }

  public var step: Step
  public var measure: SeriesMeasure
  public var points: [Point]
  public var total: AmountE4
  /// The mean of the buckets that have begun by today, counted from the first day with
  /// operations — or, for income by the month it is for, from the first month any income is
  /// for, which can come before that day; `nil` when there are none yet.
  public var average: AmountE4?

  public init(
    ledger: Ledger, period: Period, step: Step, measure: SeriesMeasure = .expenses,
    today: DateOnly
  ) {
    self.step = step
    self.measure = measure
    var points: [Point] = []
    switch step {
    case .day:
      var sums: [Int: AmountE4] = [:]
      for row in ledger.rows(in: period.range) {
        sums[row.dayNumber, default: .zero] += Self.value(of: row, measure)
      }
      points = period.range.days.map { Point(start: $0, amount: sums[$0.dayNumber] ?? .zero) }
    case .week:
      var sums: [DateOnly: AmountE4] = [:]
      for row in ledger.rows(in: period.range) {
        sums[row.day.weekStart, default: .zero] += Self.value(of: row, measure)
      }
      var monday = period.start.weekStart
      while monday <= period.end {
        points.append(Point(start: monday, amount: sums[monday] ?? .zero))
        monday = monday.adding(days: 7)
      }
    case .month:
      points = period.months.map { month in
        Point(
          start: month.firstDay,
          amount: ledger.amount(of: measure, of: month, in: period))
      }
    }
    self.points = points
    total = AmountE4.sum(points.map(\.amount))

    var elapsed = ledger.elapsed(period, today: today)
    // August's salary paid on 3 September in a book begun on the 1st is August's income: in
    // the total, so in the average too, as in the Reports' monthly average.
    if step == .month, measure == .income, period.isWholeMonths,
      let first = ledger.rows.lazy.filter({ $0.kind == .income }).map(\.month).min(),
      first.firstDay < elapsed.start
    {
      elapsed = DayRange(max(period.start, first.firstDay), elapsed.end)
    }
    let started = points.filter { point in
      guard !elapsed.isEmpty else { return false }
      let bucketEnd: DateOnly
      switch step {
      case .day: bucketEnd = point.start
      case .week: bucketEnd = point.start.adding(days: 6)
      case .month: bucketEnd = point.start.monthKey.lastDay
      }
      return point.start <= elapsed.end && bucketEnd >= elapsed.start
    }
    average =
      started.isEmpty
      ? nil
      : AmountE4.rounded(AmountE4.sum(started.map(\.amount)).decimal / Decimal(started.count))
  }

  static func value(of row: LedgerRow, _ measure: SeriesMeasure) -> AmountE4 {
    switch measure {
    case .expenses: row.contribution
    case .income: row.kind == .income ? row.amountRubE4 : .zero
    }
  }
}

/// Income against my expenses, month by month.
public struct IncomeVsExpense: Hashable, Sendable {
  public struct Month: Hashable, Sendable {
    public var month: MonthKey
    public var income: AmountE4
    public var expenses: AmountE4
    public var net: AmountE4 { income - expenses }
  }

  public var months: [Month]
  public var income: AmountE4 { AmountE4.sum(months.map(\.income)) }
  public var expenses: AmountE4 { AmountE4.sum(months.map(\.expenses)) }

  public init(ledger: Ledger, period: Period) {
    months = period.months.map { month in
      Month(
        month: month, income: ledger.income(of: month, in: period),
        expenses: ledger.expenses(in: ledger.slice(of: month, in: period)))
    }
  }
}

/// Income by top-level income category, by the month it is for.
public struct IncomeSources: Hashable, Sendable {
  public var sources: [BreakdownNode]
  public var total: AmountE4

  public init(ledger: Ledger, period: Period) {
    let breakdown = CategoryBreakdown(ledger: ledger, period: period, kind: .income)
    sources = breakdown.topLevel
    total = breakdown.total
  }
}

/// The period against the one before it. An incomplete period is compared with the same
/// span of the previous one (1–18 September with 1–18 August); a completed one with the
/// previous period as a whole.
public struct PeriodComparison: Hashable, Sendable {
  public var isComplete: Bool
  public var current: DayRange
  public var previous: DayRange
  public var expenses: Change
  public var income: Change
  /// My expenses added up day by day from the first day of each span.
  public var currentCumulative: [AmountE4]
  public var previousCumulative: [AmountE4]

  public init(ledger: Ledger, period: Period, today: DateOnly) {
    isComplete = period.isComplete(today: today)
    (current, previous) = period.comparisonSpans(today: today)
    expenses = Change(
      current: ledger.expenses(in: current), previous: ledger.expenses(in: previous))
    if isComplete {
      income = Change(
        current: ledger.income(in: period), previous: ledger.income(in: period.previous))
    } else if period.isWholeMonths {
      income = Change(
        current: ledger.income(attributedTo: current.months, notAfter: current.end),
        previous: ledger.income(attributedTo: previous.months, notAfter: previous.end))
    } else {
      income = Change(
        current: ledger.income(in: .days(current)), previous: ledger.income(in: .days(previous)))
    }
    currentCumulative = Self.cumulative(ledger, current)
    previousCumulative = Self.cumulative(ledger, previous)
  }

  static func cumulative(_ ledger: Ledger, _ range: DayRange) -> [AmountE4] {
    var sums: [Int: AmountE4] = [:]
    for row in ledger.rows(in: range) { sums[row.dayNumber, default: .zero] += row.contribution }
    var running = AmountE4.zero
    return range.days.map { day in
      running += sums[day.dayNumber] ?? .zero
      return running
    }
  }
}

/// My expenses by day of the week: the average per occurrence of each weekday, counted
/// only over [max(start of period, first day with operations), min(end of period, today)] —
/// days that have not happened, or that the history does not cover, are not zeros.
public struct WeekdayProfile: Hashable, Sendable {
  public struct Day: Hashable, Sendable {
    /// 1 = Monday … 7 = Sunday.
    public var weekday: Int
    public var total: AmountE4
    public var occurrences: Int
    public var average: AmountE4?
  }

  public var interval: DayRange
  public var days: [Day]

  public init(ledger: Ledger, period: Period, today: DateOnly) {
    interval = ledger.elapsed(period, today: today)
    var totals = Array(repeating: AmountE4.zero, count: 8)
    var counts = Array(repeating: 0, count: 8)
    for day in interval.days { counts[day.weekday] += 1 }
    for row in ledger.rows(in: interval) { totals[row.weekday] += row.contribution }
    days = (1...7).map { weekday in
      Day(
        weekday: weekday, total: totals[weekday], occurrences: counts[weekday],
        average: counts[weekday] == 0
          ? nil : AmountE4.rounded(totals[weekday].decimal / Decimal(counts[weekday])))
    }
  }
}
