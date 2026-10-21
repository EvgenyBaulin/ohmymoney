import AppCore
import AppDatabase
import Synchronization
import XCTest

@testable import OhMyMoney

/// «Собирается один zip… `README.txt` внутри архива: что это за файл, что в нём есть и чего в
/// нём нет», and: личных данных в нём нет.
final class ProblemReportTests: XCTestCase {
  private var directory: URL!

  private let secrets = [
    "Coffee and a bun at the corner", "Александра", "Пятёрочка на Невском", "Продукты",
    "12 345,67",
  ]

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-report-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  private func report() throws -> ProblemReport {
    let journal = directory.appendingPathComponent("ohmymoney.log")
    try """
    2026-09-20T09:28:43.456+03:00 info app app.started "the application started" app=1.0.0
    2026-09-20T09:28:44.000+03:00 error ui dependencies.missing "a view was shown without the app's dependencies" reader=OhMyMoney/TransactionsRootView.swift
    """.write(to: journal, atomically: true, encoding: .utf8)

    return ProblemReport(
      appVersion: "1.0.0", buildVersion: "17", systemVersion: "macOS 26.0",
      distribution: "direct", language: "ru", schemaVersion: 2, databaseBytes: 1_258_291,
      integrityCheckPassed: true,
      rowCounts: ["transactions": 412, "transaction_parts": 517, "people": 3],
      firstOperation: "2026-03-01", lastOperation: "2026-09-20",
      settings: [
        "language": "ru", "theme.scheme": "dark", "theme.accent": "teal",
        "currencies": "RUB,USD", "events.automatic": "1",
      ],
      lastRun: ["data": 180, "forecast": 24, "rates": 900],
      standIns: ["OhMyMoney/TransactionsRootView.swift"],
      lastSessionWasInterrupted: true, journals: [journal])
  }

  func testTheArchiveHoldsEverythingAReportPromises() throws {
    let data = try report().zipped()
    let paths = try ZipReader.entries(in: data).map(\.path).sorted()

    XCTAssertEqual(
      paths,
      [
        "README.txt", "database.txt", "logs/ohmymoney.log", "pipeline.txt", "settings.txt",
        "versions.txt",
      ])
  }

  /// The README says what the file is, what is in it and what is not.
  func testTheReadmeSaysWhatIsInsideAndWhatIsNot() throws {
    let files = try ZipReader.files(in: try report().zipped())
    let readme = try XCTUnwrap(String(data: try XCTUnwrap(files["README.txt"]), encoding: .utf8))

    XCTAssertTrue(readme.contains("Что здесь есть"))
    XCTAssertTrue(readme.contains("Чего здесь нет"))
    XCTAssertTrue(readme.contains("logs/"))
    XCTAssertTrue(readme.contains("database.txt"))
  }

  /// «Все тексты — через String Catalog»: the README was Russian whatever the language of the
  /// interface, so a report gathered in English said what it holds in a language its reader
  /// may not have. It follows the language the report records.
  func testTheReadmeIsInTheLanguageOfTheInterface() throws {
    var english = try report()
    english.language = "en"
    let files = try ZipReader.files(in: try english.zipped())
    let readme = try XCTUnwrap(String(data: try XCTUnwrap(files["README.txt"]), encoding: .utf8))

    XCTAssertTrue(readme.contains("What is here"), readme)
    XCTAssertTrue(readme.contains("What is not here"), readme)
    XCTAssertTrue(readme.contains("the last 7 days"), readme)
    XCTAssertNil(
      readme.range(of: "\\p{Cyrillic}", options: .regularExpression),
      "the English README has Russian in it: \(readme)")
    XCTAssertTrue(readme.contains("logs/"))
    XCTAssertTrue(readme.contains("database.txt"))

    // And the Russian one counts its days in Russian.
    let russian = try ZipReader.files(in: try report().zipped())
    let text = try XCTUnwrap(String(data: try XCTUnwrap(russian["README.txt"]), encoding: .utf8))
    XCTAssertTrue(text.contains("за последние 7 дней"), text)
  }

