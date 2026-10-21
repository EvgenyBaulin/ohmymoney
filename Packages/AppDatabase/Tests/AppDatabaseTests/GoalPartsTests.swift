import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// The parts that name a goal, read for its deletion: every one of them — of live operations and
/// of those in the bin — with its category, and nothing of another goal.
@Suite("The parts of a goal")
struct GoalPartsTests {
  let at = Date(timeIntervalSince1970: 1_789_900_000)

  private func operation(
    on account: UUID, goal: UUID?, category: UUID?, amount: Int64 = 1_000
  ) -> TransactionEntry {
    let transaction = CoreKit.Transaction(
      kind: .expense, occurredAt: at, amountE4: AmountE4(whole: amount), paymentMethodId: account,
      createdAt: at, updatedAt: at)
    return TransactionEntry(
      transaction: transaction,
      parts: [
        TransactionPart(
          transactionId: transaction.id, categoryId: category, amountE4: AmountE4(whole: amount),
          goalId: goal)
      ])
  }

  @Test func everyPartOfTheGoalWithItsCategoryBinIncluded() throws {
    let stack = try TestSupport.makeStack()
    let references = try TestSupport.seedReferences(stack)
    let goal = Goal(name: "Old trip", targetE4: AmountE4(whole: 50_000), archived: true)
    let other = Goal(name: "Car", targetE4: AmountE4(whole: 500_000))
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(upsert: PlanningRows(goals: [goal, other])))
    let account = references.paymentMethod.id
    let live = operation(on: account, goal: goal.id, category: references.category.id)
    let binned = operation(on: account, goal: goal.id, category: nil, amount: 400)
    let elsewhere = operation(on: account, goal: other.id, category: references.category.id)
    let unlinked = operation(on: account, goal: nil, category: references.category.id)
    let transactions = TransactionRepository(writer: stack.writer)
    try transactions.insert([live, binned, elsewhere, unlinked])
    try transactions.softDelete(id: binned.id, at: at)

    let parts = try transactions.goalParts(of: goal.id)
    let expected: [(UUID, UUID?)] = [
      (live.parts[0].id, references.category.id), (binned.parts[0].id, nil),
    ].sorted { $0.0.uuidString < $1.0.uuidString }
    #expect(parts.map(\.partId) == expected.map(\.0))
    #expect(parts.map(\.categoryId) == expected.map(\.1))
    #expect(try transactions.goalParts(of: other.id).map(\.partId) == [elsewhere.parts[0].id])
    #expect(try transactions.goalParts(of: UUID()).isEmpty)
  }
}
