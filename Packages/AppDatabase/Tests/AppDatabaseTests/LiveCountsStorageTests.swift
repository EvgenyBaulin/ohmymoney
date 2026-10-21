import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// One card, the owner's categories and the storage, the way the live counts meet them: every
/// write that moves money settles the counts whose windows it reaches in the same transaction.
private struct LiveBook {
  let stack: DatabaseStack
  let context = LiveCountsContext(calendar: .utc, categoryName: "Reconciliation")
  let card = PaymentMethod(name: "T-Bank", kind: .card, currency: .rub, isDefault: true)
  let cash = PaymentMethod(name: "Cash", kind: .cash, currency: .rub)
  let groceries = CoreKit.Category(kind: .expense, name: "Groceries", quality: .neutral)
  let salary = CoreKit.Category(kind: .income, name: "Salary")

  var transactions: TransactionRepository {
    TransactionRepository(writer: stack.writer, liveCounts: context)
  }
  var planning: PlanningRepository { PlanningRepository(writer: stack.writer, liveCounts: context) }
  var cardKey: BalanceKey { BalanceKey(accountId: card.id, currency: .rub) }
  var cashKey: BalanceKey { BalanceKey(accountId: cash.id, currency: .rub) }

  init() throws {
    stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    try references.save(card)
    try references.save(cash)
    try references.save(groceries)
    try references.save(salary)
  }

  func at(_ iso: String, hour: Int = 12) -> Date {
    CalendarContext.utc.startOfDay(DateOnly(iso: iso) ?? DateOnly(year: 2026, month: 1, day: 1))
      .addingTimeInterval(TimeInterval(hour * 3_600))
  }

  func operation(
    _ amount: Int64, _ kind: TransactionKind = .expense, on iso: String, hour: Int = 12,
    account: PaymentMethod? = nil
  ) -> TransactionEntry {
    let id = UUID()
    let transaction = Transaction(
      id: id, kind: kind, occurredAt: at(iso, hour: hour), amountE4: AmountE4(whole: amount),
      paymentMethodId: (account ?? card).id, createdAt: at(iso, hour: hour),
      updatedAt: at(iso, hour: hour))
    return TransactionEntry(
      transaction: transaction,
      parts: [
        TransactionPart(
          transactionId: id, categoryId: kind == .expense ? groceries.id : salary.id,
          amountE4: AmountE4(whole: amount))
      ])
  }

  /// A sheet saved the way the reconcile sheet saves it: each key compared with what the books
  /// hold at `moment` (a first count is a starting point), the mode chosen, and the keys handed
  /// to the settle, which writes the differences.
  @discardableResult
  func count(
    _ counts: [(BalanceKey, Int64)], at moment: Date, records: Bool = true,
    kind: ReconciliationKind = .accounts, origin: ReconciliationOrigin? = nil
  ) throws -> (undo: PlanningUndo, counts: [ReconciledBalance]) {
    let reconciliation = Reconciliation(
      date: CalendarContext.utc.day(of: moment), reconciledAt: moment, actualTotalRubE4: .zero,
      kind: kind, origin: origin)
    var rows: [ReconciledBalance] = []
    for (key, whole) in counts {
      let expected: AmountE4? =
        kind == .accounts
        ? try stack.writer.read { db in
          try LiveCountsWriter.balance(of: key, at: moment, context: context, db: db)
        } : nil
      let actual = AmountE4(whole: whole)
      rows.append(
        ReconciledBalance(
          reconciliationId: reconciliation.id, accountId: key.accountId, currency: key.currency,
          actualE4: actual, expectedE4: expected, differenceE4: expected.map { actual - $0 },
          recordsDifference: expected == nil ? nil : records))
    }
    var upsert = PlanningRows.empty
    upsert.reconciliations = [reconciliation]
    upsert.reconciledBalances = rows
    let undo = try planning.apply(
      PlanningChange(upsert: upsert, at: moment, settles: Set(counts.map(\.0))))
    return (undo, try rows.map { try #require(try self.row($0.id)) })
  }

  func row(_ id: UUID) throws -> ReconciledBalance? {
    try stack.writer.read { db in try ReconciledBalance.fetchOne(db, key: id.uuidString) }
  }

  /// The operation keyed to the count, live or in the bin.
  func operation(ofCount count: ReconciledBalance) throws -> TransactionEntry? {
    let key = OperationLink.reconciledBalance(
      reconciliation: count.reconciliationId, balance: count.id
    ).externalId
    return try stack.writer.read { db in
      guard
        let id = try String.fetchOne(
          db, sql: "SELECT id FROM transactions WHERE external_id = ?", arguments: [key]
        ).flatMap(UUID.init(uuidString:))
      else { return nil }
      return try TransactionRepository.entry(id: id, db: db)
    }
  }

  func reconcileOperations() throws -> Int {
    try stack.writer.read { db in
      try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM transactions WHERE substr(external_id, 1, 10) = 'reconcile:'"
      )
        ?? 0
    }
  }

  /// «Т-Банк» first counted 01.09 09:00 at 50,000; +100,000 on 03.09 and −12,000 on 05.09
  /// recorded on time; counted 130,000 on 20.09 10:00.
  func september(records: Bool = true) throws -> (sheet: PlanningUndo, count: ReconciledBalance) {
    try count([(cardKey, 50_000)], at: at("2026-09-01", hour: 9))
    try transactions.save(operation(100_000, .income, on: "2026-09-03"))
    try transactions.save(operation(12_000, on: "2026-09-05"))
    let later = try count([(cardKey, 130_000)], at: at("2026-09-20", hour: 10), records: records)
    return (later.undo, later.counts[0])
  }
}

@Suite("Live counts in the storage")
struct LiveCountsStorageTests {

  @Test func theSheetsDifferenceIsWrittenByTheSettle() throws {
    let book = try LiveBook()
    let (_, count) = try book.september()
    #expect(count.expectedE4 == AmountE4(whole: 138_000))
    #expect(count.differenceE4 == AmountE4(whole: -8_000))
    let operation = try #require(try book.operation(ofCount: count))
    #expect(operation.id == ReconcileDifferenceIds.operation(forCount: count.id))
    #expect(operation.transaction.amountE4 == AmountE4(whole: 8_000))
    #expect(count.transactionId == operation.id)
  }

  @Test func aBackdatedSaveRewritesTheDifferenceInTheSameWrite() throws {
    let book = try LiveBook()
    let (_, count) = try book.september()
    let (written, settled) = try book.transactions.saveReporting(
      book.operation(3_000, on: "2026-09-10"))
    #expect(written.transaction.amountE4 == AmountE4(whole: 3_000))
    #expect(settled.rewritten == 1)
    #expect(settled.upserted.map(\.id) == [ReconcileDifferenceIds.operation(forCount: count.id)])
    let row = try #require(try book.row(count.id))
    #expect(row.expectedE4 == AmountE4(whole: 135_000))
    #expect(row.differenceE4 == AmountE4(whole: -5_000))
    #expect(try book.operation(ofCount: count)?.transaction.amountE4 == AmountE4(whole: 5_000))
    // After the count: the balance moves, the count does not.
    let after = try book.transactions.saveReporting(book.operation(300, on: "2026-09-21"))
    #expect(after.counts.isEmpty)
    #expect(try book.row(count.id) == row)
  }

  @Test func purgeOfACreatedOperationSettlesBack() throws {
    let book = try LiveBook()
    let (_, count) = try book.september()
    let cafe = try book.transactions.save(book.operation(8_000, on: "2026-09-12"))
    #expect(try book.row(count.id)?.differenceE4 == .zero)
    #expect(try book.operation(ofCount: count) == nil)
    let settled = try book.transactions.purge(id: cafe.id)
    #expect(settled.created == 1)
    #expect(try book.row(count.id)?.differenceE4 == AmountE4(whole: -8_000))
    let recreated = try #require(try book.operation(ofCount: count))
    #expect(recreated.id == ReconcileDifferenceIds.operation(forCount: count.id))
  }

