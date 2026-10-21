import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// The journal line of an operation follows the operation when it is edited, since a payment
/// lowers its debt at the same moment: the amount, the day and the debt the edit changed, and
/// nothing it did not.
@Suite("An edited operation takes its journal line along")
struct DebtJournalEditTests {
  let loan = Debt(id: id(200), direction: .iOwe, type: .loan, name: "Loan")
  let card = Debt(id: id(201), direction: .iOwe, type: .loan, name: "Card")
  let phone = Debt(
    id: id(202), direction: .iOwe, type: .installment, name: "Phone", paymentsAreExpenses: false,
    origin: .purchase)
  let lent = Debt(id: id(203), direction: .owedToMe, type: .personal, name: "Friend")
  let dollars = Debt(
    id: id(204), direction: .iOwe, type: .loan, name: "Dollars", currency: CurrencyCode("USD"))

  private var debts: [UUID: Debt] {
    Dictionary(uniqueKeysWithValues: [loan, card, phone, lent, dollars].map { ($0.id, $0) })
  }

  private func operation(
    _ amount: Int, kind: TransactionKind = .expense, on iso: String = "2026-03-10",
    debtId: UUID? = nil, creditDebtId: UUID? = nil
  ) -> Transaction {
    entry(
      id(1), kind: kind, on: iso, note: "Loan", debtId: debtId, creditDebtId: creditDebtId,
      parts: [part(id(2), amount: money(amount))]
    ).transaction.with(amount: money(amount))
  }

  private func paymentLine(
    _ amount: Int, on debt: Debt, kind: DebtEntryKind = .payment
  )
    -> DebtEntry
  {
    DebtRules.makeEntry(
      id: id(300), debtId: debt.id, kind: kind, amountE4: money(amount), date: day("2026-03-10"),
      groupName: "Monthly", description: "Loan", transactionId: id(1), note: "kept")
  }

  private func journal(
    _ lines: [DebtEntry], from before: Transaction, to after: Transaction
  ) throws -> DebtJournalEdit {
    try DebtRules.journal(
      of: lines, afterEditing: before, into: after, debts: debts, calendar: .utc)
  }

  @Test func aNewAmountIsTheNewAmountOfTheLineSignedByItsKind() throws {
    let line = paymentLine(8_500, on: loan)
    let edit = try journal(
      [line], from: operation(8_500, debtId: loan.id), to: operation(8_000, debtId: loan.id))

    var expected = line
    expected.amountE4 = money(-8_000)
    #expect(edit == DebtJournalEdit(upsert: [expected]))
  }

  @Test func aNewDayAndANewDebtMoveTheLineAndKeepEverythingElse() throws {
    let line = paymentLine(8_500, on: loan)
    let edit = try journal(
      [line], from: operation(8_500, debtId: loan.id),
      to: operation(8_500, on: "2026-04-02", debtId: card.id))

    var expected = line
    expected.debtId = card.id
    expected.date = day("2026-04-02")
    #expect(edit == DebtJournalEdit(upsert: [expected]))
    #expect(edit.upsert.first?.groupName == "Monthly")
    #expect(edit.upsert.first?.note == "kept")
  }

  @Test func anEditThatLeavesTheMoneyAloneLeavesTheLineAlone() throws {
    var renamed = operation(8_500, debtId: loan.id)
    renamed.note = "Another note"
    renamed.occurredAt = renamed.occurredAt.addingTimeInterval(3_600)
    let edit = try journal(
      [paymentLine(8_500, on: loan)], from: operation(8_500, debtId: loan.id), to: renamed)
    #expect(edit.isEmpty)
  }

  @Test func theDebtTakenAwayTakesTheLineAway() throws {
    let edit = try journal(
      [paymentLine(8_500, on: loan)], from: operation(8_500, debtId: loan.id),
      to: operation(8_500))
    #expect(edit == DebtJournalEdit(delete: [id(300)]))
  }

