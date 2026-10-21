import CoreAccounting
import CoreKit
import Foundation

/// An operation dated after today, written as it stands, is a «future expense» that belongs to
/// nobody's plan: a payment waiting for its day, or an income waiting to come. Before such an
/// operation is written the owner is asked whether it is a record or a plan; this is what
/// decides whether to ask, and what a plan is made of.
public enum OperationAhead {
  /// What a new operation dated ahead may be turned into.
  public enum Plan: Hashable, Sendable {
    /// A payment of one date (`ScheduledPayment.isOneOff`), from an expense.
    case payment
    /// An income expected on one date (`ExpectedIncome`), from an income.
    case income
  }

  /// The plan a new `draft` may be turned into, or nil when it is a record whatever its date: a
  /// day after `today` and an expense or an income of one part — a split, a contribution to a
  /// goal, a payment on a debt, a purchase on credit and a refund of a purchase cannot be held
  /// by a plan —, and an amount above zero.
  public static func plan(
    for draft: TransactionDraft, today: DateOnly, calendar: CalendarContext
  ) -> Plan? {
    let plan: Plan
    switch draft.kind {
    case .expense: plan = .payment
    case .income: plan = .income
    case .refund, .reimbursement: return nil
    }
    guard calendar.day(of: draft.occurredAt) > today, draft.amount > .zero,
      draft.parts.count == 1, let part = draft.parts.first,
      part.goalId == nil, part.refundOfPartId == nil,
      draft.debtId == nil, draft.creditDebtId == nil
    else { return nil }
    return plan
  }

  /// The payment an expense dated ahead becomes: «Разово» — every month, ending on its own date,
  /// which is how Planning reads one charge —, named `name`, with what the expense said: amount,
  /// currency, category, account and card, event, for whom, and who gives the money back. A
  /// category of the app («Не помню», Loans and what is under them) is left out: a payment may
  /// not have one (`ScheduledRules.validate`), and the payment is saved without a category.
  public static func scheduledPayment(
    from draft: TransactionDraft, named name: String, calendar: CalendarContext,
    tree: CategoryTree = CategoryTree()
  ) -> ScheduledPayment {
    let due = calendar.day(of: draft.occurredAt)
    let part = draft.parts.first ?? PartDraft()
    let category = tree.systemRole(of: part.categoryId) == nil ? part.categoryId : nil
    return ScheduledPayment(
      name: name, kind: .bill, amountE4: draft.amount, currency: draft.currency,
      categoryId: category, paymentMethodId: draft.paymentMethodId,
      forWhom: part.forWhom, forPersonId: part.forPersonId, reimbursable: part.reimbursable,
      debtorPersonId: part.debtorPersonId, freq: .monthly, interval: 1, day: due.day,
      nextDate: due, endDate: due, cardId: draft.cardId, eventId: part.eventId)
  }

  /// The income an income dated ahead becomes: expected once, on its day, named `name`, in its
  /// category and on its account.
  public static func expectedIncome(
    from draft: TransactionDraft, named name: String, calendar: CalendarContext
  ) -> ExpectedIncome {
    ExpectedIncome(
      name: name, categoryId: draft.parts.first?.categoryId, kind: .oneOff,
      totalE4: draft.amount, currency: draft.currency,
      dueDate: calendar.day(of: draft.occurredAt), paymentMethodId: draft.paymentMethodId)
  }
}
