import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// Deleting a debt: the debt goes, every figure of the operations that point at it stays.
@Suite("Deleting a debt")
struct DebtDeletionTests {
  let categories = StartingCategories()
  let card = id(1)
  let phoneDebt = id(201)
  let now = moment("2026-09-27")

  var accounts: [PaymentMethod] {
    [PaymentMethod(id: card, name: "Card", kind: .card, isDefault: true)]
  }

  /// «Телефон» 60,000 ₽ bought on credit, three payments of 5,000 ₽ from the card.
  func phone() -> (debt: Debt, entries: [TransactionEntry], journal: [DebtEntry]) {
    let debt = Debt(
      id: phoneDebt, direction: .iOwe, type: .installment, name: "Phone",
      paymentsAreExpenses: false, origin: .purchase)
    var entries = [
      TransactionEntry(
        transaction: Transaction(
          id: id(10), kind: .expense, occurredAt: moment("2026-06-01"), amountE4: money(60_000),
          note: "Phone", paymentMethodId: card, creditDebtId: phoneDebt),
        parts: [
          TransactionPart(
            id: id(100), transactionId: id(10), categoryId: categories.other,
            amountE4: money(60_000))
        ])
    ]
    var journal = [
      DebtRules.makeEntry(
        id: id(50), debtId: phoneDebt, kind: .borrowed, amountE4: money(60_000),
        date: day("2026-06-01"), transactionId: id(10))
    ]
    for month in 7...9 {
      let paymentId = id(10 + month)
      entries.append(
        TransactionEntry(
          transaction: Transaction(
            id: paymentId, kind: .expense, occurredAt: moment("2026-0\(month)-05"),
            amountE4: money(5000), paymentMethodId: card, debtId: phoneDebt),
          parts: [
            TransactionPart(
              id: id(100 + month), transactionId: paymentId, categoryId: categories.other,
              amountE4: money(5000))
          ]))
      journal.append(
        DebtRules.makeEntry(
          id: id(50 + month), debtId: phoneDebt, kind: .payment, amountE4: money(5000),
          date: day("2026-0\(month)-05"), transactionId: paymentId))
    }
    return (debt, entries, journal)
  }

  func balances(
    _ entries: [TransactionEntry], _ journal: [DebtEntry], _ debt: Debt
  ) -> AmountE4? {
    AccountBalances.build(
      entries: entries, transfers: [], debtEntries: journal, debts: [debt.id: debt],
      reconciliations: [], balances: [], accounts: accounts, tree: categories.tree, now: now,
      calendar: .utc
    ).balance(BalanceKey(accountId: card, currency: .rub), at: now)
  }

  /// Spending stays 60,000 ₽ — the purchase — and the card stays −75,000 ₽.
  @Test func aDeletedDebtKeepsEveryFigureOfItsOperations() {
    let (debt, entries, journal) = phone()
    let deletion = DebtRules.deletion(
      of: debt, journal: journal, entries: entries, tree: categories.tree, mainAccountId: card,
      calendar: .utc, at: now)
    #expect(deletion.debt.deletedAt == now)
    #expect(deletion.debt.isDeleted)
    let before = MyExpensesRule.total(entries: entries, debts: [debt.id: debt])
    let after = MyExpensesRule.total(entries: entries, debts: [debt.id: deletion.debt])
    #expect(before == money(60_000))
    #expect(after == before)
    #expect(balances(entries, journal, deletion.debt) == balances(entries, journal, debt))
  }

  @Test func deletionSaysWhatStaysForEachKindOfDebt() {
    let (debt, entries, journal) = phone()
    let phone = DebtRules.deletion(
      of: debt, journal: journal, entries: entries, tree: categories.tree, mainAccountId: card,
      calendar: .utc, at: now)
    #expect(phone.meaning == .notSpending)
    #expect(phone.journalLines == 4)
    #expect(phone.operations == 3)
    #expect(phone.creditPurchases.map(\.id) == [id(10)])
    #expect(phone.balance == money(45_000))
    #expect(phone.movesMoneyLines == 0)
    #expect(!phone.warnsOfIncomeLater)

    let mortgage = existingDebt(id(202), subcategory: categories.loansCar)
    #expect(
      DebtRules.deletion(
        of: mortgage, journal: [], entries: [], tree: categories.tree, mainAccountId: card,
        calendar: .utc, at: now
      ).meaning == .loansExpense)

