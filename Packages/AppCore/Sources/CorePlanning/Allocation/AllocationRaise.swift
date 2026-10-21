import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// «На X больше обычного»: an income above the usual of its source.
public struct AllocationRaise: Hashable, Sendable {
  /// The income less the usual, in the currency of the income.
  public var differenceE4: AmountE4
  /// The median of the last three incomes of the source.
  public var usualE4: AmountE4

  public init(differenceE4: AmountE4, usualE4: AmountE4) {
    self.differenceE4 = differenceE4
    self.usualE4 = usualE4
  }

  /// The raise must be above the usual by this share, in basis points (5 %).
  public static let thresholdBp = 500
  /// …and by at least this many rubles.
  public static let minimumRub = AmountE4(whole: 3_000)

  /// «На X больше обычного»: the source of the income is the expectation it is linked to,
  /// else its category (the subcategory, as filed). The usual is the median of the last three
  /// incomes of the source before it, in its currency; a raise is an income above the usual by
  /// more than 5 % and by 3,000 ₽ or more (in rubles at the rate the income was written at).
  /// Fewer than three earlier incomes — no usual, no raise.
  public static func detect(
    income: TransactionEntry, ledger: Ledger, links: [ExpectedIncomeLink]
  ) -> AllocationRaise? {
    let transaction = income.transaction
    guard transaction.kind == .income, !transaction.isDeleted, transaction.amountE4.raw > 0
    else { return nil }
    let expected = links.first { $0.transactionId == income.id }?.expectedIncomeId
    var earlier: [TransactionEntry]
    if let expected {
      let ids = Set(
        links.filter { $0.expectedIncomeId == expected && $0.transactionId != income.id }
          .map(\.transactionId))
      earlier = ids.compactMap { ledger.entry($0) }
    } else {
      guard let category = income.parts.first?.categoryId else { return nil }
      earlier = ledger.entries.filter { entry in
        entry.id != income.id && entry.transaction.kind == .income
          && entry.parts.first?.categoryId == category
      }
    }
    earlier = earlier.filter {
      !$0.transaction.isDeleted && $0.transaction.currency == transaction.currency
        && $0.transaction.occurredAt < transaction.occurredAt
    }
    .sorted { $0.transaction.occurredAt > $1.transaction.occurredAt }
    guard earlier.count >= 3 else { return nil }
    let last = earlier.prefix(3).map(\.transaction.amountE4).sorted()
    let usual = last[1]
    let difference = transaction.amountE4 - usual
    guard difference.raw > 0,
      transaction.amountE4.raw * 10_000 > usual.raw * Int64(10_000 + thresholdBp)
    else { return nil }
    let rubles =
      transaction.currency == .rub
      ? difference
      : InterestMath.cents(
        difference.decimal * transaction.amountRubE4.decimal / transaction.amountE4.decimal)
    guard rubles >= minimumRub else { return nil }
    return AllocationRaise(differenceE4: difference, usualE4: usual)
  }
}
