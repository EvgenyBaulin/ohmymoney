import AppCore
import Foundation
import GRDB

/// What one batch of other devices' versions did to this database. Counts only.
public struct ApplyTally: Sendable, Equatable {
  /// Rows written or deleted because another device's version won.
  public var applied = 0
  /// Rows left alone because a version of mine was made apart from theirs (the conflict list).
  public var conflicts = 0
  /// Rows put off to the next exchange: an edit of mine was not in a file yet, or the row broke
  /// a rule of this database.
  public var deferred = 0
  /// Rows of a table this build does not know.
  public var unknownTable = 0
}

/// Applies the versions other devices made to the live database (`RecordApplier`).
///
/// One transaction for the batch, foreign keys checked at its end, so a part may arrive before
/// its operation. A batch that leaves a key pointing nowhere fails as a whole and is offered
/// again; a row that breaks any other rule is put off alone. Nothing it writes is journaled
/// again: the lines the triggers wrote for these writes are removed in the same transaction.
final class DatabaseRecordApplier: RecordApplier, @unchecked Sendable {
  private let writer: any DatabaseWriter
  private let ownDeviceId: String
  private let lock = NSLock()
  private var tally = ApplyTally()

  init(writer: any DatabaseWriter, ownDeviceId: String) {
    self.writer = writer
    self.ownDeviceId = ownDeviceId
  }

  /// What the batches since the last call did.
  func takeTally() -> ApplyTally {
    lock.withLock {
      defer { tally = ApplyTally() }
      return tally
    }
  }

  func apply(_ records: [ResolvedRecord]) throws {
    guard !records.isEmpty else { return }
    let batch = try writer.write { db -> ApplyTally in
      try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
      let marker = try SyncBook.maxOutboxSeq(db)
      var batch = ApplyTally()
      for record in records {
        try SyncBook.undefer(db, record.key)
        guard SyncTables.followed[record.key.table] != nil else {
          batch.unknownTable += 1
          continue
        }
        switch record.disposition(ownDeviceId: ownDeviceId) {
        case .keepLocal:
          continue
        case .conflict:
          batch.conflicts += 1
          continue
        case .applyWinner:
          break
        }
        // An edit of mine that is not in a file yet may be what the other side overwrote.
        if try SyncBook.hasPendingChange(db, record.key, upTo: marker) {
          try SyncBook.defer_(db, record.key)
          batch.deferred += 1
          continue
        }
        do {
          try db.inSavepoint {
            try SyncRows.write(
              db, table: record.key.table, key: record.key.uuid, fields: record.fields)
            return .commit
          }
          try SyncBook.setHead(db, record.key, record.winner.stamp)
          batch.applied += 1
        } catch let error as GRDB.DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
          try SyncBook.defer_(db, record.key)
          batch.deferred += 1
        }
      }
      try db.execute(sql: "DELETE FROM sync_outbox WHERE seq > ?", arguments: [marker])
      return batch
    }
    lock.withLock {
      tally.applied += batch.applied
      tally.conflicts += batch.conflicts
      tally.deferred += batch.deferred
      tally.unknownTable += batch.unknownTable
    }
  }
}
