import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Exercises the promises about the owner's data on a real database file: copies after a
/// change, CSV that other tools can read, and a single archive that survives a round trip.
final class ExportAndArchiveTests: XCTestCase {
  private var directory: URL!
  private var stack: DatabaseStack!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    stack = try DatabaseStack(
      url: directory.appendingPathComponent("finance.sqlite"),
      schema: BundleSchemaSource(bundle: .main))
    try seed()
  }

  override func tearDownWithError() throws {
    stack = nil
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  private func seed() throws {
    let references = ReferenceRepository(writer: stack.writer)
    try references.seedCategoriesIfEmpty(StarterCategories.tree(language: "en"))
    let person = Person(name: "Alex")
    try references.save(person)

    let transactions = TransactionRepository(writer: stack.writer)
    var draft = TransactionDraft(amount: AmountE4(whole: 250), note: "coffee, with a comma")
    draft.normalizeSinglePart()
    try transactions.save(try draft.materialize())

    var split = TransactionDraft(amount: AmountE4(whole: 1_000), note: "dinner")
    split.parts = [
      PartDraft(amount: AmountE4(whole: 600)),
      PartDraft(amount: AmountE4(whole: 400), reimbursable: true, debtorPersonId: person.id),
    ]
    try transactions.save(try split.materialize())
  }

  // MARK: CSV

  func testExportWritesEveryTableAndTheFilesParse() throws {
    let service = CSVExportService(repository: ExportRepository(writer: stack.writer))
    let target = directory.appendingPathComponent("export")
    let written = try service.export(to: target)

    XCTAssertEqual(written.count, 44)
    XCTAssertEqual(
      Array(written.map(\.lastPathComponent).suffix(21).prefix(12)),
      [
        "banks.csv", "assets.csv", "asset_valuations.csv", "debt_instalments.csv",
        "debt_costs.csv", "allocation_rules.csv", "custom_currencies.csv", "settings.csv",
        "tags.csv", "part_tags.csv", "rules.csv", "day_notes.csv",
      ])
    XCTAssertEqual(
      Array(written.map(\.lastPathComponent).suffix(9)),
      [
        "budget_month_exceptions.csv", "event_budget_items.csv", "event_templates.csv",
        "subscription_terms.csv", "subscription_usage.csv", "subscription_users.csv",
        "subscription_keep_groups.csv", "bank_conditions.csv", "deposit_offers.csv",
      ])
    for url in written {
      let text = try String(contentsOf: url, encoding: .utf8)
      let rows = try CSVReader.rows(from: Data(text.utf8))
      XCTAssertFalse(rows.isEmpty, url.lastPathComponent)
      // Every row has as many fields as the header: that is what pandas expects.
      let width = rows[0].count
      XCTAssertTrue(rows.allSatisfy { $0.count == width }, url.lastPathComponent)
    }
  }

  func testExportedAmountsAreDecimalStringsAndCommasSurvive() throws {
    let service = CSVExportService(repository: ExportRepository(writer: stack.writer))
    let target = directory.appendingPathComponent("export")
    _ = try service.export(to: target)

    let url = target.appendingPathComponent("transactions.csv")
    let rows = try CSVReader.rows(from: try Data(contentsOf: url))
    let header = rows[0]
    let noteIndex = try XCTUnwrap(header.firstIndex(of: "note"))
    let amountIndex = try XCTUnwrap(header.firstIndex(of: "amount"))

    let coffee = try XCTUnwrap(rows.first { $0[noteIndex] == "coffee, with a comma" })
    // Amounts are written the way a person and pandas both read them.
    XCTAssertEqual(coffee[amountIndex], "250")
  }

  /// Whether the journal — opened by the test on a folder of its own — has a line with this in
  /// it. A line is written off the caller's turn, so the question waits a moment for it.
  private func journal(contains needle: String) async -> Bool {
    for _ in 0..<50 {
      if Logbook.shared.lines().contains(where: { $0.contains(needle) }) { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return false
  }

  /// The owner was warned the files carry names and amounts, chose a folder, and walks away
  /// believing the export is there. One that stops after three of the files used to
  /// leave those three — over the files of an earlier export — with nothing on screen and
  /// only `export.started` in the journal. It now leaves the folder as it was, says why in the
  /// journal («экспорт: начало, результат»), and the File menu tells the owner.
  func testAnExportThatDoesNotFinishLeavesTheFolderAsItWasAndSaysSo() async throws {
    let logs = directory.appendingPathComponent("Logs", isDirectory: true)
    Logbook.shared.open(directory: logs, threshold: .debug)
    defer { Task { Logbook.shared.close() } }
    let manager = FileManager.default
    let service = CSVExportService(repository: ExportRepository(writer: stack.writer))
    let target = directory.appendingPathComponent("export")
    let earlier = try service.export(to: target)
    var before: [String: Data] = [:]
    for url in earlier { before[url.lastPathComponent] = try Data(contentsOf: url) }

    // One operation more, so the new set differs from the one in the folder.
    var draft = TransactionDraft(amount: AmountE4(whole: 90), note: "later")
    draft.normalizeSinglePart()
    try TransactionRepository(writer: stack.writer).save(try draft.materialize())

    // The fourth file cannot be put in place: something that is not a file has its name.
    let people = target.appendingPathComponent("people.csv")
    try manager.removeItem(at: people)
    try manager.createDirectory(
      at: people.appendingPathComponent("inside"), withIntermediateDirectories: true)

    XCTAssertEqual(FileCommands.exportCSV(with: service, to: target), .failed)

    for (name, data) in before where name != "people.csv" {
      XCTAssertEqual(
        try Data(contentsOf: target.appendingPathComponent(name)), data,
        "\(name) was replaced by an export that did not finish")
    }
    XCTAssertEqual(
      try manager.contentsOfDirectory(atPath: target.path).sorted(), before.keys.sorted(),
      "the export left something behind")
    let failed = await journal(contains: "export.failed")
    XCTAssertTrue(failed, "the export that did not finish is not in the journal")
    let lines = Logbook.shared.lines()
    let failure = try XCTUnwrap(lines.first { $0.contains("export.failed") })
    XCTAssertTrue(failure.contains("error="), failure)
    XCTAssertFalse(
      lines.contains { $0.contains(directory.path) }, "a path of the owner's reached the journal")
  }

  /// An export that finishes says how many files it wrote; the menu is never silent.
  func testAnExportThatFinishesSaysHowManyFilesItWrote() throws {
    let service = CSVExportService(repository: ExportRepository(writer: stack.writer))
    let target = directory.appendingPathComponent("export")
    XCTAssertEqual(FileCommands.exportCSV(with: service, to: target), .written(files: 44))
    let names = try FileManager.default.contentsOfDirectory(atPath: target.path)
    XCTAssertEqual(names.count, 44, "\(names)")
    XCTAssertTrue(names.allSatisfy { $0.hasSuffix(".csv") }, "\(names)")
  }

  /// «Бэкапы, экспорт, архив, сверка: начало, результат, размер файла, число записей»: the
  /// line of a finished CSV export said files and bytes, not how many records went out.
  func testAFinishedExportSaysInTheJournalHowManyRecordsItWrote() async throws {
    let logs = directory.appendingPathComponent("Logs", isDirectory: true)
    Logbook.shared.open(directory: logs, threshold: .debug)
    defer { Task { Logbook.shared.close() } }
    let service = CSVExportService(repository: ExportRepository(writer: stack.writer))
    let records = try service.rowCounts().values.reduce(0, +)
    XCTAssertGreaterThan(records, 5)

    try service.export(to: directory.appendingPathComponent("export"))

    let done = await journal(contains: "export.done")
    XCTAssertTrue(done)
    let lines = Logbook.shared.lines()
    let line = try XCTUnwrap(lines.first { $0.contains("export.done") })
    XCTAssertTrue(line.contains("files=44"), line)
    XCTAssertTrue(line.contains("rows=\(records)"), line)
  }

  /// The names of the files are fixed, so an export into a folder that has them
  /// replaced those files without a word — an earlier export's, or a `people.csv` of the
  /// owner's own. The File menu now asks first, naming how many would be replaced; only files
  /// count (anything else under such a name is left alone and fails the export).
  func testTheFilesAnExportWouldReplaceAreKnownBeforeItRuns() throws {
    let service = CSVExportService(repository: ExportRepository(writer: stack.writer))
    let target = directory.appendingPathComponent("export")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    XCTAssertEqual(service.filesItWouldReplace(in: target), [])

    try Data("name\nmine\n".utf8).write(to: target.appendingPathComponent("people.csv"))
    try Data("notes".utf8).write(to: target.appendingPathComponent("notes.txt"))
    try FileManager.default.createDirectory(
      at: target.appendingPathComponent("rates.csv"), withIntermediateDirectories: true)
    XCTAssertEqual(service.filesItWouldReplace(in: target), ["people.csv"])

    try FileManager.default.removeItem(at: target.appendingPathComponent("rates.csv"))
    try service.export(to: target)
    XCTAssertEqual(service.filesItWouldReplace(in: target).count, 44)
  }

  /// The three files the accounts brought are asked about like the other eighteen: an export
  /// over a folder that has only them names them.
  func testTheQuestionBeforeReplacingKnowsTheFilesOfTheAccounts() throws {
    let service = CSVExportService(repository: ExportRepository(writer: stack.writer))
    let target = directory.appendingPathComponent("export")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let files = ["account_groups.csv", "transfers.csv", "reconciliation_balances.csv"]
    for name in files {
      try Data("id\n".utf8).write(to: target.appendingPathComponent(name))
    }
    XCTAssertEqual(service.filesItWouldReplace(in: target).sorted(), files.sorted())
  }

  /// The question before replacing, in both languages.
  @MainActor
  func testTheQuestionBeforeReplacingFilesIsInBothLanguages() {
    let language = AppLanguage()
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      for key in ["export.replace.title", "export.replace.body", "export.replace.action"] {
        XCTAssertNotEqual(language(key, table: "Settings"), key, "\(key) in \(choice.rawValue)")
      }
    }
  }

  /// The words the owner reads after the CSV export, in both languages.
  @MainActor
  func testTheOutcomeOfTheExportHasWordsInBothLanguages() {
    let language = AppLanguage()
    let keys = [
      FileCommands.CSVExportOutcome.written(files: 21).messageKey,
      FileCommands.CSVExportOutcome.failed.messageKey, "export.failed.body",
    ]
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      for key in keys {
        XCTAssertNotEqual(language(key, table: "Settings"), key, "\(key) in \(choice.rawValue)")
      }
    }
  }

  // MARK: Archive

  func testArchiveRoundTripKeepsEveryFileAndCount() throws {
    let service = ArchiveService(stack: stack, appVersion: "0.1.0")
    let url = directory.appendingPathComponent("test.ohmymoneyarchive")
    _ = try service.exportArchive(to: url, settings: ["language": "ru"])

    let opened = try service.openArchive(at: url)
    XCTAssertEqual(opened.manifest.formatVersion, ArchiveManifest.currentFormatVersion)
    XCTAssertEqual(opened.manifest.rowCounts["transactions"], 2)
    XCTAssertEqual(opened.manifest.rowCounts["transaction_parts"], 3)
    XCTAssertNotNil(opened.database)
    XCTAssertNotNil(opened.settings)
    XCTAssertTrue(opened.csvTables.contains("transactions"))
  }

  /// The manifest says which schema the database inside it carries, so that an older build
  /// refuses an archive of a newer one before anything is replaced («если новее — отказ»). The
  /// number was a literal that nobody raised when `0003_model.sql` arrived: every archive said 2
  /// for a database with three migrations, and every build compared the archive against 2.
  func testTheManifestRecordsTheSchemaOfTheDatabaseItSnapshots() throws {
    let service = ArchiveService(stack: stack, appVersion: "0.1.0")
    let url = directory.appendingPathComponent("schema.ohmymoneyarchive")
    _ = try service.exportArchive(to: url)

    let opened = try service.openArchive(at: url)
    XCTAssertEqual(opened.manifest.schemaVersion, stack.applied.onDisk)
    XCTAssertEqual(opened.manifest.schemaVersion, try stack.appliedMigrations().count)
    XCTAssertEqual(opened.manifest.schemaVersion, try BundleSchemaSource().migrations().count)

    // An archive of a build with one migration more is refused by this one.
    let newer = ArchiveService(
      stack: stack, appVersion: "9.0.0", schemaVersion: stack.applied.onDisk + 1)
    let future = directory.appendingPathComponent("future.ohmymoneyarchive")
    _ = try newer.exportArchive(to: future)
    XCTAssertThrowsError(try service.openArchive(at: future)) { error in
      guard case CoreError.unsupportedSchemaVersion = error else {
        return XCTFail("an archive of a newer schema was opened: \(error)")
      }
      XCTAssertEqual(FileCommands.messageKey(for: error), "archive.error.newerSchema")
    }
  }

  /// With the capital and the cushion the schema has eight migrations: an archive says 8, this
  /// build opens an archive of schema 8 — and of the ones before it — and a build that knows only
  /// 7 refuses it.
  func testAnArchiveOfSchemaEightOpensWhereEightIsSupported() throws {
    XCTAssertEqual(stack.applied.onDisk, 15)
    let service = ArchiveService(stack: stack, appVersion: "1.6.0")
    let url = directory.appendingPathComponent("eight.ohmymoneyarchive")
    _ = try service.exportArchive(to: url)
    let data = try Data(contentsOf: url)

    let opened = try ArchiveOpener.open(data, supportedSchemaVersion: 15)
    XCTAssertEqual(opened.manifest.schemaVersion, 15)
    XCTAssertEqual(opened.csvTables.count, 44)
    XCTAssertTrue(opened.csvTables.contains("reconciliation_balances"))
    XCTAssertTrue(opened.csvTables.contains("cards"))
    XCTAssertTrue(opened.csvTables.contains("cashback_rules"))
    XCTAssertTrue(opened.csvTables.contains("banks"))
    XCTAssertTrue(opened.csvTables.contains("assets"))
    XCTAssertTrue(opened.csvTables.contains("asset_valuations"))
    XCTAssertThrowsError(try ArchiveOpener.open(data, supportedSchemaVersion: 7))

    for (version, name) in [(7, "seven"), (6, "six"), (5, "five"), (4, "four"), (3, "three")] {
      let older = ArchiveService(stack: stack, appVersion: "1.1.2", schemaVersion: version)
      let olderURL = directory.appendingPathComponent("\(name).ohmymoneyarchive")
      _ = try older.exportArchive(to: olderURL)
      XCTAssertEqual(try service.openArchive(at: olderURL).manifest.schemaVersion, version)
    }
  }

  func testEncryptedArchiveRefusesTheWrongPassword() throws {
    // A thousand iterations here: the format is what is being tested, and the real
    // 600 000 would only make the suite slow.
    let service = ArchiveService(stack: stack, appVersion: "0.1.0", iterations: 1_000)
    let url = directory.appendingPathComponent("secret.ohmymoneyarchive")
    _ = try service.exportArchive(to: url, password: "correct horse")

    XCTAssertTrue(try service.isEncrypted(at: url))
    XCTAssertNoThrow(try service.openArchive(at: url, password: "correct horse"))

    XCTAssertThrowsError(try service.openArchive(at: url, password: "wrong")) { error in
      XCTAssertEqual(error as? CoreError, .invalidArchive(reason: .wrongPassword))
    }
  }

  /// The password of a new archive was asked once. The read-back check opens the archive with
  /// the very string it was written with, so a typo passed it, and the archive could never be
  /// opened with the password the owner meant. It is typed twice now, and two different
  /// strings are not taken: the owner is told and asked again.
  @MainActor
  func testANewPasswordIsTakenOnlyWhenTypedTheSameTwice() {
    var answers: [FileCommands.NewPasswordAnswer] = [
      .typed("correct horse", again: "correct hrose"),
      .typed("", again: "correct horse"),
      .typed("correct horse", again: "correct horse"),
    ]
    var mismatches = 0
    var warnings = 0
    let password = FileCommands.newPassword(
      ask: { answers.removeFirst() }, mismatch: { mismatches += 1 },
      confirmNoPassword: {
        warnings += 1
        return true
      })
    XCTAssertEqual(password, "correct horse")
    XCTAssertEqual(mismatches, 2, "a password typed differently the second time was taken")
    XCTAssertEqual(answers, [])
    XCTAssertEqual(warnings, 0)

    // Both fields empty is the «без пароля» of the File menu, after its warning.
    answers = [.typed("", again: "")]
    XCTAssertEqual(
      FileCommands.newPassword(
        ask: { answers.removeFirst() }, mismatch: { mismatches += 1 },
        confirmNoPassword: {
          warnings += 1
          return true
        }), "")
    XCTAssertEqual(warnings, 1)

    answers = [.typed("correct horse", again: "correct"), .cancelled]
    XCTAssertNil(
      FileCommands.newPassword(
        ask: { answers.removeFirst() }, mismatch: { mismatches += 1 },
        confirmNoPassword: { true }))
    XCTAssertEqual(mismatches, 3)
  }

  /// The words of the second password field and of the refusal, in both languages.
  @MainActor
  func testTheWordsOfARepeatedPasswordAreInBothLanguages() {
    let language = AppLanguage()
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      for key in [
        "archive.password.field", "archive.password.again", "archive.password.mismatch",
        "archive.password.mismatch.body",
      ] {
        XCTAssertNotEqual(language(key, table: "Settings"), key, "\(key) in \(choice.rawValue)")
      }
    }
  }

  /// «Согласованный снимок базы», the CSV files «как при Export» and «число записей совпадает»:
  /// the database inside, the manifest's counts and the CSV files describe one state. They were
  /// read one after another — the backup, then the counts, then the files — while the rate step
  /// of the pipeline writes in the background: a row landing in between failed the archive's
  /// own check, or left the manifest and the CSV files describing another state than the
  /// database beside them.
  func testTheArchiveDescribesOneStateOfADatabaseBeingWrittenTo() async throws {
    let rates = RateRepository(writer: stack.writer)
    // A rate about every millisecond: the reads of an export are milliseconds apart, and a
    // writer with no pause would make every export larger than the last.
    let writing = Task.detached {
      var written = 0
      while !Task.isCancelled {
        let day = DateOnly(
          year: 1000 + written / 336, month: written / 28 % 12 + 1, day: written % 28 + 1)
        try? rates.save([Rate(date: day, currency: .usd, rubPerUnit: Decimal(80))])
        written += 1
        try? await Task.sleep(for: .milliseconds(1))
      }
    }
    defer { writing.cancel() }
    let service = ArchiveService(stack: stack, appVersion: "0.1.0")

    for attempt in 0..<5 {
      let url = directory.appendingPathComponent("busy-\(attempt).ohmymoneyarchive")
      let opened: ArchiveOpener.OpenedArchive
      do {
        _ = try service.exportArchive(to: url)
        opened = try service.openArchive(at: url)
      } catch {
        return XCTFail("attempt \(attempt): the archive failed its own check: \(error)")
      }
      let file = directory.appendingPathComponent("inside-\(attempt).sqlite")
      try XCTUnwrap(opened.database).write(to: file)
      let inside = try DatabaseStack(url: file, schema: BundleSchemaSource(bundle: .main))
      let counts = try ExportRepository(writer: inside.writer).rowCounts()
      try inside.close()
      XCTAssertEqual(
        counts, opened.manifest.rowCounts,
        "attempt \(attempt): the database inside and the manifest describe two states")
    }
    writing.cancel()
    await writing.value
  }

  /// File → Export Archive… and Import Archive… derived the key (600 000 rounds of a pure-Swift
  /// HMAC, up to 50 000 000 for a header written elsewhere), hashed the whole database and read
  /// the archive back on the main thread: the app stood still for seconds, for a minute with a
  /// foreign header. The key is now derived — and the cipher called — away from it.
  @MainActor
  func testTheKeyOfAnArchiveIsDerivedAwayFromTheMainThread() async throws {
    let cipher = ThreadRecordingCipher()
    let service = ArchiveService(
      stack: stack, appVersion: "0.1.0", cipher: cipher, iterations: 1_000)
    let url = directory.appendingPathComponent("secret.ohmymoneyarchive")
    let written = await FileCommands.exportArchive(
      with: service, to: url, password: "correct horse", settings: [:])
    XCTAssertTrue(written)
    XCTAssertEqual(cipher.calls, ["seal", "open"], "the export seals, then reads back")

    let backups = BackupService(stack: stack, directory: directory.appendingPathComponent("b"))
    let answers = ImportAnswers()
    answers.password = .given("wrong")
    await FileCommands.importArchive(
      from: url, archives: service, backups: backups, questions: answers.questions)?.value
    XCTAssertEqual(answers.reports, ["archive.error.password"])
    XCTAssertEqual(cipher.calls, ["seal", "open", "open"])
    XCTAssertEqual(
      cipher.onMainThread, [false, false, false], "a key was derived on the main thread")
  }

  /// The rest of an import — the database of the archive written out whole, checked by the
  /// rules of its opening, the copy of the current state, the staging — is awaited from the
  /// main actor (`ArchiveImportFlow.run`) and runs away from it: `stageReplacement` is a
  /// nonisolated async function, which Swift runs on the global executor. Were it isolated to
  /// the main actor, or were nonisolated async functions to take the caller's actor, a large
  /// database would stop the app for as long as it is written and checked.
  @MainActor
  func testTheDatabaseOfAnImportIsWrittenAndCheckedAwayFromTheMainThread() async throws {
    let service = ArchiveService(stack: stack, appVersion: "0.1.0")
    let url = directory.appendingPathComponent("transfer.ohmymoneyarchive")
    _ = try service.exportArchive(to: url)
    let opened = try service.openArchive(at: url)
    let backups = BackupService(stack: stack, directory: directory.appendingPathComponent("b"))
    let schema = ThreadRecordingSchema()
    let target = directory.appendingPathComponent("finance.pending.sqlite")

    try await ArchiveImportFlow.stageReplacement(
      opened: opened, archives: service, backups: backups, target: target, schema: schema)

    XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    XCTAssertFalse(schema.onMainThread.isEmpty, "the staged database was never checked")
    XCTAssertEqual(
      Set(schema.onMainThread), [false], "the database was written and checked on the main thread")
  }

  /// Cancel in the password alert of File → Import Archive… went on with no password, and the
  /// encrypted archive answered «Неверный пароль» to an owner who had typed none. Cancel now
  /// steps back like Cancel in the open panel; an empty field is a password given, and an
  /// encrypted archive refuses it in the words of a wrong one.
  @MainActor
  func testCancellingThePasswordOfAnImportStepsBackWithoutAWord() async throws {
    let service = ArchiveService(stack: stack, appVersion: "0.1.0", iterations: 1_000)
    let url = directory.appendingPathComponent("secret.ohmymoneyarchive")
    _ = try service.exportArchive(to: url, password: "correct horse")
    let backups = BackupService(stack: stack, directory: directory.appendingPathComponent("b"))
    let answers = ImportAnswers()

    answers.password = .cancelled
    FileCommands.importArchive(
      from: url, archives: service, backups: backups, questions: answers.questions)
    XCTAssertEqual(answers.passwordsAsked, 1)
    XCTAssertEqual(answers.reports, [], "a cancelled password was reported as a wrong one")

    answers.password = .given("")
    await FileCommands.importArchive(
      from: url, archives: service, backups: backups, questions: answers.questions)?.value
    XCTAssertEqual(answers.reports, ["archive.error.password"])
  }

  /// «Сразу после экспорта архив проверяется»: one that does not read back was left at the name
  /// the owner chose, with the date of the day — the file they would carry to the other Mac
  /// weeks later, where its import is refused. It is removed, and the journal says so.
  func testAnArchiveThatDoesNotReadBackIsNotLeftBehind() async throws {
    let logs = directory.appendingPathComponent("Logs", isDirectory: true)
    Logbook.shared.open(directory: logs, threshold: .debug)
    defer { Task { Logbook.shared.close() } }
    let service = ArchiveService(
      stack: stack, appVersion: "0.1.0", cipher: UnreadableCipher(), iterations: 1_000)
    let folder = directory.appendingPathComponent("stick", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("OhMyMoney-2026-09-23.ohmymoneyarchive")

    XCTAssertThrowsError(try service.exportArchive(to: url, password: "correct horse"))

    XCTAssertFalse(
      FileManager.default.fileExists(atPath: url.path), "the archive that failed its check is there"
    )
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    let failed = await journal(contains: "archive.export.failed")
    XCTAssertTrue(failed)
    let lines = Logbook.shared.lines()
    let failure = try XCTUnwrap(lines.first { $0.contains("archive.export.failed") })
    XCTAssertTrue(failure.contains("step=verify"), failure)
    XCTAssertTrue(failure.contains("removed=yes"), failure)
  }

  func testATamperedArchiveIsRejected() throws {
    let service = ArchiveService(stack: stack, appVersion: "0.1.0")
    let url = directory.appendingPathComponent("broken.ohmymoneyarchive")
    _ = try service.exportArchive(to: url)

    var bytes = try Data(contentsOf: url)
    // Flip a byte in the middle of the container, where the data lives.
    bytes[bytes.count / 2] ^= 0xFF
    try bytes.write(to: url)

    XCTAssertThrowsError(try service.openArchive(at: url))
  }

  // MARK: Backups

  func testBackupIsWrittenAndPassesTheIntegrityCheck() async throws {
    let target = directory.appendingPathComponent("backups")
    let service = BackupService(stack: stack, directory: target)

    let copy = try await service.writeBackup()
    XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))

    let restored = try DatabaseStack(
      url: copy, schema: BundleSchemaSource(bundle: .main))
    let transactions = TransactionRepository(writer: restored.writer)
    XCTAssertEqual(try transactions.count(), 2)
  }

  /// The database is closing, so no more copies are written against it. `cancelPending()`
  /// alone only dropped the task in flight: the next write — and for the whole of the
  /// terminate-later window there is nothing stopping one — armed another copy over a
  /// database that was about to be closed.
  func testADisabledBackupServiceArmsNoMoreCopies() async throws {
    let target = directory.appendingPathComponent("backups")
    var policy = BackupService.Policy()
    policy.debounce = .milliseconds(20)
    let service = BackupService(stack: stack, directory: target, policy: policy)

    // A copy is named after the change it follows, so the two scheduled here are given
    // moments an hour apart: two copies of the same second would be one file.
    let first = Date(timeIntervalSince1970: 1_800_000_000)
    let second = first.addingTimeInterval(3600)

    // First, the control: a scheduled copy really does appear.
    await service.scheduleBackup(now: first)
    await service.waitForPendingCopy()
    let afterFirst = try await service.backups().count
    XCTAssertEqual(afterFirst, 1, "the scheduled copy was never written")

    await service.disable()
    await service.scheduleBackup(now: second)
    // A copy armed here would be waited for, and counted.
    await service.waitForPendingCopy()

    let afterDisable = try await service.backups().count
    XCTAssertEqual(afterDisable, afterFirst, "a disabled service armed another copy")
  }

  /// The database is closing, and a copy is still waiting out its debounce: it holds the last
  /// change, so it is written now — once — and nothing is armed after it.
  func testFinishingWritesTheCopyStillWaitingAndArmsNoMore() async throws {
    let target = directory.appendingPathComponent("backups")
    // The debounce of the app: far longer than the test waits.
    let service = BackupService(stack: stack, directory: target)
    let changed = Date(timeIntervalSince1970: 1_800_000_000)

    await service.scheduleBackup(now: changed)
    await service.finish()

    let names = try await service.backups().map(\.lastPathComponent)
    XCTAssertEqual(names.count, 1, "the waiting copy was dropped")
    XCTAssertEqual(
      BackupCopy.parse(names[0])?.moment,
      Calendar.current.dateInterval(of: .minute, for: changed)?.start)

    await service.scheduleBackup(now: changed.addingTimeInterval(3600))
    await service.finish()
    let after = try await service.backups().count
    XCTAssertEqual(after, 1, "a finished service armed another copy")
  }

  /// Nothing waiting, nothing written: a quit after the copy has been made adds no second one.
  func testFinishingWithNothingWaitingWritesNothing() async throws {
    let target = directory.appendingPathComponent("backups")
    var policy = BackupService.Policy()
    policy.debounce = .milliseconds(20)
    let service = BackupService(stack: stack, directory: target, policy: policy)
    await service.scheduleBackup(now: Date(timeIntervalSince1970: 1_800_000_000))
    await service.waitForPendingCopy()
    let written = try await service.backups().count
    XCTAssertEqual(written, 1, "the scheduled copy was never written")

    await service.finish()

    let after = try await service.backups().count
    XCTAssertEqual(after, 1, "the copy was written a second time at the finish")
  }

  /// Replacing every table is only allowed once a copy of the current state is on disk.
  /// Scheduling one is not enough: the automatic copy is debounced by several seconds and
  /// the application relaunches straight after an import, so the copy would never happen.
  func testImportingAnArchiveWritesTheCopyBeforeReplacingAnything() async throws {
    let service = ArchiveService(stack: stack, appVersion: "0.1.0")
    let url = directory.appendingPathComponent("transfer.ohmymoneyarchive")
    _ = try service.exportArchive(to: url)
    let opened = try service.openArchive(at: url)

    let backupDirectory = directory.appendingPathComponent("backups")
    let backups = BackupService(stack: stack, directory: backupDirectory)
    let target = directory.appendingPathComponent("finance.pending.sqlite")

    try await ArchiveImportFlow.stageReplacement(
      opened: opened, archives: service, backups: backups, target: target)

    XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    let copies = try await backups.backups()
    XCTAssertEqual(copies.count, 1, "the state before the import has to be on disk already")
    XCTAssertEqual(
      copies.first.flatMap { BackupCopy.parse($0.lastPathComponent)?.reason }, .beforeImport)
  }

  /// A database that fails its own check still has its copy written before an import: that
  /// copy is the state before the replacement, damaged or not, and refusing the import would
  /// leave the owner with the damaged database only.
  func testImportingOverADamagedDatabaseKeepsItsCopyMarked() async throws {
    let service = ArchiveService(stack: stack, appVersion: "0.1.0")
    let url = directory.appendingPathComponent("transfer.ohmymoneyarchive")
    _ = try service.exportArchive(to: url)
    let opened = try service.openArchive(at: url)
    let backups = BackupService(
      source: DamagedSource(), directory: directory.appendingPathComponent("backups"))
    let target = directory.appendingPathComponent("finance.pending.sqlite")

    try await ArchiveImportFlow.stageReplacement(
      opened: opened, archives: service, backups: backups, target: target)

    XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    let copies = try await backups.backups().map(\.lastPathComponent)
    XCTAssertEqual(copies.count, 1)
    let kept = copies.first.flatMap { BackupCopy.parse($0) }
    XCTAssertEqual(kept?.reason, .beforeImport, "\(copies)")
    XCTAssertEqual(kept?.damaged, true, "\(copies)")
  }

  /// The checks of an archive — format, digests, row counts — prove the bytes are what the
  /// other side wrote, not that this build can open them. A database it cannot open used to be
  /// staged all the same, and at the next launch it took the place of the owner's, which was
  /// deleted before anything tried to open the new one. It is refused before anything is
  /// staged — and before a copy is written for an import that is not going to happen.
  func testAnArchiveWhoseDatabaseThisBuildCannotOpenIsRefusedBeforeStaging() async throws {
    let service = ArchiveService(stack: stack, appVersion: "0.1.0")
    let url = directory.appendingPathComponent("transfer.ohmymoneyarchive")
    _ = try service.exportArchive(to: url)
    let opened = try service.openArchive(at: url)

    // A database of a newer build: every migration of ours and one more.
    let future = directory.appendingPathComponent("future.sqlite")
    try stack.backup(to: future)
    try DatabaseStack(url: future, schema: FutureSchema()).close()
    let snapshot = directory.appendingPathComponent("future-snapshot.sqlite")
    try DatabaseStack.backup(fileAt: future, to: snapshot)

    let databases: [(String, Data, ArchiveImportFlow.Refusal)] = [
      ("a newer build's database", try Data(contentsOf: snapshot), .newerSchema),
      ("not a database", Data("not a database".utf8), .databaseDamaged),
    ]
    for (name, database, refusal) in databases {
      var files = opened.files
      files[ArchivePaths.database] = database
      let foreign = ArchiveOpener.OpenedArchive(manifest: opened.manifest, files: files)
      let backups = BackupService(
        stack: stack, directory: directory.appendingPathComponent("b-\(UUID().uuidString)"))
      let target = directory.appendingPathComponent("finance.pending.sqlite")

      do {
        try await ArchiveImportFlow.stageReplacement(
          opened: foreign, archives: service, backups: backups, target: target)
        XCTFail("\(name) was staged")
      } catch {
        XCTAssertEqual(error as? ArchiveImportFlow.Refusal, refusal, name)
        XCTAssertEqual(FileCommands.messageKey(for: error), refusal.messageKey, name)
      }

      XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), name)
      let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      XCTAssertFalse(left.contains { $0.hasPrefix("finance.pending") }, "\(name): \(left)")
      let copies = try await backups.backups()
      XCTAssertEqual(copies, [], "\(name): a copy for an import that never happens")
    }
  }

  // MARK: The journal of a transfer

  /// «Бэкапы, экспорт, архив: начало, результат» and «любая перехваченная ошибка: тип».
  /// An archive that could not be written was told to the owner in an alert and to nobody
  /// else: the problem report showed an export that started and never ended.
  func testAnArchiveThatCannotBeWrittenIsInTheJournal() async throws {
    let logs = directory.appendingPathComponent("Logs", isDirectory: true)
    Logbook.shared.open(directory: logs, threshold: .debug)
    defer { Task { Logbook.shared.close() } }
    let service = ArchiveService(stack: stack, appVersion: "0.1.0")
    try stack.close()

    XCTAssertThrowsError(
      try service.exportArchive(to: directory.appendingPathComponent("closed.ohmymoneyarchive")))

    let failed = await journal(contains: "archive.export.failed")
    XCTAssertTrue(failed, "the archive that was not written is not in the journal")
    let lines = Logbook.shared.lines()
    let failure = try XCTUnwrap(lines.first { $0.contains("archive.export.failed") })
    XCTAssertTrue(failure.contains("error="), failure)
    XCTAssertTrue(failure.contains("step=snapshot"), failure)
    XCTAssertFalse(
      lines.contains { $0.contains(directory.path) }, "a path of the owner's reached the journal")
  }

  /// An empty password is the menu's «без пароля»: the archive is written in the clear. The
  /// journal said `encrypted=yes` for it all the same, asking `password != nil` where the
  /// writing asks for a password that is not empty — and a problem report repeated it.
  func testTheJournalSaysWhetherAPasswordWasReallyUsed() async throws {
    let logs = directory.appendingPathComponent("Logs", isDirectory: true)
    Logbook.shared.open(directory: logs, threshold: .debug)
    defer { Task { Logbook.shared.close() } }
    let service = ArchiveService(stack: stack, appVersion: "0.1.0", iterations: 1_000)
    let plain = directory.appendingPathComponent("plain.ohmymoneyarchive")
    let secret = directory.appendingPathComponent("secret.ohmymoneyarchive")

    _ = try service.exportArchive(to: plain, password: "")
    XCTAssertFalse(try service.isEncrypted(at: plain))
    _ = try service.exportArchive(to: secret, password: "correct horse")
    _ = try ArchiveImportFlow.open(plain, password: "", archives: service)
    _ = try ArchiveImportFlow.open(secret, password: "correct horse", archives: service)

    var lines: [String] = []
    for _ in 0..<50 {
      lines = Logbook.shared.lines()
      if lines.filter({ $0.contains("archive.import.started") }).count == 2 { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let exports = lines.filter { $0.contains("archive.export.started") }
    let imports = lines.filter { $0.contains("archive.import.started") }
    XCTAssertEqual(exports.count, 2)
    XCTAssertEqual(imports.count, 2)
    XCTAssertTrue(exports.first?.contains("encrypted=no") == true, "\(exports)")
    XCTAssertTrue(exports.last?.contains("encrypted=yes") == true, "\(exports)")
    XCTAssertTrue(imports.first?.contains("password=no") == true, "\(imports)")
    XCTAssertTrue(imports.last?.contains("password=yes") == true, "\(imports)")
  }

  /// A manifest that does not decode was one word in the journal, `manifestUnreadable`: which
  /// field was wrong — what the writer of the archive needs to hear — was swallowed. The line
  /// now names the field and the problem, never a value; the owner reads the same words.
  func testAnUnreadableManifestNamesItsFieldInTheJournal() async throws {
    let logs = directory.appendingPathComponent("Logs", isDirectory: true)
    Logbook.shared.open(directory: logs, threshold: .debug)
    defer { Task { Logbook.shared.close() } }
    let service = ArchiveService(stack: stack, appVersion: "0.1.0")
    var writer = ZipWriter()
    try writer.add(
      path: ArchivePaths.manifest,
      text: #"{"formatVersion": 1, "appVersion": "Alex 2.0", "schemaVersion": "three"}"#)
    let url = directory.appendingPathComponent("foreign.ohmymoneyarchive")
    try writer.finish().write(to: url)

    XCTAssertThrowsError(try ArchiveImportFlow.open(url, password: nil, archives: service)) {
      XCTAssertEqual(FileCommands.messageKey(for: $0), "archive.error.manifest")
    }
    let failed = await journal(contains: "archive.import.failed")
    XCTAssertTrue(failed)
    let lines = Logbook.shared.lines()
    let failure = try XCTUnwrap(lines.first { $0.contains("archive.import.failed") })
    XCTAssertTrue(failure.contains("reason=manifestUnreadable"), failure)
    XCTAssertTrue(failure.contains("field=schemaVersion"), failure)
    XCTAssertTrue(failure.contains("problem=wrongType"), failure)
    XCTAssertFalse(failure.contains("three") || failure.contains("Alex"), failure)
  }

  /// The import is the one operation that replaces the whole database, and it left no trace
  /// but its last line: no start, and a failure only in an alert. Its start, what the archive
  /// holds, and every failure with the step and the check that failed are now in the journal —
  /// never a path.
  func testAnImportIsInTheJournalFromItsStartToItsFailure() async throws {
    let logs = directory.appendingPathComponent("Logs", isDirectory: true)
    Logbook.shared.open(directory: logs, threshold: .debug)
    defer { Task { Logbook.shared.close() } }
    let service = ArchiveService(stack: stack, appVersion: "0.1.0")
    let url = directory.appendingPathComponent("transfer.ohmymoneyarchive")
    _ = try service.exportArchive(to: url)

    // An archive somebody edited: its own checks refuse it.
    var bytes = try Data(contentsOf: url)
    bytes[bytes.count / 2] ^= 0xFF
    let edited = directory.appendingPathComponent("edited.ohmymoneyarchive")
    try bytes.write(to: edited)
    XCTAssertThrowsError(try ArchiveImportFlow.open(edited, password: nil, archives: service))

    let started = await journal(contains: "archive.import.started")
    XCTAssertTrue(started, "the start of the import is not in the journal")
    let refused = await journal(contains: "archive.import.failed")
    XCTAssertTrue(refused, "the archive that did not open is not in the journal")
    var lines = Logbook.shared.lines()
    let opening = try XCTUnwrap(lines.first { $0.contains("archive.import.failed") })
    XCTAssertTrue(opening.contains("step=open"), opening)
    XCTAssertTrue(opening.contains("reason="), opening)

    // An archive that opens and says what it holds, whose database cannot be written out.
    let opened = try ArchiveImportFlow.open(url, password: nil, archives: service)
    let described = await journal(contains: "archive.import.opened")
    XCTAssertTrue(described, "what the archive holds is not in the journal")
    var files = opened.files
    files[ArchivePaths.database] = nil
    let hollow = ArchiveOpener.OpenedArchive(manifest: opened.manifest, files: files)
    let backups = BackupService(stack: stack, directory: directory.appendingPathComponent("b"))
    do {
      try await ArchiveImportFlow.stageReplacement(
        opened: hollow, archives: service, backups: backups,
        target: directory.appendingPathComponent("finance.pending.sqlite"))
      XCTFail("an archive without a database was staged")
    } catch {}

    for _ in 0..<50 {
      lines = Logbook.shared.lines()
      if lines.contains(where: { $0.contains("archive.import.failed") && $0.contains("step=write") }
      ) {
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    let staging = try XCTUnwrap(
      lines.first { $0.contains("archive.import.failed") && $0.contains("step=write") },
      "the import that failed while staging is not in the journal")
    XCTAssertTrue(staging.contains("error="), staging)
    let opens = try XCTUnwrap(lines.first { $0.contains("archive.import.opened") })
    XCTAssertTrue(opens.contains("rows="), opens)
    XCTAssertFalse(
      lines.contains { $0.contains(directory.path) }, "a path of the owner's reached the journal")
  }

  /// The words the owner reads when the database of an archive is refused, in both languages.
  @MainActor
  func testEveryRefusalOfAnArchiveDatabaseHasWordsInBothLanguages() {
    let language = AppLanguage()
    let refusals: [ArchiveImportFlow.Refusal] = [.databaseDamaged, .newerSchema]
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      for key in refusals.map(\.messageKey) {
        XCTAssertNotEqual(language(key, table: "Settings"), key, "\(key) in \(choice.rawValue)")
      }
    }
  }

  /// «Язык интерфейса, тема и включённые валюты — такие же». The currencies are inside the
  /// database; the language and the theme are not, so they travel in `settings.json` — which
  /// used to be written and never read back.
  func testTheArchiveCarriesTheThemeAndTheImportPutsItBack() async throws {
    let service = ArchiveService(stack: stack, appVersion: "0.1.0")
    let url = directory.appendingPathComponent("carried.ohmymoneyarchive")
    _ = try service.exportArchive(
      to: url, settings: ["language": "ru", "theme.scheme": "dark", "theme.accent": "teal"])
    let opened = try service.openArchive(at: url)

    let backups = BackupService(stack: stack, directory: directory.appendingPathComponent("b"))
    try await ArchiveImportFlow.stageReplacement(
      opened: opened, archives: service, backups: backups,
      target: directory.appendingPathComponent("finance.pending.sqlite"))

    let defaults = UserDefaults.standard
    XCTAssertEqual(defaults.string(forKey: "app.language"), "ru")
    XCTAssertEqual(defaults.string(forKey: AppTheme.schemeKey), "dark")
    XCTAssertEqual(defaults.string(forKey: AppTheme.accentKey), "teal")
  }

  /// The language of an archive is written the way the settings write a choice
  /// (`AppLanguage.store`): an explicit one with the language of the menus beside it, «System»
  /// without any, so the app follows the Mac it lands on.
  func testTheLanguageOfAnArchiveIsWrittenTheWayTheSettingsWriteIt() throws {
    let service = ArchiveService(stack: stack, appVersion: "0.1.0")
    let domain = try XCTUnwrap(Bundle.main.bundleIdentifier)
    let defaults = UserDefaults.standard
    func menus() -> [String]? {
      defaults.persistentDomain(forName: domain)?[AppDefaultsGuard.appleLanguagesKey] as? [String]
    }

    let russian = directory.appendingPathComponent("russian.ohmymoneyarchive")
    _ = try service.exportArchive(to: russian, settings: ["language": "ru"])
    ArchiveImportFlow.applyPortableSettings(try service.openArchive(at: russian))
    XCTAssertEqual(defaults.string(forKey: AppDefaultsGuard.languageKey), "ru")
    XCTAssertEqual(menus(), ["ru"], "the menus of the next launch stay in the Mac's language")

    let system = directory.appendingPathComponent("system.ohmymoneyarchive")
    _ = try service.exportArchive(to: system, settings: ["language": "system"])
    ArchiveImportFlow.applyPortableSettings(try service.openArchive(at: system))
    XCTAssertEqual(defaults.string(forKey: AppDefaultsGuard.languageKey), "system")
    XCTAssertNil(menus(), "«System» kept the language of the earlier choice")
  }

  /// An archive written by another build, or edited by hand, does not get to put whatever it
  /// likes into the owner's defaults: a value this build cannot name is passed over.
  func testAnUnknownSettingFromAnArchiveIsIgnored() throws {
    let service = ArchiveService(stack: stack, appVersion: "0.1.0")
    let url = directory.appendingPathComponent("strange.ohmymoneyarchive")
    _ = try service.exportArchive(
      to: url,
      settings: [
        "language": "klingon", "theme.scheme": "../../etc", "theme.accent": "neon",
        "whatever": "1",
      ])

    ArchiveImportFlow.applyPortableSettings(try service.openArchive(at: url))

    let defaults = UserDefaults.standard
    XCTAssertNil(defaults.string(forKey: "app.language"))
    XCTAssertNil(defaults.string(forKey: AppTheme.schemeKey))
    XCTAssertNil(defaults.string(forKey: AppTheme.accentKey))
    XCTAssertNil(defaults.string(forKey: "whatever"))
  }

  /// Sixty copies a minute apart inside one day, the day of the thinning: every one of them
  /// stays. The copies are named in Moscow time whatever the zone of the Mac running the test,
  /// so the count cannot drift with a midnight that falls elsewhere.
  func testRetentionKeepsEveryCopyOfToday() async throws {
    let moscow = try XCTUnwrap(TimeZone(identifier: "Europe/Moscow"))
    // 10 September 2026, 03:26:40 in Moscow: the hour after stays inside that day.
    let start = Date(timeIntervalSince1970: 1_789_000_000)

    let left = try await retain(copies: 60, from: start, in: moscow)

    XCTAssertEqual(left.count, 60)
    XCTAssertEqual(
      left.first, BackupService.fileName(at: start.addingTimeInterval(59 * 60), in: moscow))
    XCTAssertEqual(left.last, BackupService.fileName(at: start, in: moscow))
  }

  /// The same sixty across a midnight, the older day holding the first five: all of the new day
  /// stay, and of the older day only its newest copy.
  func testRetentionKeepsOnlyTheNewestCopyOfAnEarlierDay() async throws {
    let moscow = try XCTUnwrap(TimeZone(identifier: "Europe/Moscow"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = moscow
    let start = try XCTUnwrap(
      calendar.date(
        from: DateComponents(year: 2026, month: 9, day: 9, hour: 23, minute: 55)))

    let left = try await retain(copies: 60, from: start, in: moscow)

    XCTAssertEqual(left.count, 56)
    let lastOfTheOlderDay = BackupService.fileName(at: start.addingTimeInterval(4 * 60), in: moscow)
    XCTAssertTrue(lastOfTheOlderDay.hasPrefix("finance-2026-09-09T2359"), lastOfTheOlderDay)
    XCTAssertEqual(left.last, lastOfTheOlderDay, "the older day kept no copy, or not its newest")
    XCTAssertEqual(
      left.filter { $0.hasPrefix("finance-2026-09-09") }, [lastOfTheOlderDay],
      "the older day kept more than one copy")
  }

  /// Writes `count` copies a minute apart from `start`, named in `zone`, applies the retention
  /// of the thinning an hour later and returns the names left, newest first.
  private func retain(
    copies count: Int, from start: Date, in zone: TimeZone
  ) async throws
    -> [String]
  {
    let target = directory.appendingPathComponent("backups")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    for index in 0..<count {
      let name = BackupService.fileName(
        at: start.addingTimeInterval(TimeInterval(index * 60)), in: zone)
      try Data("x".utf8).write(to: target.appendingPathComponent(name))
    }

    var policy = BackupService.Policy()
    policy.calendar.timeZone = zone
    let service = BackupService(stack: stack, directory: target, policy: policy)
    try await service.applyRetention(now: start.addingTimeInterval(3_600))
    return try await service.backups().map(\.lastPathComponent)
  }
}

/// The app's cipher, noting each call and whether it came on the main thread: the key is
/// derived right before, in the same call.
private final class ThreadRecordingCipher: ArchiveCipher, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [(call: String, main: Bool)] = []

  var calls: [String] { lock.withLock { recorded.map(\.call) } }
  var onMainThread: [Bool] { lock.withLock { recorded.map(\.main) } }

  func seal(plaintext: Data, key: Data, nonce: Data) throws -> Data {
    note("seal")
    return try CryptoKitArchiveCipher().seal(plaintext: plaintext, key: key, nonce: nonce)
  }

  func open(sealed: Data, key: Data, nonce: Data) throws -> Data {
    note("open")
    return try CryptoKitArchiveCipher().open(sealed: sealed, key: key, nonce: nonce)
  }

  private func note(_ call: String) {
    let main = Thread.isMainThread
    lock.withLock { recorded.append((call, main)) }
  }
}

/// Seals as the app does and never opens again: the archive it writes does not read back, as
/// one on a stick that damaged it on the way would not.
private struct UnreadableCipher: ArchiveCipher {
  func seal(plaintext: Data, key: Data, nonce: Data) throws -> Data {
    try CryptoKitArchiveCipher().seal(plaintext: plaintext, key: key, nonce: nonce)
  }

  func open(sealed: Data, key: Data, nonce: Data) throws -> Data {
    throw CoreError.invalidArchive(reason: .wrongPassword)
  }
}

/// The app's schema, noting whether it was read on the main thread: the check of the database
/// an import stages reads it right after the database is written, in the same stretch of work.
private final class ThreadRecordingSchema: SchemaSource, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [Bool] = []

  var onMainThread: [Bool] { lock.withLock { recorded } }

  func migrations() throws -> [SchemaMigration] {
    let main = Thread.isMainThread
    lock.withLock { recorded.append(main) }
    return try BundleSchemaSource(bundle: .main).migrations()
  }
}

/// Replacing the database is staged and applied before anything opens it: doing it while
/// the file is open would race with the write-ahead log.
final class PendingReplacementTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-pending-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
  }

  override func tearDownWithError() throws {
    unsetenv("OHMYMONEY_DATA_DIR")
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  func testNothingHappensWithoutAStagedFile() {
    XCTAssertEqual(AppPaths.applyPendingReplacement(), .nothingStaged)
  }

  func testStagedFileReplacesTheDatabaseAndClearsTheJournal() throws {
    try Data("old".utf8).write(to: AppPaths.databaseURL)
    try Data("journal".utf8).write(
      to: URL(fileURLWithPath: AppPaths.databaseURL.path + "-wal"))
    try Data("new".utf8).write(to: AppPaths.pendingReplacementURL)

    XCTAssertEqual(AppPaths.applyPendingReplacement(), .replaced)

    XCTAssertEqual(try String(contentsOf: AppPaths.databaseURL, encoding: .utf8), "new")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: AppPaths.databaseURL.path + "-wal"))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: AppPaths.pendingReplacementURL.path))
  }

  func testApplyingTwiceIsHarmless() throws {
    try Data("new".utf8).write(to: AppPaths.pendingReplacementURL)
    XCTAssertEqual(AppPaths.applyPendingReplacement(), .replaced)
    XCTAssertEqual(AppPaths.applyPendingReplacement(), .nothingStaged)
  }

  /// The database in place is the only copy of the owner's data. A staged file that cannot
  /// be moved in is a reason to keep the old one, never a reason to end up with neither.
  /// A spare copy of the old database that could not be removed after a replacement is found
  /// by every later launch. By then the database in place has been opened and used, and its
  /// log holds transactions that are committed but not yet in the file: after a crash that log
  /// is the only place they are. Finding the spare copy is a reason to remove the copy, never
  /// the log beside the database in place.
  func testASpareCopyLeftBehindDoesNotCostTheLogOfTheDatabaseInPlace() throws {
    let aside = URL(fileURLWithPath: AppPaths.databaseURL.path + ".replaced")
    try Data("new, used since".utf8).write(to: AppPaths.databaseURL)
    try Data("transactions committed since".utf8).write(
      to: URL(fileURLWithPath: AppPaths.databaseURL.path + "-wal"))
    try Data("old".utf8).write(to: aside)

    XCTAssertEqual(AppPaths.applyPendingReplacement(), .nothingStaged)

    XCTAssertEqual(
      try String(
        contentsOf: URL(fileURLWithPath: AppPaths.databaseURL.path + "-wal"), encoding: .utf8),
      "transactions committed since",
      "the log of the database in place was deleted with the spare copy")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: aside.path), "the spare copy was left behind")
  }

  /// The log of the database in place goes aside with it, or the replacement does not happen:
  /// a log left standing beside the new database would be read by SQLite as its own. Here the
  /// place for it is taken by something that cannot be removed, the way a leftover of an
  /// earlier attempt can be.
  func testALogThatCannotBeSetAsideStopsTheReplacement() throws {
    let manager = FileManager.default
    let log = URL(fileURLWithPath: AppPaths.databaseURL.path + "-wal")
    try Data("live".utf8).write(to: AppPaths.databaseURL)
    try Data("the log of the live database".utf8).write(to: log)
    try Data("new".utf8).write(to: AppPaths.pendingReplacementURL)

    let leftover = URL(fileURLWithPath: AppPaths.databaseURL.path + ".replaced-wal")
    let locked = leftover.appendingPathComponent("locked", isDirectory: true)
    try manager.createDirectory(at: locked, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: locked.appendingPathComponent("file"))
    try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
    defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }

    guard case .notApplied = AppPaths.applyPendingReplacement() else {
      return XCTFail("the new database was put in place beside the log of the old one")
    }
    XCTAssertEqual(try String(contentsOf: AppPaths.databaseURL, encoding: .utf8), "live")
    XCTAssertEqual(
      try String(contentsOf: log, encoding: .utf8), "the log of the live database",
      "the live database lost its log")
    XCTAssertTrue(
      manager.fileExists(atPath: AppPaths.pendingReplacementURL.path),
      "the staged file is still there")
  }

  /// The other side of the same interruption: the old database was moved aside and the new one
  /// never arrived. What was there a moment ago goes back, log and all, and the staged file is
  /// left for the replacement to try again.
  func testAnInterruptedReplacementPutsTheOldDatabaseBack() throws {
    let aside = URL(fileURLWithPath: AppPaths.databaseURL.path + ".replaced")
    try Data("old".utf8).write(to: aside)
    try Data("the log of the old database".utf8).write(
      to: URL(fileURLWithPath: aside.path + "-wal"))
    try Data("new".utf8).write(to: AppPaths.pendingReplacementURL)

    XCTAssertEqual(AppPaths.applyPendingReplacement(), .replaced)

    XCTAssertEqual(try String(contentsOf: AppPaths.databaseURL, encoding: .utf8), "new")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: AppPaths.databaseURL.path + "-wal"),
      "the log of the database that was put back stayed beside the new one")
    XCTAssertFalse(FileManager.default.fileExists(atPath: aside.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: aside.path + "-wal"))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: AppPaths.pendingReplacementURL.path))
  }

  func testAStagedFileThatCannotBeMovedLeavesTheDatabaseAlone() throws {
    let manager = FileManager.default
    let staging = directory.appendingPathComponent("staging", isDirectory: true)
    try manager.createDirectory(at: staging, withIntermediateDirectories: true)
    let pending = staging.appendingPathComponent("finance.pending.sqlite")
    try Data("new".utf8).write(to: pending)
    try Data("live".utf8).write(to: AppPaths.databaseURL)

    // Nothing can be unlinked from a directory that is not writable, so the move fails the
    // way it would on a volume that went away halfway through.
    try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: staging.path)
    defer {
      try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
    }

    guard case .notApplied = AppPaths.replaceDatabase(at: AppPaths.databaseURL, with: pending)
    else { return XCTFail("a replacement that did not happen was reported as something else") }
    XCTAssertEqual(try String(contentsOf: AppPaths.databaseURL, encoding: .utf8), "live")
    XCTAssertTrue(manager.fileExists(atPath: pending.path), "the staged file is still there")
  }
}

