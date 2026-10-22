import CoreCSV
import CoreKit
import Foundation

/// What a comparison of two periods is split by.
public enum ComparisonDimension: String, CaseIterable, Hashable, Sendable {
  /// Top-level categories.
  case category
  /// Places; spending without a place is the last line.
  case place
  /// People: whom the part was for, or who owes it. Spending that names nobody has no line
  /// (it is my own, not a person's) — and is not in the total of this split either.
  case person
}

/// How the owner asked the figures of a comparison to be shown.
public enum ComparisonChoice: String, CaseIterable, Hashable, Sendable {
  /// Totals when the periods are about as long, per day otherwise.
  case automatic
  case totals
  case perDay
}

/// How the figures of a comparison are in fact shown.
public enum ComparisonMeasure: String, Hashable, Sendable {
  /// What was spent in each period.
  case totals
  /// The average day of each period; one-off operations are not in an average.
  case perDay
}

/// The two periods of a comparison: the one looked at and the one it is set against.
public struct ComparisonPeriods: Hashable, Sendable {
  /// Periods whose lengths differ by no more than this many days are compared by totals.
  public static let lengthTolerance = 3

  public var current: DayRange
  public var baseline: DayRange

  public init(current: DayRange, baseline: DayRange) {
    self.current = current
    self.baseline = baseline
  }

  /// Lengths within `lengthTolerance` days of each other: 30 and 31 days, a month and a month.
  public var lengthsAreClose: Bool {
    abs(current.dayCount - baseline.dayCount) <= Self.lengthTolerance
  }

  /// What the figures show when the owner leaves the choice to the app.
  public func measure(for choice: ComparisonChoice) -> ComparisonMeasure {
    switch choice {
    case .totals: .totals
    case .perDay: .perDay
    case .automatic: lengthsAreClose ? .totals : .perDay
    }
  }
}

/// The ready-made pairs of one tap, and any two ranges of dates.
public enum ComparisonPair: Hashable, Sendable {
  case monthToSameMonthLastYear(MonthKey)
  case monthToPreviousMonth(MonthKey)
  /// `quarter` is 1…4.
  case quarterToPreviousQuarter(year: Int, quarter: Int)
  case quarterToSameQuarterLastYear(year: Int, quarter: Int)
  /// An event against an ordinary month: the closest whole month before the event that no
  /// event of `events` touches (the month right before it when every one of the last twelve is
  /// busy).
  case eventToUsualMonth(Event)
  case custom(current: DayRange, baseline: DayRange)

  public func periods(events: [Event] = []) -> ComparisonPeriods {
    func month(_ key: MonthKey) -> DayRange { DayRange(key.firstDay, key.lastDay) }
    func quarter(_ year: Int, _ number: Int) -> DayRange {
      let first = MonthKey(year: year, month: (min(max(number, 1), 4) - 1) * 3 + 1)
      return DayRange(first.firstDay, first.adding(months: 2).lastDay)
    }
    switch self {
    case .monthToSameMonthLastYear(let key):
      return ComparisonPeriods(current: month(key), baseline: month(key.adding(months: -12)))
    case .monthToPreviousMonth(let key):
      return ComparisonPeriods(current: month(key), baseline: month(key.adding(months: -1)))
    case .quarterToPreviousQuarter(let year, let number):
      let previous = number <= 1 ? (year - 1, 4) : (year, number - 1)
      return ComparisonPeriods(
        current: quarter(year, number), baseline: quarter(previous.0, previous.1))
    case .quarterToSameQuarterLastYear(let year, let number):
      return ComparisonPeriods(
        current: quarter(year, number), baseline: quarter(year - 1, number))
    case .eventToUsualMonth(let event):
      let span = DayRange(event.startDate, event.endDate)
      let others = events.filter { $0.id != event.id && !$0.archived }
        .map { DayRange($0.startDate, $0.endDate) }
      func touches(_ range: DayRange, _ other: DayRange) -> Bool {
        range.start <= other.end && other.start <= range.end
      }
      let first = event.startDate.monthKey
      let usual =
        (1...12).lazy.map { first.adding(months: -$0) }
        .first { key in
          let range = month(key)
          return !touches(range, span) && !others.contains { touches(range, $0) }
        } ?? first.adding(months: -1)
      return ComparisonPeriods(current: span, baseline: month(usual))
    case .custom(let current, let baseline):
      return ComparisonPeriods(current: current, baseline: baseline)
    }
  }
}

