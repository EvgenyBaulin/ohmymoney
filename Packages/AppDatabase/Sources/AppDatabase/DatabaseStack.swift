import AppCore
import CoreKit
import Foundation
import GRDB
import Synchronization

/// What the data steps of the migrations need from the app (`MigrationDataSteps`): the name of
/// a main account made for the operations of an older build, in the language of the interface
/// — the package cannot know it —, where its id comes from, and the month the update happens
/// in.
public struct MigrationContext: Sendable {
  /// «Основной счёт» / "Main account".
  public var mainAccountName: String
  public var makeId: @Sendable () -> UUID
  /// The month of the update, `YYYY-MM` in the owner's calendar: the plan of every goal that
  /// already has one counts from it. Taken when the context is made, so an update stopped and
  /// tried again at once gives the same month.
  public var updateMonth: String
  /// The data step throws once the SQL has run: how the tests prove that a migration that
  /// stops leaves nothing behind. The first step that runs throws.
  var failAfterSQL = false
  /// The same for the step of this one migration only, so the ones before it land.
  var failAfterSQLOf: String? = nil

  public init(
    mainAccountName: String, makeId: @escaping @Sendable () -> UUID = { UUID() },
    updateMonth: String? = nil
  ) {
    self.mainAccountName = mainAccountName
    self.makeId = makeId
    self.updateMonth = updateMonth ?? CalendarContext.system.day(of: Date()).monthKey.iso
  }

  /// For stacks nobody's history goes through — tests, tools, generated data sets. Its month is
  /// fixed, so two updates made with it compare value for value on any day.
  public static let tests = MigrationContext(
    mainAccountName: "Main account", updateMonth: "2026-09")
}

/// Opens the database, applies the SQL migrations and hands out repositories.
/// Debug builds work in their own directory so synthetic data can never reach the real
/// database.
public final class DatabaseStack: Sendable {
  public let writer: any DatabaseWriter
  public let url: URL
  /// What opening this stack did to the schema, for the journal: which migrations were
  /// applied this time and how long they took. The package writes no log of its own — it
  /// says what happened and the app records it.
  public let applied: Migrations

  public struct Migrations: Sendable, Equatable {
    /// How many migrations the schema has in all — the version of the schema, in effect.
    public var onDisk: Int
    /// How many of them this open had to apply.
    public var applied: Int
    public var milliseconds: Int
    /// What the data steps of the migrations applied this time did (`MigrationDataSteps`),
    /// counts only: `mainKept`, `mainChosen`, `mainCreated`, `defaultsCleared`, `assigned` of
    /// the accounts; `cardsCreated`, `cardsSkipped`, `countsRecorded`, `countsKept`,
    /// `goalPlansStarted` of the cards; `banksCreated`, `banksSkipped`, `accountsFiled` of the
    /// banks. Empty when no migration with a step ran.
    public var dataSteps: [String: Int]

    public init(
      onDisk: Int = 0, applied: Int = 0, milliseconds: Int = 0, dataSteps: [String: Int] = [:]
    ) {
      self.onDisk = onDisk
      self.applied = applied
      self.milliseconds = milliseconds
      self.dataSteps = dataSteps
    }
  }

  /// A migration that stopped: the version the file was at, the version it was going to, the
  /// migration that stopped and how long the attempt ran — what `Migrations` says of an open
  /// that migrated. `underlying` is what stopped it, and what the app judges the failure by.
  /// The migrations before the failed one stay applied: GRDB runs each in a transaction of
  /// its own.
  public struct MigrationFailure: Error {
    public var from: Int
    public var to: Int
    /// The identifier of the migration that stopped: the file name in `Schema/`.
    public var migration: String?
    public var milliseconds: Int
    public var underlying: any Error

    public init(
      from: Int, to: Int, migration: String?, milliseconds: Int, underlying: any Error
    ) {
      self.from = from
      self.to = to
      self.migration = migration
      self.milliseconds = milliseconds
      self.underlying = underlying
    }
  }

