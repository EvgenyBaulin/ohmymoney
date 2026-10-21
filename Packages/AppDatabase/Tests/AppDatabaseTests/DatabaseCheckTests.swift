import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// The weekly check of the database: every rule finds the breakage made for it and is quiet on a
/// healthy book; the repair removes the orphans and nothing else.
@Suite("The check of the database")
struct DatabaseCheckTests {
  /// A book with a few operations and the sample of every feature on top of a plain one.
  private static func healthy() throws -> DatabaseStack {
    let stack = try TestSupport.makeStack()
    let sample = SampleDataGenerator(seed: 20_261_020).generate(
      months: 4, endingOn: TestSupport.sampleEnd, calendar: TestSupport.sampleCalendar,
      language: "en"
    ).withEveryFeature(seed: 20_261_020, calendar: TestSupport.sampleCalendar, language: "en")
    try TransactionRepository(writer: stack.writer).insert(HistoryBatch(sample: sample))
    return stack
  }

  /// Runs `statements` with the foreign keys off, the way a damaged file would hold them.
  private static func breaking(_ stack: DatabaseStack, _ statements: [String]) throws {
    try stack.writer.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA foreign_keys = OFF")
      defer { try? db.execute(sql: "PRAGMA foreign_keys = ON") }
      for statement in statements { try db.execute(sql: statement) }
    }
  }

  @Test func aHealthyBookIsQuietAndTheReportCountsOperationsAndAccounts() throws {
    let stack = try Self.healthy()
    let report = try DatabaseCheck.run(stack.writer)
    #expect(report.isHealthy, "\(report.findings)")
    #expect(report.operations > 100)
    #expect(report.accounts >= 2)
    #expect(!report.hasRepairs)
  }

  @Test func anEmptyBookIsHealthyToo() throws {
    let stack = try TestSupport.makeStack()
    let report = try DatabaseCheck.run(stack.writer)
    #expect(report.isHealthy)
    #expect(report.operations == 0)
  }

  @Test func aPartWithNoOperationIsFoundAndRepaired() throws {
    let stack = try Self.healthy()
    try Self.breaking(
      stack,
      [
        """
        INSERT INTO transaction_parts (id, transaction_id, amount_e4, amount_rub_e4)
        VALUES ('orphan-part', 'no-such-operation', 100, 100)
        """
      ])
    let found = try DatabaseCheck.run(stack.writer)
    let finding = try #require(found.findings.first { $0.rule == .foreignKeys })
    #expect(finding.table == "transaction_parts" && finding.count == 1 && finding.isRepairable)
    #expect(found.repairableCount == 1)

    let removed = try DatabaseCheck.repair(stack.writer)

    #expect(removed == 1)
    #expect(try DatabaseCheck.run(stack.writer).isHealthy)
  }

  @Test func theRepairLeavesWhatHoldsMoneyAndReportsIt() throws {
    let stack = try Self.healthy()
    // A debt line with no debt holds an amount: not an orphan to delete.
    try Self.breaking(
      stack,
      [
        """
        INSERT INTO debt_entries (id, debt_id, kind, amount_e4, occurred_at)
        VALUES ('line', 'no-such-debt', 'payment', 5000, '2026-01-01T00:00:00Z')
        """
      ])
    let found = try DatabaseCheck.run(stack.writer)
    let finding = try #require(found.findings.first { $0.rule == .foreignKeys })
    #expect(finding.table == "debt_entries" && !finding.isRepairable)
    #expect(!found.hasRepairs)
    let removed = try DatabaseCheck.repair(stack.writer)
    #expect(removed == 0)
    let kept = try stack.writer.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM debt_entries WHERE id = 'line'")
    }
    #expect(kept == 1)
  }

  @Test func partsThatDoNotAddUpAreReportedAndLeftAlone() throws {
    let stack = try Self.healthy()
    try stack.writer.write { db in
      try db.execute(
        sql: """
          UPDATE transactions SET amount_e4 = amount_e4 + 10000
          WHERE id = (SELECT id FROM transactions WHERE deleted_at IS NULL LIMIT 1)
          """)
    }
    let found = try DatabaseCheck.run(stack.writer)
    let finding = try #require(found.findings.first { $0.rule == .partsSum })
    #expect(finding.count == 1 && !finding.isRepairable)
    #expect(try DatabaseCheck.repair(stack.writer) == 0)
    #expect(try DatabaseCheck.run(stack.writer).findings.contains { $0.rule == .partsSum })
  }

  @Test func anOperationWithNoPartsIsReported() throws {
    let stack = try Self.healthy()
    try stack.writer.write { db in
      try db.execute(
        sql: """
          DELETE FROM transaction_parts WHERE transaction_id =
            (SELECT id FROM transactions WHERE deleted_at IS NULL LIMIT 1)
          """)
    }
    #expect(try DatabaseCheck.run(stack.writer).findings.contains { $0.rule == .partsSum })
  }

  @Test func aDeletedOperationIsNotHeldToTheRule() throws {
    let stack = try Self.healthy()
    try stack.writer.write { db in
      try db.execute(
        sql: """
          UPDATE transactions SET deleted_at = '2026-01-01T00:00:00Z', amount_e4 = amount_e4 + 1
          WHERE id = (SELECT id FROM transactions WHERE deleted_at IS NULL LIMIT 1)
          """)
    }
    #expect(try DatabaseCheck.run(stack.writer).isHealthy)
  }

  @Test func aReconciliationWithNoBalancesIsReported() throws {
    let stack = try Self.healthy()
    try stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO reconciliations
            (id, date, actual_total_rub_e4, kind, reconciled_at)
          VALUES ('bare', '2026-01-01', 0, 'accounts', '2026-01-01T00:00:00Z')
          """)
    }
    let found = try DatabaseCheck.run(stack.writer)
    let finding = try #require(found.findings.first { $0.rule == .reconciliationWithoutBalances })
    #expect(finding.count == 1 && finding.ids == ["bare"])
    // The reconciliation of one total of 1.0.0 is history and holds no balances by design.
    try stack.writer.write { db in
      try db.execute(sql: "DELETE FROM reconciliations WHERE id = 'bare'")
      try db.execute(
        sql:
          "INSERT INTO reconciliations (id, date, actual_total_rub_e4) VALUES ('old', '2026-01-01', 0)"
      )
    }
    #expect(try DatabaseCheck.run(stack.writer).isHealthy)
  }

  @Test func aTransferToItselfIsReported() throws {
    let stack = try Self.healthy()
    // The schema refuses it; a file damaged by hand does not.
    let account = try stack.writer.read { db in
      try String.fetchOne(db, sql: "SELECT id FROM payment_methods LIMIT 1")!
    }
    try stack.writer.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
      defer { try? db.execute(sql: "PRAGMA ignore_check_constraints = OFF") }
      try db.execute(
        sql: """
          INSERT INTO transfers (id, occurred_at, from_payment_method_id, from_currency,
            from_amount_e4, to_payment_method_id, to_currency, to_amount_e4, created_at, updated_at)
          VALUES ('loop', '2026-01-01T00:00:00Z', ?, 'RUB', 100, ?, 'RUB', 100,
            '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
          """,
        arguments: [account, account])
    }
    let found = try DatabaseCheck.run(stack.writer)
    #expect(found.findings.contains { $0.rule == .transferToItself && $0.count == 1 })
  }

  @Test func theChecksOfSqliteAreReadFromTheFile() throws {
    let (stack, directory) = try TestSupport.makeFileStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(try DatabaseCheck.run(stack.writer).isHealthy)
    try stack.close()
  }

  @Test func theCheckWritesNothing() throws {
    let stack = try Self.healthy()
    let before = try stack.writer.read { db in try TestSupport.contents(db) }
    _ = try DatabaseCheck.run(stack.writer)
    let after = try stack.writer.read { db in try TestSupport.contents(db) }
    #expect(before == after)
  }
}
