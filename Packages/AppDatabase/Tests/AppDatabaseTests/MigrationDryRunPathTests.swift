import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// A class of ours, only so the test can find the build's products beside its own bundle.
private final class DryRunPathAnchor: NSObject {}

/// The ways `make migration-dry-run` can end other than «equal»: an update that stops, a copy
/// that does not load, a run stopped by Ctrl-C, a folder an earlier run was killed before it
/// could delete. Each says what happened in words and counts of its own — never a value of the
/// database — and no copy of the database is left behind in the temporary folder.
@Suite("The dry run of the update when something stops it")
struct MigrationDryRunPathTests {
  private var tool: URL {
    Bundle(for: DryRunPathAnchor.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("ohmymoney-migration-dry-run")
  }

  private static let prefix = "ohmymoney-migration-dry-run-"

  private func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
    try #require(FileManager.default.fileExists(atPath: tool.path), "no tool at \(tool.path)")
    let process = Process()
    process.executableURL = tool
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  /// Every line the tool may print, each of its own shape.
  static var allowedLine: Regex<AnyRegexOutput> {
    try! Regex(
      #"^(migration dry run on a copy; the original was not opened|schema: \d+ -> \d+ \(applied \d+\)|tables, rows before -> after:|  [a-z_]+ +(\d+|-) -> (\d+|-)(   differ)?|data step: (none|([a-zA-Z]+=\d+ ?)+)|accounts after: operations without an account \d+, live main \d+(   differ)?|accounts without a bank after: \d+(   differ)?|debts to review after: \d+|credit cards after: \d+(   differ)?|sums:|  [a-z ]+: (equal|differ)|month totals by kind: (equal|differ) \(\d+ rows\)|foreign_key_check: \d+ before, \d+ after|operations on an account that is not there: \d+ before, \d+ after|loads: (ok|failed)|result: (equal|differ)|migration: failed, stopped at [0-9a-z_?]+ \((SQLite \d+|[A-Za-z0-9_.]+ -?\d+( \([A-Za-z0-9_.]+ -?\d+\))?)\)|migration dry run: the (file could not be copied|copy could not be read): (SQLite \d+|[A-Za-z0-9_.]+ -?\d+( \([A-Za-z0-9_.]+ -?\d+\))?)|after the update: the copy could not be read, (SQLite \d+|[A-Za-z0-9_.]+ -?\d+( \([A-Za-z0-9_.]+ -?\d+\))?)|hint: (macOS privacy protection kept this program out of another app's data\. .+|the file's permissions do not let this user read it\.))$"#
    )
  }

  private func expectNothingLeaks(_ output: String, _ secrets: [String], _ label: String) {
    for secret in secrets {
      #expect(!output.contains(secret), "\(label): the output names «\(secret)»")
    }
    for line in output.split(separator: "\n") {
      #expect(line.wholeMatch(of: Self.allowedLine) != nil, "\(label): «\(line)»")
    }
  }

  /// A value of the wrong type in an older database — an amount that is a word, a flag that is
  /// a word in a table the update does not touch — lets the update through, and the copy then
  /// does not load: «loads: failed», «differ», status 1, and neither the value nor the note of
  /// its row in the output. Before, GRDB read such an amount as zero and the run said «equal».
  @Test(arguments: [
    "UPDATE transactions SET amount_e4 = 'abc', note = 'secret note 4417' WHERE rowid = (SELECT MIN(rowid) FROM transactions)",
    "UPDATE people SET archived = 'x', name = 'secret note 4417' WHERE rowid = (SELECT MIN(rowid) FROM people)",
    "UPDATE places SET archived = 'yes', name = 'secret note 4417' WHERE rowid = (SELECT MIN(rowid) FROM places)",
  ])
  func aValueOfTheWrongTypeIsAFailedLoadThatNamesNoValue(sql: String) throws {
    let book = try RandomLegacyDatabase(seed: 331, operations: 20, accounts: 1...2)
    defer { book.remove() }
    let queue = try DatabaseQueue(path: book.url.path)
    try queue.writeWithoutTransaction { db in
      try db.execute(
        sql:
          "INSERT OR IGNORE INTO people (id, name, relation, aliases, archived) VALUES ('\(UUID().uuidString)', 'p', 'other', '', 0)"
      )
      try db.execute(
        sql:
          "INSERT OR IGNORE INTO places (id, name, aliases, archived) VALUES ('\(UUID().uuidString)', 'q', '', 0)"
      )
      try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
      try db.execute(sql: sql)
      #expect(db.changesCount == 1)
    }
    try queue.close()
    let bytes = try Data(contentsOf: book.url)

    let (status, output) = try run([book.url.path, TestSupport.schemaDirectory.path])

    #expect(status == 1, "\(output)")
    #expect(output.contains("loads: failed"), "\(output)")
    #expect(output.contains("result: differ"))
    expectNothingLeaks(output, [book.marker, "secret note", "4417", "abc"], sql)
    #expect(try Data(contentsOf: book.url) == bytes)
  }

  /// An update that stops — an older row breaks a check the update has SQLite test again, an
  /// account flagged with a word — says «migration: failed», where it stopped and SQLite's code,
  /// and nothing of the row; the status is 3 and the original is untouched.
  @Test func anUpdateThatStopsSaysWhereAndNothingMore() throws {
    let book = try RandomLegacyDatabase(seed: 332, operations: 20, accounts: 2...3)
    defer { book.remove() }
    let queue = try DatabaseQueue(path: book.url.path)
    try queue.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
      try db.execute(
        sql: """
          UPDATE payment_methods SET archived = 'x', name = 'secret account 5521'
          WHERE rowid = (SELECT MIN(rowid) FROM payment_methods)
          """)
    }
    try queue.close()
    let bytes = try Data(contentsOf: book.url)

    let (status, output) = try run([book.url.path, TestSupport.schemaDirectory.path])

    #expect(status == 3, "\(output)")
    #expect(output.contains("migration: failed, stopped at 0004_accounts (SQLite "), "\(output)")
    #expect(!output.contains("result: equal"))
    expectNothingLeaks(output, [book.marker, "secret account", "5521"], "a stopped update")
    #expect(try Data(contentsOf: book.url) == bytes)
  }

