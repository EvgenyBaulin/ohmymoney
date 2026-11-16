import CoreAnalytics
import CoreKit
import Foundation

/// The rules that carry the chart of the capital back before the books began. Nothing here is
/// a balance: it is the chart's reading of what the owner bought, borrowed and said.
enum CapitalPast {
  /// The value on the straight line between two dated values, at `day`, to the kopeck.
  static func onTheLine(
    from start: (day: DateOnly, value: AmountE4), to end: (day: DateOnly, value: AmountE4),
    at day: DateOnly
  ) -> AmountE4 {
    let span = NetWorthChartModel.position(of: end.day) - NetWorthChartModel.position(of: start.day)
    let passed = NetWorthChartModel.position(of: day) - NetWorthChartModel.position(of: start.day)
    guard span > 0, passed > 0 else { return start.value }
    guard passed < span else { return end.value }
    let value =
      Decimal(start.value.raw)
      + (Decimal(end.value.raw) - Decimal(start.value.raw)) * Decimal(passed) / Decimal(span)
    return AmountE4(raw: (try? DecimalMath.int64(rounding: value)) ?? start.value.raw)
  }

  /// Puts the rough sum the owner named on the points before the books, along the straight line
  /// to the money of the first point the books count; without a sum (or for a point before the
  /// day it was named for) those points hold the assets and the debts alone.
  static func applyCash(_ cash: PastCash?, to points: inout [CapitalPoint]) {
    guard let end = points.first(where: { !$0.beforeBooks }) else { return }
    let endCash = end.accountsRub + end.depositsRub + end.outOfSummaryRub
    for index in points.indices where points[index].beforeBooks {
      guard let cash, points[index].day >= cash.day else {
        points[index].withoutCash = true
        continue
      }
      points[index].cashEstimated = true
      points[index].estimatedCashRub = onTheLine(
        from: (cash.day, cash.amountE4), to: (end.day, endCash), at: points[index].day)
    }
  }
}

/// What a loan I owe was worth before its journal begins: from the day it was taken out and the
/// sum borrowed, month by month along the schedule its rate, payment and term give, bent evenly
/// so that it meets the balance the journal begins with. From the first line of the journal on,
/// only the records speak.
///
/// A loan with no payment and no term has a flat schedule, so the bend alone draws a straight
/// line from the sum borrowed to the first balance. Grace periods, steps, pauses and
/// differentiated payments are not read: the schedule is the plain annuity.
struct DebtRestoration {
  let opening: DebtOpening
  /// The day of the first line of the journal: before it the loan is restored.
  let start: DateOnly
  private let schedule: [AmountE4]
  private let monthsToStart: Int
  /// What the journal begins with less what the schedule gives on that day.
  private let gap: AmountE4

  init?(debt: Debt, journal: [DebtEntry], calendar: CalendarContext) {
    guard debt.direction == .iOwe, debt.type == .loan, let opening = debt.opening,
      !journal.isEmpty
    else { return nil }
    var days: [DateOnly] = []
    for line in journal {
      // A line with no day makes the start ambiguous: nothing is restored then.
      guard let day = line.date ?? line.occurredAt.map(calendar.day(of:)) else { return nil }
      days.append(day)
    }
    guard let start = days.min() else { return nil }
    let months = Self.months(from: opening.day.monthKey, to: start.monthKey)
    guard months >= 1 else { return nil }
    self.opening = opening
    self.start = start
    monthsToStart = months

    let percent = debt.interestRate ?? 0
    let paymentDay = debt.paymentDay ?? opening.day.day
    var payment = debt.monthlyPaymentE4.flatMap { $0.raw > 0 ? $0 : nil }
    if payment == nil, let term = debt.repayMonths, term > 0 {
      payment = InterestMath.annuity(principal: opening.amountE4, percent: percent, months: term)
    }
    var balances = [opening.amountE4]
    if let payment {
      let rows = DebtAmortization.schedule(
        principal: opening.amountE4, percent: percent, payment: payment,
        firstDue: opening.day.monthKey.next.firstDay, paymentDay: paymentDay,
        limit: months + 1)
      balances += rows.map(\.balanceAfterE4)
    }
    schedule = balances
    // The payment of the month the journal begins in counts only once its day has come.
    let payday = DebtDueState.payday(paymentDay, in: start.monthKey)
    let paid = months - (start < payday ? 1 : 0)
    let reached = Self.balance(of: balances, after: paid, hasPayment: payment != nil)
    let first = DebtBalanceAt.balance(
      of: debt, journal: journal, through: start, calendar: calendar)
    gap = first - reached
  }

  /// What was owed at the end of the month `day` closes, or `nil` before the loan was taken out
  /// or from the day the journal begins.
  func balance(on day: DateOnly) -> AmountE4? {
    let months = Self.months(from: opening.day.monthKey, to: day.monthKey)
    guard months >= 0, day < start else { return nil }
    let planned = Self.balance(of: schedule, after: months, hasPayment: schedule.count > 1)
    let bent = Decimal(gap.raw) * Decimal(months) / Decimal(monthsToStart)
    let share = AmountE4(raw: (try? DecimalMath.int64(rounding: bent)) ?? 0)
    return max(.zero, planned + share)
  }

  /// The schedule after `count` payments: the sum borrowed with none, nothing once it is paid.
  private static func balance(
    of balances: [AmountE4], after count: Int, hasPayment: Bool
  )
    -> AmountE4
  {
    guard hasPayment else { return balances[0] }
    if count <= 0 { return balances[0] }
    return count < balances.count ? balances[count] : .zero
  }

  private static func months(from first: MonthKey, to last: MonthKey) -> Int {
    (last.year * 12 + last.month) - (first.year * 12 + first.month)
  }
}
