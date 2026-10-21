import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// A history written again over itself — the Debug menu does it, and so may a future import of
/// the same data — leaves the database exactly as it was: every row, every value, every rowid.
@Suite("A history written again over itself changes nothing")
struct HistoryBatchIdempotenceTests {
  @Test(arguments: [(UInt64(20_260_918), "en"), (7, "ru"), (42, "en")])
  func aSampleWrittenAgainOverItselfChangesNothing(seed: UInt64, language: String) throws {
    let stack = try TestSupport.makeStack()
    let set = SampleDataGenerator(seed: seed).generate(
      months: 4, endingOn: TestSupport.sampleEnd, calendar: TestSupport.sampleCalendar,
      language: language
    ).withAccounts(seed: seed, calendar: TestSupport.sampleCalendar, language: language)
    let repository = TransactionRepository(writer: stack.writer)
    try repository.insert(HistoryBatch(sample: set))
    let before = try stack.writer.read { db in try ExactTables.read(db) }

    try repository.save(HistoryBatch(sample: set))

    let after = try stack.writer.read { db in try ExactTables.read(db) }
    #expect(after == before, "seed \(seed): \(PlanningUndoPropertyTests.difference(before, after))")
  }
}
