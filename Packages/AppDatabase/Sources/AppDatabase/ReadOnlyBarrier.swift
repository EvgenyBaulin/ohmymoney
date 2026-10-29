import Foundation
import GRDB
import SQLite3

/// The last wall of «Только просмотр»: while it is on, the database refuses to insert, update or
/// delete a row of the owner's books, whoever asks. The screens stop the owner earlier (buttons
/// are off, the entry line is gone); this is what makes sure nothing slips past them.
///
/// It works through the SQLite authorizer of the one writing connection, so it costs nothing
/// when it is off and nothing at all for reads. The tables the app keeps by itself -- the bank's
/// rates, the category model, the exchange bookkeeping and the settings (the mode itself is one of
/// them) -- stay writable: they hold no entry of the owner's books.
public final class ReadOnlyBarrier: @unchecked Sendable {
  private let lock = NSLock()
  private var on = false

  public init() {}

  public var isOn: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return on
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      on = newValue
    }
  }

  /// What a refused write throws: the change was rolled back.
  public struct Refusal: Error, LocalizedError, Sendable {
    public var errorDescription: String? { "The books are read-only: the change is refused." }
  }

  /// Tables a write to which is never refused.
  public static let writableTables: Set<String> = [
    "settings", "rates", "rates_new", "ml_models", "category_feedback", "sync_meta",
    "sync_outbox", "sync_heads", "sync_deferred", "sync_resolutions", "sync_state",
  ]

  /// Whether a write of `kind` to `table` goes through while the barrier is on. `kind` is the
  /// SQLite action code: insert, update or delete; anything else is not a write of a row.
  public static func refuses(action: Int32, table: String?, database: String?) -> Bool {
    guard action == SQLITE_INSERT || action == SQLITE_UPDATE || action == SQLITE_DELETE else {
      return false
    }
    guard let table else { return false }
    if database == "temp" || table.hasPrefix("sqlite_") { return false }
    return !writableTables.contains(table)
  }

  /// Puts the barrier on the connection that writes. Called once for each database that is
  /// opened; the barrier is shared by all of them and only reads its switch.
  ///
  /// It is a transaction observer, not a SQLite authorizer: GRDB keeps its own authorizer on
  /// every connection to learn which tables a statement reads and writes, and a second one
  /// replaces it -- the observations of the app (the cache of hand ratings, the lists) would
  /// stop seeing writes. The observer notes a row written to a refused table while the switch
  /// is on and refuses the commit: the transaction is rolled back and the write throws.
  public func install(on writer: any DatabaseWriter) {
    let observer = Observer(barrier: self)
    writer.writeWithoutTransaction { db in
      db.add(transactionObserver: observer, extent: .databaseLifetime)
    }
  }

  private final class Observer: TransactionObserver, @unchecked Sendable {
    let barrier: ReadOnlyBarrier
    var refused = false

    init(barrier: ReadOnlyBarrier) { self.barrier = barrier }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool {
      switch eventKind {
      case .insert(let table), .delete(let table), .update(let table, _):
        return !ReadOnlyBarrier.writableTables.contains(table)
      }
    }

    func databaseDidChange(with event: DatabaseEvent) {
      guard barrier.isOn else { return }
      if ReadOnlyBarrier.refuses(
        action: event.kind.rawValue, table: event.tableName, database: event.databaseName)
      {
        refused = true
      }
    }

    func databaseWillCommit() throws {
      guard refused else { return }
      refused = false
      throw Refusal()
    }

    func databaseDidCommit(_ db: Database) { refused = false }
    func databaseDidRollback(_ db: Database) { refused = false }
  }
}