/// The service must not ask the Bank of Russia for a day it already has, or for a weekend
/// the bank never published: the bank may block for a while an address that asks too often.
final class RateServiceTests: XCTestCase {
  /// Counts the requests and answers with a fixed table.
  private actor FakeFeed: RatesFetching {
    private(set) var requestedDays: [DateOnly] = []
    private let published: DateOnly

    init(published: DateOnly) {
      self.published = published
    }

    func dailyRates(on day: DateOnly) async throws -> RateSnapshot {
      requestedDays.append(day)
      // The bank answers a weekend request with the last business day, as it really does.
      return RateSnapshot(
        date: published,
        rates: [
          .usd: Rate(date: published, currency: .usd, rubPerUnit: Decimal(string: "81.43")!)
        ],
        source: .cbr)
    }

    func count() -> Int { requestedDays.count }
  }

  private func makeRepository() throws -> RateRepository {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    return RateRepository(writer: stack.writer)
  }

  func testACachedDayIsNeverRequestedAgain() async throws {
    let repository = try makeRepository()
    let friday = DateOnly(year: 2026, month: 9, day: 18)
    try repository.save([
      Rate(date: friday, currency: .usd, rubPerUnit: Decimal(string: "81.43")!)
    ])

    let feed = FakeFeed(published: friday)
    let service = RateService(repository: repository, client: feed)

    _ = await service.rate(for: .usd, on: friday)
    _ = await service.rate(for: .usd, on: friday)

    let asked = await feed.count()
    XCTAssertEqual(asked, 0)
  }

