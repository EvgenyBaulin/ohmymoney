import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// Deleting the payment that closed a debt: the lines it wrote leave the journal and the debt is
/// owed again, though it stays «closed». The deletion asks whether to open it again
/// (`DebtRules.closedByDeleting`), and answers for the debts it names only.
@Suite("A debt a deleted payment had closed")
struct DebtReopeningTests {
  /// Masha owed 1,000 ₽; 1,700 ₽ came back by the operation `back`: the line took 1,000 and the
  /// debt closed.
  let masha = Debt(
    id: id(1), direction: .owedToMe, type: .personal, name: "Masha", paymentsAreExpenses: false,
    closed: true)
  let back = id(10)

  func lent(_ debt: Debt, _ amount: Int64 = 1_000) -> DebtEntry {
    DebtRules.makeEntry(
      id: id(Int(debt.id.uuid.15) * 100 + 1), debtId: debt.id, kind: .borrowed,
      amountE4: AmountE4(whole: amount))
  }

  func payment(_ debt: Debt, _ amount: Int64, by operation: UUID, number: Int) -> DebtEntry {
    DebtRules.makeEntry(
      id: id(number), debtId: debt.id, kind: .payment, amountE4: AmountE4(whole: amount),
      transactionId: operation)
  }

  @Test func theDebtAPaymentHadClosedIsOfferedBack() {
    let journal = [lent(masha), payment(masha, 1_000, by: back, number: 20)]
    let found = DebtRules.closedByDeleting([back], debts: [masha], journal: journal)
    #expect(found.map(\.id) == [masha.id])
  }

  @Test func anotherOperationLeavesItClosed() {
    let journal = [lent(masha), payment(masha, 1_000, by: back, number: 20)]
    #expect(DebtRules.closedByDeleting([id(99)], debts: [masha], journal: journal).isEmpty)
  }

  /// The remainder written off at the close and a payment of 400 before it: the debt is at zero;
  /// without the payment 400 are owed again.
  @Test func aDebtClosedWithAWriteOffIsOwedAgainWithoutItsPayment() {
    let writeOff = DebtRules.makeEntry(
      id: id(30), debtId: masha.id, kind: .adjustment, amountE4: -AmountE4(whole: 600))
    let journal = [lent(masha), payment(masha, 400, by: back, number: 20), writeOff]
    #expect(DebtRules.balance(entries: journal).isZero)
    #expect(
      DebtRules.closedByDeleting([back], debts: [masha], journal: journal).map(\.id) == [masha.id])
  }

  /// An open debt has nothing to open; a debt closed with money still owed on it was not closed
  /// by that payment.
  @Test func onlyAClosedDebtThatWasAtZero() {
    var open = masha
    open.closed = false
    let journal = [lent(masha), payment(masha, 1_000, by: back, number: 20)]
    #expect(DebtRules.closedByDeleting([back], debts: [open], journal: journal).isEmpty)

    let owing = [lent(masha), payment(masha, 400, by: back, number: 21)]
    #expect(
      DebtRules.balance(entries: owing) == AmountE4(whole: 600), "closed without a write-off")
    #expect(DebtRules.closedByDeleting([back], debts: [masha], journal: owing).isEmpty)
  }

  @Test func aDeletedDebtIsLeftAlone() {
    var gone = masha
    gone.deletedAt = Date(timeIntervalSince1970: 1_790_000_000)
    let journal = [lent(masha), payment(masha, 1_000, by: back, number: 20)]
    #expect(DebtRules.closedByDeleting([back], debts: [gone], journal: journal).isEmpty)
  }

  /// A debt I owe: the payments are mine, and the rule is the same.
  @Test func aDebtIOweWorksTheSame() {
    var loan = masha
    loan = Debt(
      id: id(2), direction: .iOwe, type: .loan, name: "Loan", closed: true)
    let journal = [lent(loan, 5_000), payment(loan, 5_000, by: back, number: 22)]
    #expect(
      DebtRules.closedByDeleting([back], debts: [loan], journal: journal).map(\.id) == [loan.id])
  }

  /// Several operations, several debts: each is named once, in the order of the debts given.
  @Test func eachDebtIsNamedOnce() {
    let other = Debt(
      id: id(3), direction: .owedToMe, type: .personal, name: "Petya", paymentsAreExpenses: false,
      closed: true)
    let second = id(11)
    let journal = [
      lent(masha), payment(masha, 500, by: back, number: 20),
      payment(masha, 500, by: second, number: 23), lent(other),
      payment(other, 1_000, by: second, number: 24),
    ]
    let found = DebtRules.closedByDeleting(
      [back, second], debts: [other, masha], journal: journal)
    #expect(found.map(\.id) == [other.id, masha.id])
  }
}