  @Test func deleteAndRestoreGiveTheDifferenceBack() throws {
    let book = try LiveBook()
    let (_, count) = try book.september()
    let taxi = try book.transactions.save(book.operation(3_000, on: "2026-09-10"))
    #expect(try book.row(count.id)?.differenceE4 == AmountE4(whole: -5_000))
    let effects = try book.transactions.softDelete(ids: [taxi.id], at: book.at("2026-09-22"))
    #expect(effects.counts.rewritten == 1)
    #expect(try book.row(count.id)?.differenceE4 == AmountE4(whole: -8_000))
    let restored = try book.transactions.restore(
      ids: [taxi.id], at: book.at("2026-09-22", hour: 13), effects: effects)
    #expect(restored.rewritten == 1)
    #expect(try book.row(count.id)?.differenceE4 == AmountE4(whole: -5_000))
  }

  @Test func aBulkChangeSettlesTheWindowsItMoves() throws {
    let book = try LiveBook()
    let (_, count) = try book.september()
    let taxi = try book.transactions.save(book.operation(3_000, on: "2026-09-10"))
    let moved = try book.transactions.modifyReporting(ids: [taxi.id]) { entry in
      var changed = entry
      changed.transaction.occurredAt = book.at("2026-09-25")
      return changed
    }
    #expect(moved.before.map(\.id) == [taxi.id])
    #expect(moved.counts.rewritten == 1)
    #expect(try book.row(count.id)?.differenceE4 == AmountE4(whole: -8_000))
  }

  @Test func anOwnerDeletedDifferenceBecomesKeep() throws {
    let book = try LiveBook()
    let (_, count) = try book.september()
    let operation = try #require(try book.operation(ofCount: count))
    let effects = try book.transactions.softDelete(ids: [operation.id], at: book.at("2026-09-21"))
    var row = try #require(try book.row(count.id))
    #expect(row.recordsDifference == false)
    #expect(row.transactionId == nil)
    #expect(row.differenceE4 == AmountE4(whole: -8_000))
    #expect(effects.counts.modeChanged == 1)
    // A backdated expense now only moves the numbers.
    try book.transactions.save(book.operation(3_000, on: "2026-09-10"))
    row = try #require(try book.row(count.id))
    #expect(row.differenceE4 == AmountE4(whole: -5_000))
    #expect(try book.operation(ofCount: count)?.transaction.amountE4 == AmountE4(whole: 8_000))
    // ⌘Z of the deletion brings the operation and the mode back, at the difference of now.
    try book.transactions.restore(ids: [operation.id], at: book.at("2026-09-22"), effects: effects)
    row = try #require(try book.row(count.id))
    #expect(row.recordsDifference == true)
    #expect(row.transactionId == operation.id)
    #expect(try book.operation(ofCount: count)?.transaction.amountE4 == AmountE4(whole: 5_000))
  }

