import CoreKit
import Foundation

/// Why a refund of a purchase cannot be made, or a purchase with refunds cannot go.
public enum RefundError: Error, Hashable, Sendable {
  /// The part is not something that can be refunded: not a live purchase of my own — paid
  /// for somebody else, bought on credit, a payment on a debt, a contribution to a goal, or a
  /// line the app wrote for its books.
  case notRefundable
  /// More than what is left of the part after the refunds already made.
  case exceedsRemaining
  /// A refund of nothing, or of less than nothing.
  case notPositive
  /// The purchase has refunds that take money back from it: deleting it would leave them
  /// taking back from nothing. The refunds go first, or in the same deletion.
  case purchaseHasRefunds
  /// A refund in another currency than its purchase: it takes back in the purchase's currency,
  /// at the purchase's rate.
  case otherCurrency
}

/// Refunds taken back from one part of one purchase.
///
/// A refund is made in the purchase's currency at the purchase's rate, so taking back the
/// whole part takes it to zero exactly. The money comes onto an account at the refund's own
/// moment — by default the purchase's account — and when that account does not hold the
/// currency, what it received is prefilled at the rates of the refund's own day, the way a
/// bank converts a card refund on the day it arrives (`prefillLeg`) — never at the purchase's
/// rate the refund carries.
public enum RefundRules {
  /// A live purchase of my own: not paid for somebody else, not bought on credit, not a
  /// payment on a debt, not a contribution to a goal, not a line the app wrote for its books.
  ///
  /// A purchase made on an instalment plan (`creditDebt`, the debt it was bought on) is one too:
  /// a thing bought in instalments can be returned (`instalmentReturn`). The other operations on
  /// a debt the app writes — interest, markup, a tranche, a loss — never are.
  public static func isRefundable(
    part: TransactionPart, in entry: TransactionEntry, tree: CategoryTree,
    creditDebt: Debt? = nil
  ) -> Bool {
    let transaction = entry.transaction
    let onAPlan =
      transaction.creditDebtId != nil && transaction.creditDebtId == creditDebt?.id
      && creditDebt?.isInstalmentPlan == true && transaction.externalId == nil
    guard !transaction.isDeleted, transaction.kind == .expense,
      transaction.creditDebtId == nil || onAPlan, transaction.debtId == nil,
      entry.parts.contains(where: { $0.id == part.id })
    else { return false }
    guard !part.reimbursable else { return false }
    guard
      !QualityResolver.isGoalContribution(
        goalId: part.goalId, categoryId: part.categoryId, categories: tree)
    else { return false }
    return OperationLink(externalId: transaction.externalId)?.isBookkeeping != true
  }

  /// What `account` received for a refund of `amount` in `currency` on `day`, to prefill
  /// «Списано со счёта» — here what came onto the account —, editable: `nil` when the account
  /// holds the currency, or when a rate of the day is missing and the figure is typed.
  ///
  /// At the rates of the refund's day, in rubles too: the refund carries the purchase's rate for
  /// its own rubles, and `AccountRules.prefillLeg` would take that one.
  public static func prefillLeg(
    amount: AmountE4, currency: CurrencyCode, day: DateOnly, account: PaymentMethod,
    rates: DayRates
  ) -> AmountE4? {
    AccountRules.prefillLeg(
      amount: amount, currency: currency, rate: nil, day: day, account: account, rates: rates)
  }

  /// Whether the operation is a refund that takes money back from a purchase part.
  public static func takesBack(_ entry: TransactionEntry) -> Bool {
    entry.transaction.kind == .refund && entry.parts.contains { $0.refundOfPartId != nil }
  }

  /// The same for a draft.
  public static func takesBack(_ draft: TransactionDraft) -> Bool {
    draft.kind == .refund && draft.parts.contains { $0.refundOfPartId != nil }
  }

  /// What is left of the part to refund, in the purchase's currency.
  public static func remaining(part: TransactionPart, index: RefundIndex) -> AmountE4 {
    max(.zero, part.amountE4 - index.refunded(part: part.id))
  }

