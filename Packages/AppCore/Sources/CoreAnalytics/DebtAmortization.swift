import CoreAccounting
import CoreKit
import Foundation

/// One month of the schedule of a loan: what the due asks for, how much of it is interest and
/// how much lowers the debt, and what is left after it.
public struct AmortizationRow: Hashable, Sendable {
  public var index: Int
  public var due: DateOnly
  public var paymentE4: AmountE4
  public var interestE4: AmountE4
  public var principalE4: AmountE4
  public var balanceAfterE4: AmountE4
  /// Money paid early on top of the due.
  public var prepaidE4: AmountE4
  /// The due is before today.
  public var isPast: Bool

  public init(
    index: Int, due: DateOnly, paymentE4: AmountE4, interestE4: AmountE4,
    principalE4: AmountE4, balanceAfterE4: AmountE4, prepaidE4: AmountE4 = .zero,
    isPast: Bool = false
  ) {
    self.index = index
    self.due = due
    self.paymentE4 = paymentE4
    self.interestE4 = interestE4
    self.principalE4 = principalE4
    self.balanceAfterE4 = balanceAfterE4
    self.prepaidE4 = prepaidE4
    self.isPast = isPast
  }
}

/// The schedule of a loan ahead, and what an early repayment does to it. Month by month, the
/// way banks print a schedule: the interest of a month is the balance × the yearly rate ÷ 1200,
/// to the kopeck; the rest of the payment lowers the balance; the last payment is what is left
/// with its interest.
public enum DebtAmortization {
  /// The schedule ahead from today's balance, month by month: the interest of a month is the
  /// balance × the yearly rate ÷ 1200 to the kopeck, the last payment is what is left with its
  /// interest. The dues fall on `paymentDay` of each month from the month of `firstDue`. A
  /// payment that does not cover the interest never pays the loan off: the schedule stops at
  /// `limit` rows.
  public static func schedule(
    principal: AmountE4, percent: Decimal, payment: AmountE4, firstDue: DateOnly,
    paymentDay: Int, limit: Int = 600
  ) -> [AmortizationRow] {
    guard principal.raw > 0, payment.raw > 0, limit >= 1 else { return [] }
    var rows: [AmortizationRow] = []
    var balance = principal
    var index = 0
    while balance.raw > 0, index < limit {
      let interest = monthInterest(of: balance, percent: percent)
      let due = DebtDueState.payday(paymentDay, in: firstDue.monthKey.adding(months: index))
      let pays: AmountE4
      if balance + interest <= payment {
        pays = balance + interest
      } else {
        pays = payment
      }
      let principalPaid = pays - interest
      balance = balance - principalPaid
      rows.append(
        AmortizationRow(
          index: index, due: due, paymentE4: pays, interestE4: interest,
          principalE4: principalPaid, balanceAfterE4: balance))
      index += 1
    }
    return rows
  }

  /// The interest of one month on `balance`: balance × percent ÷ 1200, to the kopeck.
  public static func monthInterest(of balance: AmountE4, percent: Decimal) -> AmountE4 {
    guard balance.raw > 0, percent > 0 else { return .zero }
    return InterestMath.cents(balance.decimal * percent / 1200)
  }

  /// «Уменьшить платёж»: a new annuity on the balance over the dues left.
  public static func paymentAfterPrepay(
    balance: AmountE4, percent: Decimal, dueLeft: Int
  ) -> AmountE4 {
    InterestMath.annuity(principal: balance, percent: percent, months: dueLeft)
  }

  /// «Уменьшить срок»: the payment stays, the dues are fewer, the last is what is left with its
  /// interest. `(0, 0)` for nothing left; a payment that never pays the loan off gives the
  /// longest schedule there is.
  public static func termAfterPrepay(
    balance: AmountE4, percent: Decimal, payment: AmountE4
  ) -> (dues: Int, last: AmountE4) {
    let rows = schedule(
      principal: balance, percent: percent, payment: payment,
      firstDue: DateOnly(year: 2000, month: 1, day: 1), paymentDay: 1)
    return (rows.count, rows.last?.paymentE4 ?? .zero)
  }

  /// The steps of the sums the early repayments of the journal give: for `.payment` a new step
  /// from the index of the due after the one the payment was made for — the first due on its day
  /// or after it (`DebtPrepay.effectiveDay`) —: the annuity of the principal left after it over
  /// the dues the schedule had left before it. `.term` changes no sum: the payment stays, and the
  /// balance cap of the dues shortens the schedule.
  public static func prepaySteps(
    debt: Debt, journal: [DebtEntry], dues: DebtDueState, calendar: CalendarContext
  ) -> [DebtInstalments.Step] {
    let lines = journal.filter { $0.debtId == debt.id }
    let prepays =
      lines
      .filter { $0.kind == .payment && $0.prepay == .payment && $0.amountE4.isNegative }
      .compactMap { line -> (DateOnly, DebtEntry)? in
        guard let day = line.date ?? line.occurredAt.map(calendar.day(of:)) else { return nil }
        return (day, line)
      }
      .sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.id.uuidString < $1.1.id.uuidString }
    guard !prepays.isEmpty, dues.firstDue != nil else { return [] }
    let percent = debt.interestRate ?? 0
    var instalments = dues.instalments
    var result: [DebtInstalments.Step] = []
    for (day, line) in prepays {
      guard let current = dues.firstIndex(onOrAfter: day) else { continue }
      let next = current + 1
      let payment = instalments.amount(at: next)
      guard payment.raw > 0 else { continue }
      // The dues the schedule had left before the payment: counted on the principal without
      // it, less the due it pays itself when no other payment of that due's stretch did.
      let others = lines.filter { $0.id != line.id }
      let before = principal(of: debt, journal: others, through: day, calendar: calendar)
      let after = principal(of: debt, journal: lines, through: day, calendar: calendar)
      guard after.raw > 0, before.raw > 0 else { continue }
      let stretchStart = current > 0 ? dues.due(current - 1) : DateOnly(year: 1, month: 1, day: 1)
      let paidByOthers = AmountE4.sum(
        others.filter { other in
          guard other.kind == .payment, other.amountE4.isNegative,
            let otherDay = other.date ?? other.occurredAt.map(calendar.day(of:))
          else { return false }
          return otherDay > stretchStart && otherDay <= max(day, dues.due(current))
        }.map(\.amountE4.magnitude))
      let due = instalments.amount(at: current)
      let paysItsDue = paidByOthers + DebtDues.tolerance(of: due) < due
      var left = termAfterPrepay(balance: before, percent: percent, payment: payment).dues
      if paysItsDue { left -= 1 }
      guard left >= 1 else { continue }
      let amount = paymentAfterPrepay(balance: after, percent: percent, dueLeft: left)
      let step = DebtInstalments.Step(fromIndex: next, amountE4: amount)
      result.append(step)
      instalments = DebtInstalments(steps: instalments.steps + [step])
    }
    return result
  }

  /// What is left of the principal of `debt` at the end of `day`: its journal through the day,
  /// with the interest its payments paid given back when it accrues interest.
  static func principal(
    of debt: Debt, journal: [DebtEntry], through day: DateOnly, calendar: CalendarContext
  ) -> AmountE4 {
    let effective = DebtInterest.effectiveJournal(
      debt: debt, journal: journal, through: day, calendar: calendar)
    return DebtRules.balance(
      entries: effective.filter { line in
        guard let lineDay = line.date ?? line.occurredAt.map(calendar.day(of:)) else {
          return true
        }
        return lineDay <= day
      })
  }
}