  /// The whole file, every entry of it, through the same filter the journal is held to.
  func testNothingOfTheOwnersIsAnywhereInTheArchive() throws {
    for entry in try ZipReader.entries(in: try report().zipped()) {
      let text = String(data: entry.data, encoding: .utf8) ?? ""
      XCTAssertEqual(
        LogPrivacy.offences(in: text, forbidding: secrets), [],
        "\(entry.path) holds what a report must never hold")
    }
  }

  /// The list shown before the file is saved is the list of what goes in it.
  func testTheContentsAreCountedBeforeTheFileIsWritten() throws {
    let contents = try report().contents

    XCTAssertEqual(contents.journalFiles, 1)
    XCTAssertEqual(contents.journalDays, 7)
    XCTAssertEqual(contents.tables, 3)
    XCTAssertEqual(contents.rows, 932)
    XCTAssertEqual(contents.settings, 5)
    XCTAssertFalse(contents.crashReport)
    XCTAssertEqual(contents.integrityCheckPassed, true)
  }

  /// The number of days the list and the README name is the window the journals are picked
  /// by, held to the files themselves rather than to the constant: a rotated file written to
  /// half a day inside it goes in, one half a day outside it stays out.
  func testTheDaysTheListNamesAreTheDaysTheJournalsAreChosenBy() throws {
    let days = try report().contents.journalDays
    XCTAssertEqual(days, 7, "the report takes the journals of the last 7 days")
    let now = Date()
    let files = ["ohmymoney.log", "ohmymoney.1.log", "ohmymoney.2.log"].map {
      directory.appendingPathComponent($0)
    }
    let ages: [TimeInterval] = [
      // The live file is in however old.
      10 * TimeInterval(days) * 86_400,
      TimeInterval(days) * 86_400 - 43_200,
      TimeInterval(days) * 86_400 + 43_200,
    ]
    for (file, age) in zip(files, ages) {
      try "2026-01-01T09:00:00.000+03:00 info app app.started \"old\"\n"
        .write(to: file, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: file.path)
    }

    XCTAssertEqual(
      ProblemReport.journals(files, now: now).map(\.lastPathComponent),
      ["ohmymoney.log", "ohmymoney.1.log"],
      "the journals picked are not those of the last \(days) days the list names")
  }

  /// «Переносимые настройки» of the README means the theme too: it travels in the same
  /// dictionary the archive carries, so the report shows what the owner is on.
  func testTheThemeIsInTheSettingsOfTheReport() throws {
    let files = try ZipReader.files(in: try report().zipped())
    let settings = try XCTUnwrap(
      String(data: try XCTUnwrap(files["settings.txt"]), encoding: .utf8))

    XCTAssertTrue(settings.contains("theme.scheme dark"), settings)
    XCTAssertTrue(settings.contains("theme.accent teal"), settings)

    let readme = try XCTUnwrap(String(data: try XCTUnwrap(files["README.txt"]), encoding: .utf8))
    XCTAssertTrue(readme.contains("тема"), readme)
  }