  /// The rubles a new refund of `amount` stores: what is left of the part's rubles when it
  /// completes the part — so the stored rubles of all its refunds add up to the part exactly —
  /// otherwise its share of the part's rubles. For display and the export only: the rubles
  /// taken off the purchase are worked out from the part itself (`RefundIndex`).
  ///
  /// A refund brings money back, so its rubles are above zero: when the refunds before it
  /// stored as much as the part is worth now, or more — its rate was edited down after them —
  /// nothing is left to complete it with, and it stores its own share at the part's rate
  /// instead.
  public static func rubles(
    refundAmount amount: AmountE4, part: TransactionPart,
    refundedBefore: (amount: AmountE4, rub: AmountE4)
  ) -> AmountE4 {
    let rest = part.amountRubE4 - refundedBefore.rub
    if amount == part.amountE4 - refundedBefore.amount, rest.raw > 0 {
      return rest
    }
    guard !part.amountE4.isZero else { return .zero }
    let exact = amount.decimal * part.amountRubE4.decimal / part.amountE4.decimal
    return (try? AmountE4(decimal: exact)) ?? .zero
  }

  /// What the refunds of the part already took back, in amount and in stored rubles — what
  /// `rubles(refundAmount:part:refundedBefore:)` needs for the next one.
  public static func refundedBefore(
    part: TransactionPart, index: RefundIndex
  ) -> (amount: AmountE4, rub: AmountE4) {
    (index.refunded(part: part.id), index.refundedStoredRub(part: part.id))
  }

  /// The live refunds of a purchase as they follow it once its rate or rubles changed — by the
  /// bank's refinement or by the owner's own edit: each refund part's rubles worked out again
  /// from its purchase part (`rubles(refundAmount:part:refundedBefore:)`), the refunds taken in
  /// the order given — oldest first —, each refund carrying the purchase's rate, rate date,
  /// source and provisional flag, and its rubles the sum of its parts. What came onto the
  /// account (the refund's own charge) never changes: balances do not move.
  ///
  /// 100 $ bought at 90 (9,000 ₽) with 90 $ refunded (8,100 ₽): the rate edited to 50 makes the
  /// purchase 5,000 ₽ and the refund 4,500 ₽; a later refund of the last 10 $ then completes the
  /// part with 500 ₽.
  ///
  /// Only the refunds that change come back; `updated_at` is the writer's.
  public static func following(
    purchase: TransactionEntry, refunds: [TransactionEntry]
  ) -> [TransactionEntry] {
    let parts = Dictionary(
      purchase.parts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var before: [UUID: (amount: AmountE4, rub: AmountE4)] = [:]
    var changed: [TransactionEntry] = []
    for refund in refunds where !refund.transaction.isDeleted && refund.transaction.kind == .refund
    {
      var next = refund
      var touched = false
      for index in next.parts.indices {
        guard let partId = next.parts[index].refundOfPartId, let part = parts[partId] else {
          continue
        }
        touched = true
        let taken = before[partId] ?? (.zero, .zero)
        let rubles = rubles(
          refundAmount: next.parts[index].amountE4, part: part, refundedBefore: taken)
        before[partId] = (taken.amount + next.parts[index].amountE4, taken.rub + rubles)
        next.parts[index].amountRubE4 = rubles
      }
      guard touched else { continue }
      let source = purchase.transaction
      next.transaction.rate = source.rate
      next.transaction.rateDate = source.rateDate
      next.transaction.rateSource = source.rateSource
      next.transaction.rateProvisional = source.rateProvisional
      next.transaction.amountRubE4 = AmountE4.sum(next.parts.map(\.amountRubE4))
      if next != refund { changed.append(next) }
    }
    return changed
  }

  /// The refund of `amount` of `part` — «Вся сумма» when `amount` is nil: what is left of it.
  ///
  /// A refund in the purchase's currency at the purchase's rate, with one part that takes back
  /// from `part` and carries its category, quality, «на кого», person and event; the place is
  /// the purchase's, and so is the account unless `accountId` names another. What it copies is
  /// for display: the figures follow the purchase part, so later edits of the purchase are not
  /// carried over to the refund.
  ///
  /// The draft is materialized with the rubles of `rubles(refundAmount:part:refundedBefore:)`
  /// as its converter; the rate stays the purchase's.
  public static func draft(
    refunding part: TransactionPart, of purchase: TransactionEntry, amount: AmountE4?,
    occurredAt: Date, accountId: UUID?, index: RefundIndex, tree: CategoryTree
  ) throws -> TransactionDraft {
    guard isRefundable(part: part, in: purchase, tree: tree) else {
      throw RefundError.notRefundable
    }
    let left = remaining(part: part, index: index)
    let refund = amount ?? left
    guard refund.raw > 0 else {
      throw amount == nil ? RefundError.exceedsRemaining : RefundError.notPositive
    }
    guard refund <= left else { throw RefundError.exceedsRemaining }
    let transaction = purchase.transaction
    return TransactionDraft(
      kind: .refund,
      occurredAt: occurredAt,
      currency: transaction.currency,
      amount: refund,
      rate: transaction.rate,
      rateDate: transaction.rateDate,
      rateSource: transaction.rateSource,
      rateProvisional: transaction.rateProvisional,
      note: part.note ?? transaction.note,
      placeId: transaction.placeId,
      paymentMethodId: accountId ?? transaction.paymentMethodId,
      parts: [
        PartDraft(
          categoryId: part.categoryId,
          categorySource: part.categorySource,
          quality: part.quality,
          qualitySource: part.qualitySource,
          amount: refund,
          forWhom: part.forWhom,
          forPersonId: part.forPersonId,
          eventId: part.eventId,
          refundOfPartId: part.id)
      ])
  }
}

/// What a returned thing bought in instalments does to the money: the bank lowers the debt, or
/// gives the money back to the card.
public enum InstalmentReturnChoice: String, Hashable, Sendable, CaseIterable {
  case reducesDebt
  case toCard
}

/// The money of a returned thing bought in instalments: what goes to the account, what lowers
/// the debt.
public struct InstalmentReturnSplit: Hashable, Sendable {
  public var toDebtE4: AmountE4
  public var toAccountE4: AmountE4

