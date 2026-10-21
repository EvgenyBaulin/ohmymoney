import CoreKit
import Foundation

/// The interest a deposit or a savings account earns, worked out on the balance at the end of
/// each day (`InterestMath`), never stored: what the bank pays is an income the owner records.
public enum DepositInterest {
  /// The balance of the pair `key` in steps (`InterestMath.accrue`), from `from` through
  /// `through`: the balance at the end of each day — its count in force plus what moved by then
  /// (`AccountBalances.balance(_:at:)`), which after `today` is the balance now plus what is
  /// written ahead. A day before the first count holds nothing. The first step is on `from`; a
  /// step follows only when the balance changes, and the last one holds on after `through`.
  /// `nil` while the pair was never counted — without a balance there is no interest to work
  /// out — and when `through` is before `from`.
  public static func segments(
    key: BalanceKey, balances: AccountBalances, from: DateOnly, through: DateOnly,
    today: DateOnly
  ) -> [(from: DateOnly, amount: AmountE4)]? {
    guard !balances.anchors(key).isEmpty, from <= through else { return nil }
    // After the later of today and the last movement written ahead, nothing changes.
    var last = balances.day(of: balances.momentAhead(key))
    if today > last { last = today }
    if through < last { last = through }

    var ends = DayEnds(balances: balances)
    var steps: [(from: DateOnly, amount: AmountE4)] = []
    var serial = DepositDays.serial(from)
    let lastSerial = max(DepositDays.serial(last), serial)
    while serial <= lastSerial {
      let day = DepositDays.civil(serial)
      let amount = balances.balance(key, at: ends.end(of: day)) ?? .zero
      if steps.last?.amount != amount { steps.append((day, amount)) }
      serial += 1
    }
    return steps
  }

  /// The interest of `period` earned through `through` (no later than its pay date), not
  /// rounded: the bank rounds once, at the payout.
  public static func accrued(
    terms: DepositTerms, segments: [(from: DateOnly, amount: AmountE4)], period: DepositPeriod,
    through: DateOnly
  ) -> Decimal {
    let end = min(through, period.payDate)
    guard end > period.start else { return 0 }
    return InterestMath.accrue(
      segments: segments, percent: terms.rate, after: period.start, through: end)
  }

  /// The interest `period` is expected to pay on its pay date, to the cent.
  public static func expected(
    terms: DepositTerms, segments: [(from: DateOnly, amount: AmountE4)], period: DepositPeriod
  ) -> AmountE4 {
    InterestMath.cents(
      accrued(terms: terms, segments: segments, period: period, through: period.payDate))
  }

  /// What the deposit is still expected to pay from `today` to the day it ends, to the cent:
  /// every payout dated after today, each rounded on its own, the whole of the current period
  /// among them. Interest paid onto the deposit itself earns in turn from its pay date. `nil` for
  /// a savings account, which never ends; zero for a deposit that has ended. The segments must
  /// hold the balance through the day the deposit ends, as `segments` gives it.
  public static func projectionToEnd(
    terms: DepositTerms, segments: [(from: DateOnly, amount: AmountE4)], today: DateOnly
  ) -> AmountE4? {
    guard let ends = terms.endsOn else { return nil }
    let dates = DepositSchedule.payDates(terms: terms, after: today, through: ends)
    guard let first = dates.first,
      let opening = DepositSchedule.period(
        terms: terms, containing: first, firstCount: segments.map(\.from).min())
    else { return .zero }
    var steps = segments
    var start = opening.start
    var total = AmountE4.zero
    for payDate in dates {
      let amount = expected(
        terms: terms, segments: steps, period: DepositPeriod(start: start, payDate: payDate))
      total += amount
      if terms.capitalizes, !amount.isZero {
        steps = compounded(steps, adding: [(payDate, amount)])
      }
      start = payDate
    }
    return total
  }

  /// `segments` with money joining the balance: each of `extras` from the end of its day on, as
  /// interest paid onto the account joins it from its pay date. Of two steps of the segments on
  /// one day the later holds, as in `InterestMath.accrue`.
  public static func compounded(
    _ segments: [(from: DateOnly, amount: AmountE4)], adding extras: [(DateOnly, AmountE4)]
  ) -> [(from: DateOnly, amount: AmountE4)] {
    guard !extras.isEmpty else { return segments }
    var byDay: [DateOnly: AmountE4] = [:]
    for segment in segments { byDay[segment.from] = segment.amount }
    let original = byDay.sorted { $0.key < $1.key }
    var days = Set(original.map(\.key))
    for extra in extras { days.insert(extra.0) }

    var result: [(from: DateOnly, amount: AmountE4)] = []
    var index = 0
    var base = AmountE4.zero
    for day in days.sorted() {
      while index < original.count, original[index].key <= day {
        base = original[index].value
        index += 1
      }
      let added = AmountE4.sum(extras.filter { $0.0 <= day }.map(\.1))
      result.append((day, base + added))
    }
    return result
  }

  /// The last instant of a day in the calendar of the balances, found once and then reused as
  /// long as the offset of the time zone holds.
  struct DayEnds {
    let balances: AccountBalances
    private var offset: TimeInterval?

    init(balances: AccountBalances) {
      self.balances = balances
    }

    /// The last millisecond of `day`: moments are kept to the millisecond.
    mutating func end(of day: DateOnly) -> Date {
      let utcNext = TimeInterval(DepositDays.serial(day) + 1) * 86_400
      if let offset {
        let start = Date(timeIntervalSince1970: utcNext + offset)
        if isStartOfTheNextDay(start, after: day) { return start.addingTimeInterval(-0.001) }
      }
      // The next day starts within fifteen hours of midnight UTC in every time zone.
      var low = Int64((utcNext - 15 * 3600) * 1000)
      var high = Int64((utcNext + 15 * 3600) * 1000)
      while low < high {
        let middle = low + (high - low) / 2
        if balances.day(of: Date(timeIntervalSince1970: TimeInterval(middle) / 1000)) > day {
          high = middle
        } else {
          low = middle + 1
        }
      }
      let start = Date(timeIntervalSince1970: TimeInterval(low) / 1000)
      offset = start.timeIntervalSince1970 - utcNext
      return start.addingTimeInterval(-0.001)
    }

    private func isStartOfTheNextDay(_ instant: Date, after day: DateOnly) -> Bool {
      balances.day(of: instant) > day && balances.day(of: instant.addingTimeInterval(-0.001)) <= day
    }
  }
}
