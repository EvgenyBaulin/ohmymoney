import CoreKit
import Foundation

/// Which refunds take money back from which part of which purchase, over one set of
/// operations.
///
/// A refund part is *linked* when its operation is a live refund and `refundOfPartId` names a
/// part of a live purchase. Anything else — a refund with no purchase, or one whose purchase
/// is gone — counts as a refund of its own, as refunds always did.
///
/// A linked refund is counted in the purchase — on its day, in its month, in its category —
/// as if the purchase had been cheaper, while the money moves on the account at the refund's
/// own moment. The rubles taken off the purchase are worked out from the purchase part itself,
/// never added up from the refunds' stored rubles: a full refund takes the part to zero exactly,
/// whatever was edited afterwards — the rate of the purchase, its amount, the refund's amount.
public struct RefundIndex: Hashable, Sendable {
  /// A purchase part and what was taken back from it.
  private struct Purchase: Hashable, Sendable {
    var part: TransactionPart
    /// Whether the part counts as my spending at all: only then does a refund take anything
    /// off my spending.
    var counts: Bool
    var refunded: AmountE4 = .zero
    var storedRub: AmountE4 = .zero
    var refunds: [UUID] = []
  }

  private var purchases: [UUID: Purchase] = [:]
  private var purchaseOfRefundPart: [UUID: UUID] = [:]

  public static let empty = RefundIndex()

  private init() {}

  /// `debts` decides whether a purchase part is my spending at all (`MyExpensesRule`): a
  /// payment on a debt that is no expense has nothing a refund could take off.
  public init(entries: some Sequence<TransactionEntry>, debts: [UUID: Debt]) {
    var refunds: [TransactionEntry] = []
    for entry in entries where !entry.transaction.isDeleted {
      let transaction = entry.transaction
      switch transaction.kind {
      case .expense:
        let debt = transaction.debtId.flatMap { debts[$0] }
        let creditDebt = transaction.creditDebtId.flatMap { debts[$0] }
        for part in entry.parts {
          purchases[part.id] = Purchase(
            part: part,
            counts: MyExpensesRule.isMySpending(
              part: part, in: transaction, debt: debt, creditDebt: creditDebt))
        }
      case .refund:
        if entry.parts.contains(where: { $0.refundOfPartId != nil }) { refunds.append(entry) }
      case .income, .reimbursement:
        continue
      }
    }
    // Oldest refund first, so the list of each part reads in the order the money came back.
    refunds.sort { left, right in
      if left.transaction.occurredAt != right.transaction.occurredAt {
        return left.transaction.occurredAt < right.transaction.occurredAt
      }
      return left.id.uuidString < right.id.uuidString
    }
    for refund in refunds {
      for part in refund.parts {
        guard let target = part.refundOfPartId, var purchase = purchases[target] else { continue }
        purchase.refunded += part.amountE4
        purchase.storedRub += part.amountRubE4
        if purchase.refunds.last != refund.id { purchase.refunds.append(refund.id) }
        purchases[target] = purchase
        purchaseOfRefundPart[part.id] = target
      }
    }
  }

  public var isEmpty: Bool { purchaseOfRefundPart.isEmpty }

  /// A part of a live refund that takes back from a part of a live purchase.
  public func isLinked(refundPart: UUID) -> Bool { purchaseOfRefundPart[refundPart] != nil }

  /// The purchase part a linked refund part takes back from.
  public func purchasePart(ofRefundPart refundPart: UUID) -> UUID? {
    purchaseOfRefundPart[refundPart]
  }

  /// What the linked refunds took back from the part, in the purchase's currency.
  public func refunded(part: UUID) -> AmountE4 { purchases[part]?.refunded ?? .zero }

  /// The rubles the refunds took back from the part, from the part itself: all of its rubles
  /// once the whole part came back, otherwise its rubles in proportion to what came back.
  public func refundedRub(part: UUID) -> AmountE4 {
    guard let purchase = purchases[part], !purchase.refunded.isZero else { return .zero }
    return Self.rubles(of: purchase.refunded, from: purchase.part)
  }

  /// What the refunds of the part take off my spending: nothing while the part is not my
  /// spending, otherwise its refunded rubles, as a negative amount.
  public func movedContribution(part: UUID) -> AmountE4 {
    guard let purchase = purchases[part], purchase.counts else { return .zero }
    return -refundedRub(part: part)
  }

  /// The live refunds that take back from the part, oldest first.
  public func refunds(ofPart part: UUID) -> [UUID] { purchases[part]?.refunds ?? [] }

  /// The stored rubles of the linked refunds of the part — for display and for the rubles of
  /// the next refund, which close the part to its rubles exactly (`RefundRules.rubles`).
  public func refundedStoredRub(part: UUID) -> AmountE4 { purchases[part]?.storedRub ?? .zero }

  /// The purchase parts with a linked refund.
  public var refundedParts: [UUID] { purchases.filter { !$0.value.refunds.isEmpty }.map(\.key) }

  /// The rubles of `amount` of `part`: all of them once `amount` covers the part.
  static func rubles(of amount: AmountE4, from part: TransactionPart) -> AmountE4 {
    guard amount < part.amountE4, !part.amountE4.isZero else { return part.amountRubE4 }
    let exact = part.amountRubE4.decimal * amount.decimal / part.amountE4.decimal
    return (try? AmountE4(decimal: exact)) ?? part.amountRubE4
  }
}