    // Маша: 5,000 ₽ lent through the journal alone, money moved; 2,000 ₽ given back.
    let masha = Debt(
      id: id(203), direction: .owedToMe, type: .personal, name: "Masha",
      paymentsAreExpenses: false)
    var lent = DebtRules.makeEntry(
      id: id(60), debtId: masha.id, kind: .borrowed, amountE4: money(5000),
      date: day("2026-08-01"))
    lent.paymentMethodId = card
    lent.occurredAt = moment("2026-08-01")
    let repaid = DebtRules.makeEntry(
      id: id(61), debtId: masha.id, kind: .payment, amountE4: money(2000),
      date: day("2026-09-01"), transactionId: id(30))
    let back = TransactionEntry(
      transaction: Transaction(
        id: id(30), kind: .reimbursement, occurredAt: moment("2026-09-01"),
        amountE4: money(2000), paymentMethodId: card, debtId: masha.id),
      parts: [TransactionPart(id: id(300), transactionId: id(30), amountE4: money(2000))])
    let owed = DebtRules.deletion(
      of: masha, journal: [lent, repaid], entries: [back], tree: categories.tree,
      mainAccountId: card, calendar: .utc, at: now)
    #expect(owed.meaning == .moneyBack)
    #expect(owed.operations == 1)
    #expect(owed.movesMoneyLines == 1)
    #expect(owed.balance == money(3000))
  }

  /// Deleting a debt owed to me with money still on it says a later repayment is income.
  @Test func anOwedToMeDebtWithABalanceWarnsOfIncome() {
    let masha = Debt(
      id: id(203), direction: .owedToMe, type: .personal, name: "Masha",
      paymentsAreExpenses: false)
    let lent = DebtRules.makeEntry(
      id: id(60), debtId: masha.id, kind: .borrowed, amountE4: money(5000))
    func deletion(_ journal: [DebtEntry]) -> DebtDeletion {
      DebtRules.deletion(
        of: masha, journal: journal, entries: [], tree: categories.tree, mainAccountId: card,
        calendar: .utc, at: now)
    }
    #expect(deletion([lent]).warnsOfIncomeLater)
    let repaid = DebtRules.makeEntry(
      id: id(61), debtId: masha.id, kind: .payment, amountE4: money(5000))
    #expect(!deletion([lent, repaid]).warnsOfIncomeLater)
  }

  @Test func theLiveLoansSubcategoryGoesToTheArchive() {
    let debt = existingDebt(subcategory: categories.loansCar)
    let deletion = DebtRules.deletion(
      of: debt, journal: [], entries: [], tree: categories.tree, mainAccountId: card,
      calendar: .utc, at: now)
    #expect(deletion.archivedSubcategory?.id == categories.loansCar)
    #expect(deletion.archivedSubcategory?.archived == true)
    #expect(deletion.archivedSubcategory?.name == "Car loan")
  }

  @Test func anArchivedOrMissingSubcategoryIsLeftAlone() {
    let missing = DebtRules.deletion(
      of: existingDebt(subcategory: id(999)), journal: [], entries: [], tree: categories.tree,
      mainAccountId: card, calendar: .utc, at: now)
    #expect(missing.archivedSubcategory == nil)
    let none = DebtRules.deletion(
      of: existingDebt(), journal: [], entries: [], tree: categories.tree, mainAccountId: card,
      calendar: .utc, at: now)
    #expect(none.archivedSubcategory == nil)
    var loan = CoreKit.Category(
      id: categories.loansCar, parentId: categories.loans, kind: .expense, name: "Car loan")
    loan.archived = true
    let archived = DebtRules.deletion(
      of: existingDebt(subcategory: categories.loansCar), journal: [], entries: [],
      tree: CategoryTree([loan]), mainAccountId: card, calendar: .utc, at: now)
    #expect(archived.archivedSubcategory == nil)
  }

  /// Paid: a live operation that paid the debt, or a payment line of its journal; money lent
  /// more and offsets are not payments.
  @Test func thePaidDebtsAreTheOnesSomethingPaid() {
    let (_, entries, journal) = phone()
    #expect(DebtRules.paidDebts(entries: entries, journal: journal) == [phoneDebt])
    let opening = journal.filter { $0.kind == .borrowed }
    #expect(DebtRules.paidDebts(entries: [entries[0]], journal: opening).isEmpty)
    let byHand = DebtRules.makeEntry(debtId: id(204), kind: .payment, amountE4: money(100))
    #expect(DebtRules.paidDebts(entries: [], journal: [byHand]) == [id(204)])
    var deleted = entries[1]
    deleted.transaction.deletedAt = now
    #expect(DebtRules.paidDebts(entries: [deleted], journal: opening).isEmpty)
  }
}
