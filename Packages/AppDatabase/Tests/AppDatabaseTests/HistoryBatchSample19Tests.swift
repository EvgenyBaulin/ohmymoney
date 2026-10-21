import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// The sample with its credit and allocation lands whole: the costs of a loan, the rules of
/// allocation, a currency of the owner's own with its rates, and the main card of an account —
/// set once the cards are there, since the schema refuses a main card the account does not have
/// yet —; and written again over itself, it changes nothing.
@Suite("A sample with credit and allocation in one write")
struct HistoryBatchSample19Tests {
  static func set(seed: UInt64, language: String) -> SampleDataSet {
    SampleDataGenerator(seed: seed).generate(
      months: 4, endingOn: TestSupport.sampleEnd, calendar: TestSupport.sampleCalendar,
      language: language
    ).withEveryFeature(seed: seed, calendar: TestSupport.sampleCalendar, language: language)
  }

  @Test(arguments: [(UInt64(20_260_918), "en"), (7, "ru")])
  func theNewRowsLand(seed: UInt64, language: String) throws {
    let stack = try TestSupport.makeStack()
    let set = Self.set(seed: seed, language: language)
    #expect(!set.debtCosts.isEmpty && !set.allocationRules.isEmpty && !set.rates.isEmpty)
    try TransactionRepository(writer: stack.writer).insert(HistoryBatch(sample: set))
    try stack.writer.read { db in
      #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM debt_costs") == set.debtCosts.count)
      #expect(
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM allocation_rules")
          == set.allocationRules.count)
      #expect(
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM custom_currencies")
          == set.customCurrencies.count)
      #expect(
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rates WHERE source = 'manual'")
          == set.rates.count)
      let main = try #require(set.paymentMethods.first { $0.mainCardId != nil })
      #expect(
        try String.fetchOne(
          db, sql: "SELECT main_card_id FROM payment_methods WHERE id = ?",
          arguments: [main.id.uuidString]) == main.mainCardId?.uuidString)
      #expect(
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM payment_methods WHERE credit_limit_e4 > 0")
          == 1)
      #expect(
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM debts WHERE terms_reviewed = 0") == 0)
    }
  }

  @Test(arguments: [(UInt64(20_260_918), "en"), (42, "ru")])
  func writtenAgainOverItselfItChangesNothing(seed: UInt64, language: String) throws {
    let stack = try TestSupport.makeStack()
    let set = Self.set(seed: seed, language: language)
    let repository = TransactionRepository(writer: stack.writer)
    try repository.insert(HistoryBatch(sample: set))
    let before = try stack.writer.read { db in try ExactTables.read(db) }

    try repository.save(HistoryBatch(sample: set))

    let after = try stack.writer.read { db in try ExactTables.read(db) }
    #expect(after == before, "seed \(seed): \(PlanningUndoPropertyTests.difference(before, after))")
  }
}
