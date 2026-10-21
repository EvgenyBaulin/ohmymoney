import CoreKit
import Foundation

/// A credit card kept both as an account and as a debt of the kind `credit_card`: «Оставить
/// только счёт» deletes the debt softly — every operation keeps pointing at it, as any deleted
/// debt — and gives its rate to the account, as the rate of purchases, when the account has
/// none. An account without terms gets them from the sheet first: its limit only the owner
/// knows.
public enum CreditCardDebtMerge {
  /// Whether «Оставить только счёт» is offered for `debt`: a live debt of a credit card I owe.
  public static func offered(for debt: Debt) -> Bool {
    debt.type == .creditCard && debt.direction == .iOwe && debt.deletedAt == nil
  }

  public static func keepOnlyAccount(
    debt: Debt, account: PaymentMethod
  ) -> (account: PaymentMethod, debtDeleted: Debt) {
    var debt = debt
    if debt.deletedAt == nil { debt.deletedAt = Date() }
    var account = account
    if var terms = account.credit, terms.purchaseRate == nil, let rate = debt.interestRate,
      rate > 0
    {
      terms.purchaseRate = rate
      account.credit = terms
    }
    return (account, debt)
  }
}
