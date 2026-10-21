import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// «Уже списано до сверки» of a debt's due, as the database keeps it: an ordinary `payment`
/// line of the journal, with no operation, no account and no moment — the columns 1.1 already
/// had — and one step of ⌘Z.
@Suite("A debt due closed as taken before a count")
struct DueSettlementStorageTests {
  @Test func aSettledDebtDueIsAPaymentLineWithoutMoney() throws {
    let stack = try TestSupport.makeStack()
    let repository = PlanningRepository(writer: stack.writer)
    let loan = Debt(
      direction: .iOwe, type: .loan, name: "Loan", monthlyPaymentE4: AmountE4(whole: 8_000),
      paymentDay: 5)
    var rows = PlanningRows.empty
    rows.debts = [loan]
    rows.debtEntries = [
      DebtEntry(
        debtId: loan.id, date: DateOnly(year: 2026, month: 8, day: 20),
        amountE4: AmountE4(whole: 80_000), kind: .adjustment)
    ]
    _ = try repository.apply(PlanningChange(upsert: rows))

    let due = DateOnly(year: 2026, month: 9, day: 5)
    let line = try #require(
      DebtRules.settledByCount(debt: loan, due: due, balance: AmountE4(whole: 80_000)))
    var settled = PlanningRows.empty
    settled.debtEntries = [line]
    let undo = try repository.apply(PlanningChange(upsert: settled))

    let journal = try repository.book().debtEntries.filter { $0.debtId == loan.id }
    let stored = try #require(journal.first { $0.id == line.id })
    #expect(stored == line)
    #expect(stored.kind == .payment)
    #expect(stored.amountE4 == AmountE4(whole: -8_000))
    #expect(stored.date == due)
    #expect(stored.transactionId == nil)
    #expect(stored.paymentMethodId == nil)
    #expect(stored.occurredAt == nil)
    #expect(stored.accountCurrency == nil)
    #expect(DebtRules.balance(entries: journal) == AmountE4(whole: 72_000))

    try repository.revert(undo)
    #expect(try repository.book().debtEntries.contains { $0.id == line.id } == false)
  }
}
