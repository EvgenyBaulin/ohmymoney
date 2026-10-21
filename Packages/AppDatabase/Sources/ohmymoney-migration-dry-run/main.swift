import AppCore
import AppDatabase
import Dispatch
import Foundation
import GRDB

// Tries the update on a copy of a database file and says what it did — before the update
// reaches the owner's own copy of the app.
//
// The file is copied, with its `-wal` and `-shm`, into a fresh folder of its own; the original
// is never opened, not even to read. The copy is migrated with the schema of this tree and read
// back the way the app reads it. What is printed is the shape of the data only: table names,
// row counts, how many rows the data step changed, «equal» or «differ» for the sums of money
// and the totals of every month, and what the update has to give — no operation without an
// account, one live main account, every account with a name under a bank, the tables it adds
// empty but for the cards the data step gives the card accounts and the banks it gives the
// accounts. No amount, name, note or error message is ever printed — an error
// message of SQLite can quote a row, one of the file system a path: an error is said by its
// domain and codes (`DryRunText`), with a line of advice when the codes say why — the privacy
// protection of macOS keeping a terminal out of another app's data, or the file's permissions.
//
// The folder is deleted at the end, and on Ctrl-C or a termination too. A run that could not
// delete it — killed outright, or crashed — leaves it to the next run, which deletes it first:
// the folder is a copy of somebody's database, and nothing else may keep one.
//
// Exit status: 0 when everything is equal, 1 when something differs or the copy does not load
// after the update, 2 for a wrong call, 3 when the migration or the copy failed, 128 + the
// signal when stopped by one.
//
// Usage: ohmymoney-migration-dry-run <database file> <schema folder>

/// The folder of a run is `<prefix><process id>-<uuid>` in the temporary folder: whose it is
/// says whether a run still uses it.
let folderPrefix = "ohmymoney-migration-dry-run-"

/// Deletes the folders earlier runs left behind. The folder of a run still going — its process
/// is alive — stays; any other is a leftover, a name without a process id included.
func removeLeftovers(in temporary: URL) {
  let manager = FileManager.default
  let names = (try? manager.contentsOfDirectory(atPath: temporary.path)) ?? []
  for name in names where name.hasPrefix(folderPrefix) {
    let owner = name.dropFirst(folderPrefix.count).split(separator: "-").first.flatMap {
      Int32($0)
    }
    if let owner, owner > 0, kill(owner, 0) == 0 || errno == EPERM { continue }
    try? manager.removeItem(at: temporary.appendingPathComponent(name, isDirectory: true))
  }
}

/// Ctrl-C, a termination or a closed terminal deletes the folder before the process goes: a
/// signal ends it without running a `defer`. The sources are kept for as long as the run.
func removeOnSignals(_ folder: URL) -> [any DispatchSourceSignal] {
  [SIGINT, SIGTERM, SIGHUP].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
    source.setEventHandler {
      try? FileManager.default.removeItem(at: folder)
      exit(128 + number)
    }
    source.resume()
    return source
  }
}

/// What the update has to give, read on the copy after it: every operation has an account, and
/// exactly one live account is main whenever there is a live account.
struct AccountsAfter {
  var withoutAnAccount = 0
  var liveMain = 0
  var live = 0
  /// Accounts with a name that sit under no bank.
  var withoutABank = 0
  /// Open debts the owner has not yet seen the terms of this version for: every one the update
  /// finds. Said, never a difference.
  var debtsToReview = 0
  /// Accounts with the terms of a credit card: the update gives none.
  var creditCards = 0

  var holds: Bool { withoutAnAccount == 0 && liveMain == (live > 0 ? 1 : 0) }
  var filed: Bool { withoutABank == 0 }
}

func accountsAfter(_ url: URL) throws -> AccountsAfter {
  var configuration = Configuration()
  configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA query_only = ON") }
  let queue = try DatabaseQueue(path: url.path, configuration: configuration)
  defer { try? queue.close() }
  return try queue.read { db in
    func count(_ sql: String) throws -> Int { try Int.fetchOne(db, sql: sql) ?? 0 }
    return AccountsAfter(
      withoutAnAccount: try count(
        "SELECT COUNT(*) FROM transactions WHERE payment_method_id IS NULL"),
      liveMain: try count(
        "SELECT COUNT(*) FROM payment_methods WHERE archived = 0 AND is_default = 1"),
      live: try count("SELECT COUNT(*) FROM payment_methods WHERE archived = 0"),
      withoutABank: try count(
        """
        SELECT COUNT(*) FROM payment_methods
        WHERE bank_id IS NULL AND length(trim(name)) > 0
        """),
      debtsToReview: try count(
        """
        SELECT COUNT(*) FROM debts
        WHERE terms_reviewed = 0 AND closed = 0 AND deleted_at IS NULL
        """),
      creditCards: try count(
        "SELECT COUNT(*) FROM payment_methods WHERE credit_limit_e4 IS NOT NULL"))
  }
}