  /// «Журналы за последние 7 дней». The rotation keeps five files of two megabytes, and a
  /// lightly used app fills them over months: a rotated file nobody has written to for ten
  /// days stays out, and the list and the README then say something true. The live file is
  /// always in.
  @MainActor
  func testOnlyTheJournalsOfTheLastSevenDaysAreGathered() async throws {
    let logs = directory.appendingPathComponent("Logs", isDirectory: true)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let now = Date()
    let rotated = [
      ("ohmymoney.1.log", now.addingTimeInterval(-3 * 86_400)),
      ("ohmymoney.2.log", now.addingTimeInterval(-10 * 86_400)),
    ]
    for (name, modified) in rotated {
      let url = logs.appendingPathComponent(name)
      try "2026-01-01T09:00:00.000+03:00 info app app.started \"old\"\n"
        .write(to: url, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }
    Logbook.shared.open(directory: logs, threshold: .debug)
    defer { Logbook.shared.close() }
    // The live file too was last written long ago: it is the one being written now, and in.
    try FileManager.default.setAttributes(
      [.modificationDate: now.addingTimeInterval(-30 * 86_400)],
      ofItemAtPath: logs.appendingPathComponent("ohmymoney.log").path)

    let report = await ProblemReportService.gather(
      environment: AppEnvironment(), compute: ComputeStore(calendar: .utc))

    XCTAssertEqual(
      report.journals.map(\.lastPathComponent), ["ohmymoney.log", "ohmymoney.1.log"],
      "a journal older than a week went into the report")
    XCTAssertEqual(report.contents.journalFiles, 2)
    let paths = try ZipReader.entries(in: report.zipped()).map(\.path).filter {
      $0.hasPrefix("logs/")
    }
    XCTAssertEqual(paths.sorted(), ["logs/ohmymoney.1.log", "logs/ohmymoney.log"])
  }

  /// A database that did not open — the likeliest reason to gather a report at all — was
  /// never checked, and the report must not say the check failed: that sends a reader after
  /// a corruption nobody tested for.
  @MainActor
  func testAnIntegrityCheckThatNeverRanIsNotReportedAsFailed() async throws {
    let report = await ProblemReportService.gather(
      environment: AppEnvironment(), compute: ComputeStore(calendar: .utc))

    let files = try ZipReader.files(in: report.zipped())
    let database = try XCTUnwrap(
      String(data: try XCTUnwrap(files["database.txt"]), encoding: .utf8))
    XCTAssertTrue(database.contains("integrityCheck not-run"), database)
    XCTAssertFalse(database.contains("integrityCheck failed"), database)
    // And the list shown before saving says the same (`report.contents.integrity.notRun`).
    XCTAssertNil(report.contents.integrityCheckPassed)
  }

  /// «Результат `PRAGMA integrity_check`»: the list shown before saving said «Проверка
  /// целостности базы» whether the check passed or failed, so the owner learned the result
  /// only by opening the zip. Each outcome has a line of its own, in both languages.
  @MainActor
  func testTheListSaysWhetherTheIntegrityCheckPassed() throws {
    var contents = try report().contents
    var keys: [String] = []
    for outcome in [true, false, nil] as [Bool?] {
      contents.integrityCheckPassed = outcome
      keys.append(contents.integrityKey)
    }

    XCTAssertEqual(Set(keys).count, 3, "passed, failed and not run read the same: \(keys)")
    let language = AppLanguage()
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      for key in keys {
        XCTAssertNotEqual(
          language(key, table: "Settings"), key, "\(key) is missing in \(choice.rawValue)")
      }
    }
  }

