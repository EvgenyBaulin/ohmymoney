import CoreKit
import Foundation

/// Income used by every total. A reconciliation changes a balance, not earnings.
public enum IncomeRule {
  public static func isIncome(kind: TransactionKind, link: OperationLink?) -> Bool {
    kind == .income && !MyExpensesRule.isCountDifference(link)
  }

  public static func isIncome(_ transaction: Transaction) -> Bool {
    isIncome(kind: transaction.kind, link: OperationLink(externalId: transaction.externalId))
  }
}