  func testAWeekendIsAskedAboutOnceAndThenLeftAlone() async throws {
    let repository = try makeRepository()
    let friday = DateOnly(year: 2026, month: 9, day: 18)
    let saturday = DateOnly(year: 2026, month: 9, day: 19)
    try repository.save([
      Rate(date: friday, currency: .usd, rubPerUnit: Decimal(string: "81.43")!)
    ])

    let feed = FakeFeed(published: friday)
    let service = RateService(repository: repository, client: feed)

    // The day is past the end of the history, so it is worth one question.
    _ = await service.rate(for: .usd, on: saturday)
    _ = await service.rate(for: .usd, on: saturday)
    _ = await service.rate(for: .usd, on: saturday)

    let asked = await feed.count()
    XCTAssertEqual(asked, 1)
  }

  func testTheRateOfTheLastBusinessDayIsUsedForTheWeekend() async throws {
    let repository = try makeRepository()
    let friday = DateOnly(year: 2026, month: 9, day: 18)
    try repository.save([
      Rate(date: friday, currency: .usd, rubPerUnit: Decimal(string: "81.43")!)
    ])

    let service = RateService(repository: repository, client: FakeFeed(published: friday))
    let rate = await service.rate(for: .usd, on: DateOnly(year: 2026, month: 9, day: 19))

    XCTAssertEqual(rate?.date, friday)
    XCTAssertEqual(rate?.rubPerUnit, Decimal(string: "81.43")!)
  }

