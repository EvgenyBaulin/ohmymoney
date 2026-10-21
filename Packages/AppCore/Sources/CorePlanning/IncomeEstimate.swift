import CoreAnalytics
import CoreKit
import Foundation

/// The income a month is expected to bring, in rubles — the first term of «can save this
/// month».
public struct MonthIncomeEstimate: Hashable, Sendable {
  public enum Source: String, Hashable, Sendable, CaseIterable {
    /// Received plus what the expectations of this month still wait for.
    case expectations
    /// No expectation this month: the median of the last complete months, or what already
    /// came when that is more.
    case median
    /// Neither: only what already came, and the figure is marked «not enough data».
    case receivedOnly
  }

  public var month: MonthKey
  /// Income that belongs to the month and arrived by today — the Overview figure.
  public var received: AmountE4
  /// What the expectations due this month (up to `until`) still wait for, in rubles.
  public var expectedRemaining: AmountE4
  /// The median income of the last complete months, at most three; `nil` before the first
  /// month is complete, or while none of them brought any income.
  public var median3: AmountE4?
  /// How many complete months `median3` is the median of.
  public var monthsInMedian: Int
  /// The estimate; `nil` when nothing came and there is nothing to go by.
  public var value: AmountE4?
  public var source: Source
  public var lowData: Bool
  /// Expectations due this month in a currency without a known rate: left out, not guessed.
  public var expectationsWithoutRate: [UUID]

  public init(
    month: MonthKey, received: AmountE4, expectedRemaining: AmountE4, median3: AmountE4?,
    monthsInMedian: Int, value: AmountE4?, source: Source, lowData: Bool,
    expectationsWithoutRate: [UUID] = []
  ) {
    self.month = month
    self.received = received
    self.expectedRemaining = expectedRemaining
    self.median3 = median3
    self.monthsInMedian = monthsInMedian
    self.value = value
    self.source = source
    self.lowData = lowData
    self.expectationsWithoutRate = expectationsWithoutRate
  }
}

/// One due date of an expectation and what it still brings this month, in rubles: the part
/// not received yet plus operations already linked to it that are dated after today.
public struct ExpectedIncomeItem: Hashable, Sendable {
  public var incomeId: UUID
  public var name: String
  public var due: DateOnly
  public var rub: AmountE4

  public init(incomeId: UUID, name: String, due: DateOnly, rub: AmountE4) {
    self.incomeId = incomeId
    self.name = name
    self.due = due
    self.rub = rub
  }
}

/// The expected income of the current month: the income received this month plus what is
/// still expected before its end; with nothing expected, the median income of 3 months.
///
/// * **Received** is the Overview figure: income that belongs to the month and arrived by
///   today.
/// * **Expected** is what the due dates of this month — from the 1st through `until`, the
///   end of the month by default — still wait for. A due date of an earlier month that was
///   never paid is overdue, not this month's income, and stays out. A payment already
///   entered for a due date and dated after `until` is not waited for in that window.
/// * When some expectation is due this month the estimate is received + expected, even if
///   it came in whole already. Otherwise it is the median of the last complete months, at
///   most three — or what already came when that is more. That last clause is a deliberate
///   step away from a plain median: income already in hand is never ignored, and a month
///   with a large one-off payment is not estimated below what it already brought. The first
///   month of the history counts only when the history starts on its 1st (`historyStart`):
///   a month the owner began to write down on the 25th holds a few days of it, not a
///   month's income.
/// * With neither — no expectation, and no complete month that brought any income — the
///   estimate is what came, marked «not enough data», and with nothing come there is no
///   estimate at all. Months without income next to one that had some are real zeros.
public enum IncomeEstimate {
  /// Complete months the median looks back over at most.
  public static let medianMonths = 3

  public static func month(
    ledger: Ledger, statuses: [ExpectedIncomeStatus], today: DateOnly, until: DateOnly? = nil
  ) -> MonthIncomeEstimate {
    let month = today.monthKey
    let received = ledger.income(attributedTo: [month], notAfter: today)

    let expectations = expectedThisMonth(
      ledger: ledger, statuses: statuses, today: today, until: until)
    let expectationsExist = expectations.exist
    let expected = expectations.total
    let withoutRate = expectations.withoutRate

    let history = SavingsMath.completeMonths(
      before: month, historyStart: historyStart(firstDay: ledger.firstDay), count: medianMonths)
    let incomes = history.map { ledger.income(attributedTo: [$0]) }
    // Months without any income are no history of income: an owner who wrote down only
    // expenses has no median to go by, and 0 would be an invented figure.
    let median3 = incomes.contains { $0.raw > 0 } ? median(incomes) : nil

    let value: AmountE4?
    let source: MonthIncomeEstimate.Source
    if expectationsExist {
      value = received + expected
      source = .expectations
    } else if let median3 {
      value = max(received, median3)
      source = .median
    } else {
      value = received.raw > 0 ? received : nil
      source = .receivedOnly
    }
    return MonthIncomeEstimate(
      month: month, received: received, expectedRemaining: expected, median3: median3,
      monthsInMedian: median3 == nil ? 0 : history.count, value: value, source: source,
      lowData: source == .receivedOnly, expectationsWithoutRate: withoutRate)
  }

