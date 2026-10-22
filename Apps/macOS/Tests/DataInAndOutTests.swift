import AppCore
import AppDatabase
import SQLite3
import XCTest

@testable import OhMyMoney

/// Data in and out of a book that holds everything the accounts brought — groups, one of them
/// out of the summary, accounts in several currencies, transfers with an exchange, counts by
/// account, refunds of a purchase and money back — through the services the File menu, the
/// Backups tab and «Собрать отчёт о проблеме…» use: every CSV file, the transfer archive onto a
/// clean database, a copy restored, and the problem report.
final class DataInAndOutTests: XCTestCase {
  private var scratch: URL!
  private var stack: DatabaseStack!

  private static let today = DateOnly(year: 2026, month: 9, day: 18)

  override func setUpWithError() throws {
    try super.setUpWithError()
    scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-io-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    stack = try Self.book(in: scratch, named: "source")
  }

  override func tearDownWithError() throws {
    try? stack?.close()
    stack = nil
    try? FileManager.default.removeItem(at: scratch)
    try super.tearDownWithError()
  }

  /// Six months of the sample with its accounts, the default currency set to dollars (so the
  /// setting is not the default one a clean database would give anyway) and a fee category
  /// remembered for the transfers.
  private static func book(in scratch: URL, named name: String) throws -> DatabaseStack {
    let stack = try DataSetGeneration.prepare(
      directory: scratch.appendingPathComponent("Sets/\(name)", isDirectory: true),
      generation: .months(6), today: today, calendar: .utc, language: "ru",
      schema: BundleSchemaSource(bundle: .main))
    let settings = SettingsRepository(writer: stack.writer)
    try settings.setDefaultCurrency(.usd)
    if try settings.string(AccountSettings.transferFeeCategoryKey) == nil {
      let fees = try ReferenceRepository(writer: stack.writer).categories(includeArchived: true)
        .first { $0.kind == .expense }
      try settings.set(
        AccountSettings.transferFeeCategoryKey, to: try XCTUnwrap(fees).id.uuidString)
    }
    return stack
  }