  /// `rates.fetched_at` says when a rate was obtained, so a questioned value
  /// can be traced; `rates.csv` exports it. A rate already stored keeps its own instant.
  func testAFetchedRateCarriesTheInstantItArrived() async throws {
    let repository = try makeRepository()
    let thursday = DateOnly(year: 2026, month: 9, day: 17)
    let fetchedBefore = Date(timeIntervalSince1970: 1_789_500_000)
    try repository.save([
      Rate(
        date: thursday, currency: .usd, rubPerUnit: Decimal(string: "81.10")!,
        fetchedAt: fetchedBefore)
    ])
    let friday = DateOnly(year: 2026, month: 9, day: 18)
    let now = Date(timeIntervalSince1970: 1_789_560_000)
    let service = RateService(
      repository: repository, client: FakeFeed(published: friday), clock: FixedClock(now))

    _ = await service.rate(for: .usd, on: friday)

    let stored = try repository.allRates()
    XCTAssertEqual(stored.first { $0.date == friday }?.fetchedAt, now)
    XCTAssertEqual(stored.first { $0.date == thursday }?.fetchedAt, fetchedBefore)
  }

  func testRublesNeedNoRateAndNoRequest() async throws {
    let repository = try makeRepository()
    let feed = FakeFeed(published: DateOnly(year: 2026, month: 9, day: 18))
    let service = RateService(repository: repository, client: feed)

    let rate = await service.rate(for: .rub, on: DateOnly(year: 2026, month: 9, day: 18))
    XCTAssertNil(rate)
    let asked = await feed.count()
    XCTAssertEqual(asked, 0)
  }
}