  /// A category a hand edit broke stops the update at the capital step: adding a column with a
  /// check makes SQLite test every check of the table again. The file stays the older database.
  @Test func aCategoryAHandEditBrokeStopsTheCapitalStep() throws {
    let book = try RandomLegacyDatabase(seed: 334, operations: 20, accounts: 2...3)
    defer { book.remove() }
    let queue = try DatabaseQueue(path: book.url.path)
    try queue.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
      try db.execute(
        sql:
          "UPDATE categories SET archived = 'x' WHERE rowid = (SELECT MIN(rowid) FROM categories)")
    }
    try queue.close()
    let bytes = try Data(contentsOf: book.url)

    let (status, output) = try run([book.url.path, TestSupport.schemaDirectory.path])

    #expect(status == 3, "\(output)")
    #expect(output.contains("migration: failed, stopped at 0008_capital (SQLite "), "\(output)")
    #expect(try Data(contentsOf: book.url) == bytes)
  }

  /// The same file opened by the app: the update stops at the check, throws what stopped it, and
  /// the file is the older database it was — the start then offers the copies.
  @Test func theAppSeesTheSameStopAndTheFileStaysOlder() throws {
    let book = try RandomLegacyDatabase(seed: 333, operations: 20, accounts: 2...3)
    defer { book.remove() }
    let queue = try DatabaseQueue(path: book.url.path)
    try queue.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
      try db.execute(
        sql:
          "UPDATE payment_methods SET archived = 'x' WHERE rowid = (SELECT MIN(rowid) FROM payment_methods)"
      )
    }
    try queue.close()
    let before = book.url.deletingLastPathComponent().appendingPathComponent("before.sqlite")
    try DatabaseStack.backup(fileAt: book.url, to: before)

    let failure = try #require(
      throws: DatabaseStack.MigrationFailure.self,
      performing: { try DatabaseStack(url: book.url, schema: TestSupport.schemaSource) })
    #expect(failure.migration == "0004_accounts")
    // SQLite reports the check `ALTER TABLE … ADD COLUMN … CHECK` runs over the older rows as
    // an error of the statement, not as a constraint of a row.
    let code = (failure.underlying as? GRDB.DatabaseError)?.extendedResultCode
    #expect(code == .SQLITE_ERROR, "\(String(describing: code))")
    #expect(try DatabaseStack.sameData(fileAt: before, as: book.url))
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: book.url, schema: TestSupport.schemaSource)
        == [
          "0004_accounts", "0005_cards", "0006_banks", "0007_debts_and_deposits", "0008_capital",
          "0009_credit_and_allocation",
          "0010_scenarios",
          "0011_travel",
          "0012_sync",
          "0013_spending_rules",
          "0014_import_year_questions_subscriptions",
          "0015_bank_conditions",
          "0016_rate_source",
        ])
  }

  /// A database of 1.1 tried on a copy: one migration applied, a card for every live card
  /// account in a table that was not there, the counts of the step by name, and everything
  /// else equal — in lines that name no value of the database.
  /// A file of 1.2 whose cards hold cashback rules: the rules that go up to their account are
  /// the same rows, the copies and the rules on loans go, and the run counts exactly the rows
  /// the data step says — «equal», with the rule table shorter by the ones dropped.
  @Test func aOnePointTwoFileMovesItsRulesAndComesOutEqual() throws {
    let (book, _) = try Migration0006CashbackTests.book(named: "dry-run-rules")
    defer { book.remove() }
    let bytes = try Data(contentsOf: book.url)

    let (status, output) = try run([book.url.path, TestSupport.schemaDirectory.path])

    #expect(status == 0, "\(output)")
    #expect(output.contains("schema: 5 -> 16 (applied 11)"), "\(output)")
    #expect(output.contains(" cashbackRulesMoved=4"), "\(output)")
    #expect(output.contains(" cashbackRulesDropped=3"), "\(output)")
    #expect(output.contains(" cashbackRulesVoided=1"), "\(output)")
    let rules = "cashback_rules".padding(toLength: 26, withPad: " ", startingAt: 0)
    // Twelve rules before: three, four, two, two and one; three of them go.
    #expect(output.contains("  \(rules) 12 -> 9\n"), "\(output)")
    #expect(!output.contains("differ"), "\(output)")
    #expect(output.contains("result: equal"), "\(output)")
    expectNothingLeaks(output, ["Shape", "Card"], "a 1.2 file with rules")
    #expect(try Data(contentsOf: book.url) == bytes)
  }

  @Test func aOnePointOneFileCountsItsCards() throws {
    let book = try OnePointOneBook(named: "dry-run")
    defer { book.remove() }
    let bytes = try Data(contentsOf: book.url)
    let step = book.cardsStep
    let cards = try #require(step["cardsCreated"])
    #expect(cards > 0)

    let (status, output) = try run([book.url.path, TestSupport.schemaDirectory.path])

    #expect(status == 0, "\(output)")
    #expect(output.contains("schema: 4 -> 16 (applied 12)"), "\(output)")
    let name = "cards".padding(toLength: 26, withPad: " ", startingAt: 0)
    let lines = output.split(separator: "\n").map(String.init)
    #expect(lines.contains("  \(name) - -> \(cards)"), "\(output)")
    #expect(!output.contains("differ"), "\(output)")
    // The step of the cards, and the step of the banks worked out from the same file.
    let banks = try book.read { db in try TestSupport.banksStep(db) }
    #expect(banks["banksCreated"] ?? 0 > 0)
    #expect(
      lines.contains(
        "  " + "banks".padding(toLength: 26, withPad: " ", startingAt: 0)
          + " - -> \(banks["banksCreated"] ?? -1)"), "\(output)")
    let steps = step.merging(banks) { first, _ in first }
      .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    #expect(lines.contains("data step: " + steps.joined(separator: " ")), "\(output)")
    #expect(lines.contains("accounts without a bank after: 0"), "\(output)")
    #expect(step["cardsSkipped"] == 1)
    #expect(step["countsKept"] == 3)
    #expect(output.contains("result: equal"), "\(output)")
    expectNothingLeaks(output, ["Visa", "Наличные", "Сбер", book.lowerCaseText], "a 1.1 file")
    #expect(try Data(contentsOf: book.url) == bytes)
  }

  /// A file this user may not read — its permissions taken away — is not copied: the run says
  /// so with the codes of the error and the likely cause, never its path; the status is 3 and
  /// no folder of the run is left behind. (Root reads any file: skipped then.)
  @Test(.enabled(if: getuid() != 0))
  func anUnreadableFileSaysWhyAndLeavesNothing() throws {
    let book = try RandomLegacyDatabase(seed: 335, operations: 5, accounts: 1...1)
    let manager = FileManager.default
    defer {
      try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: book.url.path)
      book.remove()
    }
    try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: book.url.path)
    try #require(FileManager.default.fileExists(atPath: tool.path), "no tool at \(tool.path)")
    let process = Process()
    process.executableURL = tool
    process.arguments = [book.url.path, TestSupport.schemaDirectory.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let pid = process.processIdentifier
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self)

    #expect(process.terminationStatus == 3, "\(output)")
    #expect(
      output.contains("migration dry run: the file could not be copied: NSCocoaErrorDomain "),
      "\(output)")
    #expect(output.contains("(NSPOSIXErrorDomain 13)"), "\(output)")
    #expect(output.contains("hint: the file's permissions do not let this user read it."))
    expectNothingLeaks(
      output, [book.url.path, book.url.lastPathComponent, book.marker], "unreadable")
    let temporary = FileManager.default.temporaryDirectory
    let left = try FileManager.default.contentsOfDirectory(atPath: temporary.path)
      .filter { $0.hasPrefix("\(Self.prefix)\(pid)-") }
    #expect(left.isEmpty, "the run left \(left)")
  }

  /// A folder an earlier run left — killed before it could delete it — goes at the start of the
  /// next run, whatever that run is called with: one whose process is gone, one with no process
  /// in its name. The folder of a run still going stays.
  @Test func aFolderAnEarlierRunLeftGoesAtTheNextRun() throws {
    let temporary = FileManager.default.temporaryDirectory
    var dead: Int32 = 2_147_483_000
    while kill(dead, 0) == 0 || errno == EPERM { dead -= 1 }
    let leftovers = [
      temporary.appendingPathComponent("\(Self.prefix)\(dead)-\(UUID().uuidString)"),
      temporary.appendingPathComponent("\(Self.prefix)left-behind-\(UUID().uuidString)"),
    ]
    let alive = temporary.appendingPathComponent("\(Self.prefix)\(getpid())-\(UUID().uuidString)")
    defer {
      for folder in leftovers + [alive] { try? FileManager.default.removeItem(at: folder) }
    }
    for folder in leftovers + [alive] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try Data("a copy of somebody's database".utf8).write(
        to: folder.appendingPathComponent("finance.sqlite"))
    }

    let (status, output) = try run([])

    #expect(status == 2, "\(output)")
    for folder in leftovers {
      #expect(!FileManager.default.fileExists(atPath: folder.path), "\(folder.lastPathComponent)")
    }
    #expect(FileManager.default.fileExists(atPath: alive.path), "the folder of a live run went")
  }

  /// Ctrl-C in the middle of the update — a long one, of a schema with a slow step appended —
  /// ends the run with 128 + SIGINT and deletes its copy; the original is untouched. So does a
  /// termination.
  @Test(arguments: [SIGINT, SIGTERM])
  func aSignalInTheMiddleDeletesTheCopy(signal number: Int32) throws {
    let book = try RandomLegacyDatabase(seed: 334, operations: 30, accounts: 1...3)
    defer { book.remove() }
    let schema = book.url.deletingLastPathComponent().appendingPathComponent("schema")
    try FileManager.default.createDirectory(at: schema, withIntermediateDirectories: true)
    for file in try FileManager.default.contentsOfDirectory(
      atPath: TestSupport.schemaDirectory.path)
    where file.hasSuffix(".sql") {
      try FileManager.default.copyItem(
        at: TestSupport.schemaDirectory.appendingPathComponent(file),
        to: schema.appendingPathComponent(file))
    }
    try """
    CREATE TABLE slow_probe AS
      WITH RECURSIVE c(x) AS (VALUES(1) UNION ALL SELECT x + 1 FROM c WHERE x < 400000000)
      SELECT COUNT(*) AS n FROM c;
    """.write(
      to: schema.appendingPathComponent("0009_slow_probe.sql"), atomically: true, encoding: .utf8)
    let bytes = try Data(contentsOf: book.url)

    try #require(FileManager.default.fileExists(atPath: tool.path), "no tool at \(tool.path)")
    let process = Process()
    process.executableURL = tool
    process.arguments = [book.url.path, schema.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let folderPrefix = "\(Self.prefix)\(process.processIdentifier)-"
    let temporary = FileManager.default.temporaryDirectory
    func folders() -> [String] {
      ((try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? [])
        .filter { $0.hasPrefix(folderPrefix) }
    }
    // Wait until the copy is made and the update is under way.
    let deadline = Date().addingTimeInterval(20)
    while folders().isEmpty, process.isRunning, Date() < deadline { usleep(10_000) }
    #expect(!folders().isEmpty, "the run made no folder")
    usleep(300_000)
    #expect(process.isRunning, "the run ended before the signal")
    kill(process.processIdentifier, number)
    let stop = Date().addingTimeInterval(20)
    while process.isRunning, Date() < stop { usleep(10_000) }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
      Issue.record("the run went on after the signal")
    }
    process.waitUntilExit()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

    #expect(process.terminationStatus == 128 + number, "\(output)")
    #expect(folders().isEmpty, "the copy was left behind")
    #expect(try Data(contentsOf: book.url) == bytes)
  }

  /// An operation of an older database whose account is not in the file — a key left pointing
  /// nowhere — is counted before and after, and the update makes no more of them. The update
  /// does not give such an operation an account: it overwrites nothing an older build wrote.
  @Test func anOperationOnAMissingAccountIsCountedAndKept() throws {
    let book = try RandomLegacyDatabase(
      seed: 335, operations: 20, accounts: 1...3, brokenLinks: true)
    defer { book.remove() }
    let known = Set(book.accounts.map(\.id))
    let missing = book.operationAccounts.filter { $0.account.map { !known.contains($0) } ?? false }
    #expect(missing.count == 1)

    let (status, output) = try run([book.url.path, TestSupport.schemaDirectory.path])

    #expect(status == 0, "\(output)")
    #expect(
      output.contains(
        "operations on an account that is not there: \(missing.count) before, \(missing.count) after"
      ),
      "\(output)")
    #expect(output.contains("accounts after: operations without an account 0"))
    expectNothingLeaks(output, [book.marker], "a missing account")
  }
}
