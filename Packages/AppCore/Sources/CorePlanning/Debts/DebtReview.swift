import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// What the owner is asked about a debt the update found.
public enum DebtReviewField: String, Hashable, Sendable, CaseIterable {
  /// Fees and insurance of a loan.
  case costs
  /// The full cost of credit from the contract.
  case psk
  /// Whether the bank takes an early repayment on any day.
  case prepayAnyDay
  /// How many days before an early repayment the application is filed.
  case prepayNotice
  /// Whether the debt is on the payoff ladder.
  case ladder
  /// «Это рассрочка частями?» — the parts, the step and the markup.
  case instalmentPlan
  /// «Оставить только счёт» — a credit card kept as a debt too.
  case keepOnlyAccount
}

/// A debt the owner has not yet seen the terms of this version for, and what to ask about it.
public struct DebtReviewItem: Hashable, Sendable, Identifiable {
  public var debtId: UUID
  public var fields: [DebtReviewField]

  public init(debtId: UUID, fields: [DebtReviewField]) {
    self.debtId = debtId
    self.fields = fields
  }

  public var id: UUID { debtId }
}

/// The debts made before this version, asked about once: every open debt I owe the owner has
/// not seen the new terms for. Nothing is worked out anew until they answer. A loan with a rate
/// or a payment is asked about its costs, its full cost of credit, early repayments and the
/// ladder; a purchase on credit whether it is an instalment plan; a debt kept as a credit card
/// whether to keep only the account. A debt there is nothing to ask about is not listed. Loans
/// come first, then purchases, then credit cards, each by name.
public enum DebtReview {
  public static func toReview(debts: [Debt]) -> [DebtReviewItem] {
    var items: [(rank: Int, name: String, item: DebtReviewItem)] = []
    for debt in debts
    where !debt.closed && !debt.isDeleted && !debt.termsReviewed && debt.direction == .iOwe {
      let item = DebtReviewItem(debtId: debt.id, fields: fields(of: debt))
      guard !item.fields.isEmpty else { continue }
      let rank = debt.type == .creditCard ? 2 : (debt.origin == .purchase ? 1 : 0)
      items.append((rank, debt.name, item))
    }
    return
      items
      .sorted { left, right in
        if left.rank != right.rank { return left.rank < right.rank }
        if left.name != right.name { return left.name < right.name }
        return left.item.debtId.uuidString < right.item.debtId.uuidString
      }
      .map(\.item)
  }

  /// What to ask about `debt`.
  public static func fields(of debt: Debt) -> [DebtReviewField] {
    if debt.type == .creditCard { return [.keepOnlyAccount] }
    if debt.origin == .purchase { return debt.parts == nil ? [.instalmentPlan] : [] }
    let loan =
      (debt.interestRate ?? 0) > 0 || (debt.monthlyPaymentE4?.raw ?? 0) > 0
      || debt.hasDues
    return loan ? [.costs, .psk, .prepayAnyDay, .prepayNotice, .ladder] : []
  }
}