/// Sums of the money a database holds, by what they are of: each must be the same after the
/// update. The keys are words and currency codes; the values are never printed.
struct Measures: Equatable {
  var sums: [String: [String: Int64]] = [:]
  var months: [String: Int64] = [:]
  var brokenKeys = 0
  /// Operations whose account is not in the file — a key an older build or a hand edit left
  /// pointing nowhere. The update overwrites no value an older build wrote, so it gives such an
  /// operation no account of its own: they stay as many as they were, and the line says so.
  var onAMissingAccount = 0
}

func measure(_ url: URL) throws -> Measures {
  var configuration = Configuration()
  configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA query_only = ON") }
  let queue = try DatabaseQueue(path: url.path, configuration: configuration)
  defer { try? queue.close() }
  return try queue.read { db in
    var result = Measures()
    func sums(_ label: String, _ sql: String) throws {
      var values: [String: Int64] = [:]
      for row in try Row.fetchAll(db, sql: sql) {
        let key: String? = row[0]
        values[key ?? "-"] = row[1]
      }
      result.sums[label] = values
    }
    try sums(
      "operations by currency",
      "SELECT currency, SUM(amount_e4) FROM transactions GROUP BY currency")
    try sums("operations in rubles", "SELECT 'RUB', SUM(amount_rub_e4) FROM transactions")
    try sums(
      "parts by currency",
      """
      SELECT t.currency, SUM(p.amount_e4) FROM transaction_parts p
      JOIN transactions t ON t.id = p.transaction_id GROUP BY t.currency
      """)
    try sums("parts in rubles", "SELECT 'RUB', SUM(amount_rub_e4) FROM transaction_parts")
    try sums("money back links", "SELECT 'RUB', SUM(amount_e4) FROM reimbursement_links")
    try sums(
      "debt journal by currency",
      """
      SELECT d.currency, SUM(e.amount_e4) FROM debt_entries e
      JOIN debts d ON d.id = e.debt_id GROUP BY d.currency
      """)
    for row in try Row.fetchAll(
      db,
      sql: """
        SELECT kind || ' ' || substr(occurred_at, 1, 7), SUM(amount_rub_e4) FROM transactions
        WHERE deleted_at IS NULL GROUP BY 1
        """)
    {
      result.months[row[0]] = row[1]
    }
    result.brokenKeys = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count
    result.onAMissingAccount =
      try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*) FROM transactions t WHERE t.payment_method_id IS NOT NULL
            AND NOT EXISTS (SELECT 1 FROM payment_methods p WHERE p.id = t.payment_method_id)
          """) ?? 0
    return result
  }
}

/// The schema that brought the terms of a credit card (`0009_credit_and_allocation`).
let creditTermsSchema = 9

func say(_ line: String) {
  FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

func complain(_ line: String) {
  FileHandle.standardError.write(Data((line + "\n").utf8))
}

/// The domain and codes of an error, for SQLite its code: never its message.
func describe(_ error: any Error) -> String {
  DryRunText.describe(error)
}

/// A line of advice after the line of an error, when the codes of the error say why.
func hint(_ error: any Error, _ write: (String) -> Void) {
  if let hint = DryRunText.hint(for: error) { write("hint: \(hint)") }
}

func run() async -> Int32 {
  // First of all, whatever the call: a copy an earlier run left is not kept a moment longer.
  let temporary = FileManager.default.temporaryDirectory
  removeLeftovers(in: temporary)
  let arguments = CommandLine.arguments
  guard arguments.count == 3 else {
    complain("usage: ohmymoney-migration-dry-run <database file> <schema folder>")
    return 2
  }
  let manager = FileManager.default
  let original = URL(fileURLWithPath: arguments[1])
  let schema = DirectorySchemaSource(
    directory: URL(fileURLWithPath: arguments[2], isDirectory: true))
  guard manager.fileExists(atPath: original.path) else {
    complain("migration dry run: there is no file at the path given")
    return 2
  }

  let folder = temporary.appendingPathComponent(
    "\(folderPrefix)\(getpid())-\(UUID().uuidString)", isDirectory: true)
  let signals = removeOnSignals(folder)
  defer {
    try? manager.removeItem(at: folder)
    for source in signals { source.cancel() }
  }
  let copy = folder.appendingPathComponent("finance.sqlite")
  let before: Measures
  let countsBefore: [String: Int]
  let schemaBefore: Int
  // Copying and reading are told apart: macOS may let the file be seen and not copied.
  do {
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    for part in ["", "-wal", "-shm"] where manager.fileExists(atPath: original.path + part) {
      try manager.copyItem(
        at: URL(fileURLWithPath: original.path + part),
        to: URL(fileURLWithPath: copy.path + part))
    }
  } catch {
    complain("migration dry run: the file could not be copied: \(describe(error))")
    hint(error, complain)
    return 3
  }
  do {
    let pending = try DatabaseStack.pendingMigrations(fileAt: copy, schema: schema)
    schemaBefore = try schema.migrations().count - pending.count
    countsBefore = try DatabaseStack.rowCounts(fileAt: copy)
    before = try measure(copy)
  } catch {
    complain("migration dry run: the copy could not be read: \(describe(error))")
    hint(error, complain)
    return 3
  }

  say("migration dry run on a copy; the original was not opened")
  let applied: DatabaseStack.Migrations
  var loads = false
  do {
    let stack = try DatabaseStack(
      url: copy, schema: schema, context: MigrationContext(mainAccountName: "Main account"))
    applied = stack.applied
    // The app reads it the same way at every start: the whole history, then the ledger.
    if let dataset = try? await DatasetRepository(writer: stack.writer).load(version: 0) {
      _ = Ledger(dataset: dataset, calendar: .system)
      loads = true
    }
    try stack.close()
  } catch {
    say("migration: failed, \(describe(error))")
    hint(error, say)
    return 3
  }

  let after: Measures
  let countsAfter: [String: Int]
  let accounts: AccountsAfter
  do {
    countsAfter = try DatabaseStack.rowCounts(fileAt: copy)
    after = try measure(copy)
    accounts = try accountsAfter(copy)
  } catch {
    say("after the update: the copy could not be read, \(describe(error))")
    hint(error, say)
    return 3
  }

  say("schema: \(schemaBefore) -> \(applied.onDisk) (applied \(applied.applied))")
  say("tables, rows before -> after:")
  var equal = true
  let created = applied.dataSteps["mainCreated"] ?? 0
  let cardsCreated = applied.dataSteps["cardsCreated"] ?? 0
  let banksCreated = applied.dataSteps["banksCreated"] ?? 0
  let rulesDropped = applied.dataSteps["cashbackRulesDropped"] ?? 0
  for table in Set(countsBefore.keys).union(countsAfter.keys).sorted() {
    let old = countsBefore[table]
    let new = countsAfter[table]
    // Every table keeps its rows — the accounts gain the one the data step made, if it made
    // one, and the cashback rules lose the ones the data step dropped: the copies of cards that
    // held the same rules and the rules on loans, while the others only move up to their
    // account — and a table the update adds starts empty: it only adds, and fills nothing new,
    // except the cards, which hold the one card the data step gives every live card account,
    // and the banks, which hold the one bank the data step gives every name of an account.
    let expected =
      old.map {
        table == "payment_methods"
          ? $0 + created : table == "cashback_rules" ? $0 - rulesDropped : $0
      } ?? (table == "cards" ? cardsCreated : table == "banks" ? banksCreated : 0)
    let mark = new == expected ? "" : "   differ"
    if !mark.isEmpty { equal = false }
    let name = table.padding(toLength: 26, withPad: " ", startingAt: 0)
    say("  \(name) \(old.map(String.init) ?? "-") -> \(new.map(String.init) ?? "-")\(mark)")
  }
  let steps = applied.dataSteps.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
  say("data step: \(steps.isEmpty ? "none" : steps.joined(separator: " "))")
  if !accounts.holds { equal = false }
  say(
    "accounts after: operations without an account \(accounts.withoutAnAccount), live main "
      + "\(accounts.liveMain)\(accounts.holds ? "" : "   differ")")
  if !accounts.filed { equal = false }
  say(
    "accounts without a bank after: \(accounts.withoutABank)"
      + (accounts.filed ? "" : "   differ"))
  say("debts to review after: \(accounts.debtsToReview)")
  // The update gives no account the terms of a credit card; a file already at the schema
  // that brought them may hold the owner's own.
  let creditCardsExpected = schemaBefore < creditTermsSchema ? 0 : accounts.creditCards
  if accounts.creditCards != creditCardsExpected { equal = false }
  say(
    "credit cards after: \(accounts.creditCards)"
      + (accounts.creditCards == creditCardsExpected ? "" : "   differ"))
  say("sums:")
  for label in Set(before.sums.keys).union(after.sums.keys).sorted() {
    let same = before.sums[label] == after.sums[label]
    if !same { equal = false }
    say("  \(label): \(same ? "equal" : "differ")")
  }
  let monthsSame = before.months == after.months
  if !monthsSame { equal = false }
  say("month totals by kind: \(monthsSame ? "equal" : "differ") (\(before.months.count) rows)")
  say("foreign_key_check: \(before.brokenKeys) before, \(after.brokenKeys) after")
  if after.brokenKeys > before.brokenKeys { equal = false }
  say(
    "operations on an account that is not there: \(before.onAMissingAccount) before, "
      + "\(after.onAMissingAccount) after")
  if after.onAMissingAccount > before.onAMissingAccount { equal = false }
  say("loads: \(loads ? "ok" : "failed")")
  say("result: \(equal && loads ? "equal" : "differ")")
  return equal && loads ? 0 : 1
}

exit(await run())