/// The dictionaries carry every field they have, and a round trip through the database
/// keeps them: aliases, the relation of a person, the kind and the default flag
/// of a payment method, the dates, budget and yearly repeat of an event.
final class ReferenceBookTests: XCTestCase {
  private var references: ReferenceRepository!

  override func setUpWithError() throws {
    try super.setUpWithError()
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
  }

  func testAPersonKeepsRelationAndAliases() throws {
    let person = Person(
      name: "Alex", relation: .partner, aliases: ["Алекс", "Sasha"])
    try references.save(person)

    let loaded = try XCTUnwrap(try references.people().first)
    XCTAssertEqual(loaded.relation, .partner)
    XCTAssertEqual(loaded.aliases, ["Алекс", "Sasha"])
  }

  func testAPaymentMethodKeepsKindCurrencyAndTheDefaultFlag() throws {
    let method = PaymentMethod(
      name: "Travel card", kind: .card, currency: CurrencyCode("EUR"),
      aliases: ["евровая"], isDefault: true)
    try references.save(method)

    let loaded = try XCTUnwrap(try references.paymentMethods().first)
    XCTAssertEqual(loaded.kind, .card)
    XCTAssertEqual(loaded.currency, CurrencyCode("EUR"))
    XCTAssertEqual(loaded.aliases, ["евровая"])
    XCTAssertTrue(loaded.isDefault)
  }