  @Test func aRewriteKeepsTheOwnersCategoryNoteAndPartId() throws {
    let book = try LiveBook()
    let (_, count) = try book.september()
    var owners = try #require(try book.operation(ofCount: count))
    owners.transaction.note = "lost somewhere"
    owners.parts[0].categoryId = book.groceries.id
    owners.parts[0].quality = .bad
    owners.parts[0].qualitySource = .manual
    try book.transactions.save(owners)
    try book.stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO category_feedback (id, text, chosen_category_id, at, part_id)
          VALUES (?, 'lost', ?, ?, ?)
          """,
        arguments: [
          UUID().uuidString, book.groceries.id.uuidString,
          StoredInstant.databaseValue(book.at("2026-09-20", hour: 11)),
          owners.parts[0].id.uuidString,
        ])
    }
    try book.transactions.save(book.operation(3_000, on: "2026-09-10"))
    let rewritten = try #require(try book.operation(ofCount: count))
    #expect(rewritten.transaction.amountE4 == AmountE4(whole: 5_000))
    #expect(rewritten.transaction.note == "lost somewhere")
    #expect(rewritten.parts.map(\.id) == owners.parts.map(\.id))
    #expect(rewritten.parts[0].categoryId == book.groceries.id)
    #expect(rewritten.parts[0].quality == .bad)
    #expect(rewritten.parts[0].qualitySource == .manual)
    let feedback = try book.stack.writer.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM category_feedback") ?? 0
    }
    #expect(feedback == 1)
  }

  /// The owner filed «Сверка» −8,000 under «Groceries» with the comment «for mum» and rated it,
  /// then entered the missing 8,000 dated back: the difference is zero and its operation goes.
  /// ⌘Z of that entry brings the operation back as he left it — category, comment, rating, ids
  /// and the moment it was made —, not a bare «Сверка».
  @Test func undoGivesBackTheOwnersDifferenceAsItWas() throws {
    let book = try LiveBook()
    let (_, count) = try book.september()
    let filed = try fileTheDifference(of: count, in: book)
    let (gift, settled) = try book.transactions.saveReporting(
      book.operation(8_000, on: "2026-09-12"))
    #expect(settled.purged == 1)
    #expect(try book.operation(ofCount: count) == nil)
    let back = try book.transactions.purge(id: gift.id, templates: settled.operationsBefore)
    #expect(back.created == 1)
    #expect(try book.operation(ofCount: count) == filed)
    #expect(try book.row(count.id)?.transactionId == filed.id)
    #expect(try book.row(count.id)?.differenceE4 == AmountE4(whole: -8_000))
  }

  /// The same through the deletion of an income dated in the window, and through a planning
  /// change: their ⌘Z gives the owner's operation back as he left it.
  @Test func undoOfADeletionOrAPlanningChangeGivesBackTheOwnersDifference() throws {
    let book = try LiveBook()
    try book.count([(book.cardKey, 50_000)], at: book.at("2026-09-01", hour: 9))
    try book.transactions.save(book.operation(100_000, .income, on: "2026-09-03"))
    let bonus = try book.transactions.save(book.operation(8_000, .income, on: "2026-09-04"))
    try book.transactions.save(book.operation(12_000, on: "2026-09-05"))
    let count = try book.count([(book.cardKey, 138_000)], at: book.at("2026-09-20", hour: 10))
      .counts[0]
    let filed = try fileTheDifference(of: count, in: book)

    let effects = try book.transactions.softDelete(ids: [bonus.id], at: book.at("2026-09-21"))
    #expect(effects.counts.purged == 1)
    #expect(try book.operation(ofCount: count) == nil)
    try book.transactions.restore(
      ids: effects.deletedIds, at: book.at("2026-09-21", hour: 13), effects: effects)
    #expect(try book.operation(ofCount: count) == filed)

    var upsert = PlanningRows.empty
    upsert.transfers = [
      Transfer(
        occurredAt: book.at("2026-09-15"), fromAccountId: book.card.id, fromCurrency: .rub,
        fromAmountE4: AmountE4(whole: 8_000), toAccountId: book.cash.id, toCurrency: .rub,
        toAmountE4: AmountE4(whole: 8_000))
    ]
    let undo = try book.planning.apply(PlanningChange(upsert: upsert))
    #expect(undo.counts.purged == 1)
    try book.planning.revert(undo)
    #expect(try book.operation(ofCount: count) == filed)
  }

  /// A template whose category is gone since cannot come back as it was: the difference is
  /// written anew, and the ⌘Z lands.
  @Test func aTemplateWhoseCategoryIsGoneIsWrittenAnew() throws {
    let book = try LiveBook()
    let (_, count) = try book.september()
    let gifts = CoreKit.Category(kind: .expense, name: "Gifts", quality: .neutral)
    try ReferenceRepository(writer: book.stack.writer).save(gifts)
    var owners = try #require(try book.operation(ofCount: count))
    owners.parts[0].categoryId = gifts.id
    try book.transactions.save(owners)
    let (gift, settled) = try book.transactions.saveReporting(
      book.operation(8_000, on: "2026-09-12"))
    try book.stack.writer.write { db in
      try db.execute(sql: "DELETE FROM categories WHERE id = ?", arguments: [gifts.id.uuidString])
    }
    let back = try book.transactions.purge(id: gift.id, templates: settled.operationsBefore)
    #expect(back.created == 1)
    let written = try #require(try book.operation(ofCount: count))
    #expect(written.id == ReconcileDifferenceIds.operation(forCount: count.id))
    #expect(written.parts[0].categoryId != gifts.id)
    #expect(written.transaction.amountE4 == AmountE4(whole: 8_000))
  }

  /// The owner files the difference of `count` under «Groceries», comments and rates it; the
  /// operation as stored.
  private func fileTheDifference(
    of count: ReconciledBalance, in book: LiveBook
  ) throws -> TransactionEntry {
    var owners = try #require(try book.operation(ofCount: count))
    owners.transaction.note = "for mum"
    owners.parts[0].categoryId = book.groceries.id
    owners.parts[0].quality = .bad
    owners.parts[0].qualitySource = .manual
    try book.transactions.save(owners)
    return try #require(try book.operation(ofCount: count))
  }

  @Test func theCategoryIsMadeWhenMissing() throws {
    let book = try LiveBook()
    let (_, count) = try book.september()
    let expense = try book.stack.writer.read { db in
      try String.fetchOne(
        db, sql: "SELECT value FROM settings WHERE key = ?",
        arguments: [PlanningSettings.reconcileExpenseCategoryKey])
    }
    let category = try #require(expense.flatMap(UUID.init(uuidString:)))
    let made = try book.stack.writer.read { db in
      try CoreKit.Category.fetchOne(db, key: category.uuidString)
    }
    #expect(made?.name == "Reconciliation")
    #expect(made?.kind == .expense)
    #expect(try book.operation(ofCount: count)?.parts.first?.categoryId == category)
    // Archived since, it is brought back rather than made twice.
    try book.stack.writer.write { db in
      try db.execute(
        sql: "UPDATE categories SET archived = 1 WHERE id = ?", arguments: [category.uuidString])
    }
    try book.transactions.save(book.operation(9_500, .income, on: "2026-09-10"))
    try book.transactions.save(book.operation(20_000, on: "2026-09-11"))
    let income = try #require(try book.operation(ofCount: count))
    #expect(income.transaction.kind == .income)
    try book.transactions.save(book.operation(10_000, .income, on: "2026-09-12"))
    let expenseAgain = try #require(try book.operation(ofCount: count))
    #expect(expenseAgain.transaction.kind == .expense)
    #expect(expenseAgain.parts.first?.categoryId == category)
    let categories = try book.stack.writer.read { db in
      try CoreKit.Category.filter(Column("name") == "Reconciliation").fetchAll(db)
    }
    #expect(categories.count == 2)
    #expect(categories.allSatisfy { !$0.archived })
  }

  @Test func aTransferPlanningChangeAndItsRevertSettle() throws {
    let book = try LiveBook()
    try book.count([(book.cardKey, 50_000)], at: book.at("2026-09-01", hour: 9))
    try book.transactions.save(book.operation(100_000, .income, on: "2026-09-03"))
    try book.transactions.save(book.operation(15_000, on: "2026-09-05"))
    let later = try book.count(
      [(book.cardKey, 130_000)], at: book.at("2026-09-20", hour: 10)
    ).counts[0]
    #expect(later.differenceE4 == AmountE4(whole: -5_000))
    try book.count([(book.cashKey, 7_000)], at: book.at("2026-09-18", hour: 9))
    var upsert = PlanningRows.empty
    upsert.transfers = [
      Transfer(
        occurredAt: book.at("2026-09-15"), fromAccountId: book.card.id, fromCurrency: .rub,
        fromAmountE4: AmountE4(whole: 5_000), toAccountId: book.cash.id, toCurrency: .rub,
        toAmountE4: AmountE4(whole: 5_000))
    ]
    let undo = try book.planning.apply(PlanningChange(upsert: upsert))
    #expect(try book.row(later.id)?.differenceE4 == AmountE4(raw: 0))
    #expect(try book.operation(ofCount: later) == nil)
    #expect(undo.counts.purged == 1)
    try book.planning.revert(undo)
    #expect(try book.row(later.id)?.differenceE4 == AmountE4(whole: -5_000))
    #expect(try book.operation(ofCount: later)?.transaction.amountE4 == AmountE4(whole: 5_000))
  }

  /// A count's operation, purged at zero and made again under the same id by a later ⌘Z, goes
  /// with its count when the sheet is taken back.
  @Test func undoingTheCountAfterItsOperationWasRecreatedLeavesNoOperation() throws {
    let book = try LiveBook()
    let (sheet, count) = try book.september()
    let rent = try book.transactions.save(book.operation(8_000, on: "2026-09-12"))
    #expect(try book.operation(ofCount: count) == nil)
    try book.transactions.purge(id: rent.id)
    #expect(try book.operation(ofCount: count) != nil)
    try book.planning.revert(sheet)
    #expect(try book.row(count.id) == nil)
    #expect(try book.reconcileOperations() == 0)
  }

  /// A sheet that wrote its own differences, as the sheet does: taken back, nothing of them is
  /// left, whatever the settles did in between.
  @Test func undoingASheetWithItsOwnOperationsLeavesNoneBehind() throws {
    let book = try LiveBook()
    try book.count([(book.cardKey, 50_000)], at: book.at("2026-09-01", hour: 9))
    try book.transactions.save(book.operation(12_000, on: "2026-09-05"))
    let moment = book.at("2026-09-20", hour: 10)
    let rows = [
      ReconcileRow(
        key: book.cardKey, expected: AmountE4(whole: 38_000), lastCountedAt: nil, isHeld: true)
    ]
    let categories = try book.stack.writer.write { db in
      try LiveCountsWriter.categories(context: book.context, db: db)
    }
    let record = AccountReconciliation.record(
      counted: [book.cardKey: AmountE4(whole: 30_000)], rows: rows, writeDifference: true,
      kind: .accounts, at: moment, calendar: .utc, tree: CategoryTree(),
      categories: (categories.expense, categories.income), rubPerUnit: [:], makeId: { UUID() })
    var upsert = PlanningRows.empty
    upsert.reconciliations = [record.reconciliation]
    upsert.reconciledBalances = record.balances
    let undo = try book.planning.apply(
      PlanningChange(created: record.differences, upsert: upsert, settles: [book.cardKey]))
    let count = try #require(try book.row(record.balances[0].id))
    #expect(try book.operation(ofCount: count)?.id == record.differences.first?.id)
    try book.transactions.save(book.operation(3_000, on: "2026-09-10"))
    #expect(try book.operation(ofCount: count)?.transaction.amountE4 == AmountE4(whole: 5_000))
    try book.planning.revert(undo)
    #expect(try book.reconcileOperations() == 0)
  }

  @Test func settleAllPurgesAnOrphanDifference() throws {
    let book = try LiveBook()
    let (_, count) = try book.september()
    let operation = try #require(try book.operation(ofCount: count))
    // Gone by a path that did not take its difference along.
    try book.stack.writer.write { db in
      try db.execute(
        sql: "DELETE FROM reconciliation_balances WHERE id = ?", arguments: [count.id.uuidString])
    }
    let settled = try ReconciliationRepository(writer: book.stack.writer).settleAll(
      context: book.context)
    #expect(settled.orphansPurged == 1)
    #expect(try book.transactions.entry(id: operation.id) == nil)
  }

  @Test func settleAllCatchesUpAndChangesNothingTwice() throws {
    let book = try LiveBook()
    let (_, count) = try book.september()
    // Written by a path that did not settle, as 1.1 wrote a backdated entry.
    try book.stack.writer.write { db in
      let taxi = book.operation(3_000, on: "2026-09-10")
      try taxi.transaction.insert(db)
      for part in taxi.parts { try part.insert(db) }
    }
    #expect(try book.row(count.id)?.differenceE4 == AmountE4(whole: -8_000))
    let repository = ReconciliationRepository(writer: book.stack.writer)
    let first = try repository.settleAll(context: book.context)
    #expect(first.rewritten == 1)
    #expect(try book.row(count.id)?.differenceE4 == AmountE4(whole: -5_000))
    let again = try repository.settleAll(context: book.context)
    #expect(again.isEmpty)
  }

  /// Money lent through a debt's journal alone stays in the window after the debt is deleted:
  /// its line still moved the money.
  @Test func aDeletedDebtsCashLineStaysInTheWindow() throws {
    let book = try LiveBook()
    let friend = Debt(direction: .owedToMe, type: .personal, name: "A friend")
    try ReferenceRepository(writer: book.stack.writer).save(friend)
    try book.count([(book.cardKey, 50_000)], at: book.at("2026-09-01", hour: 9))
    var upsert = PlanningRows.empty
    upsert.debtEntries = [
      DebtEntry(
        debtId: friend.id, date: DateOnly(year: 2026, month: 9, day: 5),
        amountE4: AmountE4(whole: 5_000), kind: .borrowed, paymentMethodId: book.card.id,
        occurredAt: book.at("2026-09-05"))
    ]
    _ = try book.planning.apply(PlanningChange(upsert: upsert))
    let count = try book.count([(book.cardKey, 45_000)], at: book.at("2026-09-20", hour: 10))
      .counts[0]
    #expect(count.differenceE4 == .zero)
    try book.stack.writer.write { db in
      try db.execute(
        sql: "UPDATE debts SET deleted_at = ? WHERE id = ?",
        arguments: [StoredInstant.databaseValue(book.at("2026-09-21")), friend.id.uuidString])
    }
    try book.transactions.save(book.operation(300, on: "2026-09-10"))
    #expect(try book.row(count.id)?.differenceE4 == AmountE4(whole: 300))
    #expect(try book.operation(ofCount: count)?.transaction.kind == .income)
    let again = try ReconciliationRepository(writer: book.stack.writer).settleAll(
      context: book.context)
    #expect(again.isEmpty)
  }

  /// A debt deleted in a change takes its journal along: the money its lines moved leaves the
  /// windows in the same step, and ⌘Z brings it back.
  @Test func aDebtDeletedWithItsJournalSettlesItsWindows() throws {
    let book = try LiveBook()
    let loan = Debt(direction: .iOwe, type: .personal, name: "A friend's loan")
    try ReferenceRepository(writer: book.stack.writer).save(loan)
    try book.count([(book.cardKey, 50_000)], at: book.at("2026-09-01", hour: 9))
    var upsert = PlanningRows.empty
    upsert.debtEntries = [
      DebtEntry(
        debtId: loan.id, date: DateOnly(year: 2026, month: 9, day: 5),
        amountE4: AmountE4(whole: 30_000), kind: .borrowed, paymentMethodId: book.card.id,
        occurredAt: book.at("2026-09-05"))
    ]
    _ = try book.planning.apply(PlanningChange(upsert: upsert))
    let count = try book.count([(book.cardKey, 80_000)], at: book.at("2026-09-20", hour: 10))
      .counts[0]
    #expect(count.differenceE4 == .zero)
    let undo = try book.planning.apply(PlanningChange(delete: PlanningRowIDs(debts: [loan.id])))
    #expect(try book.row(count.id)?.differenceE4 == AmountE4(whole: 30_000))
    try book.planning.revert(undo)
    #expect(try book.row(count.id)?.differenceE4 == .zero)
    #expect(try book.operation(ofCount: count) == nil)
  }

  @Test func movingTheMainFlagSettlesBothAccounts() throws {
    let book = try LiveBook()
    let friend = Debt(direction: .iOwe, type: .personal, name: "A friend")
    try ReferenceRepository(writer: book.stack.writer).save(friend)
    try book.count(
      [(book.cardKey, 50_000), (book.cashKey, 1_000)], at: book.at("2026-09-01", hour: 9))
    // Borrowed through the journal alone, on no account: the main account's money.
    try book.stack.writer.write { db in
      try DebtEntry(
        debtId: friend.id, date: DateOnly(year: 2026, month: 9, day: 5),
        amountE4: AmountE4(whole: 2_000), kind: .borrowed, occurredAt: book.at("2026-09-05")
      ).insert(db)
    }
    let counts = try book.count(
      [(book.cardKey, 52_000), (book.cashKey, 1_000)], at: book.at("2026-09-20", hour: 10)
    ).counts
    #expect(counts.allSatisfy { $0.differenceE4 == .zero })
    var cash = book.cash
    cash.isDefault = true
    var upsert = PlanningRows.empty
    upsert.paymentMethods = [cash]
    let undo = try book.planning.apply(PlanningChange(upsert: upsert))
    #expect(try book.row(counts[0].id)?.differenceE4 == AmountE4(whole: 2_000))
    #expect(try book.row(counts[1].id)?.differenceE4 == AmountE4(whole: -2_000))
    try book.planning.revert(undo)
    #expect(try book.row(counts[0].id)?.differenceE4 == .zero)
    #expect(try book.row(counts[1].id)?.differenceE4 == .zero)
  }

  @Test func expectingBalancesRefusesAStaleAmount() throws {
    let book = try LiveBook()
    try book.count([(book.cashKey, 3_000)], at: book.at("2026-09-01", hour: 9))
    try book.transactions.save(book.operation(500, on: "2026-09-05", account: book.cash))
    var archived = book.cash
    archived.archived = true
    var upsert = PlanningRows.empty
    upsert.paymentMethods = [archived]
    #expect(throws: PlanningWriteError.balanceChanged(book.cashKey)) {
      try book.planning.apply(
        PlanningChange(
          upsert: upsert, at: book.at("2026-09-06"),
          expectingBalances: [book.cashKey: AmountE4(whole: 3_000)]))
    }
    let undo = try book.planning.apply(
      PlanningChange(
        upsert: upsert, at: book.at("2026-09-06"),
        expectingBalances: [book.cashKey: AmountE4(whole: 2_500)]))
    #expect(undo.before.paymentMethods.count == 1)
  }

  /// A purchase typed ahead of the write counts: «Cash» counted 3,000, 500 spent before the
  /// write and 1,000 dated after it. The change expects what the account will hold once both
  /// are paid, 1,500 — the question showed that —, and the 2,500 of the moment is stale.
  @Test func expectingBalancesCountMoneyTypedAhead() throws {
    let book = try LiveBook()
    try book.count([(book.cashKey, 3_000)], at: book.at("2026-09-01", hour: 9))
    try book.transactions.save(book.operation(500, on: "2026-09-05", account: book.cash))
    try book.transactions.save(book.operation(1_000, on: "2026-09-10", account: book.cash))
    var archived = book.cash
    archived.archived = true
    var upsert = PlanningRows.empty
    upsert.paymentMethods = [archived]
    #expect(throws: PlanningWriteError.balanceChanged(book.cashKey)) {
      try book.planning.apply(
        PlanningChange(
          upsert: upsert, at: book.at("2026-09-06"),
          expectingBalances: [book.cashKey: AmountE4(whole: 2_500)]))
    }
    let undo = try book.planning.apply(
      PlanningChange(
        upsert: upsert, at: book.at("2026-09-06"),
        expectingBalances: [book.cashKey: AmountE4(whole: 1_500)]))
    #expect(undo.before.paymentMethods.count == 1)
  }

  /// The balance of the moment is checked as well when the change expects it: «Cash» counted
  /// 3,000, with 500 and 1,000 dated after the write. What the account will hold once both are
  /// paid, 1,500, still holds, but 2,500 at the moment of the write — what the question saw
  /// when the 500 was dated before it — no longer does: it is 3,000.
  @Test func expectingBalancesNowRefusesMoneyMovedToAnotherDay() throws {
    let book = try LiveBook()
    try book.count([(book.cashKey, 3_000)], at: book.at("2026-09-01", hour: 9))
    try book.transactions.save(book.operation(500, on: "2026-09-08", account: book.cash))
    try book.transactions.save(book.operation(1_000, on: "2026-09-10", account: book.cash))
    var archived = book.cash
    archived.archived = true
    var upsert = PlanningRows.empty
    upsert.paymentMethods = [archived]
    #expect(throws: PlanningWriteError.balanceChanged(book.cashKey)) {
      try book.planning.apply(
        PlanningChange(
          upsert: upsert, at: book.at("2026-09-06"),
          expectingBalances: [book.cashKey: AmountE4(whole: 1_500)],
          expectingBalancesNow: [book.cashKey: AmountE4(whole: 2_500)]))
    }
    #expect(try book.stack.writer.read { db in try PaymentMethod.fetchCount(db) } == 2)
    let undo = try book.planning.apply(
      PlanningChange(
        upsert: upsert, at: book.at("2026-09-06"),
        expectingBalances: [book.cashKey: AmountE4(whole: 1_500)],
        expectingBalancesNow: [book.cashKey: AmountE4(whole: 3_000)]))
    #expect(undo.before.paymentMethods.count == 1)
  }

  /// A deletion that brings transfers settling an account in the archive, planned on two
  /// purchases of which one was deleted elsewhere since: the transfer counts both, so nothing
  /// is written — the other purchase stays, and no transfer is there. Planned on what is there,
  /// it lands.
  @Test func aDeletionPlannedOnOperationsGoneSinceWritesNothing() throws {
    let book = try LiveBook()
    try book.count(
      [(book.cardKey, 10_000), (book.cashKey, 5_000)], at: book.at("2026-09-01", hour: 9))
    let first = book.operation(2_000, on: "2026-09-05", account: book.cash)
    let second = book.operation(3_000, on: "2026-09-05", hour: 13, account: book.cash)
    try book.transactions.save(first)
    try book.transactions.save(second)
    _ = try book.transactions.softDelete(id: first.id, at: book.at("2026-09-06"))
    let settling = Transfer(
      occurredAt: book.at("2026-09-06", hour: 13), fromAccountId: book.cash.id,
      fromCurrency: .rub, fromAmountE4: AmountE4(whole: 5_000), toAccountId: book.card.id,
      toCurrency: .rub, toAmountE4: AmountE4(whole: 5_000))
    var upsert = PlanningRows.empty
    upsert.transfers = [settling]
    let planned = [first.id, second.id]
    #expect(throws: SettlingPlanOutdated(operationIds: [first.id])) {
      try book.planning.apply(
        PlanningChange(
          upsert: upsert, softDeleted: planned, at: book.at("2026-09-06", hour: 13),
          settlingPlanned: Set(planned)))
    }
    #expect(try book.transactions.entry(id: second.id)?.transaction.isDeleted == false)
    #expect(try book.stack.writer.read { db in try Transfer.fetchCount(db) } == 0)

    var alone = settling
    alone.fromAmountE4 = AmountE4(whole: 3_000)
    alone.toAmountE4 = AmountE4(whole: 3_000)
    upsert.transfers = [alone]
    let undo = try book.planning.apply(
      PlanningChange(
        upsert: upsert, softDeleted: [second.id], at: book.at("2026-09-06", hour: 13),
        settlingPlanned: [second.id]))
    #expect(undo.deletion.deletedIds == [second.id])
    #expect(try book.stack.writer.read { db in try Transfer.fetchCount(db) } == 1)
  }

  // MARK: The first count the owner has not decided about

  /// The owner's own case: «Т-Банк» left empty in the setup of 1.1 (an opening of 0), counted
  /// 120,000 on 26.09 and recorded as income, then ТП +100,000 on 25.09 and −4,000 on 22.09
  /// entered afterwards.
  private func theOwnersN8Base(_ book: LiveBook) throws -> (count: ReconciledBalance, income: UUID)
  {
    try book.count(
      [(book.cardKey, 0)], at: book.at("2026-09-20", hour: 9), kind: .opening)
    let moment = book.at("2026-09-26", hour: 12)
    let reconciliation = Reconciliation(
      date: DateOnly(year: 2026, month: 9, day: 26), reconciledAt: moment,
      actualTotalRubE4: .zero, kind: .accounts)
    let countId = UUID()
    let categories = try book.stack.writer.write { db in
      try LiveCountsWriter.categories(context: book.context, db: db)
    }
    let income = LiveCounts.differenceOperation(
      AmountE4(whole: 120_000), key: book.cardKey, rate: nil, at: moment, tree: CategoryTree(),
      categories: categories, countId: countId,
      link: .reconciledBalance(reconciliation: reconciliation.id, balance: countId), now: moment)
    let count = ReconciledBalance(
      id: countId, reconciliationId: reconciliation.id, accountId: book.card.id, currency: .rub,
      actualE4: AmountE4(whole: 120_000), expectedE4: .zero,
      differenceE4: AmountE4(whole: 120_000), transactionId: income.id, recordsDifference: true)
    try book.stack.writer.write { db in
      try reconciliation.insert(db)
      try income.transaction.insert(db)
      for part in income.parts { try part.insert(db) }
      try count.insert(db)
    }
    return (count, income.id)
  }

  @Test func settleAllLeavesAFirstCountCandidateAsItIs() throws {
    let book = try LiveBook()
    let (count, income) = try theOwnersN8Base(book)
    let repository = ReconciliationRepository(writer: book.stack.writer)
    // (a) Nothing backdated: nothing written.
    #expect(try repository.settleAll(context: book.context).isEmpty)
    #expect(try book.row(count.id) == count)
    // (b) Backdated into the window: the income stays 120,000, the count keeps its expected.
    try book.transactions.save(book.operation(100_000, .income, on: "2026-09-25"))
    try book.transactions.save(book.operation(4_000, on: "2026-09-22"))
    #expect(try repository.settleAll(context: book.context).isEmpty)
    #expect(try book.row(count.id) == count)
    #expect(
      try book.transactions.entry(id: income)?.transaction.amountE4 == AmountE4(whole: 120_000))
    // (c) «Это настоящая разница»: kept and settled in the same step, one ⌘Z brings both back.
    let keep = try book.planning.apply(
      PlanningChange(
        settings: [PlanningSettings.firstCountKeptKey: count.id.uuidString],
        settles: [book.cardKey]))
    #expect(try book.row(count.id)?.expectedE4 == AmountE4(whole: 96_000))
    #expect(
      try book.transactions.entry(id: income)?.transaction.amountE4 == AmountE4(whole: 24_000))
    try book.planning.revert(keep)
    #expect(try book.row(count.id)?.expectedE4 == .zero)
    #expect(
      try book.transactions.entry(id: income)?.transaction.amountE4 == AmountE4(whole: 120_000))
    // (d) «Сделать точкой отсчёта»: a starting point, its income in the bin, the balance kept.
    var start = count
    start.expectedE4 = nil
    start.differenceE4 = nil
    start.transactionId = nil
    start.recordsDifference = nil
    var upsert = PlanningRows.empty
    upsert.reconciledBalances = [start]
    _ = try book.planning.apply(PlanningChange(upsert: upsert, softDeleted: [income]))
    #expect(try book.row(count.id) == start)
    #expect(try book.transactions.entry(id: income)?.transaction.isDeleted == true)
    let balance = try book.stack.writer.read { db in
      try LiveCountsWriter.balance(
        of: book.cardKey, at: book.at("2026-09-27"), context: book.context, db: db)
    }
    #expect(balance == AmountE4(whole: 120_000))
  }

  /// A count of 1.1 that recorded but has no operation, resting on a zero opening: the first
  /// open writes no income for it.
  @Test func settleAllWritesNoIncomeForAnUnwrittenFirstCount() throws {
    let book = try LiveBook()
    try book.count([(book.cardKey, 0)], at: book.at("2026-09-20", hour: 9), kind: .opening)
    let reconciliation = Reconciliation(
      date: DateOnly(year: 2026, month: 9, day: 26), reconciledAt: book.at("2026-09-26"),
      actualTotalRubE4: .zero, kind: .accounts)
    let count = ReconciledBalance(
      reconciliationId: reconciliation.id, accountId: book.card.id, currency: .rub,
      actualE4: AmountE4(whole: 1_000), expectedE4: .zero, differenceE4: AmountE4(whole: 1_000),
      recordsDifference: true)
    try book.stack.writer.write { db in
      try reconciliation.insert(db)
      try count.insert(db)
    }
    #expect(
      try ReconciliationRepository(writer: book.stack.writer).settleAll(
        context: book.context
      ).isEmpty)
    #expect(try book.reconcileOperations() == 0)
    #expect(try book.row(count.id) == count)
  }

  // MARK: The first open of a book of 1.1

  /// A book as 1.1.2 leaves it, whose windows got operations dated back while nothing settled
  /// them, written the way 1.1 wrote them — straight into the rows:
  ///
  /// * A (Visa, −500, its operation alive under an id of 1.1): a 500 purchase on 05.08;
  /// * C (Вклад, +300, its operation in the bin, so only the numbers are kept): a 100 income on
  ///   05.08;
  /// * F (Вклад, −200, only the numbers): a 50 purchase on 12.08;
  /// * I (Наличные, −1,000, its operation alive under an id of 1.1): a 300 purchase on 14.08.
  private func aBookOfOnePointOneWithEntriesDatedBack(
    named name: String
  ) throws -> OnePointOneBook {
    let old = try OnePointOneBook(named: name)
    let stack = try DatabaseStack(url: old.url, schema: TestSupport.schemaSource, context: .tests)
    let calendar = TestSupport.sampleCalendar
    let spending = try #require(
      old.set.categories.first { $0.kind == .expense && $0.parentId != nil && !$0.isSystem })
    let earning = try #require(old.set.categories.first { $0.kind == .income && !$0.isSystem })
    func raw(
      _ amount: Int64, _ kind: TransactionKind, on day: Int, _ account: PaymentMethod
    ) -> TransactionEntry {
      let moment = calendar.startOfDay(DateOnly(year: 2026, month: 8, day: day))
        .addingTimeInterval(12 * 3_600)
      let id = UUID()
      return TransactionEntry(
        transaction: Transaction(
          id: id, kind: kind, occurredAt: moment, amountE4: AmountE4(whole: amount),
          paymentMethodId: account.id, createdAt: moment.addingTimeInterval(30 * 86_400),
          updatedAt: moment.addingTimeInterval(30 * 86_400)),
        parts: [
          TransactionPart(
            transactionId: id, categoryId: kind == .expense ? spending.id : earning.id,
            amountE4: AmountE4(whole: amount))
        ])
    }
    try stack.writer.write { db in
      for entry in [
        raw(500, .expense, on: 5, old.visa), raw(100, .income, on: 5, old.deposit),
        raw(50, .expense, on: 12, old.deposit), raw(300, .expense, on: 14, old.cash),
      ] {
        try entry.transaction.insert(db)
        for part in entry.parts { try part.insert(db) }
      }
    }
    try stack.close()
    return old
  }

  @Test func settleAllCatchesUpA11Base() throws {
    let old = try aBookOfOnePointOneWithEntriesDatedBack(named: "catch-up")
    defer { old.remove() }
    let stack = try DatabaseStack(url: old.url, schema: TestSupport.schemaSource, context: .tests)
    defer { try? stack.close() }
    let context = LiveCountsContext(calendar: TestSupport.sampleCalendar, categoryName: "Сверка")
    func row(_ letter: String) throws -> ReconciledBalance {
      let id = try #require(old.rows[letter]).id
      return try #require(
        try stack.writer.read { db in try ReconciledBalance.fetchOne(db, key: id.uuidString) })
    }
    func entry(_ id: UUID?) throws -> TransactionEntry? {
      guard let id else { return nil }
      return try stack.writer.read { db in try TransactionRepository.entry(id: id, db: db) }
    }
    let a = try row("A")
    let c = try row("C")
    let h = try row("H")
    let i = try row("I")
    let aOperation = try #require(a.transactionId)
    let cOperation = try #require(old.rows["C"]?.transactionId)
    let iOperation = try #require(i.transactionId)
    #expect(aOperation != ReconcileDifferenceIds.operation(forCount: a.id))
    #expect(iOperation != ReconcileDifferenceIds.operation(forCount: i.id))
    let totalOperation = try #require(
      old.entries.first {
        $0.transaction.externalId?.hasPrefix("reconcile:") == true
          && $0.transaction.externalId?.filter { $0 == ":" }.count == 1
      })
    let totalBefore = try entry(totalOperation.id)

    let settled = try ReconciliationRepository(writer: stack.writer).settleAll(context: context)

    // A: the purchase explains the difference; its operation of 1.1 goes for good.
    #expect(try row("A").differenceE4 == .zero)
    #expect(try row("A").transactionId == nil)
    #expect(try row("A").recordsDifference == true)
    #expect(try entry(aOperation) == nil)
    // C: in the bin it stays, only the numbers follow.
    #expect(try row("C").expectedE4 == (c.expectedE4 ?? .zero) + AmountE4(whole: 100))
    #expect(try row("C").differenceE4 == AmountE4(whole: 200))
    #expect(try row("C").recordsDifference == false)
    #expect(try entry(cOperation)?.transaction.isDeleted == true)
    #expect(try entry(cOperation)?.transaction.amountE4 == AmountE4(whole: 300))
    // F: only the numbers.
    #expect(try row("F").differenceE4 == AmountE4(whole: -150))
    #expect(try row("F").recordsDifference == false)
    #expect(try row("F").transactionId == nil)
    // I: rewritten in place under its id of 1.1.
    let rewritten = try #require(try entry(iOperation))
    #expect(try row("I").differenceE4 == AmountE4(whole: -700))
    #expect(try row("I").transactionId == iOperation)
    #expect(rewritten.transaction.amountE4 == AmountE4(whole: 700))
    #expect(rewritten.transaction.kind == .expense)
    #expect(!rewritten.transaction.isDeleted)
    // H waits for a rate of the dollar; the total of 1.0.0 is never a count.
    #expect(try row("H") == h)
    #expect(settled.waitingForRate >= 1)
    #expect(try entry(totalOperation.id) == totalBefore)
    #expect(settled.purged == 1)
    #expect(settled.rewritten == 1)
    #expect(settled.created == 0)
    #expect(settled.orphansPurged == 0)

    // A difference of A again: written under the id derived from the count.
    var salary = TransactionDraft(
      kind: .income,
      occurredAt: TestSupport.sampleCalendar.startOfDay(DateOnly(year: 2026, month: 8, day: 6))
        .addingTimeInterval(12 * 3_600),
      amount: AmountE4(whole: 200), paymentMethodId: old.visa.id)
    salary.normalizeSinglePart()
    let later = try TransactionRepository(writer: stack.writer, liveCounts: context)
      .saveReporting(try salary.materialize())
    #expect(later.counts.created == 1)
    let recreated = try #require(try entry(try row("A").transactionId))
    #expect(recreated.id == ReconcileDifferenceIds.operation(forCount: a.id))
    #expect(recreated.transaction.kind == .expense)
    #expect(recreated.transaction.amountE4 == AmountE4(whole: 200))
  }

  @Test func settleAllChangesNothingTwice() throws {
    let old = try aBookOfOnePointOneWithEntriesDatedBack(named: "twice")
    defer { old.remove() }
    let context = LiveCountsContext(calendar: TestSupport.sampleCalendar, categoryName: "Сверка")
    var stack = try DatabaseStack(url: old.url, schema: TestSupport.schemaSource, context: .tests)
    let first = try ReconciliationRepository(writer: stack.writer).settleAll(context: context)
    #expect(!first.isEmpty)
    try stack.close()
    let settledOnce = try old.keep(as: "settled-once.sqlite")
    stack = try DatabaseStack(url: old.url, schema: TestSupport.schemaSource, context: .tests)
    let again = try ReconciliationRepository(writer: stack.writer).settleAll(context: context)
    try stack.close()
    #expect(again.isEmpty)
    #expect(again.countsChanged == 0)
    #expect(try DatabaseStack.sameData(fileAt: old.url, as: settledOnce))
  }

  /// A book as 1.1.2 leaves it, updated and untouched since: the catch-up at open rewrites no
  /// count and no operation of it but the one difference 1.1 could not write for want of a
  /// rate, and a second catch-up writes nothing.
  @Test func settleAllLeavesAnUntouched11BaseByteEqual() throws {
    let old = try OnePointOneBook(named: "live-counts")
    defer { old.remove() }
    try DatabaseStack(url: old.url, schema: TestSupport.schemaSource, context: .tests).close()
    let before = try old.keep(as: "before-settle.sqlite")
    let stack = try DatabaseStack(url: old.url, schema: TestSupport.schemaSource, context: .tests)
    let repository = ReconciliationRepository(writer: stack.writer)
    let context = LiveCountsContext(calendar: TestSupport.sampleCalendar, categoryName: "Сверка")
    let settled = try repository.settleAll(context: context)
    let again = try repository.settleAll(context: context)
    try stack.close()
    #expect(settled.rewritten == 0)
    #expect(settled.purged == 0)
    #expect(settled.orphansPurged == 0)
    #expect(settled.modeChanged == 0)
    // R4's row H recorded +10 $ that 1.1 had no rate to write: the one operation it may add.
    #expect(settled.created <= 1)
    #expect(again.isEmpty)
    if settled.isEmpty {
      #expect(try DatabaseStack.sameData(fileAt: old.url, as: before))
    }
  }
}

// MARK: Edits, rate refinements and money back follow the books in their own write

extension LiveBook {
  /// The difference of `count` under an id of its own, the way 1.1 wrote it: the operation
  /// made under the id derived from the count is written again under another id, and the count
  /// points at that one. Returns the id.
  func asOnePointOne(_ count: ReconciledBalance) throws -> UUID {
    let derived = try #require(try operation(ofCount: count))
    let id = UUID()
    var old = derived
    old.transaction.id = id
    old.parts = derived.parts.map { part in
      var moved = part
      moved.id = UUID()
      moved.transactionId = id
      return moved
    }
    try stack.writer.write { db in
      try db.execute(
        sql: "DELETE FROM transactions WHERE id = ?", arguments: [derived.id.uuidString])
      try old.transaction.insert(db)
      for part in old.parts { try part.insert(db) }
      try db.execute(
        sql: "UPDATE reconciliation_balances SET transaction_id = ? WHERE id = ?",
        arguments: [id.uuidString, count.id.uuidString])
    }
    return id
  }

  /// 100 $ — or `dollars` — paid from the ruble card on `iso` at `rate` rubles a dollar, the
  /// card charged the rubles; provisional at the rate of the day before, as the entry line
  /// writes it offline. `friend` pays the whole of it back later.
  func dollarPurchase(
    _ dollars: Int64 = 100, rate: Decimal, on iso: String, provisional: Bool = true,
    for friend: Person? = nil
  ) throws -> TransactionEntry {
    var entry = operation(dollars, on: iso)
    let rubles = try AmountE4(decimal: Decimal(dollars) * rate)
    entry.transaction.currency = .usd
    entry.transaction.rate = rate
    entry.transaction.rateDate = CalendarContext.utc.day(of: at(iso))
      .adding(days: provisional ? -1 : 0)
    entry.transaction.rateSource = .cbr
    entry.transaction.rateProvisional = provisional
    entry.transaction.amountRubE4 = rubles
    entry.transaction.accountCurrency = .rub
    entry.transaction.accountAmountE4 = rubles
    entry.parts[0].amountRubE4 = rubles
    if let friend {
      entry.parts[0].reimbursable = true
      entry.parts[0].reimbursementStatus = .expected
      entry.parts[0].debtorPersonId = friend.id
      entry.parts[0].forWhom = .friends
    }
    return entry
  }
}

extension LiveCountsStorageTests {

  /// Counts of 01.09 (the first), 20.09 and 30.09, both agreeing with the books; a 2,000
  /// expense is moved by an edit from 05.09 to 25.09. The 20.09 count now misses 2,000 of
  /// spending (an expense of 2,000), the 30.09 count holds 2,000 more than the books (an income
  /// of 2,000) — written by the edit itself; its undo takes both back.
  @Test func anEditMovingTheDaySettlesBothCounts() throws {
    let book = try LiveBook()
    try book.count([(book.cardKey, 102_000)], at: book.at("2026-09-01", hour: 9))
    let lunch = try book.transactions.save(book.operation(2_000, on: "2026-09-05"))
    let twentieth = try book.count([(book.cardKey, 100_000)], at: book.at("2026-09-20", hour: 10))
      .counts[0]
    try book.transactions.save(book.operation(10_000, on: "2026-09-22"))
    let thirtieth = try book.count([(book.cardKey, 90_000)], at: book.at("2026-09-30", hour: 10))
      .counts[0]
    #expect(twentieth.differenceE4 == .zero)
    #expect(thirtieth.differenceE4 == .zero)

    let result = try book.transactions.edit(
      id: lunch.id, at: book.at("2026-10-01"), calendar: .utc
    ) { entry in
      var moved = entry
      moved.transaction.occurredAt = book.at("2026-09-25")
      return moved
    }
    guard case .edited(let edited) = result else {
      Issue.record("the edit was not written: \(result)")
      return
    }
    #expect(edited.counts.created == 2)
    #expect(edited.counts.upserted.count == 2)
    #expect(try book.row(twentieth.id)?.expectedE4 == AmountE4(whole: 102_000))
    #expect(try book.row(twentieth.id)?.differenceE4 == AmountE4(whole: -2_000))
    let spending = try #require(try book.operation(ofCount: twentieth))
    #expect(spending.transaction.kind == .expense)
    #expect(spending.transaction.amountE4 == AmountE4(whole: 2_000))
    #expect(try book.row(thirtieth.id)?.expectedE4 == AmountE4(whole: 88_000))
    #expect(try book.row(thirtieth.id)?.differenceE4 == AmountE4(whole: 2_000))
    let income = try #require(try book.operation(ofCount: thirtieth))
    #expect(income.transaction.kind == .income)
    #expect(income.transaction.amountE4 == AmountE4(whole: 2_000))

    let back = try book.transactions.revert(edited)
    #expect(back.purged == 2)
    #expect(Set(back.removed) == [spending.id, income.id])
    #expect(try book.row(twentieth.id)?.differenceE4 == .zero)
    #expect(try book.row(thirtieth.id)?.differenceE4 == .zero)
    #expect(try book.reconcileOperations() == 0)
  }

  /// The owner commented a difference written by 1.1 under an id of its own; a backdated entry
  /// took it to zero, and its ⌘Z made it again under the id derived from the count. ⌘Z of the
  /// comment then lands: the operation made again gives way to the one the owner edited, which
  /// is back with its old comment and the amount of now.
  @Test func revertingAnEditOfADifferenceAfterRecreationLands() throws {
    let book = try LiveBook()
    let (_, count) = try book.september()
    let oldId = try book.asOnePointOne(count)
    let result = try book.transactions.edit(
      id: oldId, at: book.at("2026-09-21"), calendar: .utc
    ) { entry in
      var noted = entry
      noted.transaction.note = "lost somewhere"
      return noted
    }
    guard case .edited(let edited) = result else {
      Issue.record("the edit was not written: \(result)")
      return
    }
    #expect(edited.counts.isEmpty)
    let (cafe, settled) = try book.transactions.saveReporting(
      book.operation(8_000, on: "2026-09-12"))
    #expect(settled.purged == 1)
    try book.transactions.purge(id: cafe.id)
    let made = try #require(try book.operation(ofCount: count))
    #expect(made.id == ReconcileDifferenceIds.operation(forCount: count.id))

    try book.transactions.revert(edited)

    let back = try #require(try book.operation(ofCount: count))
    #expect(back.id == oldId)
    #expect(back.transaction.note == nil)
    #expect(back.transaction.amountE4 == AmountE4(whole: 8_000))
    #expect(!back.transaction.isDeleted)
    #expect(try book.row(count.id)?.transactionId == oldId)
    #expect(try book.row(count.id)?.recordsDifference == true)
    #expect(try book.reconcileOperations() == 1)
  }

  /// The difference's money is the count's: an edit of its amount or its account, or one filing
  /// it under «Цели», is refused inside the write; its comment is the owner's.
  @Test func anEditOfADifferencesMoneyIsRefused() throws {
    let book = try LiveBook()
    let (_, count) = try book.september()
    let operation = try #require(try book.operation(ofCount: count))
    let goals = CoreKit.Category(kind: .expense, name: "Goals", systemRole: .goals)
    try ReferenceRepository(writer: book.stack.writer).save(goals)
    let edits: [(TransactionEntry) -> TransactionEntry] = [
      { entry in
        var changed = entry
        changed.transaction.amountE4 = AmountE4(whole: 5_000)
        changed.parts[0].amountE4 = AmountE4(whole: 5_000)
        return changed
      },
      { entry in
        var changed = entry
        changed.transaction.paymentMethodId = book.cash.id
        return changed
      },
      { entry in
        var changed = entry
        changed.parts[0].categoryId = goals.id
        return changed
      },
    ]
    for edit in edits {
      #expect(throws: DifferenceEditRefusal.reconciliationDifference) {
        try book.transactions.edit(id: operation.id, calendar: .utc) { edit($0) }
      }
    }
    #expect(try book.operation(ofCount: count) == operation)
    let noted = try book.transactions.edit(id: operation.id, calendar: .utc) { entry in
      var changed = entry
      changed.transaction.note = "lost at the market"
      return changed
    }
    guard case .edited = noted else {
      Issue.record("the comment was not written: \(noted)")
      return
    }
    #expect(try book.operation(ofCount: count)?.transaction.note == "lost at the market")
  }

  /// 100 $ paid from the ruble card on 12.09 at a provisional 92.00: 9,200 ₽ inside the window
  /// of the 20.09 count (40,000 counted, 40,800 expected: −800). The bank's 92.35 makes the
  /// charge 9,235 ₽, and the refinement's own write makes the difference −765.
  @Test func aRateRefinementSettlesTheRubleLeg() throws {
    let book = try LiveBook()
    try book.count([(book.cardKey, 50_000)], at: book.at("2026-09-01", hour: 9))
    try book.transactions.save(book.dollarPurchase(rate: 92, on: "2026-09-12"))
    let count = try book.count([(book.cardKey, 40_000)], at: book.at("2026-09-20", hour: 10))
      .counts[0]
    #expect(count.differenceE4 == AmountE4(whole: -800))

    let usages = try book.transactions.provisionalUsages(calendar: .utc)
    #expect(usages.count == 1)
    let table = RateTable(
      rates: [
        Rate(
          date: DateOnly(year: 2026, month: 9, day: 12), currency: .usd,
          rubPerUnit: Decimal(string: "92.35")!, source: .cbr)
      ], unpublishedDays: [:])
    let refined = try book.transactions.applyRefinements(
      RateTable.refinement(for: usages, with: table), of: usages, calendar: .utc,
      at: book.at("2026-09-21"))
    #expect(refined == 1)

    let row = try #require(try book.row(count.id))
    #expect(row.expectedE4 == AmountE4(whole: 40_765))
    #expect(row.differenceE4 == AmountE4(whole: -765))
    #expect(try book.operation(ofCount: count)?.transaction.amountE4 == AmountE4(whole: 765))
  }

  /// 20 $ paid for a friend from the ruble card on 12.09 at 90: 1,800 ₽ inside the window of the
  /// 20.09 count (48,000 counted, 48,200 expected: −200). The friend gives back 1,760 ₽ on 25.09
  /// in cash, and the sheet corrects the purchase's rate to 88 from the statement: the card was
  /// charged 1,760 ₽, and the money back's own write makes the difference −240. Its ⌘Z puts the
  /// purchase back at 90 and the difference back at −200.
  @Test func aRepricedPurchaseSettlesItsWindow() throws {
    let book = try LiveBook()
    let friend = Person(name: "Friend")
    try ReferenceRepository(writer: book.stack.writer).save(friend)
    try book.count([(book.cardKey, 50_000)], at: book.at("2026-09-01", hour: 9))
    let purchase = try book.transactions.save(
      book.dollarPurchase(20, rate: 90, on: "2026-09-12", provisional: false, for: friend))
    let count = try book.count([(book.cardKey, 48_000)], at: book.at("2026-09-20", hour: 10))
      .counts[0]
    #expect(count.differenceE4 == AmountE4(whole: -200))

    let cameBack = book.at("2026-09-25")
    let repriced = try PurchaseRate.repriced(
      purchase, rate: 88, day: CalendarContext.utc.day(of: purchase.transaction.occurredAt))
    let owed = PurchaseRate.repriced(
      [OwedPart(part: purchase.parts[0], in: purchase.transaction)], of: repriced)
    let plan = MoneyBack.plan(
      received: AmountE4(whole: 1_760), currency: .rub, receivedRub: AmountE4(whole: 1_760),
      rateProvisional: false, person: friend.id, owed: owed, openDebts: [])
    var draft = TransactionDraft(
      kind: .reimbursement, occurredAt: cameBack, currency: .rub,
      amount: AmountE4(whole: 1_760), paymentMethodId: book.cash.id)
    draft.normalizeSinglePart()
    let back = try draft.materialize(now: cameBack)
    let outcome = MoneyBack.outcome(plan, reimbursementTxId: back.id, accountId: book.cash.id)
    #expect(outcome.surplus == nil)

    let write = try book.transactions.apply(
      outcome, reimbursement: back, repricing: [purchase.id: 88], calendar: .utc, at: cameBack)
    #expect(write.counts.rewritten == 1)
    #expect(try book.row(count.id)?.differenceE4 == AmountE4(whole: -240))
    #expect(try book.operation(ofCount: count)?.transaction.amountE4 == AmountE4(whole: 240))

    let undone = try book.transactions.revertMoneyBack(write, at: book.at("2026-09-26"))
    #expect(undone.rewritten == 1)
    #expect(try book.row(count.id)?.differenceE4 == AmountE4(whole: -200))
    #expect(try book.operation(ofCount: count)?.transaction.amountE4 == AmountE4(whole: 200))
  }

  /// Money back dated inside a count's window is money that came onto the account then: its
  /// write settles the count, and its ⌘Z settles it back.
  @Test func aMoneyBackInsideAWindowSettlesAndItsUndoToo() throws {
    let book = try LiveBook()
    let friend = Person(name: "Friend")
    try ReferenceRepository(writer: book.stack.writer).save(friend)
    try book.count([(book.cardKey, 50_000)], at: book.at("2026-09-01", hour: 9))
    var dinner = book.operation(3_000, on: "2026-09-05")
    dinner.parts[0].reimbursable = true
    dinner.parts[0].reimbursementStatus = .expected
    dinner.parts[0].debtorPersonId = friend.id
    dinner.parts[0].forWhom = .friends
    let purchase = try book.transactions.save(dinner)
    let count = try book.count([(book.cardKey, 50_000)], at: book.at("2026-09-20", hour: 10))
      .counts[0]
    #expect(count.differenceE4 == AmountE4(whole: 3_000))

    let cameBack = book.at("2026-09-10")
    let plan = MoneyBack.plan(
      received: AmountE4(whole: 3_000), currency: .rub, receivedRub: AmountE4(whole: 3_000),
      rateProvisional: false, person: friend.id,
      owed: [OwedPart(part: purchase.parts[0], in: purchase.transaction)], openDebts: [])
    var draft = TransactionDraft(
      kind: .reimbursement, occurredAt: cameBack, currency: .rub,
      amount: AmountE4(whole: 3_000), paymentMethodId: book.card.id)
    draft.normalizeSinglePart()
    let back = try draft.materialize(now: cameBack)
    let outcome = MoneyBack.outcome(plan, reimbursementTxId: back.id, accountId: book.card.id)
    let write = try book.transactions.apply(
      outcome, reimbursement: back, calendar: .utc, at: book.at("2026-09-21"))
    #expect(write.counts.purged == 1)
    #expect(try book.row(count.id)?.differenceE4 == .zero)
    #expect(try book.operation(ofCount: count) == nil)

    let undone = try book.transactions.revertMoneyBack(write, at: book.at("2026-09-22"))
    #expect(undone.created == 1)
    #expect(try book.row(count.id)?.differenceE4 == AmountE4(whole: 3_000))
    #expect(try book.operation(ofCount: count)?.transaction.kind == .income)
  }

  /// «Записывать разницу» on a count whose difference 1.1 wrote under an id of its own and the
  /// owner put in the bin: the new operation takes the place of the binned one — they share the
  /// count's key, which is unique —, and ⌘Z gives back the count that kept and the operation in
  /// the bin, under its own id.
  @Test func recordingAgainOverAOnePointOneDifferenceInTheBinLandsAndUndoes() throws {
    let book = try LiveBook()
    let (_, count) = try book.september()
    let oldId = try book.asOnePointOne(count)
    _ = try book.transactions.softDelete(ids: [oldId], at: book.at("2026-09-21"))
    let keeping = try #require(try book.row(count.id))
    #expect(keeping.recordsDifference == false)

    var asked = keeping
    asked.recordsDifference = true
    asked.transactionId = nil
    var rows = PlanningRows.empty
    rows.reconciledBalances = [asked]
    let undo = try book.planning.apply(
      PlanningChange(upsert: rows, at: book.at("2026-09-22"), settles: [book.cardKey]))

    let written = try #require(try book.operation(ofCount: count))
    #expect(!written.transaction.isDeleted)
    #expect(written.transaction.amountE4 == AmountE4(whole: 8_000))
    #expect(try book.row(count.id)?.recordsDifference == true)
    #expect(try book.row(count.id)?.transactionId == written.id)
    #expect(try book.reconcileOperations() == 1)

    try book.planning.revert(undo, at: book.at("2026-09-23"))

    let back = try #require(try book.operation(ofCount: count))
    #expect(back.id == oldId)
    #expect(back.transaction.isDeleted)
    #expect(try book.row(count.id)?.recordsDifference == false)
    #expect(try book.row(count.id)?.transactionId == nil)
    #expect(try book.reconcileOperations() == 1)
  }
}