  /// A debt chosen in the editor for an ordinary expense gets the line the entry line would
  /// have written; an operation that always pointed at its debt without one is not given one.
  @Test func aDebtChosenInTheEditGetsTheLineTheEntryLineWouldHaveWritten() throws {
    let edit = try journal([], from: operation(8_500), to: operation(8_500, debtId: loan.id))
    #expect(edit.upsert.count == 1)
    #expect(edit.upsert.first?.debtId == loan.id)
    #expect(edit.upsert.first?.kind == .payment)
    #expect(edit.upsert.first?.amountE4 == money(-8_500))
    #expect(edit.upsert.first?.transactionId == id(1))
    #expect(edit.upsert.first?.date == day("2026-03-10"))

    let older = try journal(
      [], from: operation(8_500, debtId: loan.id), to: operation(8_000, debtId: loan.id))
    #expect(older.isEmpty)
  }

  /// Money I gave on a debt owed to me grows it; turned into money that came back, the same
  /// operation pays it.
  @Test func aChangeOfKindChangesWhetherTheMoneyGrowsOrPaysTheDebt() throws {
    let lending = paymentLine(5_000, on: lent, kind: .borrowed)
    let edit = try journal(
      [lending], from: operation(5_000, debtId: lent.id),
      to: operation(5_000, kind: .reimbursement, debtId: lent.id))
    #expect(edit.upsert.map(\.kind) == [.payment])
    #expect(edit.upsert.map(\.amountE4) == [money(-5_000)])
  }

  /// «В этом месяце больше платежей не будет» is the word of a payment only: a payment that
  /// closed its term, edited into money that grows the debt, no longer closes anything.
  @Test func aLineThatStopsBeingAPaymentStopsClosingItsTerm() throws {
    var closing = paymentLine(5_000, on: loan)
    closing.closesTerm = true
    let edit = try journal(
      [closing], from: operation(5_000, debtId: loan.id),
      to: operation(5_000, kind: .income, debtId: loan.id))
    #expect(edit.upsert.map(\.kind) == [.borrowed])
    #expect(edit.upsert.map(\.closesTerm) == [false])
  }

  @Test func theOpeningLineOfAPurchaseOnCreditFollowsItsPrice() throws {
    let opening = try DebtRules.creditPurchaseOpening(
      on: phone, amountE4: money(60_000), date: day("2026-03-10"), transactionId: id(1),
      entryId: id(301))
    let edit = try journal(
      [opening], from: operation(60_000, creditDebtId: phone.id),
      to: operation(55_000, creditDebtId: phone.id))
    #expect(edit.upsert.map(\.id) == [id(301)])
    #expect(edit.upsert.map(\.amountE4) == [money(55_000)])
    #expect(edit.upsert.map(\.kind) == [.borrowed])
  }

  @Test func aDebtInAnotherCurrencyIsRefused() {
    #expect(throws: EditRefusal.debtCurrency) {
      try journal(
        [paymentLine(8_500, on: loan)], from: operation(8_500, debtId: loan.id),
        to: operation(8_500, debtId: dollars.id))
    }
  }

  /// The rule of the entry line and of the edit is one rule.
  @Test func whetherMoneyGrowsADebtDependsOnItsDirection() {
    #expect(DebtRules.operationGrows(.expense, lent))
    #expect(DebtRules.operationGrows(.income, loan))
    #expect(!DebtRules.operationGrows(.expense, loan))
    #expect(!DebtRules.operationGrows(.reimbursement, lent))
    // Money back on a debt I owe — a loan payment refunded — undoes a payment: the debt grows
    // back. On a debt owed to me money back pays it.
    #expect(DebtRules.operationGrows(.refund, loan))
    #expect(DebtRules.operationGrows(.reimbursement, loan))
    #expect(!DebtRules.operationGrows(.refund, lent))
    #expect(!DebtRules.operationGrows(.income, lent))
  }
}

extension Transaction {
  fileprivate func with(amount: AmountE4) -> Transaction {
    var copy = self
    copy.amountE4 = amount
    copy.amountRubE4 = amount
    return copy
  }
}
