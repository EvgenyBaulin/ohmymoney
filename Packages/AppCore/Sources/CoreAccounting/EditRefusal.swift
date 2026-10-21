import CoreKit
import Foundation

/// Why the edit of one saved operation — in the inspector or the edit sheet — is not
/// written. The app turns each case into words; nothing of the edit lands.
public enum EditRefusal: Error, Hashable, Sendable, CaseIterable {
  /// The operation moves a debt kept in another currency: its journal counts the debt's own
  /// units, and rubles are never taken for dollars — the rule the entry line keeps too.
  case debtCurrency
  /// The money of a reimbursement that closed parts, or of the surplus or a shortfall it
  /// left: the links, the statuses of the closed parts and those operations were all worked
  /// out from that money. Another amount, type or currency written over it would leave them
  /// telling the old story. It is changed by deleting the reimbursement — which takes all of
  /// it along — and recording it again.
  case settledReimbursement
  /// The edit takes away a part a reimbursement closed: that reimbursement would close
  /// nothing, and its shortfall would be my spending on a part that is not there. The
  /// reimbursement is deleted first, which opens the part again.
  case closedPartRemoved
  /// The edit changes the money of a part a reimbursement closed — takes «paid for someone»
  /// off it, gives it another amount, or the operation another currency or type. The part
  /// is off my spending because its money came back, and the link holds how much: un-ticked,
  /// the part would be my spending while the money still counted as returned — in neither
  /// income nor a reduction of spending; re-amounted, the link would tell the old sum. The
  /// reimbursement is deleted first, which opens the part again.
  case closedPartChanged
}

/// Why the edit of the difference a count recorded is not written. Nothing of the edit lands.
public enum DifferenceEditRefusal: Error, Hashable, Sendable, CaseIterable {
  /// The operation is the difference of a count (`reconcile:<reconciliation>:<count>`), and the
  /// edit changes what follows the count by itself — its amount, type, account, what the account
  /// was charged, currency, moment, or the debt it pays — or files it under «Цели» or a category
  /// the app keeps for itself: lost money would turn into a contribution to a goal, a payment of
  /// a debt or money given back, and the next count's settle would write over an amount typed by
  /// hand. Its category, comment, «на кого» and rating stay the owner's; deleting it stops the
  /// count from recording.
  case reconciliationDifference
}

/// Why the edit of one saved operation is not written because a refund or money back leans on
/// what it changes. Nothing of the edit lands.
public enum LinkedEditRefusal: Error, Hashable, Sendable, CaseIterable {
  /// The edit takes away a part a live refund takes money back from: the refund would take
  /// back from nothing. The refund is deleted first.
  case refundedPartRemoved
  /// The edit makes a part cheaper than what its refunds already took back.
  case refundedPartReduced
  /// The edit changes what a refund of a part was worked out from: the currency or the type of
  /// the purchase, the part made one paid for somebody else, or the purchase put on credit.
  case refundedPartChanged
  /// The edit changes the money of a part some money already came back for, while it still
  /// waits for the rest — its amount, «за другого», or the currency or the type of the
  /// purchase: the money back was spread over the part as it was. A new rate may change what is
  /// left of it, but not take its rubles down to what came back or below: the part would wait
  /// for nothing, and could be neither closed nor written off.
  case partlyReturnedPartChanged
  /// The edit of a refund taken back from a purchase makes it more than is left of that part
  /// to refund, or changes its currency or its type.
  case linkedRefundChanged
}

/// What only the database knows about an operation being edited, read inside the write.
public struct EditFacts: Hashable, Sendable {
  /// The operation is a reimbursement that closed parts or left a surplus or a shortfall.
  public var settles: Bool
  /// The rubles of the live money back that reached each part of the operation.
  public var linkedRubByPart: [UUID: AmountE4]
  /// What the live refunds took back from each part of the operation, in its currency.
  public var refundedByPart: [UUID: AmountE4]
  /// For each purchase part a part of the operation takes back from: what is left of it to
  /// refund, the operation's own refunds not counted, and its currency.
  public var refundOf: [UUID: RefundableRemainder]
  /// The categories that have a system role or hang under one (`CategoryTree.systemRole`):
  /// «Цели» and its goals, «Кредиты», «Доплаты», «Не помню». A difference of a count may not
  /// be filed there; read only when the operation is one.
  public var systemCategories: Set<UUID>