  /// A report that could not be saved said so with the name of the error's type — «CocoaError»
  /// under the button. The owner reads words from the catalog in the language of the
  /// interface; the type goes to the journal.
  @MainActor
  func testAReportThatCouldNotBeSavedSaysSoInWords() throws {
    let nowhere = directory.appendingPathComponent("gone/OhMyMoney-report.zip")
    let language = AppLanguage()
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      let said = try XCTUnwrap(ProblemReportService.save(report(), to: nowhere, language: language))

      XCTAssertEqual(said, language("report.saveFailed", table: "Settings"), "\(choice)")
      XCTAssertNotEqual(said, "report.saveFailed", "\(choice): no text in the catalog")
      XCTAssertNil(said.range(of: "Error"), "\(choice): the type of the error is shown: \(said)")
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: nowhere.path))

    let somewhere = directory.appendingPathComponent("OhMyMoney-report.zip")
    XCTAssertNil(ProblemReportService.save(try report(), to: somewhere, language: language))
    XCTAssertTrue(FileManager.default.fileExists(atPath: somewhere.path))
  }

  /// «Версии: приложение, сборка, macOS, схема базы, версии зависимостей». A failure inside
  /// the storage or the updater has to be matched to the version it happened in: GRDB and
  /// SQLite are in every build, Sparkle in the one that updates itself.
  @MainActor
  func testTheVersionsNameTheDependencies() async throws {
    let report = await ProblemReportService.gather(
      environment: AppEnvironment(), compute: ComputeStore(calendar: .utc))

    let files = try ZipReader.files(in: report.zipped())
    let versions = try XCTUnwrap(
      String(data: try XCTUnwrap(files["versions.txt"]), encoding: .utf8))
    let lines = versions.split(separator: "\n").map(String.init)
    XCTAssertTrue(lines.contains { $0.hasPrefix("grdb 7.") }, versions)
    XCTAssertTrue(lines.contains("grdb \(StorageVersions.grdb)"), versions)
    XCTAssertTrue(lines.contains { $0.hasPrefix("sqlite 3.") }, versions)
    #if canImport(Sparkle) && !APPSTORE
      XCTAssertTrue(lines.contains { $0.hasPrefix("sparkle 2.") }, versions)
    #endif
  }

  /// «Настройки без личных данных: язык, валюты, пороги, флаги». The report used to
  /// carry what the archive carries — language, theme, currencies — and not one threshold or
  /// switch the numbers are computed with: «events attach themselves to my operations» could
  /// not be told from the file. The captions of «для кого» are the owner's own words and stay
  /// out.
  @MainActor
  func testTheSettingsCarryTheThresholdsAndTheSwitchesAndNoCaption() async throws {
    let before = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    defer {
      if let before {
        setenv("OHMYMONEY_DATA_DIR", before, 1)
      } else {
        unsetenv("OHMYMONEY_DATA_DIR")
      }
    }
    let environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    XCTAssertEqual(environment.state, .ready)
    let settings = try XCTUnwrap(environment.settings)
    XCTAssertTrue(environment.setAssignsEventAutomatically(true))
    try settings.set(PlanningSettings.reconcileEveryDaysKey, to: "21")
    try settings.set(AnalyticsSettings.anomalySensitivityKey, to: AnomalySensitivity.high.rawValue)
    try settings.set(PlanningSettings.dismissedRemindersKey, to: "a\nb")
    environment.setLabel("Александра", for: .partner)

    let report = await ProblemReportService.gather(
      environment: environment, compute: ComputeStore(calendar: .utc))
    await environment.close()

    XCTAssertEqual(report.settings["events.automatic"], "1")
    XCTAssertEqual(report.settings[PlanningSettings.reconcileEveryDaysKey], "21")
    XCTAssertEqual(report.settings[PlanningSettings.savingsTargetKey], "1000", "a default")
    XCTAssertEqual(report.settings[PlanningSettings.reserveGoalPlanKey], "1", "a default")
    XCTAssertEqual(report.settings[AnalyticsSettings.anomalySensitivityKey], "high")
    XCTAssertNotNil(
      report.settings[AnalyticsSettings.cashbackCategoryKey].flatMap(UUID.init(uuidString:)),
      "the id of the cashback category the first start chose")
    XCTAssertEqual(report.settings["reminders.dismissed.count"], "2")
    XCTAssertNil(report.settings[PlanningSettings.dismissedRemindersKey])
    let files = try ZipReader.files(in: report.zipped())
    let text = try XCTUnwrap(String(data: try XCTUnwrap(files["settings.txt"]), encoding: .utf8))
    XCTAssertTrue(text.contains("events.automatic 1"), text)
    XCTAssertEqual(LogPrivacy.offences(in: text, forbidding: ["Александра"]), [], text)
  }

  /// The settings of the accounts go in as values — the default currency, how far the setup
  /// has come, the category of the fees by its id — and so does how many limits the planning
  /// shows. The operations the owner said do not pay a due date are ids of operations and of
  /// payments: only their count goes in.
  @MainActor
  func testTheSettingsOfTheAccountsGoInAndTheRejectedMatchesAsACount() async throws {
    let before = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    defer {
      if let before {
        setenv("OHMYMONEY_DATA_DIR", before, 1)
      } else {
        unsetenv("OHMYMONEY_DATA_DIR")
      }
    }
    let environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    XCTAssertEqual(environment.state, .ready)
    let settings = try XCTUnwrap(environment.settings)
    let fees = UUID()
    let operation = UUID().uuidString.lowercased()
    let payment = UUID().uuidString.lowercased()
    try settings.set(AccountSettings.defaultCurrencyKey, to: "KZT")
    try settings.set(AccountSettings.setupKey, to: "later")
    try settings.set(AccountSettings.transferFeeCategoryKey, to: fees.uuidString)
    try settings.set(PlanningSettings.limitsTopNKey, to: "all")
    try settings.set(
      PlanningSettings.scheduledMatchRejectionsKey,
      to: "\(operation):\(payment):2026-09-01\nop-2:\(payment):2026-10-01")

    let report = await ProblemReportService.gather(
      environment: environment, compute: ComputeStore(calendar: .utc))
    await environment.close()

    XCTAssertEqual(report.settings[AccountSettings.defaultCurrencyKey], "KZT")
    XCTAssertEqual(report.settings[AccountSettings.setupKey], "later")
    XCTAssertEqual(report.settings[AccountSettings.transferFeeCategoryKey], fees.uuidString)
    XCTAssertEqual(report.settings[PlanningSettings.limitsTopNKey], "all")
    XCTAssertEqual(report.settings["planning.scheduledMatchRejections.count"], "2")
    XCTAssertNil(report.settings[PlanningSettings.scheduledMatchRejectionsKey])
    let files = try ZipReader.files(in: report.zipped())
    let text = try XCTUnwrap(String(data: try XCTUnwrap(files["settings.txt"]), encoding: .utf8))
    XCTAssertFalse(text.contains(operation), text)
    XCTAssertFalse(text.contains(payment), text)
  }

  /// Nothing set: the defaults are what the report says, and a setup still due says nothing.
  @MainActor
  func testTheSettingsOfTheAccountsHaveTheirDefaults() async throws {
    let before = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    defer {
      if let before {
        setenv("OHMYMONEY_DATA_DIR", before, 1)
      } else {
        unsetenv("OHMYMONEY_DATA_DIR")
      }
    }
    let environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    let report = await ProblemReportService.gather(
      environment: environment, compute: ComputeStore(calendar: .utc))
    await environment.close()

    XCTAssertEqual(report.settings[AccountSettings.defaultCurrencyKey], "RUB")
    XCTAssertNil(report.settings[AccountSettings.setupKey])
    XCTAssertNil(report.settings[AccountSettings.transferFeeCategoryKey])
    XCTAssertEqual(report.settings[PlanningSettings.limitsTopNKey], "5")
    XCTAssertEqual(report.settings["planning.scheduledMatchRejections.count"], "0")
  }

  /// How goal money in another currency is valued goes in as its value; the counts whose
  /// difference the owner called real and the answers about a count remembered are ids of
  /// reconciliations and counts: only how many of each.
  @MainActor
  func testTheNewPlanningKeys() async throws {
    let before = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    defer {
      if let before {
        setenv("OHMYMONEY_DATA_DIR", before, 1)
      } else {
        unsetenv("OHMYMONEY_DATA_DIR")
      }
    }
    let environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    XCTAssertEqual(environment.state, .ready)
    let settings = try XCTUnwrap(environment.settings)
    let kept = [UUID(), UUID(), UUID()]
    let answered = [UUID(), UUID()]
    try settings.set(
      PlanningSettings.firstCountKeptKey, to: kept.map(\.uuidString).joined(separator: "\n"))
    try settings.set(
      PlanningSettings.beforeCountAnswersKey,
      to: "\(answered[0].uuidString) before\n\(answered[1].uuidString) after")

    let report = await ProblemReportService.gather(
      environment: environment, compute: ComputeStore(calendar: .utc))

    XCTAssertEqual(report.settings[PlanningSettings.goalSavingsValuationKey], "today")
    XCTAssertEqual(report.settings["reconcile.firstCountKept.count"], "3")
    XCTAssertEqual(report.settings["reconcile.beforeCountAnswers.count"], "2")
    XCTAssertNil(report.settings[PlanningSettings.firstCountKeptKey])
    XCTAssertNil(report.settings[PlanningSettings.beforeCountAnswersKey])
    let files = try ZipReader.files(in: report.zipped())
    let text = try XCTUnwrap(String(data: try XCTUnwrap(files["settings.txt"]), encoding: .utf8))
    for id in kept + answered {
      XCTAssertFalse(text.contains(id.uuidString), text)
      XCTAssertFalse(text.contains(id.uuidString.lowercased()), text)
    }

    // Valued at the rates of the deposits, the setting says so; nothing kept, the counts are 0.
    try settings.set(PlanningSettings.goalSavingsValuationKey, to: "deposits")
    try settings.set(PlanningSettings.firstCountKeptKey, to: "")
    let second = await ProblemReportService.gather(
      environment: environment, compute: ComputeStore(calendar: .utc))
    await environment.close()
    XCTAssertEqual(second.settings[PlanningSettings.goalSavingsValuationKey], "deposits")
    XCTAssertEqual(second.settings["reconcile.firstCountKept.count"], "0")
  }

  /// The list said «Файлов журнала: 2» and the zip held one: a journal that could not be read
  /// when the file was saved — rolled away since the list was gathered, or taken from the
  /// app's reach — was skipped without a word. It leaves a note in its place instead.
  func testAJournalThatCannotBeReadLeavesANoteInItsPlace() throws {
    var report = try report()
    report.journals.append(directory.appendingPathComponent("ohmymoney.1.log"))

    let entries = try ZipReader.entries(in: report.zipped())
    let logs = entries.map(\.path).filter { $0.hasPrefix("logs/") }.sorted()

    XCTAssertEqual(logs.count, report.contents.journalFiles, "the list and the file disagree")
    XCTAssertEqual(logs, ["logs/ohmymoney.1.log.unreadable.txt", "logs/ohmymoney.log"])
    let note = try XCTUnwrap(entries.first { $0.path == "logs/ohmymoney.1.log.unreadable.txt" })
    let text = try XCTUnwrap(String(data: note.data, encoding: .utf8))
    XCTAssertTrue(text.contains("ohmymoney.1.log could not be read"), text)
  }

  /// «Файлов журнала: 0» and nothing else was all a report said when the journal's file had
  /// never opened. The list says the journal could not be opened, and `versions.txt` carries
  /// the code of the error.
  @MainActor
  func testAReportSaysTheJournalCouldNotBeOpened() async throws {
    // A file where the folder of the journal should be: nothing can be created under it.
    let blocked = directory.appendingPathComponent("Logs")
    try Data("not a folder".utf8).write(to: blocked)
    Logbook.shared.open(directory: blocked.appendingPathComponent("Inner"), threshold: .debug)
    defer { Logbook.shared.close() }

    let report = await ProblemReportService.gather(
      environment: AppEnvironment(), compute: ComputeStore(calendar: .utc))

    XCTAssertEqual(report.contents.journalFiles, 0)
    XCTAssertTrue(report.contents.journalUnavailable, "the list does not say why it has no files")
    let files = try ZipReader.files(in: report.zipped())
    let versions = try XCTUnwrap(
      String(data: try XCTUnwrap(files["versions.txt"]), encoding: .utf8))
    XCTAssertTrue(versions.contains("journalUnavailable error "), versions)
  }

  /// `PRAGMA integrity_check` reads the whole file and every table is counted: on a large
  /// database, seconds — and both ran on the main thread, the settings window frozen while
  /// the report was gathered.
  @MainActor
  func testTheDatabaseIsReadOffTheMainThread() async throws {
    let before = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    defer {
      if let before {
        setenv("OHMYMONEY_DATA_DIR", before, 1)
      } else {
        unsetenv("OHMYMONEY_DATA_DIR")
      }
    }
    let environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    XCTAssertEqual(environment.state, .ready)
    let threads = ReadingThreads()

    let report = await ProblemReportService.gather(
      environment: environment, compute: ComputeStore(calendar: .utc),
      reading: { stack, export in
        threads.onMain.withLock { $0.append(Thread.isMainThread) }
        return ProblemReportService.read(stack, export)
      })
    await environment.close()

    XCTAssertEqual(
      threads.onMain.withLock { $0 }, [false], "the database was read on the main thread")
    XCTAssertEqual(report.integrityCheckPassed, true)
    XCTAssertFalse(report.rowCounts.isEmpty)
  }

  private final class ReadingThreads: Sendable {
    let onMain = Mutex<[Bool]>([])
  }

  /// A stand-in that fired is a defect, and the report says which file asked.
  func testAStandInThatFiredIsInTheReport() throws {
    let files = try ZipReader.files(in: try report().zipped())
    let pipeline = try XCTUnwrap(
      String(data: try XCTUnwrap(files["pipeline.txt"]), encoding: .utf8))

    XCTAssertTrue(pipeline.contains("OhMyMoney/TransactionsRootView.swift"))
    XCTAssertTrue(pipeline.contains("without the app's dependencies"))
  }
}