  /// What the due dates of this month still wait for — the `expectedRemaining` of `month`, due
  /// date by due date. Every due date of the month from the 1st through `until` (the end of the
  /// month by default) adds what it has not received yet plus the operations linked to it that
  /// are dated after today (`rublesAhead`); the items list those that add something, and add
  /// up to `total` exactly. `exist` says whether any expectation is due this month at all.
  public static func expectedThisMonth(
    ledger: Ledger, statuses: [ExpectedIncomeStatus], today: DateOnly, until: DateOnly? = nil
  ) -> (items: [ExpectedIncomeItem], total: AmountE4, exist: Bool, withoutRate: [UUID]) {
    let month = today.monthKey
    let first = month.firstDay
    let last = month.lastDay
    let horizon = min(max(until ?? last, first), last)
    var exist = false
    var total = AmountE4.zero
    var withoutRate: [UUID] = []
    var items: [ExpectedIncomeItem] = []
    for status in statuses where !status.income.closed {
      for occurrence in status.occurrences where occurrence.due.monthKey == month {
        exist = true
        guard occurrence.due <= horizon else { continue }
        // A linked operation dated after today fills the due date already, but `received`
        // counts only what came by today: until its day comes it is still expected — within
        // a window that ends before its day, not at all: that money comes after `until`.
        var item = rublesAhead(
          of: occurrence, month: month, today: today, through: horizon < last ? horizon : nil,
          ledger: ledger)
        if !occurrence.isFulfilled {
          if let rubles = occurrence.remainingRub {
            item += rubles
          } else if !withoutRate.contains(status.id) {
            withoutRate.append(status.id)
          }
        }
        total += item
        if !item.isZero {
          items.append(
            ExpectedIncomeItem(
              incomeId: status.id, name: status.income.name, due: occurrence.due, rub: item))
        }
      }
    }
    return (items, total, exist, withoutRate)
  }

  /// The first month the income history counts: the month of the first record when it is on
  /// the 1st, else the month after — a first month begun later is only part of a month.
  public static func historyStart(firstDay: DateOnly?) -> MonthKey? {
    guard let firstDay else { return nil }
    return firstDay.day == 1 ? firstDay.monthKey : firstDay.monthKey.next
  }

  /// The income rubles of the operations counted towards a due date that belong to `month`
  /// but are dated after today — the part of the due date `received` does not see yet. With
  /// `through` (a window shorter than the month), only those dated by then: what comes later
  /// is not in the window. The whole month takes every one that belongs to it, one dated
  /// early next month included, as it takes income by the month it is for.
  private static func rublesAhead(
    of occurrence: ExpectedOccurrence, month: MonthKey, today: DateOnly, through: DateOnly?,
    ledger: Ledger
  ) -> AmountE4 {
    var total = AmountE4.zero
    for transactionId in occurrence.transactionIds {
      guard let entry = ledger.entry(transactionId) else { continue }
      for part in entry.parts {
        guard let row = ledger.row(ofPart: part.id), row.kind == .income, row.month == month,
          row.day > today, through.map({ row.day <= $0 }) ?? true
        else { continue }
        total += row.amountRubE4
      }
    }
    return total
  }

  /// What the expectations still wait for from today through `through`, in rubles at today's
  /// rate — the grey line «ещё ждём до D» of the free sum, shown and never added.
  ///
  /// Every due date from the 1st of today's month through `through` counts, an overdue one of
  /// this month included (a due date of an earlier month never paid is not waited for any
  /// more, as `month` has it): its unfulfilled remainder, plus the operations already linked to
  /// it that are dated after today and by `through` — written ahead, their money has not come
  /// yet. `statuses` have to reach `through` (`ExpectedIncomeRules.statuses(through:)`).
  /// Expectations whose remainder has no rate are left out and listed.
  public static func stillExpected(
    statuses: [ExpectedIncomeStatus], today: DateOnly, through: DateOnly, ledger: Ledger
  ) -> (amount: AmountE4, withoutRate: [UUID]) {
    let first = today.monthKey.firstDay
    var total = AmountE4.zero
    var withoutRate: [UUID] = []
    for status in statuses where !status.income.closed {
      for occurrence in status.occurrences where occurrence.due >= first {
        guard occurrence.due <= through else { continue }
        for transactionId in occurrence.transactionIds {
          guard let entry = ledger.entry(transactionId) else { continue }
          for part in entry.parts {
            guard let row = ledger.row(ofPart: part.id), row.kind == .income, row.day > today,
              row.day <= through
            else { continue }
            total += row.amountRubE4
          }
        }
        guard !occurrence.isFulfilled else { continue }
        if let rubles = occurrence.remainingRub {
          total += rubles
        } else if !withoutRate.contains(status.id) {
          withoutRate.append(status.id)
        }
      }
    }
    return (total, withoutRate)
  }

  /// The median, with the mean of the two middle values for an even count, rounded half
  /// away from zero; `nil` for no values.
  public static func median(_ values: [AmountE4]) -> AmountE4? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count % 2 == 1 { return sorted[middle] }
    return SavingsMath.divide(sorted[middle - 1] + sorted[middle], by: 2)
  }
}