  public init(
    settles: Bool = false, linkedRubByPart: [UUID: AmountE4] = [:],
    refundedByPart: [UUID: AmountE4] = [:], refundOf: [UUID: RefundableRemainder] = [:],
    systemCategories: Set<UUID> = []
  ) {
    self.settles = settles
    self.linkedRubByPart = linkedRubByPart
    self.refundedByPart = refundedByPart
    self.refundOf = refundOf
    self.systemCategories = systemCategories
  }
}

/// What is left of a purchase part to refund, and in which currency.
public struct RefundableRemainder: Hashable, Sendable {
  public var remaining: AmountE4
  public var currency: CurrencyCode

  public init(remaining: AmountE4, currency: CurrencyCode) {
    self.remaining = remaining
    self.currency = currency
  }
}

/// What the edit of one saved operation may not do. The storage layer asks it inside the
/// write, of the row as it is then, with the facts only the database knows.
public enum OperationEditRule {
  /// Why `before` may not become `after`, or `nil` when it may: the refusal of a count's
  /// difference (`differenceRefusal`), the refusals of `refusal(editing:into:settles:)`, then
  /// those of refunds and of money back that covered only some of a part (`LinkedEditRefusal`).
  public static func refusal(
    editing before: TransactionEntry, into after: TransactionEntry, facts: EditFacts
  ) -> (any Error & Sendable)? {
    if let refusal = differenceRefusal(
      editing: before, into: after, systemCategories: facts.systemCategories)
    {
      return refusal
    }
    if let refusal = refusal(editing: before, into: after, settles: facts.settles) {
      return refusal
    }
    return linkedRefusal(editing: before, into: after, facts: facts)
  }

  /// Whether the operation is the difference a count recorded: its money follows the count.
  public static func isReconcileDifference(_ transaction: Transaction) -> Bool {
    if case .reconciledBalance = OperationLink(externalId: transaction.externalId) { return true }
    return false
  }

