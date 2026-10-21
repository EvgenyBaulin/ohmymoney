import CoreAnalytics
import CoreKit
import Foundation

/// «В этом месяце больше платежей не будет»: a payment of a debt may say that no more money goes
/// to the due it was made for, and the due closes although the payment is smaller than the
/// monthly one (`DebtEntry.closesTerm`, `DebtDues`). Said only where it can matter.
public enum DebtTerms {
  /// Whether a payment of `amount` on `debt` may say it: the debt is one I owe, open, with dues
  /// (`Debt.hasDues`) and something to pay, and the payment, with the money already paid toward
  /// the earliest unpaid due, does not cover that due — a percent of the due short of it is
  /// covered (`DebtDues.tolerance`). `dues` is the state of the debt's dues; without it the
  /// monthly payment is the measure. What is left of the due is never more than is left of
  /// the debt (`DebtDueState.owed`): a payment of all of it pays the debt off, and there is no
  /// month after it for the word to speak of.
  public static func offersClosing(
    _ debt: Debt, paying amount: AmountE4, dues: DebtDueState?
  ) -> Bool {
    guard debt.direction == .iOwe, !debt.closed, amount.raw > 0, debt.hasDues else {
      return false
    }
    var left = debt.monthlyPaymentE4 ?? .zero
    var due = left
    if let dues = dues?.knowing(debt) {
      guard let index = dues.firstUnpaidIndex else { return false }
      left = dues.owed(dues.due(index))
      due = dues.amount(ofDue: index)
    }
    return amount + DebtDues.tolerance(of: due) < left
  }

  /// What a payment of `debt` starts with: what is left of the earliest unpaid due — the sum of
  /// that due less the money already paid toward it —, else the monthly payment; zero for a debt
  /// with none.
  public static func amountToPay(_ debt: Debt, dues: DebtDueState?) -> AmountE4 {
    let monthly = debt.monthlyPaymentE4.flatMap { $0.raw > 0 ? $0 : nil }
    guard monthly != nil || debt.hasDues else { return .zero }
    guard let dues = dues?.knowing(debt), let first = dues.firstUnpaid else {
      return monthly ?? .zero
    }
    let left = dues.owed(first)
    return left.raw > 0 ? left : (monthly ?? dues.amount(ofDue: dues.firstUnpaidIndex ?? 0))
  }

  /// Whether a loan written today asks «Платёж за этот месяц уже сделан?»: it is one I already
  /// had, with a monthly payment and a payment day, and today is that day —
  /// the last day of a shorter month included —; the balance the owner entered is either what is
  /// left after the payment or before it, and only they know. A debt owed to me and a purchase on
  /// credit, which first owes a month after the purchase (`DebtStart`), ask nothing. Nor does a
  /// loan whose first due asks for nothing (`instalments`, its dues as
  /// `DebtSchedulePlan.instalments` works them out — a grace period that charges nothing yet):
  /// there is no payment to have made.
  public static func asksAboutThisMonth(
    _ debt: Debt, balance: AmountE4, today: DateOnly, instalments: DebtInstalments? = nil
  ) -> Bool {
    guard debt.direction == .iOwe, debt.origin == .existing, balance.raw > 0, debt.hasDues,
      let day = debt.paymentDay, day >= 1
    else { return false }
    if let instalments, !instalments.isEmpty, instalments.amount(at: 0).isZero { return false }
    return DebtDueState.payday(day, in: today.monthKey) == today
  }
}