  func testAnEventKeepsItsDatesBudgetAndRepeat() throws {
    let event = Event(
      name: "New Year", kind: .newYear,
      startDate: DateOnly(year: 2026, month: 12, day: 25),
      endDate: DateOnly(year: 2027, month: 1, day: 8),
      budgetE4: AmountE4(whole: 60_000),
      recurringYearly: true)
    try references.save(event)

    let loaded = try XCTUnwrap(try references.events().first)
    XCTAssertEqual(loaded.kind, .newYear)
    XCTAssertEqual(loaded.startDate, DateOnly(year: 2026, month: 12, day: 25))
    XCTAssertEqual(loaded.endDate, DateOnly(year: 2027, month: 1, day: 8))
    XCTAssertEqual(loaded.budgetE4, AmountE4(whole: 60_000))
    XCTAssertTrue(loaded.recurringYearly)
    XCTAssertTrue(loaded.covers(DateOnly(year: 2027, month: 1, day: 1)))
  }

  func testArchivingKeepsTheRowOutOfTheListButNotOutOfTheDatabase() throws {
    var place = Place(name: "Corner Cafe")
    try references.save(place)
    place.archived = true
    try references.save(place)

    XCTAssertTrue(try references.places().isEmpty)
    XCTAssertEqual(try references.places(includeArchived: true).count, 1)
  }
}