  /// Why the difference of a count may not become `after`, or `nil` when it may — and always
  /// `nil` for any other operation. Its money is the count's: the amount, the type, the account
  /// and what it was charged, the currency, the moment and the debt stay as they are, and a
  /// part moved into a category among `systemCategories` or given a goal is refused. A part
  /// already there — a difference of 1.1 filed under «Не помню» — may stay.
  public static func differenceRefusal(
    editing before: TransactionEntry, into after: TransactionEntry, systemCategories: Set<UUID>
  ) -> DifferenceEditRefusal? {
    guard isReconcileDifference(before.transaction) else { return nil }
    let old = before.transaction
    let new = after.transaction
    if old.kind != new.kind || old.amountE4 != new.amountE4 || old.currency != new.currency
      || old.paymentMethodId != new.paymentMethodId || old.accountCurrency != new.accountCurrency
      || old.accountAmountE4 != new.accountAmountE4 || old.occurredAt != new.occurredAt
      || old.debtId != new.debtId || old.creditDebtId != new.creditDebtId
    {
      return .reconciliationDifference
    }
    let was = Dictionary(
      before.parts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for part in after.parts {
      let earlier = was[part.id]
      if part.goalId != nil, part.goalId != earlier?.goalId { return .reconciliationDifference }
      if let category = part.categoryId, category != earlier?.categoryId,
        systemCategories.contains(category)
      {
        return .reconciliationDifference
      }
    }
    return nil
  }

  /// The refusals that protect refunds and money back that covered only some of a part.
  public static func linkedRefusal(
    editing before: TransactionEntry, into after: TransactionEntry, facts: EditFacts
  ) -> LinkedEditRefusal? {
    let old = before.transaction
    let new = after.transaction
    let edited = Dictionary(
      after.parts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    let refunded = before.parts.filter { (facts.refundedByPart[$0.id] ?? .zero).raw > 0 }
    if refunded.contains(where: { edited[$0.id] == nil }) { return .refundedPartRemoved }
    if !refunded.isEmpty {
      if old.kind != new.kind || old.currency != new.currency
        || (old.creditDebtId == nil && new.creditDebtId != nil)
      {
        return .refundedPartChanged
      }
      for part in refunded {
        guard let now = edited[part.id] else { continue }
        if now.reimbursable && !part.reimbursable { return .refundedPartChanged }
        if now.amountE4 < (facts.refundedByPart[part.id] ?? .zero) { return .refundedPartReduced }
      }
    }

    let partlyReturned = before.parts.filter {
      $0.reimbursable && ($0.reimbursementStatus ?? .expected) == .expected
        && (facts.linkedRubByPart[$0.id] ?? .zero).raw > 0
    }
    if !partlyReturned.isEmpty {
      if old.kind != new.kind || old.currency != new.currency {
        return .partlyReturnedPartChanged
      }
      for part in partlyReturned {
        guard let now = edited[part.id] else { return .partlyReturnedPartChanged }
        // The rubles may change — a rate or a charge corrected by hand: the money that came
        // back is balanced again in the same write (`MoneyBackSettlement`), and a part it now
        // covers closes, the money over it income.
        if now.amountE4 != part.amountE4 || now.reimbursable != part.reimbursable {
          return .partlyReturnedPartChanged
        }
      }
    }

    let takesBack = before.parts.contains { $0.refundOfPartId != nil }
    if takesBack && new.kind != .refund { return .linkedRefundChanged }
    var asked: [UUID: AmountE4] = [:]
    for part in after.parts {
      guard let target = part.refundOfPartId else { continue }
      asked[target, default: .zero] += part.amountE4
    }
    for (target, amount) in asked {
      guard let left = facts.refundOf[target] else { continue }
      if new.kind != .refund || new.currency != left.currency || amount > left.remaining {
        return .linkedRefundChanged
      }
    }
    return nil
  }

  /// Why `before` may not become `after`, or `nil` when it may.
  ///
  /// `settles` — `before` is a reimbursement that closed parts through its links or left a
  /// surplus or a shortfall. A surplus or a shortfall itself is known by its `external_id`
  /// (`OperationLink`).
  public static func refusal(
    editing before: TransactionEntry, into after: TransactionEntry, settles: Bool
  ) -> EditRefusal? {
    if settles || isCompanion(before.transaction),
      changesMoney(before.transaction, after.transaction)
    {
      return .settledReimbursement
    }
    let kept = Set(after.parts.map(\.id))
    let closed = before.parts.filter { $0.reimbursementStatus == .returned }
    if closed.contains(where: { !kept.contains($0.id) }) { return .closedPartRemoved }
    if changesClosedParts(closed, before: before.transaction, after: after) {
      return .closedPartChanged
    }
    return nil
  }

  /// Whether the edit touches what a reimbursement settled on these parts: that each is paid
  /// for somebody else and still closed, its amount, and the currency and the type of their
  /// operation. Rubles are left out: they follow the rate of the day, not the edit.
  private static func changesClosedParts(
    _ closed: [TransactionPart], before: Transaction, after: TransactionEntry
  ) -> Bool {
    guard !closed.isEmpty else { return false }
    if before.kind != after.transaction.kind || before.currency != after.transaction.currency {
      return true
    }
    let edited = Dictionary(
      after.parts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return closed.contains { part in
      guard let now = edited[part.id] else { return false }
      return !now.reimbursable || now.reimbursementStatus != .returned
        || now.amountE4 != part.amountE4
    }
  }

  /// The surplus or a shortfall of a reimbursement, or what is left of a part written off:
  /// each was worked out from money that came back, and is not edited in place.
  public static func isCompanion(_ transaction: Transaction) -> Bool {
    switch OperationLink(externalId: transaction.externalId) {
    case .surplus, .shortfall, .remainderWriteOff: true
    default: false
    }
  }

  /// What a reimbursement's resolver worked out from: how much, in what, and what it is.
  private static func changesMoney(_ before: Transaction, _ after: Transaction) -> Bool {
    before.kind != after.kind || before.amountE4 != after.amountE4
      || before.currency != after.currency
  }
}