/// One line of a comparison: the same thing in the two periods.
public struct ComparisonRow: Hashable, Sendable {
  public var key: ReportKey
  public var current: AmountE4
  public var baseline: AmountE4
  /// Basis points of the current figure among the positive ones; `nil` for a figure that is
  /// not positive.
  public var share: Int?

  public init(key: ReportKey, current: AmountE4, baseline: AmountE4, share: Int? = nil) {
    self.key = key
    self.current = current
    self.baseline = baseline
    self.share = share
  }

  public var delta: AmountE4 { current - baseline }

  /// The change against the baseline in basis points (-2000 is «20 % less»); `nil` when the
  /// baseline is zero and there is nothing to compare with.
  public var changeBasisPoints: Int? {
    Change(current: current, previous: baseline).basisPoints
  }
}

/// Two periods side by side by category, place or person, in rubles.
///
/// * What counts is my spending as everywhere (`LedgerRow.contribution`: a part for somebody
///   else once written off, refunds taken off), without the differences of reconciliations.
/// * Periods about as long (up to three days apart) are compared by totals; otherwise by the
///   average day, and the screen says so. The owner may force either.
/// * Totals keep the operations marked one-off — they happened; the average day does not.
public struct SpendingComparison: Hashable, Sendable {
  public var periods: ComparisonPeriods
  public var dimension: ComparisonDimension
  /// What the figures are.
  public var measure: ComparisonMeasure
  /// The measure was chosen by the app, not by the owner.
  public var isAutomatic: Bool
  /// Largest current figure first, the «none» line last; lines empty in both periods are not
  /// listed.
  public var rows: [ComparisonRow]
  public var total: ComparisonRow

  /// The screen says «в среднем за день, периоды разной длины» exactly when the app switched
  /// to the average day because the periods differ in length.
  public var showsDifferentLengthNote: Bool {
    measure == .perDay && isAutomatic && !periods.lengthsAreClose
  }

  public init(
    ledger: Ledger, periods: ComparisonPeriods, dimension: ComparisonDimension = .category,
    choice: ComparisonChoice = .automatic, oneOff: OneOffMarks = .none
  ) {
    self.periods = periods
    self.dimension = dimension
    let measure = periods.measure(for: choice)
    self.measure = measure
    self.isAutomatic = choice == .automatic

    func key(of row: LedgerRow) -> ReportKey? {
      switch dimension {
      case .category: ReportGrouping.category.outerKey(of: row)
      case .place: ReportGrouping.place.outerKey(of: row)
      case .person: row.personId.map(ReportKey.person)
      }
    }
    func figures(_ range: DayRange) -> [ReportKey: AmountE4] {
      var sums: [ReportKey: AmountE4] = [:]
      for row in SpendingRows.rows(in: range, of: ledger) {
        if measure == .perDay && oneOff.contains(row.transactionId) { continue }
        guard let key = key(of: row) else { continue }
        sums[key, default: .zero] += row.contribution
      }
      guard measure == .perDay else { return sums }
      let days = Decimal(max(range.dayCount, 1))
      return sums.mapValues { AmountE4.rounded($0.decimal / days) }
    }
    let current = figures(periods.current)
    let baseline = figures(periods.baseline)

    let keys = Set(current.keys).union(baseline.keys)
    let positive = AmountE4.sum(current.values.filter { $0.raw > 0 })
    var rows = keys.compactMap { key -> ComparisonRow? in
      let now = current[key] ?? .zero
      let before = baseline[key] ?? .zero
      guard !now.isZero || !before.isZero else { return nil }
      return ComparisonRow(
        key: key, current: now, baseline: before,
        share: now.raw > 0 ? Shares.ratio(now, of: positive) : nil)
    }
    rows.sort { left, right in
      if left.key.isRemainder != right.key.isRemainder { return !left.key.isRemainder }
      if left.current != right.current { return left.current > right.current }
      if left.baseline != right.baseline { return left.baseline > right.baseline }
      return left.key.description < right.key.description
    }
    self.rows = rows
    self.total = ComparisonRow(
      key: .total, current: AmountE4.sum(current.values), baseline: AmountE4.sum(baseline.values),
      share: positive.raw > 0 ? Shares.whole : nil)
  }
}