/// A yearly event is recreated for the next year with the same series, so the same
/// birthday or New Year can be compared across years.
///
/// «Passed» is judged on the day the environment is told it is: on the wall clock these tests
/// turned red on 1 January 2027, when the copy made for 2026 had itself passed.
@MainActor
final class YearlyEventTests: XCTestCase {
  private var environment: AppEnvironment!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func tearDown() async throws {
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  /// An environment on a database of its own, whose today is `today` whatever the date.
  private func makeEnvironment(today: DateOnly) async throws -> ReferenceRepository {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-events-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)

    let environment = AppEnvironment()
    let noon = environment.calendar.startOfDay(today).addingTimeInterval(12 * 3600)
    environment.now = { noon }
    self.environment = environment
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    XCTAssertEqual(environment.today, today)
    return try XCTUnwrap(environment.references)
  }

  private func years(of name: String, in references: ReferenceRepository) throws -> [Int] {
    try references.events(includeArchived: true)
      .filter { $0.name == name }
      .map(\.startDate.year)
      .sorted()
  }

  func testAPassedYearlyEventIsRecreatedForTheNextYear() async throws {
    let references = try await makeEnvironment(today: DateOnly(year: 2026, month: 9, day: 18))

    let lastYear = Event(
      name: "Birthday", kind: .birthday,
      startDate: DateOnly(year: 2025, month: 5, day: 10),
      endDate: DateOnly(year: 2025, month: 5, day: 12),
      budgetE4: AmountE4(whole: 15_000),
      recurringYearly: true)
    try references.save(lastYear)

    environment.rolloverYearlyEvents()

    let events = try references.events(includeArchived: true)
      .filter { $0.name == "Birthday" }
    // May 2026 has passed by 18 September too, so the series goes on to the coming May.
    XCTAssertEqual(events.map(\.startDate.year).sorted(), [2025, 2026, 2027])

    let next = try XCTUnwrap(events.first { $0.startDate.year == 2026 })
    XCTAssertEqual(next.startDate, DateOnly(year: 2026, month: 5, day: 10))
    // The event keeps its length: three days stay three days.
    XCTAssertEqual(next.endDate, DateOnly(year: 2026, month: 5, day: 12))
    XCTAssertEqual(next.budgetE4, AmountE4(whole: 15_000))
    XCTAssertTrue(next.recurringYearly)

    // Both belong to one series, which is what the comparison across years needs.
    let series = Set(events.map { $0.seriesId ?? $0.id })
    XCTAssertEqual(series.count, 1)
  }

