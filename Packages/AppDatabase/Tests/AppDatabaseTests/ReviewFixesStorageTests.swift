import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// Storage cases a review of the planning and the debts found: a deleted «Mark as paid»
/// operation gives its due date back, and undo puts removed rows back where they were.
@Suite("Review fixes: deleted payments and restored rows")
struct ReviewFixesStorageTests {
  let due = DateOnly(year: 2026, month: 9, day: 10)

  /// Internet, 500 ₽ on the 10th of every month, marked as paid for 10 September: the
  /// operation carries `sched:<payment>:2026-09-10` and the payment moved on to 10 October.
  private func paidInternet(
    _ stack: DatabaseStack
  ) throws -> (payment: ScheduledPayment, operation: TransactionEntry) {
    var payment = ScheduledPayment(
      name: "Internet", amountE4: AmountE4(whole: 500), day: 10, nextDate: due)
    payment.nextDate = DateOnly(year: 2026, month: 10, day: 10)
    let operation = try markAsPaid(payment, on: due)
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(created: [operation], upsert: PlanningRows(scheduled: [payment])))
    return (payment, operation)
  }

  private func markAsPaid(
    _ payment: ScheduledPayment, on due: DateOnly
  ) throws -> TransactionEntry {
    var entry = try TestSupport.makeEntry(amount: 5_000_000, note: nil)
    entry.transaction.externalId = key(payment, due)
    return entry
  }

  private func key(_ payment: ScheduledPayment, _ due: DateOnly) -> String {
    OperationLink.scheduled(paymentId: payment.id, due: due).externalId
  }

  private func externalId(of id: UUID, _ stack: DatabaseStack) throws -> String? {
    try stack.writer.read { db in
      try String.fetchOne(
        db, sql: "SELECT external_id FROM transactions WHERE id = ?", arguments: [id.uuidString])
    }
  }

  /// Deleted in Transactions (not with ⌘Z): 10 September is owed again, and paying it once
  /// more is not refused by the unique key of the deleted operation.
  @Test func aDeletedPaymentGivesItsDueDateBack() throws {
    let stack = try TestSupport.makeStack()
    let (payment, operation) = try paidInternet(stack)
    let transactions = TransactionRepository(writer: stack.writer)
    let planning = PlanningRepository(writer: stack.writer)

    let effects = try transactions.softDelete(ids: [operation.id])
    #expect(try planning.scheduled().first?.nextDate == due)
    #expect(try externalId(of: operation.id, stack) == nil)
    let released = "sched:\(payment.id.uuidString.lowercased()):2026-09-10"
    #expect(effects.releasedExternalIds == [operation.id: released])
    #expect(effects.reopenedPayments.map(\.nextDate) == [DateOnly(year: 2026, month: 10, day: 10)])

    let again = try markAsPaid(payment, on: due)
    _ = try planning.apply(
      PlanningChange(created: [again], upsert: PlanningRows(scheduled: [payment])))
    #expect(try externalId(of: again.id, stack) == key(payment, due))
  }

  /// Undo of the deletion puts the key and the schedule back as they were.
  @Test func restoringTheDeletedPaymentPaysTheDateAgain() throws {
    let stack = try TestSupport.makeStack()
    let (payment, operation) = try paidInternet(stack)
    let transactions = TransactionRepository(writer: stack.writer)
    let effects = try transactions.softDelete(ids: [operation.id])
    try transactions.restore(ids: [operation.id], effects: effects)
    #expect(try externalId(of: operation.id, stack) == key(payment, due))
    #expect(
      try PlanningRepository(writer: stack.writer).scheduled().first?.nextDate
        == DateOnly(year: 2026, month: 10, day: 10))
  }

  /// Paid anew in the meantime: the restored operation keeps no key, since the date has its
  /// payment, and the schedule stays where the new payment left it.
  @Test func restoringAfterPayingAgainKeepsOnePayment() throws {
    let stack = try TestSupport.makeStack()
    let (payment, operation) = try paidInternet(stack)
    let transactions = TransactionRepository(writer: stack.writer)
    let planning = PlanningRepository(writer: stack.writer)
    let effects = try transactions.softDelete(ids: [operation.id])
    let again = try markAsPaid(payment, on: due)
    _ = try planning.apply(
      PlanningChange(created: [again], upsert: PlanningRows(scheduled: [payment])))

    try transactions.restore(ids: [operation.id], effects: effects)
    #expect(try externalId(of: operation.id, stack) == nil)
    #expect(try externalId(of: again.id, stack) != nil)
    #expect(try planning.scheduled().first?.nextDate == DateOnly(year: 2026, month: 10, day: 10))
  }

  /// A payment paid on to November: deleting the September operation alone leaves the
  /// schedule, deleting both gives back both dates, the earliest first.
  @Test func onlyTheLatestPaidDateGoesBack() throws {
    let stack = try TestSupport.makeStack()
    var payment = ScheduledPayment(
      name: "Internet", amountE4: AmountE4(whole: 500), day: 10,
      nextDate: DateOnly(year: 2026, month: 11, day: 10))
    let september = try markAsPaid(payment, on: due)
    let october = try markAsPaid(payment, on: DateOnly(year: 2026, month: 10, day: 10))
    let planning = PlanningRepository(writer: stack.writer)
    _ = try planning.apply(
      PlanningChange(created: [september, october], upsert: PlanningRows(scheduled: [payment])))
    let transactions = TransactionRepository(writer: stack.writer)

    let one = try transactions.softDelete(ids: [september.id])
    #expect(try planning.scheduled().first?.nextDate == DateOnly(year: 2026, month: 11, day: 10))
    try transactions.restore(ids: [september.id], effects: one)

    let both = try transactions.softDelete(ids: [september.id, october.id])
    #expect(try planning.scheduled().first?.nextDate == due)
    try transactions.restore(ids: [september.id, october.id], effects: both)
    payment = try #require(try planning.scheduled().first)
    #expect(payment.nextDate == DateOnly(year: 2026, month: 11, day: 10))
  }

  /// Three limits; the first is deleted and ⌘Z brings it back first, not last.
  @Test func undoPutsARemovedLimitBackInItsPlace() throws {
    let stack = try TestSupport.makeStack()
    let references = try TestSupport.seedReferences(stack)
    let repository = PlanningRepository(writer: stack.writer)
    let limits = [
      Budget(
        scope: .category, categoryId: references.category.id,
        amountE4: AmountE4(whole: 20_000)),
      Budget(scope: .badTotal, amountE4: AmountE4(whole: 5_000)),
      Budget(scope: .forWhom, forWhom: .me, amountE4: AmountE4(whole: 30_000)),
    ]
    _ = try repository.apply(PlanningChange(upsert: PlanningRows(budgets: limits)))
    #expect(try repository.budgets().map(\.id) == limits.map(\.id))

    let undo = try repository.apply(PlanningChange(delete: PlanningRowIDs(budgets: [limits[0].id])))
    #expect(try repository.budgets().map(\.id) == [limits[1].id, limits[2].id])
    try repository.revert(undo)
    #expect(try repository.budgets() == limits)

    // The category takes its limit with it; undo brings it back in its place as well.
    let cascade = try repository.apply(
      PlanningChange(delete: PlanningRowIDs(categories: [references.category.id])))
    #expect(try repository.budgets().map(\.id) == [limits[1].id, limits[2].id])
    try repository.revert(cascade)
    #expect(try repository.budgets() == limits)
  }
}
