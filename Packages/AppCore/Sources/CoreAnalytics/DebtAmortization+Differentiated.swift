import CoreAccounting
import CoreKit
import Foundation

extension DebtAmortization {
  /// The schedule of a loan paid in differentiated payments: the same part of the principal every
  /// month and the interest of the balance on top, so the payments fall month by month.
  ///
  /// The part of the principal is `principal / months` cut down to the kopeck; the last payment
  /// pays what is left, so the parts add up to `principal` exactly. The interest of a month is
  /// `monthInterest(of:percent:)` on the balance before the payment. The dues fall on
  /// `paymentDay` of each month from the month of `firstDue`, and the rows are the rows of the
  /// annuity schedule, so every report of a loan reads them alike. Like `schedule`, it stops at
  /// `limit` rows: a longer term leaves a balance after the last row.
  public static func differentiatedSchedule(
    principal: AmountE4, percent: Decimal, months: Int, firstDue: DateOnly, paymentDay: Int,
    limit: Int = 600
  ) -> [AmortizationRow] {
    guard principal.raw > 0, months >= 1, limit >= 1 else { return [] }
    let kopeck: Int64 = 100
    let part = AmountE4(raw: principal.raw / Int64(months) / kopeck * kopeck)
    var rows: [AmortizationRow] = []
    var balance = principal
    var index = 0
    while balance.raw > 0, index < min(months, limit) {
      let interest = monthInterest(of: balance, percent: percent)
      let principalPaid = index == months - 1 ? balance : min(part, balance)
      balance = balance - principalPaid
      let due = DebtDueState.payday(paymentDay, in: firstDue.monthKey.adding(months: index))
      rows.append(
        AmortizationRow(
          index: index, due: due, paymentE4: principalPaid + interest, interestE4: interest,
          principalE4: principalPaid, balanceAfterE4: balance))
      index += 1
    }
    return rows
  }
}