  /// The rows of a query on the file of a database, as text, read through SQLite itself: the
  /// test bundle does not link the conformances GRDB fetches with.
  private func rows(_ sql: String, in stack: DatabaseStack) throws -> [[String]] {
    var handle: OpaquePointer?
    defer { sqlite3_close(handle) }
    guard sqlite3_open_v2(stack.url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
    else { throw CocoaError(.fileReadUnknown) }
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
      throw CocoaError(.fileReadCorruptFile)
    }
    var result: [[String]] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let columns = sqlite3_column_count(statement)
      result.append(
        (0..<columns).map { column in
          sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        })
    }
    return result
  }

  private func count(_ sql: String, in stack: DatabaseStack) throws -> Int {
    Int(try rows(sql, in: stack).first?.first ?? "") ?? 0
  }

  /// The rows of the `settings` and `currencies` tables, which no CSV file carries: the
  /// database inside the archive is what brings them over.
  private func settingsRows(of stack: DatabaseStack) throws -> [String] {
    try rows("SELECT key || '=' || value FROM settings ORDER BY key", in: stack).map { $0[0] }
      + rows(
        "SELECT code || ':' || enabled || ':' || sort FROM currencies ORDER BY code", in: stack
      ).map { $0[0] }
  }

  // MARK: The book itself

  /// What the other tests lean on: the book really holds every kind of row they are about.
  func testTheBookHoldsEveryKindOfRowTheAccountsBrought() throws {
    let counts = try ExportRepository(writer: stack.writer).rowCounts()
    for table in [
      "account_groups", "transfers", "reconciliations", "reconciliation_balances",
      "reimbursement_links", "payment_methods", "debts", "debt_entries", "goals",
    ] {
      XCTAssertGreaterThan(counts[table] ?? 0, 0, "\(table) is empty in the sample")
    }
    XCTAssertGreaterThan(
      try count("SELECT COUNT(*) FROM transactions WHERE kind = 'refund'", in: stack), 0)
    XCTAssertGreaterThan(
      try count(
        "SELECT COUNT(*) FROM transaction_parts WHERE refund_of_part_id IS NOT NULL", in: stack),
      0, "no refund is linked to the part it returns")
    XCTAssertGreaterThan(
      try count("SELECT COUNT(*) FROM transfers WHERE from_currency <> to_currency", in: stack),
      0, "no transfer exchanges one currency for another")
    XCTAssertGreaterThan(
      try count("SELECT COUNT(*) FROM account_groups WHERE in_summary = 0", in: stack), 0)
    let settings = SettingsRepository(writer: stack.writer)
    XCTAssertEqual(try settings.string(AccountSettings.defaultCurrencyKey), "USD")
    XCTAssertEqual(try settings.string(AccountSettings.setupKey), "done")
  }

  // MARK: CSV

  /// Every file of the export carries every column of its table, in the table's order, under
  /// its name with `_e4` dropped (the amounts are decimal strings there). A column added by a
  /// later migration and forgotten in the export would be lost to every tool reading the CSV.
  func testEveryExportFileHasEveryColumnOfItsTable() throws {
    for table in ExportTables.all {
      let name = String(table.fileName.dropLast(4))
      let columns = try rows("SELECT name FROM pragma_table_info('\(name)')", in: stack)
        .map { $0[0] }
      XCTAssertFalse(columns.isEmpty, "\(name) is not a table of the database")
      let expected = columns.map { $0.hasSuffix("_e4") ? String($0.dropLast(3)) : $0 }
      XCTAssertEqual(table.columns, expected, table.fileName)
    }
  }

  /// All 42 files from a book with accounts: every row of every table is in its file — no more,
  /// no fewer — each row as wide as the header, the header the one the export declares, and
  /// the amounts decimal strings with a dot.
  func testAnExportOfABookWithAccountsWritesEveryRowOfEveryTable() throws {
    let service = CSVExportService(repository: ExportRepository(writer: stack.writer))
    let target = scratch.appendingPathComponent("export", isDirectory: true)
    let written = try service.export(to: target)
    let counts = try service.rowCounts()

    XCTAssertEqual(written.map(\.lastPathComponent), ExportTables.all.map(\.fileName))
    for table in ExportTables.all {
      let name = String(table.fileName.dropLast(4))
      let data = try Data(contentsOf: target.appendingPathComponent(table.fileName))
      XCTAssertFalse(data.starts(with: [0xEF, 0xBB, 0xBF]), "\(table.fileName) has a BOM")
      let rows = try CSVReader.rows(from: data)
      XCTAssertEqual(rows.first, table.columns, table.fileName)
      XCTAssertEqual(rows.count - 1, counts[name], "\(table.fileName): rows written")
      XCTAssertTrue(rows.allSatisfy { $0.count == table.columns.count }, table.fileName)
    }

    // Every amount of the transfers reads as a decimal number with a dot, never a comma.
    let transfers = try CSVReader.rows(
      from: Data(contentsOf: target.appendingPathComponent("transfers.csv")))
    let header = try XCTUnwrap(transfers.first)
    for column in ["from_amount", "to_amount"] {
      let index = try XCTUnwrap(header.firstIndex(of: column))
      for row in transfers.dropFirst() {
        XCTAssertNotNil(Decimal(string: row[index], locale: Locale(identifier: "en_US_POSIX")))
        XCTAssertFalse(row[index].contains(","), "\(column) \(row[index])")
      }
    }
  }

  /// An export over a folder with an earlier export finds every one of the 42 files it would
  /// replace — the three of the accounts and the two of the cards as well — and nothing else of
  /// the folder; the question before the replacement counts them in the plural of both
  /// languages (it gives the number, not the names).
  @MainActor
  func testTheServiceFindsEveryFileOfAnEarlierExportAndTheQuestionCountsThem() throws {
    let service = CSVExportService(repository: ExportRepository(writer: stack.writer))
    let target = scratch.appendingPathComponent("export", isDirectory: true)
    try service.export(to: target)
    try Data("mine".utf8).write(to: target.appendingPathComponent("notes.csv"))

    let replaced = service.filesItWouldReplace(in: target)
    XCTAssertEqual(replaced, ExportTables.all.map(\.fileName))

    let language = AppLanguage()
    language.choice = .russian
    XCTAssertEqual(
      language.format("export.replace.title", table: "Settings", replaced.count),
      "Заменить 42 файла в этой папке?")
    XCTAssertEqual(
      language.format("export.done", table: "Settings", replaced.count), "Записано 42 файла CSV")
    language.choice = .english
    XCTAssertEqual(
      language.format("export.replace.title", table: "Settings", replaced.count),
      "Replace 42 files in this folder?")
  }

  /// A second export over the first replaces the files with the same bytes, leaves nothing of
  /// its own behind — no hidden staging folder — and keeps the owner's file beside them.
  func testASecondExportOverTheFirstLeavesTheFolderAsTheFirstLeftIt() throws {
    let service = CSVExportService(repository: ExportRepository(writer: stack.writer))
    let target = scratch.appendingPathComponent("export", isDirectory: true)
    try service.export(to: target)
    try Data("mine".utf8).write(to: target.appendingPathComponent("notes.csv"))
    let first = try ExportTables.all.map {
      try Data(contentsOf: target.appendingPathComponent($0.fileName))
    }

    try service.export(to: target)

    let second = try ExportTables.all.map {
      try Data(contentsOf: target.appendingPathComponent($0.fileName))
    }
    XCTAssertEqual(first, second)
    let names = try FileManager.default.contentsOfDirectory(atPath: target.path).sorted()
    XCTAssertEqual(names, (ExportTables.all.map(\.fileName) + ["notes.csv"]).sorted())
  }

  // MARK: Archive

  /// The whole path of a transfer: an archive of this book, with a password, imported on
  /// another Mac whose database is clean. After the launch puts the staged file in place, the
  /// new database holds exactly what the old one did — every table value for value, the
  /// accounts, transfers and counts among them, and the settings that live in the database:
  /// the default currency, the state of the setup, the fee category, the enabled currencies.
  @MainActor
  func testAnArchiveImportedOnACleanDatabaseGivesTheSameBook() async throws {
    let before = scratch.appendingPathComponent("before.sqlite")
    try stack.backup(to: before)
    let archives = ArchiveService(stack: stack, appVersion: "1.1.1", iterations: 1_000)
    let url = scratch.appendingPathComponent("move.ohmymoneyarchive")
    _ = try archives.exportArchive(
      to: url, password: "пароль", settings: ["language": "ru", "theme.scheme": "dark"])

    // The other Mac: a clean database, its own folder of copies.
    let other = scratch.appendingPathComponent("other", isDirectory: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let database = other.appendingPathComponent("finance.sqlite")
    var clean: DatabaseStack? = try DatabaseStack(
      url: database, schema: BundleSchemaSource(bundle: .main))
    let cleanStack = try XCTUnwrap(clean)
    XCTAssertEqual(try TransactionRepository(writer: cleanStack.writer).count(), 0)
    let theirs = ArchiveService(stack: cleanStack, appVersion: "1.1.1", iterations: 1_000)
    let opened = try theirs.openArchive(at: url, password: "пароль")
    // The settings that live outside the database travel beside it, and the import puts them
    // into the defaults the next launch reads (the guard of the test host takes them away).
    let portable = try XCTUnwrap(opened.settings)
    XCTAssertEqual(
      try JSONSerialization.jsonObject(with: portable) as? [String: String],
      ["language": "ru", "theme.scheme": "dark"])
    let pending = other.appendingPathComponent("finance.pending.sqlite")
    try await ArchiveImportFlow.stageReplacement(
      opened: opened, archives: theirs,
      backups: BackupService(stack: cleanStack, directory: other.appendingPathComponent("b")),
      target: pending)
    XCTAssertEqual(UserDefaults.standard.string(forKey: AppDefaultsGuard.languageKey), "ru")
    XCTAssertEqual(UserDefaults.standard.string(forKey: AppTheme.schemeKey), "dark")
    try cleanStack.close()
    clean = nil

    // What the next launch does with the staged file.
    BackupService.removeDatabaseFiles(at: database)
    try FileManager.default.moveItem(at: pending, to: database)
    XCTAssertTrue(try DatabaseStack.sameData(fileAt: database, as: before))

    let imported = try DatabaseStack(url: database, schema: BundleSchemaSource(bundle: .main))
    defer { try? imported.close() }
    XCTAssertEqual(
      try ExportRepository(writer: imported.writer).rowCounts(),
      try ExportRepository(writer: stack.writer).rowCounts())
    XCTAssertEqual(
      try ExportRepository(writer: imported.writer).tables().map(\.data),
      try ExportRepository(writer: stack.writer).tables().map(\.data))
    XCTAssertEqual(try settingsRows(of: imported), try settingsRows(of: stack))
    let settings = SettingsRepository(writer: imported.writer)
    XCTAssertEqual(try settings.defaultCurrency(), .usd)
    XCTAssertEqual(try settings.string(AccountSettings.setupKey), "done")
    XCTAssertEqual(try settings.enabledCurrencies().first, .rub)
    XCTAssertTrue(try settings.enabledCurrencies().contains(.usd))
    // Set up on the old Mac, so the new one does not offer the setup of the accounts again.
    let setup = try settings.string(AccountSettings.setupKey)
      .flatMap(AccountSettings.Setup.init(rawValue:))
    XCTAssertFalse(
      AccountSetupOffer.asks(setup: setup, isOpen: true, isTestHost: false, dataSet: nil))
  }

  /// The copy an import writes first is the state of the Mac it lands on — here the clean
  /// database — checked and listed, so the import can be taken back from the Backups tab.
  func testTheCopyBeforeAnImportOnACleanDatabaseIsTheCleanOne() async throws {
    let archives = ArchiveService(stack: stack, appVersion: "1.1.1")
    let url = scratch.appendingPathComponent("move.ohmymoneyarchive")
    _ = try archives.exportArchive(to: url)

    let other = scratch.appendingPathComponent("other", isDirectory: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let clean = try DatabaseStack(
      url: other.appendingPathComponent("finance.sqlite"),
      schema: BundleSchemaSource(bundle: .main))
    defer { try? clean.close() }
    let theirs = ArchiveService(stack: clean, appVersion: "1.1.1")
    let backups = BackupService(stack: clean, directory: other.appendingPathComponent("b"))
    try await ArchiveImportFlow.stageReplacement(
      opened: try theirs.openArchive(at: url), archives: theirs, backups: backups,
      target: other.appendingPathComponent("finance.pending.sqlite"))

    let copies = try await backups.backups()
    XCTAssertEqual(copies.count, 1)
    let copy = try XCTUnwrap(copies.first)
    XCTAssertEqual(
      BackupCopy.parse(copy.lastPathComponent)?.reason, .beforeImport, copy.lastPathComponent)
    XCTAssertTrue(DatabaseStack.integrityCheckPassed(at: copy))
    let counts = try DatabaseStack.rowCounts(fileAt: copy)
    for table in ["transactions", "transfers", "account_groups", "reconciliation_balances"] {
      XCTAssertEqual(counts[table], 0, "\(table) of the clean database")
    }
  }

  /// The manifest of the archive counts the rows of the 42 files it carries, the three of the
  /// accounts among them, and the counts agree with the files: an import checks one against
  /// the other.
  func testTheManifestCountsTheRowsOfTheAccountsFiles() throws {
    let archives = ArchiveService(stack: stack, appVersion: "1.1.1")
    let url = scratch.appendingPathComponent("counts.ohmymoneyarchive")
    _ = try archives.exportArchive(to: url)
    let opened = try archives.openArchive(at: url)
    let counts = try ExportRepository(writer: stack.writer).rowCounts()

    XCTAssertEqual(opened.manifest.rowCounts, counts)
    for table in ["account_groups", "transfers", "reconciliation_balances"] {
      XCTAssertGreaterThan(opened.manifest.rowCounts[table] ?? 0, 0, table)
      XCTAssertTrue(opened.csvTables.contains(table), table)
    }
  }

  // MARK: Copies

  /// A copy of this book taken after a change, restored through the Backups tab: the file
  /// staged for the next launch holds the book as the copy had it, and the state before the
  /// restore is on disk first.
  func testACopyOfABookWithAccountsRestoresWhole() async throws {
    let folder = scratch.appendingPathComponent("copies", isDirectory: true)
    let backups = BackupService(stack: stack, directory: folder)
    let copy = try await backups.writeBackup()
    let expected = try ExportRepository(writer: stack.writer).tables().map(\.data)
    let expectedSettings = try settingsRows(of: stack)

    // The owner goes on: the default currency changes and an operation is added.
    let settings = SettingsRepository(writer: stack.writer)
    try settings.setDefaultCurrency(.eur)
    var draft = TransactionDraft(amount: AmountE4(whole: 250), note: "coffee")
    draft.normalizeSinglePart()
    try TransactionRepository(writer: stack.writer).save(try draft.materialize())

    let target = scratch.appendingPathComponent("finance.pending.sqlite")
    try await BackupRestoreFlow.stage(copy: copy, backups: backups, target: target)

    let names = try await backups.backups().map(\.lastPathComponent)
    XCTAssertEqual(
      names.filter { BackupCopy.parse($0)?.reason == .beforeRestore }.count, 1, "\(names)")
    let restored = try DatabaseStack(url: target, schema: BundleSchemaSource(bundle: .main))
    defer { try? restored.close() }
    XCTAssertEqual(try ExportRepository(writer: restored.writer).tables().map(\.data), expected)
    XCTAssertEqual(try settingsRows(of: restored), expectedSettings)
    XCTAssertEqual(try SettingsRepository(writer: restored.writer).defaultCurrency(), .usd)
  }

  /// A copy after every change, far more than the thinning keeps: the copy written before the
  /// update stays, however old, and takes no place among the others.
  func testTheCopyBeforeTheUpdateOutlivesTheThinningOfCopiesAfterChanges() async throws {
    let folder = scratch.appendingPathComponent("copies", isDirectory: true)
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    let kept = try BackupService.copyBeforeMigration(
      of: stack.url, into: folder, now: start.addingTimeInterval(-200 * 86_400))
    var policy = BackupService.Policy()
    policy.calendar.timeZone = TimeZone(identifier: "UTC")!
    let backups = BackupService(stack: stack, directory: folder, policy: policy)
    // Four days, three copies a day: the days before the last keep their newest copy alone.
    for day in 0..<4 {
      for minute in 0..<3 {
        try await backups.writeBackup(
          now: start.addingTimeInterval(Double(day) * 86_400 + Double(minute) * 60))
      }
    }

    let names = try await backups.backups().map(\.lastPathComponent)
    XCTAssertTrue(names.contains(kept.lastPathComponent), "\(names)")
    XCTAssertEqual(names.filter { !BackupService.isBeforeMigration($0) }.count, 6, "\(names)")
  }

  // MARK: Problem report

  /// A report gathered on this book: nothing of the owner's is anywhere in it — no name of an
  /// account, a group, a person, a place, an event or a category, no note of an operation or
  /// a transfer, no amount of a transfer, of a counted balance of an account or of an
  /// operation in an account's own currency — while the new settings go in as values the report may hold: the default
  /// currency as its code, the setup as its state, the fee category as an id. The tables of
  /// the accounts are counted like the others.
  @MainActor
  func testAReportOnABookWithAccountsHoldsNothingOfTheOwners() async throws {
    var all: [String] = []
    for sql in [
      "SELECT name FROM payment_methods", "SELECT name FROM account_groups",
      "SELECT name FROM people", "SELECT name FROM places", "SELECT name FROM events",
      "SELECT name FROM categories", "SELECT note FROM transactions WHERE note IS NOT NULL",
      "SELECT note FROM transfers WHERE note IS NOT NULL", "SELECT name FROM goals",
      "SELECT name FROM debts", "SELECT name FROM scheduled_payments",
    ] {
      all += try rows(sql, in: stack).map { $0[0] }
    }
    // Held to the rule of the journal: every name of three letters and more.
    let names = Array(Set(all.filter { $0.count >= LogPrivacy.shortestMeaningful }))
    XCTAssertGreaterThan(names.count, 20)
    XCTAssertTrue(
      names.contains { $0.count < 5 }, "the sample has no short name to look for: \(names)")
    // The amounts the accounts brought, as decimal numbers the way the export writes them;
    // `LogPrivacy` looks for their digits inside every number of the report, separators or
    // not, and passes over those shorter than four digits like the journal's rule does.
    var amounts: [String] = []
    for sql in [
      "SELECT from_amount_e4 FROM transfers", "SELECT to_amount_e4 FROM transfers",
      "SELECT abs(actual_e4) FROM reconciliation_balances",
      "SELECT abs(difference_e4) FROM reconciliation_balances WHERE difference_e4 <> 0",
      "SELECT account_amount_e4 FROM transactions WHERE account_amount_e4 IS NOT NULL",
    ] {
      amounts += try rows(sql, in: stack).compactMap { row in
        Int64(row[0]).map { "\(Decimal($0) / 10_000)" }
      }
    }
    amounts = Array(Set(amounts))
    XCTAssertGreaterThan(
      amounts.filter { $0.filter(\.isNumber).count >= 4 }.count, 20,
      "the accounts of the sample brought too few amounts to look for")
    let expectedCounts = try ExportRepository(writer: stack.writer).rowCounts()
    try stack.close()
    stack = nil

    let before = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    setenv("OHMYMONEY_DATA_DIR", scratch.path, 1)
    defer {
      if let before {
        setenv("OHMYMONEY_DATA_DIR", before, 1)
      } else {
        unsetenv("OHMYMONEY_DATA_DIR")
      }
    }
    let scratch = scratch!
    let environment = AppEnvironment()
    await environment.start(preparing: { try Self.book(in: scratch, named: "report") })
    XCTAssertEqual(environment.state, .ready)
    let report = await ProblemReportService.gather(
      environment: environment, compute: ComputeStore(calendar: .utc))
    await environment.close()

    XCTAssertEqual(report.settings[AccountSettings.defaultCurrencyKey], "USD")
    XCTAssertEqual(report.settings[AccountSettings.setupKey], "done")
    XCTAssertNotNil(
      report.settings[AccountSettings.transferFeeCategoryKey].flatMap(UUID.init(uuidString:)))
    for table in ["account_groups", "transfers", "reconciliation_balances"] {
      XCTAssertEqual(report.rowCounts[table], expectedCounts[table], table)
    }
    let files = try ZipReader.files(in: try report.zipped())
    let database = String(decoding: try XCTUnwrap(files["database.txt"]), as: UTF8.self)
    for table in ["account_groups", "transfers", "reconciliation_balances"] {
      XCTAssertTrue(
        database.contains("  \(table) \(expectedCounts[table] ?? -1)\n")
          || database.hasSuffix("  \(table) \(expectedCounts[table] ?? -1)"), database)
    }
    let settingsText = String(decoding: try XCTUnwrap(files["settings.txt"]), as: UTF8.self)
    XCTAssertTrue(settingsText.contains("USD"), settingsText)
    XCTAssertTrue(settingsText.contains("done"), settingsText)
    // The report holds the thresholds of the settings by design — the savings target of 10 %
    // is `1000` in basis points — so an amount whose digits are those of a setting's value
    // cannot be told from it and is not looked for. Every other amount is.
    let settingDigits = report.settings.values.map { String($0.filter(\.isNumber)) }
    let lookedFor = amounts.filter { amount in
      let digits = String(amount.filter(\.isNumber))
      return !settingDigits.contains { !$0.isEmpty && $0.contains(digits) }
    }
    XCTAssertGreaterThan(lookedFor.filter { $0.filter(\.isNumber).count >= 4 }.count, 20)
    for entry in try ZipReader.entries(in: try report.zipped()) {
      let text = String(data: entry.data, encoding: .utf8) ?? ""
      XCTAssertEqual(
        LogPrivacy.offences(in: text, forbidding: names), [],
        "\(entry.path) holds a name or a note")
      // An id is never an amount: the digits between the letters of a UUID are taken out
      // before the amounts are looked for, or a random id would read as a leak.
      XCTAssertEqual(
        LogPrivacy.offences(in: Self.withoutIds(text), forbidding: lookedFor), [],
        "\(entry.path) holds an amount")
    }
  }

  private static func withoutIds(_ text: String) -> String {
    text.replacingOccurrences(
      of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
      with: " ", options: .regularExpression)
  }
}
