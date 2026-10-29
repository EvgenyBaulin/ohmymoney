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

  /// Puts the authorizer on the connection that writes. Called once for each database that is
  /// opened; the barrier is shared by all of them and only reads its switch.
  public func install(on writer: any DatabaseWriter) {
    let context = Unmanaged.passRetained(self).toOpaque()
    writer.writeWithoutTransaction { db in
      _ = sqlite3_set_authorizer(
        db.sqliteConnection,
        { context, action, first, _, database, _ in
          guard let context else { return SQLITE_OK }
          let barrier = Unmanaged<ReadOnlyBarrier>.fromOpaque(context).takeUnretainedValue()
          guard barrier.isOn else { return SQLITE_OK }
          let table = first.map { String(cString: $0) }
          let name = database.map { String(cString: $0) }
          return ReadOnlyBarrier.refuses(action: action, table: table, database: name)
            ? SQLITE_DENY : SQLITE_OK
        }, context)
    }
  }
}