  public init(
    url: URL, schema: any SchemaSource, context: MigrationContext = .tests
  ) throws {
    self.url = url
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    var configuration = Configuration()
    // This, and not the `PRAGMA foreign_keys = ON` in `Schema/0001`, is what turns the keys
    // on: a migration runs inside a transaction, where SQLite ignores that pragma. Every
    // connection that writes these tables has to set it itself.
    configuration.foreignKeysEnabled = true
    // `busyMode` stays GRDB's `.immediateError`, on purpose. Every write of the app goes
    // through this pool's one writer, which GRDB serialises, so the app never finds its own
    // file locked; only another process can — a second copy started with `open -n`, a
    // `sqlite3` writing by hand. The app writes from the main thread, and a busy timeout would
    // freeze the window for as long as that process holds the lock; failing at once shows
    // «не сохранено» and loses nothing that was saved.
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA journal_mode = WAL")
      // A sync on macOS stops at the drive's own cache unless it asks for F_FULLFSYNC;
      // a power-off by the button empties that cache. Checkpoints use it too.
      try db.execute(sql: "PRAGMA fullfsync = ON")
    }

    let pool = try DatabasePool(path: url.path, configuration: configuration)
    // GRDB turns WAL on after `prepareDatabase` and sets the writer to NORMAL, which syncs
    // the log only at a checkpoint: a commit that returned could still be lost to a kernel
    // panic or a power loss. FULL syncs it at every commit — about a millisecond and a half
    // on this Mac's disk, for writes a person makes one at a time.
    try pool.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA synchronous = FULL")
    }
    self.writer = pool
    self.applied = try Self.migrate(pool, schema: schema, context: context)
  }

  /// In-memory stack for tests.
  public init(inMemory schema: any SchemaSource, context: MigrationContext = .tests) throws {
    self.url = URL(fileURLWithPath: ":memory:")
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let queue = try DatabaseQueue(configuration: configuration)
    self.writer = queue
    self.applied = try Self.migrate(queue, schema: schema, context: context)
  }

  /// Closes every connection. Reads and the write in flight finish first — GRDB waits for
  /// them — so nothing is left holding the file when its folder goes. Throws when
  /// a statement is still alive, which the caller logs rather than hides.
  public func close() throws {
    try writer.close()
  }

  /// Every file in `Schema/` is one migration, applied in file-name order, each in a
  /// transaction of its own together with its data step (`MigrationDataSteps`). Returns what it
  /// had to do, so the app can write it in the journal.
  ///
  /// From `0004` on, the foreign keys are checked as each statement runs (`.immediate`), for
  /// the rows it writes. GRDB's default checks every key of the whole file before the commit,
  /// so one key an older build left pointing nowhere — anywhere, in any table — would stop the
  /// update for good. The earlier migrations keep the check they were applied with.
  private static func migrate(
    _ writer: any DatabaseWriter, schema: any SchemaSource, context: MigrationContext
  ) throws -> Migrations {
    let migrations = try schema.migrations()
    try refuseUnknownMigrations(writer, onDisk: migrations.map(\.name))
    var migrator = DatabaseMigrator()
    let steps = StepCounts()
    for migration in migrations {
      migrator.registerMigration(
        migration.name, foreignKeyChecks: migration.name >= "0004" ? .immediate : .deferred
      ) { db in
        try db.execute(sql: migration.sql)
        let counts = try MigrationDataSteps.after(migration.name, db: db, context: context)
        steps.add(counts)
      }
    }
    let alreadyApplied = (try? writer.read { try migrator.appliedIdentifiers($0) }) ?? []
    let began = DispatchTime.now().uptimeNanoseconds
    do {
      try migrator.migrate(writer)
    } catch {
      // Each migration commits on its own and they run in order, so the first one still not
      // applied is the one that stopped.
      let appliedNow =
        (try? writer.read { try migrator.appliedIdentifiers($0) }) ?? alreadyApplied
      throw MigrationFailure(
        from: alreadyApplied.count, to: migrations.count,
        migration: migrations.first { !appliedNow.contains($0.name) }?.name,
        milliseconds: Int((DispatchTime.now().uptimeNanoseconds - began) / 1_000_000),
        underlying: error)
    }
    let elapsed = Int((DispatchTime.now().uptimeNanoseconds - began) / 1_000_000)
    let applied = migrations.filter { !alreadyApplied.contains($0.name) }.count
    // The readers opened before the update keep the schema they read then: a `SELECT *` one of
    // them prepares takes the columns of that schema, and SQLite, noticing the change only when
    // the statement runs, reads the new columns into no row — the first reads after an update
    // would see a count without its mode and a goal without the month of its plan. Readers made
    // after the update read the schema it left.
    if applied > 0, let pool = writer as? DatabasePool {
      pool.invalidateReadOnlyConnections()
    }
    return Migrations(
      onDisk: migrations.count, applied: applied, milliseconds: elapsed,
      dataSteps: steps.total)
  }

  /// The counts of the data steps, added up across the migrations of one open. GRDB runs the
  /// migrations one after another on its writer; the lock is for the compiler's sake.
  private final class StepCounts: Sendable {
    private let counts = Mutex<[String: Int]>([:])

    func add(_ more: [String: Int]) {
      counts.withLock { $0.merge(more) { $0 + $1 } }
    }

    var total: [String: Int] { counts.withLock { $0 } }
  }

  /// Refuses a database that was migrated by a build whose migrations we do not have.
  /// Writing into a schema we cannot see is how the owner's data gets lost: an older app,
  /// or one whose `Schema/` file was renamed, has to stop instead.
  private static func refuseUnknownMigrations(
    _ writer: any DatabaseWriter, onDisk: [String]
  ) throws {
    let applied = try writer.read { db -> [String] in
      guard try db.tableExists("grdb_migrations") else { return [] }
      return try String.fetchAll(
        db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
    }
    let known = Set(onDisk)
    guard applied.allSatisfy(known.contains) else {
      throw DatabaseError.migrationMismatch(applied: applied, onDisk: onDisk)
    }
  }

  // MARK: Changes

  /// The tables a `Dataset` is read from (`DatasetRepository.load`) — the planning book
  /// included, whose tables change with every «Mark as paid», limit and reconciliation — plus
  /// the rates, whose refinement rewrites the rubles of operations. The debt journals are part
  /// of the book: they move with every debt payment and hold the balances the debt figures
  /// are made of. The anomalies waved away come with the data too, so «Это нормально» is a
  /// change like any other, whoever writes it; so do the owner's choices of a category
  /// against the model, which «Качество модели» counts; so do the groups of the accounts,
  /// the transfers between them and the balances counted on them; so do the cards and
  /// their cashback rules, which the cashback expected of every purchase is made of; and so do
  /// the banks, which name the accounts in every list; and the conditions of bank products and the
  /// deposits the owner typed in. A test holds this list against the
  /// statements the load runs.
  static let ledgerTables = [
    "transactions", "transaction_parts", "reimbursement_links", "categories", "people",
    "places", "events", "payment_methods", "goals", "debts", "debt_entries", "rates",
    "settings", "scheduled_payments", "subscription_prices", "expected_income",
    "expected_income_links", "budgets", "reconciliations", "anomaly_dismissals",
    "category_feedback", "account_groups", "transfers", "reconciliation_balances", "cards",
    "cashback_rules", "banks", "assets", "asset_valuations", "debt_instalments", "debt_costs",
    "allocation_rules", "custom_currencies", "tags", "part_tags", "rules", "day_notes",
    "saved_views", "budget_month_exceptions", "event_budget_items", "event_templates",
    "subscription_terms", "subscription_usage", "subscription_users", "subscription_keep_groups",
    "bank_conditions", "deposit_offers",
  ]

  /// One element after every committed transaction that changed one of `ledgerTables` —
  /// whoever wrote it: the store, a sheet writing a part off, a merge of duplicates, the
  /// rate step. The elements carry nothing; the consumer reads what it needs.
  ///
  /// Threading. GRDB calls `onChange` on the writer's dispatch queue, inside the commit,
  /// before the writing call has returned — and the app writes synchronously from the main
  /// thread. So the callback does nothing but `yield`, which never blocks: a hop to the
  /// main thread from there would wait for the main thread while the main thread waits for
  /// the write — a deadlock — and any work there would stall every write. The buffer keeps
  /// only the newest element: ten writes in a row while the consumer is busy come out as
  /// one, and the consumer debounces anyway.
  ///
  /// The observation starts right away and blocks the calling thread until it can get
  /// write access. It stops when the stream terminates — the consuming task is cancelled or
  /// the stream is released.
  public func ledgerChanges() -> AsyncStream<Void> {
    ledgerChanges(onChange: {})
  }

  /// `ledgerChanges()` with a callback run inside every commit the observation sees, right
  /// before the element is yielded. It shows whether the observation itself is still
  /// registered: a yield on a finished stream is silently dropped, so the stream alone cannot
  /// tell a stopped observation from one left behind on the writer. The tests use it. Like
  /// the yield, the callback must never block.
  func ledgerChanges(onChange: @escaping @Sendable () -> Void) -> AsyncStream<Void> {
    changes(of: Self.ledgerTables, onChange: onChange)
  }

  /// The tables whose change is a change of the owner's data, worth a copy: the ledger's, plus
  /// the templates, the enabled currencies and the saved scenarios, which no number reads but a
  /// restore must bring back. The model file (`ml_models`) is left out: it is rebuilt from the data.
  /// The list of imports, the numbers of the owner's own contracts and the owner's profiles of
  /// files are no figure's input either, but a restore must bring them back.
  static let dataTables =
    ledgerTables + [
      "templates", "currencies", "scenarios", "import_batches", "identity_items",
      "statement_profiles",
    ]

  /// One element after every committed transaction that changed one of `dataTables`, whoever
  /// wrote it — the stream the copy after every change listens to. Same threading, buffer
  /// and lifetime as `ledgerChanges()`.
  public func dataChanges() -> AsyncStream<Void> {
    changes(of: Self.dataTables, onChange: {})
  }

  private func changes(
    of tables: [String], onChange: @escaping @Sendable () -> Void
  ) -> AsyncStream<Void> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let observation = DatabaseRegionObservation(
        tracking: tables.map { Table($0) })
      let cancellable = observation.start(
        in: writer,
        onError: { _ in continuation.finish() },
        onChange: { _ in
          onChange()
          continuation.yield()
        })
      continuation.onTermination = { _ in cancellable.cancel() }
    }
  }

  /// Names of the migrations recorded in the database, in application order.
  public func appliedMigrations() throws -> [String] {
    try writer.read { db in
      try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
    }
  }

  /// Consistent snapshot for backups and for the transfer archive.
  public func backup(to destination: URL) throws {
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    // An SQLite database is up to three files. Anyone who opens a snapshot to look at it
    // leaves a write-ahead log beside it, and that log belongs to the snapshot that used
    // to be there: replacing the main file alone either resurrects the old contents or
    // makes the new copy unreadable.
    for path in Self.databaseFiles(of: destination)
    where FileManager.default.fileExists(atPath: path) {
      try FileManager.default.removeItem(atPath: path)
    }
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let target = try DatabaseQueue(path: destination.path, configuration: configuration)
    try writer.backup(to: target)
  }

  /// A consistent snapshot of a database file this build did not open as its own — one written
  /// by a newer build, one a migration failed on. Nothing is applied to it and nothing is
  /// written into it: it is read as it is, through the backup API, log included, so the copy
  /// is the state the owner had (`reading(fileAt:)`). Throws when SQLite cannot read the file
  /// at all.
  public static func backup(fileAt source: URL, to destination: URL) throws {
    guard FileManager.default.fileExists(atPath: source.path) else {
      throw DatabaseError.notFound
    }
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try reading(fileAt: source) { queue in
      // Each attempt starts from nothing: a first one that failed halfway leaves no page behind.
      for path in Self.databaseFiles(of: destination)
      where FileManager.default.fileExists(atPath: path) {
        try FileManager.default.removeItem(atPath: path)
      }
      let target = try DatabaseQueue(path: destination.path)
      defer { try? target.close() }
      try queue.backup(to: target)
    }
  }

  /// The database file together with the journals SQLite keeps next to it.
  static func databaseFiles(of url: URL) -> [String] {
    [url.path, url.path + "-wal", url.path + "-shm", url.path + "-journal"]
  }

  /// Integrity check of the live database, for the problem report and for telling a damaged
  /// database from a damaged copy of a sound one.
  public func integrityCheckPassed() throws -> Bool {
    try writer.read { db in
      let result = try String.fetchOne(db, sql: "PRAGMA integrity_check")
      return result == "ok"
    }
  }

  /// Integrity check of a database file nobody has open: a copy just written, or one about to
  /// take the place of the live database. It has to have tables — an empty file opens as an
  /// empty database, which `PRAGMA integrity_check` calls «ok».
  public static func integrityCheckPassed(at url: URL) -> Bool {
    inspect(fileAt: url, isSound) ?? false
  }

  /// The quick check of a database file nobody has open — `PRAGMA quick_check`, which reads the
  /// structure but not the content of every index: what every new copy is asked, the full
  /// `integrity_check` being kept for the copy of the day. Like `integrityCheckPassed(at:)`, the
  /// file has to have tables.
  public static func quickCheckPassed(at url: URL) -> Bool {
    inspect(fileAt: url) { db -> Bool in
      let tables = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master") ?? 0
      let result = try String.fetchOne(db, sql: "PRAGMA quick_check")
      return tables > 0 && result == "ok"
    } ?? false
  }

  /// The columns of every table of a database file nobody has open, by table, in the order the
  /// table declares them — what a copy written by an older build had.
  public static func tableColumns(fileAt url: URL) throws -> [String: [String]] {
    try read(fileAt: url) { db in
      let tables = try String.fetchAll(
        db,
        sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
      var columns: [String: [String]] = [:]
      for table in tables {
        let quoted = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        columns[table] = try Row.fetchAll(db, sql: "PRAGMA table_info(\(quoted))")
          .map { $0["name"] as String }
      }
      return columns
    }
  }

  /// What a database file nobody has open would be to this build, were it put in the place of
  /// the live one: a copy about to be restored, the database of an archive about to be
  /// imported.
  public enum FileCheck: Sendable, Equatable {
    /// It opens, has tables, passes `PRAGMA integrity_check`, and every migration it records
    /// is one this build has.
    case sound
    /// Not a database, empty, or it fails its integrity check.
    case damaged
    /// It records migrations this build does not have: a newer build wrote it. Opening it
    /// would be refused (`refuseUnknownMigrations`).
    case newerSchema
  }

  /// Checks a file before it replaces the live database, by the same rules the opening of the
  /// database will apply. The integrity check alone lets through a sound database of a newer
  /// build, which this build refuses to open — at the next launch, after the database it
  /// replaced is gone. Throws only when the schema of this build cannot be read.
  public static func check(fileAt url: URL, schema: any SchemaSource) throws -> FileCheck {
    let known = Set(try schema.migrations().map(\.name))
    let verdict = inspect(fileAt: url) { db -> FileCheck in
      guard try isSound(db) else { return .damaged }
      guard try db.tableExists("grdb_migrations") else { return .sound }
      let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
      return applied.allSatisfy(known.contains) ? .sound : .newerSchema
    }
    return verdict ?? .damaged
  }

  /// The migrations of `schema` a database file nobody has open has not had yet: what opening
  /// it would apply. Empty when there is nothing to apply, and also when there is nothing to
  /// keep a copy of — no file, a file without a schema (it is made anew) — or when the file
  /// records a migration this build does not have: the opening refuses it then
  /// (`DatabaseError.migrationMismatch`) and writes nothing.
  ///
  /// A file that is there but cannot be read throws what SQLite said: never «nothing to apply»
  /// for a file the opening might still migrate.
  public static func pendingMigrations(
    fileAt url: URL, schema: any SchemaSource
  ) throws -> [String] {
    let names = try schema.migrations().map(\.name)
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let recorded = try read(fileAt: url) { db -> [String]? in
      guard try db.tableExists("grdb_migrations") else { return nil }
      return try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
    }
    guard let recorded else { return [] }
    let known = Set(names)
    guard recorded.allSatisfy(known.contains) else { return [] }
    let applied = Set(recorded)
    return names.filter { !applied.contains($0) }
  }

  /// The rows of every table of a database file nobody has open, by table — SQLite's own and
  /// GRDB's list of migrations left out. A copy holds what its source held when these agree.
  public static func rowCounts(fileAt url: URL) throws -> [String: Int] {
    try read(fileAt: url) { db in
      let tables = try String.fetchAll(
        db,
        sql: """
          SELECT name FROM sqlite_master
          WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name <> 'grdb_migrations'
          """)
      var counts: [String: Int] = [:]
      for table in tables {
        let quoted = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(quoted)") ?? 0
      }
      return counts
    }
  }

  /// Everything the numbers are made of (`Dataset`), read from a database file nobody has open
  /// without writing into it — the copies listed in Settings are compared and described this
  /// way. Throws when the file does not open or its schema is not the one this build reads.
  public static func dataset(fileAt url: URL) throws -> Dataset {
    try read(fileAt: url) { db in try DatasetRepository.dataset(db, version: 0) }
  }

  /// Whether two database files nobody has open hold the same data: the same schema — every
  /// table, index and trigger, GRDB's list of migrations included — and every table the same
  /// rows, value for value, in the order of their keys. A copy of a database is a copy of the
  /// state it holds now exactly when this is true, whenever the copy was taken; the dates of the
  /// files could not tell, since a file put back from elsewhere keeps an old one.
  public static func sameData(fileAt first: URL, as second: URL) throws -> Bool {
    try read(fileAt: first) { one in
      try read(fileAt: second) { other in
        let schema = """
          SELECT type, name, tbl_name, sql FROM sqlite_master
          WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name
          """
        let objects = try Row.fetchAll(one, sql: schema)
        guard try objects == Row.fetchAll(other, sql: schema) else { return false }
        for object in objects where object["type"] == "table" {
          let name: String = object["name"]
          let sql: String = object["sql"] ?? ""
          let quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
          // A table without a rowid is read in the order of its key, which a full scan is.
          let order = sql.uppercased().contains("WITHOUT ROWID") ? "" : " ORDER BY rowid"
          let query = "SELECT * FROM \(quoted)\(order)"
          let left = try Row.fetchCursor(one, sql: query)
          let right = try Row.fetchCursor(other, sql: query)
          while let row = try left.next() {
            guard let twin = try right.next(), row == twin else { return false }
          }
          guard try right.next() == nil else { return false }
        }
        return true
      }
    }
  }

  private static func isSound(_ db: Database) throws -> Bool {
    let tables = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master") ?? 0
    let result = try String.fetchOne(db, sql: "PRAGMA integrity_check")
    return tables > 0 && result == "ok"
  }

  /// Reads a database file nobody has open; nil when it does not open or the reading throws.
  private static func inspect<T>(
    fileAt url: URL, _ read: (Database) throws -> T
  ) -> T? {
    try? Self.read(fileAt: url, read)
  }

  /// Reads a database file nobody has open, and says why it could not: `DatabaseError.notFound`
  /// when there is no file, what SQLite said when it does not open or the reading fails.
  private static func read<T>(
    fileAt url: URL, _ read: (Database) throws -> T
  ) throws -> T {
    guard FileManager.default.fileExists(atPath: url.path) else { throw DatabaseError.notFound }
    return try reading(fileAt: url) { queue in try queue.read(read) }
  }

  /// Runs `body` over a connection to a database file nobody has open, one that writes nothing
  /// into the file.
  ///
  /// Read-only. A connection that may write checkpoints the log it finds beside the file into
  /// the file when it closes — as the last connection to a database in WAL mode does — so
  /// reading a file left with rows in its `-wal` that way would write into it: the copy kept
  /// before an update, taken of a file the update then refuses, would no longer be the file the
  /// owner had, and a damaged file would get its log moved into its damaged pages.
  ///
  /// A read-only connection cannot always open a file in WAL mode, though: not when its `-shm`
  /// cannot be made or used, not with a log only a writer may recover. Only then — SQLite says
  /// it cannot open the file, or cannot do it read-only — is the file read from a copy of it
  /// and its log, in a folder of its own that goes afterwards; the file itself is still never
  /// opened by a connection that may write. Any other failure — a damaged page, a body that
  /// throws — is thrown as it is, and the body is not run twice.
  ///
  /// The folder is left as it was found: a `-wal` or `-shm` the reading made is removed, so no
  /// log is left for the next file of that name to read as its own.
  private static func reading<T>(
    fileAt url: URL, _ body: (DatabaseQueue) throws -> T
  ) throws -> T {
    let manager = FileManager.default
    let beside = [url.path + "-wal", url.path + "-shm"]
    let there = beside.filter { manager.fileExists(atPath: $0) }
    defer {
      for path in beside where !there.contains(path) {
        try? manager.removeItem(atPath: path)
      }
    }
    var readOnly = Configuration()
    readOnly.readonly = true
    do {
      let queue = try DatabaseQueue(path: url.path, configuration: readOnly)
      defer { try? queue.close() }
      return try body(queue)
    } catch let error as GRDB.DatabaseError
      where [.SQLITE_CANTOPEN, .SQLITE_READONLY].contains(error.resultCode)
    {
      return try readingACopy(of: url, body)
    }
  }

  /// `reading(fileAt:)` for a file a read-only connection cannot open: the file and its `-wal`
  /// are copied into a folder of their own — never the `-shm`, which the copy makes anew — and
  /// the copy is read, kept from writing by `query_only`; the folder goes afterwards.
  private static func readingACopy<T>(
    of url: URL, _ body: (DatabaseQueue) throws -> T
  ) throws -> T {
    let manager = FileManager.default
    let folder = manager.temporaryDirectory.appendingPathComponent(
      "ohmymoney-read-\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: folder) }
    let copy = folder.appendingPathComponent(url.lastPathComponent)
    try manager.copyItem(at: url, to: copy)
    if manager.fileExists(atPath: url.path + "-wal") {
      try manager.copyItem(atPath: url.path + "-wal", toPath: copy.path + "-wal")
    }
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA query_only = ON")
    }
    let queue = try DatabaseQueue(path: copy.path, configuration: configuration)
    defer { try? queue.close() }
    return try body(queue)
  }
}