// MARK: - A year ago

/// This month against the same month of the year before — «на такси на 20 % меньше».
public struct YearAgoComparison: Hashable, Sendable {
  public var month: MonthKey
  public var comparison: SpendingComparison

  /// The lines that have last year's figure to be compared with, largest current first.
  public var changes: [ComparisonRow] {
    comparison.rows.filter { $0.changeBasisPoints != nil }
  }
}

public enum YearAgoResult: Hashable, Sendable {
  case comparison(YearAgoComparison)
  /// The history is shorter than a year: «Мало данных: история с марта 2026». `historyStart` is
  /// the month of the first operation, `nil` with no operations at all. No ranking and no
  /// comparison with other people is made up instead.
  case notEnoughData(historyStart: MonthKey?)
}

public enum YearAgo {
  /// `month` against the same month a year before. The month that is not over (`today` is in it)
  /// is compared by the same days of the year before, so the two spans are equally long. The
  /// history has to reach the first day of last year's month: a month that was only started
  /// then is not a month to compare with.
  public static func build(
    ledger: Ledger, month: MonthKey, today: DateOnly, oneOff: OneOffMarks = .none
  ) -> YearAgoResult {
    let ago = month.adding(months: -12)
    guard let first = ledger.firstDay, first <= ago.firstDay else {
      return .notEnoughData(historyStart: ledger.firstDay?.monthKey)
    }
    var current = DayRange(month.firstDay, month.lastDay)
    var baseline = DayRange(ago.firstDay, ago.lastDay)
    if today.monthKey == month, today < month.lastDay {
      current = DayRange(month.firstDay, today)
      baseline = DayRange(
        ago.firstDay, DateOnly(year: ago.year, month: ago.month, day: min(today.day, ago.dayCount)))
    }
    return .comparison(
      YearAgoComparison(
        month: month,
        comparison: SpendingComparison(
          ledger: ledger, periods: ComparisonPeriods(current: current, baseline: baseline),
          dimension: .category, choice: .automatic, oneOff: oneOff)))
  }
}

// MARK: - CSV

/// A comparison as CSV in the way of the Reports: `row_type`, `name`, then the current figure,
/// the baseline and their difference (whole rubles and exact), then `share`. Read by
/// `pandas.read_csv` with no parameters. Names come from the caller; the core holds only the
/// token `Total`.
public enum ComparisonCSV {
  public static let columns = [
    "row_type", "name", "current_rub", "current_rub_exact", "baseline_rub",
    "baseline_rub_exact", "delta_rub", "delta_rub_exact", "share",
  ]

  public static func data(_ comparison: SpendingComparison, label: (ReportKey) -> String) -> Data {
    var writer = CSVWriter(columns: columns)
    func write(_ type: String, _ name: String, _ row: ComparisonRow) {
      writer.append([
        type, name,
        String(row.current.wholeRubles), ReportCSV.exact(row.current),
        String(row.baseline.wholeRubles), ReportCSV.exact(row.baseline),
        String(row.delta.wholeRubles), ReportCSV.exact(row.delta),
        ReportCSV.share(row.share),
      ])
    }
    for row in comparison.rows { write("item", label(row.key), row) }
    write("total", "Total", comparison.total)
    return writer.data()
  }

  /// `comparison-2026-09-vs-2025-09.csv`: a whole month is `YYYY-MM`, a whole quarter
  /// `YYYY-Qn`, any other span `YYYY-MM-DD_YYYY-MM-DD`.
  public static func fileName(for periods: ComparisonPeriods) -> String {
    "comparison-\(tag(periods.current))-vs-\(tag(periods.baseline)).csv"
  }

  static func tag(_ range: DayRange) -> String {
    let start = range.start
    let month = start.monthKey
    if start.day == 1 && range.end == month.lastDay { return month.iso }
    if start.day == 1, (start.month - 1) % 3 == 0, range.end == month.adding(months: 2).lastDay {
      return "\(start.year)-Q\((start.month - 1) / 3 + 1)"
    }
    return "\(range.start.iso)_\(range.end.iso)"
  }
}
