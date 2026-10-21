import AppCore
import AppDatabase
import Foundation

/// «Записать рефинансирование…»: a new loan paid the old one off. Both halves of what really
/// happened are written as one change, so one step of ⌘Z takes both back:
///
/// - the new loan comes in like any new loan whose money arrived today: its opening line is
///   cash on the account, and a fee, if there was one, is an expense of its own;
/// - the old loan is paid off in full from the same account by an ordinary payment that closes
///   it — the interest it had accrued is told apart as in every payment of a loan.
///
/// Nothing is worked out in advance and nothing is proposed: it is for the day the
/// refinancing really happened.
extension DebtActions {
  /// What the new loan is, as the sheet gathers it.
  struct Refinancing {
    var name: String
    var rate: Decimal?
    var monthlyPayment: AmountE4?
    var paymentDay: Int?
    /// «Платёж сначала гасит проценты» (`Debt.accruesInterest`); the owner answers it for a
    /// loan with a rate.
    var accruesInterest: Bool
    /// What the bank gave.
    var amount: AmountE4
    var day: DateOnly
    /// The account the money arrived on and the old loan was paid from.
    var account: UUID?
    /// A fee for the refinancing, paid once apart from the loan.
    var fee: AmountE4?
  }

  /// The new loan of a refinancing of `old`: a loan I owe in the currency of the old one, its
  /// payments expenses, written with the terms of this version in view.
  static func refinancedLoan(for old: Debt, as terms: Refinancing) -> Debt {
    Debt(
      direction: .iOwe, type: .loan,
      name: terms.name.trimmingCharacters(in: .whitespacesAndNewlines),
      currency: old.currency, interestRate: terms.rate, monthlyPaymentE4: terms.monthlyPayment,
      paymentDay: terms.paymentDay, accruesInterest: terms.rate != nil && terms.accruesInterest,
      termsReviewed: true)
  }

  /// The refinancing as one write, not yet applied: the new loan and the full payment of the old
  /// one. `nil` when the old debt cannot be paid off (closed, owed to me, nothing owed) or the
  /// new one is not a positive sum.
  func refinancingChange(of old: Debt, as terms: Refinancing) -> PlanningChange? {
    guard old.direction == .iOwe, !old.closed, !old.isDeleted, terms.amount.raw > 0,
      let owed = payoff(of: old), owed.raw > 0
    else { return nil }
    let calendar = planning.environment.calendar
    let moment = terms.day == planning.environment.today ? Date() : calendar.noon(of: terms.day)
    let new = Self.refinancedLoan(for: old, as: terms)
    let costs =
      (terms.fee.flatMap { $0.raw > 0 ? $0 : nil }).map {
        [
          DebtCost(
            debtId: new.id, kind: .fee,
            name: planning.environment.language("refinance.feeName", table: "Debts"), amountE4: $0,
            every: .once, day: terms.day, inLoan: false)
        ]
      } ?? []
    guard
      let opening = createChange(
        new, balance: terms.amount, on: terms.day, moneyMovedNow: true, account: terms.account,
        at: moment, costs: costs),
      let payment = payChange(
        old, amount: owed, on: moment, paymentMethodId: terms.account, closing: true)
    else { return nil }
    return Self.joined(opening, payment)
  }

  /// «Записать»: the refinancing in one write and one step of ⌘Z.
  @discardableResult
  func refinance(_ old: Debt, as terms: Refinancing) -> Bool {
    guard let change = refinancingChange(of: old, as: terms), apply(change) else { return false }
    AppLog.info(
      "debts.refinanced", .db, "a loan was refinanced", [LogPair("old", .id(old.id))])
    return true
  }

  /// Two changes of debts as one: what both create and what both upsert.
  static func joined(_ first: PlanningChange, _ second: PlanningChange) -> PlanningChange {
    var change = first
    change.created += second.created
    change.upsert.debts += second.upsert.debts
    change.upsert.debtEntries += second.upsert.debtEntries
    change.upsert.categories += second.upsert.categories
    change.upsert.debtCosts += second.upsert.debtCosts
    return change
  }
}
