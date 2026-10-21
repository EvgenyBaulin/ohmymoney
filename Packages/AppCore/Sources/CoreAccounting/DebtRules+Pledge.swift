import CoreKit
import Foundation

extension DebtRules {
  /// The key of the expense of a pledge that did not come back: `pledgeloss:<debt>`.
  public static func pledgeLossKey(of debtId: UUID) -> String {
    "pledgeloss:" + debtId.uuidString.lowercased()
  }

  /// A pledge that did not come back, written off: the debt closed with what is left of it
  /// (`closing` with the remainder written off), the line of the journal that brings it to zero,
  /// and the expense of the loss in `categoryId` at noon of `day`, pointing at the pledge as a
  /// purchase on credit points at its debt (`creditDebtId`: spending, but no money moves — the
  /// money left when the pledge was given) under the key `pledgeloss:<debt>`. A pledge with
  /// nothing left is closed with a line and an expense of nothing.
  public static func writeOff(
    debt: Debt, balance: AmountE4, categoryId: UUID, day: DateOnly,
    calendar: CalendarContext = .system, now: Date = Date()
  ) -> (Debt, DebtEntry, TransactionEntry) {
    let left = max(balance, .zero)
    let expenseId = UUID()
    let (closed, closingLine) = closing(debt, balance: left, writeOffRemainder: true, date: day)
    let line =
      closingLine
      ?? makeEntry(debtId: debt.id, kind: .adjustment, amountE4: .zero, date: day)
    let transaction = Transaction(
      id: expenseId, kind: .expense, occurredAt: calendar.noon(of: day), currency: debt.currency,
      amountE4: left, amountRubE4: debt.currency == .rub ? left : .zero,
      creditDebtId: debt.id, externalId: pledgeLossKey(of: debt.id), createdAt: now,
      updatedAt: now)
    let part = TransactionPart(
      transactionId: expenseId, categoryId: categoryId, categorySource: .manual,
      amountE4: left, amountRubE4: transaction.amountRubE4)
    return (closed, line, TransactionEntry(transaction: transaction, parts: [part]))
  }
}