  public init(toDebtE4: AmountE4, toAccountE4: AmountE4) {
    self.toDebtE4 = toDebtE4
    self.toAccountE4 = toAccountE4
  }
}

extension RefundRules {
  /// How the money of a returned thing bought in instalments splits. When the bank lowers the
  /// debt (`.reducesDebt`), what was already paid off the price comes back to the account — never
  /// more than the refund —, the rest closes the debt, never more than is left on it; what the
  /// debt cannot hold comes back to the account too. When the money comes back to the card
  /// (`.toCard`), all of it goes to the account and the debt is left alone.
  public static func instalmentReturn(
    refund: AmountE4, debt: Debt, balance: AmountE4, paidPrincipal: AmountE4,
    choice: InstalmentReturnChoice
  ) -> InstalmentReturnSplit {
    let money = refund.magnitude
    guard choice == .reducesDebt, debt.direction == .iOwe, !debt.closed else {
      return InstalmentReturnSplit(toDebtE4: .zero, toAccountE4: money)
    }
    let back = min(money, max(paidPrincipal, .zero))
    let toDebt = min(money - back, max(balance, .zero))
    return InstalmentReturnSplit(toDebtE4: toDebt, toAccountE4: money - toDebt)
  }

  /// The key of the part of an instalment return that lowers the debt: `instreturn:<return>:debt`.
  public static func instalmentReturnKey(of refundId: UUID) -> String {
    "instreturn:" + refundId.uuidString.lowercased() + ":debt"
  }

  /// `key` when it is the key of the part of an instalment return that lowers the debt, else
  /// `nil`.
  public static func instalmentReturnKey(ofKey key: String?) -> String? {
    guard let key, key.hasPrefix("instreturn:"), key.hasSuffix(":debt") else { return nil }
    return key
  }
}
