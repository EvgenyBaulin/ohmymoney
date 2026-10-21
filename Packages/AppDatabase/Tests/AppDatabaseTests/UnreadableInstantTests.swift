import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// An instant a hand edit or another program wrote as something no reader can make sense of
/// stops the read with `UnreadableValue` naming its column — never the program, which would
/// stop again at every start, since the whole history is read at every start. Where an instant
/// is only a note — when a rate was fetched, when an anomaly was waved away — it reads as none.
/// Every form GRDB writes or reads — with a space or a `T`, to the second or the millisecond —
/// still reads.
@Suite("An unreadable instant stops the read, not the program")
struct UnreadableInstantTests {
  private func stack(with sql: String) throws -> DatabaseStack {
    let stack = try TestSupport.makeStack()
    let references = try TestSupport.seedReferences(stack)
    try stack.writer.write { db in
      try db.execute(
        sql: sql,
        arguments: ["account": references.paymentMethod.id.uuidString, "id": UUID().uuidString])
    }
    return stack
  }

  private func load(_ stack: DatabaseStack) throws -> Dataset {
    try stack.writer.read { db in try DatasetRepository.dataset(db, version: 1) }
  }

  @Test(arguments: ["created_at", "updated_at", "occurred_at", "deleted_at"])
  func anOperationWithAnUnreadableInstantStopsTheLoad(column: String) throws {
    let values = ["occurred_at", "created_at", "updated_at"].map {
      $0 == column ? "'soon'" : "'2026-09-01 10:00:00.000'"
    }
    let deleted = column == "deleted_at" ? "'yesterday'" : "NULL"
    let stack = try stack(
      with: """
        INSERT INTO transactions (id, kind, occurred_at, created_at, updated_at, deleted_at,
          currency, amount_e4, amount_rub_e4, payment_method_id)
        VALUES (:id, 'expense', \(values[0]), \(values[1]), \(values[2]), \(deleted), 'RUB', 1, 1,
          :account)
        """)
    if column == "deleted_at" {
      // A deleted operation is not loaded; reading it by its id says what is wrong with it.
      #expect(throws: UnreadableValue(column: column)) {
        try stack.writer.read { db in try CoreKit.Transaction.fetchAll(db) }
      }
    } else {
      #expect(throws: UnreadableValue(column: column)) { try load(stack) }
    }
  }

  @Test func aTransferOrACountWithAnUnreadableMomentStopsTheLoad() throws {
    let transfer = try stack(
      with: """
        INSERT INTO transfers (id, occurred_at, from_payment_method_id, from_currency,
          from_amount_e4, to_payment_method_id, to_currency, to_amount_e4, created_at, updated_at)
        VALUES (:id, 'noon', :account, 'RUB', 1, :account, 'USD', 1,
          '2026-09-01 10:00:00.000', '2026-09-01 10:00:00.000')
        """)
    #expect(throws: UnreadableValue(column: "occurred_at")) { try load(transfer) }

    let count = try stack(
      with: """
        INSERT INTO reconciliations (id, date, actual_total_rub_e4, reconciled_at)
        VALUES (:id, '2026-09-01', 0, 'noon')
        """)
    #expect(throws: UnreadableValue(column: "reconciled_at")) { try load(count) }
  }

  /// When a rate was fetched, when an anomaly was waved away, when the owner chose a category:
  /// notes about a row, not what its money is — one that cannot be read reads as none, and the
  /// history loads.
  @Test func anUnreadableNoteOfTimeReadsAsNone() throws {
    let stack = try stack(
      with: """
        INSERT INTO rates (date, currency, rub_per_unit, nominal, source, fetched_at)
          VALUES ('2026-09-01', 'USD', '81.5', 1, 'cbr', 'some day');
        INSERT INTO anomaly_dismissals (id, rule, at, subject)
          VALUES (:id, 'largeExpense', 'some day', 'x');
        """)
    let dataset = try load(stack)
    #expect(dataset.dismissals.count == 1)
    let rates = try stack.writer.read { db in try Rate.fetchAll(db) }
    #expect(rates.count == 1)
    #expect(rates.first?.fetchedAt == nil)
  }

  /// Every form of an instant GRDB reads still reads, to the millisecond.
  @Test(arguments: [
    ("2026-09-01 10:00:00.000", 1_788_256_800.0), ("2026-09-01 10:00:00", 1_788_256_800.0),
    ("2026-09-01T10:00:00.250", 1_788_256_800.25), ("2026-09-01 10:00", 1_788_256_800.0),
  ])
  func everyFormAnInstantIsWrittenInReads(text: String, seconds: Double) throws {
    let stack = try stack(
      with: """
        INSERT INTO transactions (id, kind, occurred_at, created_at, updated_at, currency,
          amount_e4, amount_rub_e4, payment_method_id)
        VALUES (:id, 'expense', '\(text)', '\(text)', '\(text)', 'RUB', 1, 1, :account)
        """)
    let entry = try #require(try load(stack).entries.first)
    #expect(entry.transaction.occurredAt.timeIntervalSince1970 == seconds)
    #expect(entry.transaction.createdAt.timeIntervalSince1970 == seconds)
  }
}
