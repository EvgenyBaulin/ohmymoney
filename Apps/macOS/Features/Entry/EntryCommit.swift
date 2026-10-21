import AppCore
import AppDatabase
import Foundation
import SwiftUI

/// What saving the entry line writes besides the operation itself, as one change of planning
/// and so one step of ⌘Z: a debt opened for a purchase on credit and its first line — both
/// pointing at the purchase, so ⌘Z takes them away with it instead of leaving the debt
/// behind — the line a debt payment moves its debt by, and the link of income to what was
/// expected. `nil` when the operation is all there is: then the store saves it the usual way.
/// `openingLine`: the first line of a new instalment plan, which owes the markup too.
enum EntryCommit {
  /// The debt is kept in another currency than the operation: its journal counts its own
  /// units, and rubles are never taken for dollars (review of the app, 19.09).
  struct CurrencyMismatch: Error {}

  /// A debt opened «on credit» for anything but a purchase: an income or a refund buys
  /// nothing, and a debt for it would be paid off by nothing.
  struct CreditNotPurchase: Error {}

  /// What the entry line says when saving threw. The line has been read and its expression
  /// calculated by then, so nothing thrown here is «the expression cannot be calculated»: an
  /// amount too large for rubles says so, and a failure nobody foresaw says the operation was
  /// not saved — and goes to the journal by its type, which the words on screen do not name.
  static func errorKey(of error: any Error) -> String {
    switch error {
    case is CurrencyMismatch: return "entry.error.debtCurrency"
    case is CreditNotPurchase: return "entry.error.creditNotPurchase"
    case MoneyConversionError.rateMissing: return "entry.error.rateMissing"
    // A refund of a purchase: more than is left of it — another refund came meanwhile — or a
    // purchase that can no longer be refunded.
    case RefundError.exceedsRemaining: return "entry.error.refundExceedsRemaining"
    case RefundError.notPositive: return "entry.error.amountNotPositive"
    case RefundError.otherCurrency: return "entry.error.refundOtherCurrency"
    case RefundError.notRefundable, RefundError.purchaseHasRefunds:
      return "entry.error.refundNotRefundable"
    case ReimbursementRecording.Failure.noSurchargesCategory: return "reimbursement.noSurcharges"
    case CoreError.divisionByZero: return "entry.error.divisionByZero"
    case CoreError.amountOutOfRange: return "entry.error.amountTooLarge"
    default:
      AppLog.error(
        "entry.saveFailed", .db, "the entry line could not save an operation",
        [LogPair("error", .error(error))])
      return "entry.error.notSaved"
    }
  }

  /// Where money given back above a debt owed to me goes: the system Surcharges category and
  /// the note of that income, in the interface language.
  struct SurplusSetting: Hashable {
    var categoryId: UUID?
    var note: String?
  }

  /// `paidDebtBalance` — what was left on `paidDebt` when the line saves: money given back on a
  /// debt owed to me then follows the one rule of repayments (`DebtRules.repayment`) — the
  /// journal takes what was owed, the debt closes once covered, and what came back above it is
  /// income in «Доплаты» (`surplus` says where; without its category the save is refused with
  /// `ReimbursementRecording.Failure.noSurchargesCategory`), all in the one change. Without a
  /// balance the whole amount is the payment, as before.
  static func change(
    entry: TransactionEntry, openedCredit: Debt?, creditIsNew: Bool = true, paidDebt: Debt?,
    expectedIncomeId: UUID?, day: DateOnly, paidDebtBalance: AmountE4? = nil,
    surplus: SurplusSetting? = nil, closesTerm: Bool = false, openingLine: DebtEntry? = nil,
    now: Date = Date()
  ) throws -> PlanningChange? {
    var rows = PlanningRows.empty
    var created = [entry]
    let note = entry.transaction.note
    if let debt = openedCredit {
      guard entry.transaction.kind.canBeBoughtOnCredit else { throw CreditNotPurchase() }
      guard debt.currency == entry.transaction.currency else { throw CurrencyMismatch() }
      if creditIsNew { rows.debts = [debt] }
      // An instalment plan opens with its own line — the price and the markup together
      // (`InstalmentPlan.make`); a credit with the price.
      if let openingLine, openingLine.debtId == debt.id {
        rows.debtEntries.append(openingLine)
      } else {
        rows.debtEntries.append(
          try DebtRules.creditPurchaseOpening(
            on: debt, amountE4: entry.transaction.amountE4, date: day, transactionId: entry.id,
            description: note))
      }
    }
    if let debt = paidDebt {
      guard debt.currency == entry.transaction.currency else { throw CurrencyMismatch() }
      if DebtRules.operationGrows(entry.transaction.kind, debt) {
        // Money I gave on a debt owed to me — I lent more — or money I got on a debt I owe —
        // I borrowed more: the debt grows. Only money that flows the paying way pays it.
        rows.debtEntries.append(
          DebtRules.makeEntry(
            debtId: debt.id, kind: .borrowed, amountE4: entry.transaction.amountE4, date: day,
            description: note, transactionId: entry.id))
      } else if debt.direction == .owedToMe, let balance = paidDebtBalance {
        let outcome = try DebtRules.repayment(
          on: debt, by: entry.transaction, balance: balance, date: day, description: note)
        if let line = outcome.line { rows.debtEntries.append(line) }
        if outcome.closes, !debt.closed {
          var closed = debt
          closed.closed = true
          rows.debts.append(closed)
        }
        if let income = outcome.surplus {
          guard let categoryId = surplus?.categoryId else {
            throw ReimbursementRecording.Failure.noSurchargesCategory
          }
          let transaction = entry.transaction
          created.append(
            try MoneyBack.surplusEntry(
              income, of: entry.id, on: transaction.occurredAt, now: now,
              rate: income.currency == .rub ? nil : transaction.rate,
              rateDate: transaction.rateDate, categoryId: categoryId, note: surplus?.note))
        }
      } else {
        let outcome = try DebtRules.payment(
          on: debt, amountE4: entry.transaction.amountE4, date: day, transactionId: entry.id,
          description: note, closesTerm: closesTerm)
        rows.debtEntries.append(outcome.entry)
      }
    }
    if let expectedIncomeId, entry.transaction.kind == .income {
      rows.expectedLinks = [
        ExpectedIncomeLink(expectedIncomeId: expectedIncomeId, transactionId: entry.id)
      ]
    }
    guard rows != .empty || created.count > 1 else { return nil }
    return PlanningChange(created: created, upsert: rows)
  }
}
