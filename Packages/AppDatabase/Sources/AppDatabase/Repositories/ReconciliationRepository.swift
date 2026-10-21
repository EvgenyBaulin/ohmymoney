import CoreKit
import Foundation
import GRDB

/// Reconciliations of the total with what the owner actually has. Overview asks when the
/// last one was; the planning reads them all.
public struct ReconciliationRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  /// The day of the latest reconciliation, `nil` when there has been none.
  public func latestDate() throws -> DateOnly? {
    try writer.read { db in
      try String.fetchOne(db, sql: "SELECT MAX(date) FROM reconciliations")
        .flatMap(DateOnly.init(iso:))
    }
  }

  /// Every reconciliation, oldest first.
  public func all() throws -> [Reconciliation] {
    try writer.read { db in try Self.all(db) }
  }

  /// Oldest first: by day, then by the instant within the day. A reconciliation made before
  /// the instant was recorded (NULL) comes first among those of its day — SQLite sorts NULL
  /// first — and rows equal in both keep the order they were made in.
  static func all(_ db: Database) throws -> [Reconciliation] {
    try Reconciliation.order(Column("date"), Column("reconciled_at"), Column.rowID).fetchAll(db)
  }

  /// Every counted balance of an account, in the order of `all` — by the day, the moment and
  /// the order of their reconciliations — and within one reconciliation in the order they
  /// were written. The last one of an account and currency is its latest count.
  public func balances() throws -> [ReconciledBalance] {
    try writer.read { db in try Self.balances(db) }
  }

  /// Every live count follows the books once, and every difference whose count is gone goes
  /// (`LiveCountsWriter.settleAll`): the catch-up at open, for counts whose windows got entries
  /// dated back while nothing settled them — the first open of a book of 1.1 — and for anything a
  /// missed path left behind. One write; writes nothing when everything already follows. Not a
  /// step of ⌘Z: the difference is derived by definition.
  @discardableResult
  public func settleAll(
    context: LiveCountsContext = .standard, at instant: Date = Date()
  ) throws -> CountsSettled {
    try writer.write { db in
      try LiveCountsWriter.settleAll(context: context, now: instant, db: db)
    }
  }

  /// `settleAll` off the calling thread, awaited: the catch-up at open runs beside the launch
  /// rather than in its way.
  @discardableResult
  public func settleAllInBackground(
    context: LiveCountsContext = .standard, at instant: Date = Date()
  ) async throws -> CountsSettled {
    try await writer.write { db in
      try LiveCountsWriter.settleAll(context: context, now: instant, db: db)
    }
  }

  static func balances(_ db: Database) throws -> [ReconciledBalance] {
    try ReconciledBalance.fetchAll(
      db,
      sql: """
        SELECT b.* FROM reconciliation_balances b
        JOIN reconciliations r ON r.id = b.reconciliation_id
        ORDER BY r.date, r.reconciled_at, r.rowid, b.rowid
        """)
  }
}
