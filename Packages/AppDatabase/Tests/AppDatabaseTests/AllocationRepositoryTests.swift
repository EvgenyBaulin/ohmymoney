import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// The allocation of an income is one record and one step of ⌘Z: the contributions, the
/// transfers with their `alloc:` keys and the goal whose «transfer on contribution» changed go
/// in together and come back out together; the deletion of an income can take them along.
@Suite("The allocation is one record")
struct AllocationRepositoryTests {
  func tables(_ stack: DatabaseStack) throws -> [String: ExactTable] {
    try stack.writer.read { db in try ExactTables.read(db) }
  }

  struct Book {
    var main = PaymentMethod(name: "Основной", kind: .card, isDefault: true)
    var savings = PaymentMethod(name: "Накопительный", kind: .account, cushion: true)
    var goals = CoreKit.Category(kind: .expense, name: "Цели", systemRole: .goals)
    var trip: CoreKit.Category
    var salary = CoreKit.Category(kind: .income, name: "Заработок")
    var goal: Goal
    var income: TransactionEntry

    init() {
      trip = CoreKit.Category(parentId: goals.id, kind: .expense, name: "Отпуск")
      goal = Goal(
        name: "Отпуск", targetE4: AmountE4(whole: 200_000), subcategoryId: trip.id,
        accountId: savings.id, transfersOnContribution: true)
      let id = UUID()
      let amount = AmountE4(whole: 120_000)
      income = TransactionEntry(
        transaction: Transaction(
          id: id, kind: .income, occurredAt: Date(timeIntervalSince1970: 1_790_000_000),
          amountE4: amount, paymentMethodId: main.id),
        parts: [TransactionPart(transactionId: id, categoryId: salary.id, amountE4: amount)])
    }
  }

  func book(_ stack: DatabaseStack) throws -> Book {
    let book = Book()
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(
        created: [book.income],
        upsert: PlanningRows(
          categories: [book.goals, book.trip, book.salary], goals: [book.goal],
          paymentMethods: [book.main, book.savings])))
    return book
  }

  @Test func writtenAndTakenBackInOneStep() throws {
    let stack = try TestSupport.makeStack()
    let repository = AllocationRepository(writer: stack.writer)
    let book = try book(stack)
    let sheet = AllocationSheet(
      incomeId: book.income.id, currency: .rub, incomeE4: book.income.transaction.amountE4,
      baseE4: book.income.transaction.amountE4,
      lines: [
        AllocationLine(
          id: "goal", kind: .goal(book.goal.id), suggestedE4: AmountE4(whole: 12_000),
          targetCurrency: .rub, transferTo: book.savings.id),
        AllocationLine(
          id: "cushion", kind: .cushion(book.savings.id), suggestedE4: AmountE4(whole: 10_000),
          targetCurrency: .rub, transferTo: book.savings.id),
      ],
      until: DateOnly(year: 2026, month: 10, day: 31),
      unallocatedE4: book.income.transaction.amountE4)
    let write = Allocation.write(
      sheet: sheet, chosen: ["goal": AmountE4(whole: 12_000), "cushion": AmountE4(whole: 10_000)],
      income: book.income, goals: [book.goal], ids: { UUID() })
    let before = try tables(stack)
    let undo = try repository.write(
      write, settings: [AllocationSettings.cushionAccountKey: book.savings.id.uuidString])
    let linked = try repository.linked(incomeId: book.income.id)
    #expect(linked.contributions.count == 1)
    #expect(linked.transfers.count == 2)
    try stack.writer.read { (db: Database) throws in
      let keys = try String.fetchAll(db, sql: "SELECT external_id FROM transfers")
      #expect(keys.allSatisfy { Allocation.income(ofKey: $0) == book.income.id })
      #expect(
        try String.fetchOne(
          db, sql: "SELECT value FROM settings WHERE key = ?",
          arguments: [AllocationSettings.cushionAccountKey]) == book.savings.id.uuidString)
    }
    try repository.planning.revert(undo)
    #expect(try tables(stack) == before)
  }

  @Test func theIncomeGoesWithItsAllocationInOneStep() throws {
    let stack = try TestSupport.makeStack()
    let repository = AllocationRepository(writer: stack.writer)
    let book = try book(stack)
    let sheet = AllocationSheet(
      incomeId: book.income.id, currency: .rub, incomeE4: book.income.transaction.amountE4,
      baseE4: book.income.transaction.amountE4,
      lines: [
        AllocationLine(
          id: "goal", kind: .goal(book.goal.id), suggestedE4: AmountE4(whole: 12_000),
          targetCurrency: .rub, transferTo: book.savings.id)
      ],
      until: DateOnly(year: 2026, month: 10, day: 31),
      unallocatedE4: book.income.transaction.amountE4)
    try repository.write(
      Allocation.write(
        sheet: sheet, chosen: ["goal": AmountE4(whole: 12_000)], income: book.income,
        goals: [book.goal], ids: { UUID() }))
    let linked = try repository.linked(incomeId: book.income.id)
    let before = try tables(stack)
    let undo = try repository.planning.apply(
      AllocationRepository.deletion(
        incomeIds: [book.income.id], contributions: linked.contributions,
        transfers: linked.transfers))
    try stack.writer.read { (db: Database) throws in
      #expect(
        try Int.fetchOne(db, sql: "SELECT count(*) FROM transactions WHERE deleted_at IS NULL")
          == 0)
      #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM transfers") == 0)
    }
    try repository.planning.revert(undo)
    #expect(try tables(stack) == before)
  }

  @Test func theRulesAreOneStep() throws {
    let stack = try TestSupport.makeStack()
    let repository = AllocationRepository(writer: stack.writer)
    let book = try book(stack)
    let rule = AllocationRule(target: .goal(book.goal.id), amount: .percent(10))
    let before = try tables(stack)
    let undo = try repository.planning.apply(AllocationRepository.rules(saving: [rule]))
    try stack.writer.read { (db: Database) throws in
      #expect(try AllocationRule.fetchAll(db) == [rule])
    }
    try repository.planning.revert(undo)
    #expect(try tables(stack) == before)
  }
}