  func testRunningTwiceDoesNotCreateTheEventTwice() async throws {
    let references = try await makeEnvironment(today: DateOnly(year: 2026, month: 9, day: 18))

    try references.save(
      Event(
        name: "New Year", kind: .newYear,
        startDate: DateOnly(year: 2025, month: 12, day: 31),
        endDate: DateOnly(year: 2025, month: 12, day: 31),
        recurringYearly: true))

    environment.rolloverYearlyEvents()
    environment.rolloverYearlyEvents()

    XCTAssertEqual(try years(of: "New Year", in: references), [2025, 2026])
  }

  /// The same runs in January 2027: the copy made for 2026-12-31 has passed by then, so the
  /// rollover goes on to 2027 — and the runs after it make nothing, because 2027-12-31 is still
  /// ahead.
  func testRolloverIsJudgedOnTheDayTheEnvironmentIsTold() async throws {
    let references = try await makeEnvironment(today: DateOnly(year: 2027, month: 1, day: 10))

    try references.save(
      Event(
        name: "New Year", kind: .newYear,
        startDate: DateOnly(year: 2025, month: 12, day: 31),
        endDate: DateOnly(year: 2025, month: 12, day: 31),
        recurringYearly: true))

    environment.rolloverYearlyEvents()
    environment.rolloverYearlyEvents()
    environment.rolloverYearlyEvents()

    XCTAssertEqual(try years(of: "New Year", in: references), [2025, 2026, 2027])
  }

  /// A yearly event that ended years ago — entered for the history, or brought by an import —
  /// reaches this year in one launch. The rollover read the events once, so the copy it
  /// made, passed as well, waited for the next launch to be rolled on: one year per launch.
  func testAnEventYearsAgoReachesTheComingOneInOneLaunch() async throws {
    let references = try await makeEnvironment(today: DateOnly(year: 2026, month: 9, day: 18))
    let today = environment.today

    try references.save(
      Event(
        name: "Anniversary", kind: .other,
        startDate: DateOnly(year: today.year - 3, month: 1, day: 10),
        endDate: DateOnly(year: today.year - 3, month: 1, day: 12),
        recurringYearly: true))

    environment.rolloverYearlyEvents()

    let events = try references.events(includeArchived: true).filter { $0.name == "Anniversary" }
    XCTAssertTrue(
      events.contains { $0.endDate >= today },
      "the series has no occurrence that has not passed yet: "
        + "\(events.map(\.startDate.year).sorted())")
    // Every year in between is there once, as launches in each of those years would have
    // left it, and all of them are one series.
    let years = events.map(\.startDate.year).sorted()
    XCTAssertEqual(years, Array(Set(years)).sorted(), "a year was made twice")
    XCTAssertEqual(years.first, today.year - 3)
    XCTAssertEqual(years, Array(years.first!...years.last!))
    XCTAssertEqual(Set(events.map { $0.seriesId ?? $0.id }).count, 1)

    // And the next launch finds nothing more to do.
    environment.rolloverYearlyEvents()
    XCTAssertEqual(
      try references.events(includeArchived: true).filter { $0.name == "Anniversary" }.count,
      events.count)
  }

  func testAnEventThatDoesNotRepeatIsLeftAlone() async throws {
    let references = try await makeEnvironment(today: DateOnly(year: 2026, month: 9, day: 18))

    try references.save(
      Event(
        name: "Moving", kind: .other,
        startDate: DateOnly(year: 2025, month: 3, day: 1),
        endDate: DateOnly(year: 2025, month: 3, day: 5)))

    environment.rolloverYearlyEvents()

    XCTAssertEqual(try years(of: "Moving", in: references), [2025])
  }
}

/// The answers a test gives to the questions of an import, and what the import told it.
@MainActor
final class ImportAnswers {
  var confirms = false
  var password: ArchiveImportFlow.PasswordAnswer = .cancelled
  private(set) var confirmations = 0
  private(set) var passwordsAsked = 0
  private(set) var reports: [String] = []

  var questions: ArchiveImportFlow.Questions {
    ArchiveImportFlow.Questions(
      confirm: { [self] in
        confirmations += 1
        return confirms
      },
      password: { [self] in
        passwordsAsked += 1
        return password
      },
      report: { [self] in reports.append($0) },
      relaunch: { XCTFail("the test host was asked to relaunch") })
  }
}

/// A double click on an archive in Finder: «двойной щелчок открывает импорт».
/// When the double click is what launches the app, Finder hands the file over while the launch
/// still waits on the journal — before the database is open.
@MainActor
final class ArchiveFromFinderTests: XCTestCase {
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-finder-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
  }

  override func tearDown() async throws {
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private var archive: URL {
    directory.appendingPathComponent("OhMyMoney-2026-09-23.ohmymoneyarchive")
  }

  /// The archive used to be dropped there and then: no confirmation, no alert, no line in the
  /// journal — the app opened on the old data as if nothing had been double-clicked.
  func testAnArchiveHandedOverBeforeTheDatabaseOpensIsTakenUpOnceItHas() async throws {
    let answers = ImportAnswers()
    let environment = AppEnvironment()

    ArchiveImportFlow.begin(with: archive, environment: environment, questions: answers.questions)
    XCTAssertEqual(environment.pendingArchiveImport, archive, "the archive was dropped")
    XCTAssertEqual(answers.confirmations, 0)
    XCTAssertEqual(answers.reports, [])

    // Nothing is taken up while the database is still opening.
    ArchiveImportFlow.resumeDeferred(in: environment, questions: answers.questions)
    XCTAssertEqual(answers.confirmations, 0)

    await environment.start()
    XCTAssertEqual(environment.state, .ready)
    ArchiveImportFlow.resumeDeferred(in: environment, questions: answers.questions)
    XCTAssertEqual(
      answers.confirmations, 1, "the archive was not taken up once the database opened")
    XCTAssertNil(environment.pendingArchiveImport)
    XCTAssertEqual(answers.reports, [], "the owner said no, and nothing more is said")

    ArchiveImportFlow.resumeDeferred(in: environment, questions: answers.questions)
    XCTAssertEqual(answers.confirmations, 1, "the archive was taken up twice")
    await environment.close()
  }

  /// A database that did not open cannot be replaced by an archive (the import needs it open):
  /// the owner is told so, in words, instead of nothing happening.
  func testAnArchiveHandedOverWhenTheDatabaseDidNotOpenIsAnsweredInWords() async throws {
    let answers = ImportAnswers()
    try AppPaths.ensureDirectories()
    try Data("not a database".utf8).write(to: AppPaths.databaseURL)
    let environment = AppEnvironment()

    ArchiveImportFlow.begin(with: archive, environment: environment, questions: answers.questions)
    await environment.start()
    guard case .failed = environment.state else {
      return XCTFail("a file that is not a database opened: \(environment.state)")
    }
    ArchiveImportFlow.resumeDeferred(in: environment, questions: answers.questions)
    XCTAssertEqual(answers.confirmations, 0)
    XCTAssertEqual(answers.reports, ["archive.import.unavailable"])
    XCTAssertNil(environment.pendingArchiveImport)

    // And a double click while the database stays shut.
    ArchiveImportFlow.begin(with: archive, environment: environment, questions: answers.questions)
    XCTAssertEqual(answers.reports, ["archive.import.unavailable", "archive.import.unavailable"])
    XCTAssertNil(environment.pendingArchiveImport)
    await environment.close()
  }

  func testTheWordsOfAnImportThatCannotRunNowAreInBothLanguages() {
    let language = AppLanguage()
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      let words = language("archive.import.unavailable", table: "Settings")
      XCTAssertNotEqual(words, "archive.import.unavailable", choice.rawValue)
    }
  }
}
