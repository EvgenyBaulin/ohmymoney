import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// A debt deleted the way the Debts screen deletes it: one planning change of the debt stamped
/// and its subcategory of «Кредиты» archived — one ⌘Z.
@Suite("Deleting a debt in the database")
struct DebtDeletionStorageTests {
  let instant = Date(timeIntervalSince1970: 1_790_000_000)

  struct Book {
    var stack: DatabaseStack
    var planning: PlanningRepository
    var references: ReferenceRepository
    var card: PaymentMethod
    var loans: CoreKit.Category
    var loan: CoreKit.Category
    var debt: Debt
    var lent: DebtEntry
  }

  /// Masha owes 5,000 ₽ lent from the card through the journal alone; a loan I owe has its own
  /// subcategory under «Кредиты».
  func book() throws -> Book {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let card = PaymentMethod(name: "Card", kind: .card, currency: .rub, isDefault: true)
    try references.save(card)
    let loans = CoreKit.Category(
      kind: .expense, name: "Loans", quality: .neutral, systemRole: .loans)
    let loan = CoreKit.Category(parentId: loans.id, kind: .expense, name: "Masha")
    try references.seedCategoriesIfEmpty([loans, loan])
    let debt = Debt(
      direction: .owedToMe, type: .personal, name: "Masha", paymentsAreExpenses: false,
      loansSubcategoryId: loan.id)
    try references.save(debt)
    var lent = DebtRules.makeEntry(
      debtId: debt.id, kind: .borrowed, amountE4: AmountE4(whole: 5_000),
      date: DateOnly(year: 2026, month: 9, day: 1))
    lent.paymentMethodId = card.id
    lent.occurredAt = Date(timeIntervalSince1970: 1_788_220_800)
    try references.save(lent)
    return Book(
      stack: stack, planning: PlanningRepository(writer: stack.writer), references: references,
      card: card, loans: loans, loan: loan, debt: debt, lent: lent)
  }

  /// The change the Debts screen writes.
  func delete(_ book: Book) throws -> PlanningUndo {
    let deletion = DebtRules.deletion(
      of: book.debt, journal: [book.lent], entries: [],
      tree: CategoryTree([book.loans, book.loan]), mainAccountId: book.card.id, calendar: .utc,
      at: instant)
    return try book.planning.apply(
      PlanningChange(
        upsert: PlanningRows(
          categories: deletion.archivedSubcategory.map { [$0] } ?? [], debts: [deletion.debt]),
        at: instant))
  }

  @Test func aDeletedDebtLeavesTheListsButNotTheDataset() async throws {
    let book = try book()
    _ = try delete(book)
    #expect(try book.references.debts(includeClosed: true).isEmpty)
    #expect(try book.references.debts(includeClosed: true, includeDeleted: true).count == 1)
    let dataset = try await DatasetRepository(writer: book.stack.writer).load(version: 0)
    #expect(dataset.debts.isEmpty)
    #expect(dataset.deletedDebts.map(\.id) == [book.debt.id])
    #expect(dataset.deletedDebts.first?.deletedAt == instant)
    #expect(
      try book.references.categories(includeArchived: true).first { $0.id == book.loan.id }?
        .archived == true)
  }

  @Test func undoOfADeletionBringsTheDebtAndItsCategoryBack() throws {
    let book = try book()
    let undo = try delete(book)
    try book.planning.revert(undo, at: instant)
    let debts = try book.references.debts(includeClosed: true)
    #expect(debts.map(\.id) == [book.debt.id])
    #expect(debts.first?.deletedAt == nil)
    #expect(try book.references.categories().contains { $0.id == book.loan.id })
  }

  /// The 5,000 ₽ that left the card through the journal stay gone from it.
  @Test func theJournalOfADeletedDebtStillMovesMoney() async throws {
    let book = try book()
    func card() async throws -> AmountE4 {
      let dataset = try await DatasetRepository(writer: book.stack.writer).load(version: 0)
      return AccountBalances.build(
        entries: dataset.entries, transfers: dataset.transfers,
        debtEntries: dataset.planning.debtEntries, debts: dataset.debtsById,
        reconciliations: dataset.planning.reconciliations,
        balances: dataset.planning.reconciledBalances, accounts: dataset.paymentMethods,
        tree: CategoryTree(dataset.categories), now: instant, calendar: .utc
      ).moved(
        BalanceKey(accountId: book.card.id, currency: .rub),
        after: Date(timeIntervalSince1970: 0), through: instant)
    }
    let before = try await card()
    _ = try delete(book)
    #expect(try await card() == before)
    #expect(try await card() == AmountE4(whole: -5_000))
  }

  @Test func aDeletedDebtTravelsInTheExportWithItsMoment() throws {
    let book = try book()
    _ = try delete(book)
    let debts = try #require(
      try ExportRepository(writer: book.stack.writer).tables().first {
        $0.fileName == "debts.csv"
      })
    let rows = try CSVReader.dictionaries(from: debts.data)
    #expect(rows.count == 1)
    #expect(rows.first?["deleted_at"] == CSVValue.string(instant: instant))
  }
}
