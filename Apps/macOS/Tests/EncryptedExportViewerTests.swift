import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// A locked file of tables — «Итог поездки», «Отчёты», «Банкам за год», a copy of «Только CSV» —
/// opened in the app: once its password is given it is shown, never imported, and the owner's
/// books stay as they were; an archive with a database goes on as an import, as before.
@MainActor
final class EncryptedExportViewerTests: XCTestCase {
  private let rounds = 1_000
  private var directory: URL!
  private var stack: DatabaseStack!
  private var dataDirectoryBefore: String?

  private let byDay = PersonalDataExport.File(
    name: "trip-turkey-by-day.csv",
    data: Data("row_type,name,amount_rub\nitem,2026-10-06,3000\nitem,2026-10-07,\"4,000\"\n".utf8))
  private let settlement = PersonalDataExport.File(
    name: "trip-turkey-settlement.csv", data: Data("row_type,name\nperson,Анна\n".utf8))

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-tables-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.appendingPathComponent("data").path, 1)
    stack = try DatabaseStack(
      url: directory.appendingPathComponent("finance.sqlite"),
      schema: BundleSchemaSource(bundle: .main))
  }

  override func tearDown() async throws {
    ReadOnlyGate.isOn = false
    stack = nil
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  // MARK: Helpers

  private var schema: Int { stack.applied.onDisk }

  private func lockedTables(_ name: String = "trip-turkey") throws -> URL {
    let url = directory.appendingPathComponent(EncryptedExport.fileName(name))
    try EncryptedExport.write(
      [byDay, settlement], password: "secret", to: url, appVersion: "2.6.1",
      schemaVersion: schema, cipher: CryptoKitArchiveCipher(), iterations: rounds)
    return url
  }

  private func service() -> ArchiveService {
    ArchiveService(stack: stack, appVersion: "2.6.1", iterations: rounds)
  }

  private func backups() -> BackupService {
    BackupService(stack: stack, directory: directory.appendingPathComponent("backups"))
  }

  private final class Answers {
    var password: ArchiveImportFlow.PasswordAnswer = .given("secret")
    var confirms = false
    var confirmations = 0
    var passwordsAsked = 0
    var reports: [String] = []
    var shown: [ArchiveTables] = []
    var relaunches = 0

    @MainActor var questions: ArchiveImportFlow.Questions {
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
        relaunch: { [self] in relaunches += 1 },
        tables: { [self] in shown.append(ArchiveTables($0)) })
    }
  }

  private var staged: Bool {
    FileManager.default.fileExists(atPath: AppPaths.pendingReplacementURL.path)
      || FileManager.default.fileExists(
        atPath: AppPaths.importMark(for: AppPaths.pendingReplacementURL).path)
  }

  private func copies() -> [String] {
    (try? FileManager.default.contentsOfDirectory(
      atPath: directory.appendingPathComponent("backups").path)) ?? []
  }

  // MARK: The model

  func testTheGridHasTheHeaderAndTheLines() throws {
    let grid = try ArchiveTables.grid(of: .init(name: byDay.name, data: byDay.data))
    XCTAssertEqual(grid.header, ["row_type", "name", "amount_rub"])
    XCTAssertEqual(
      grid.lines.map(\.cells),
      [
        ["item", "2026-10-06", "3000"], ["item", "2026-10-07", "4,000"],
      ])
    XCTAssertEqual(grid.totalLines, 2)
    XCTAssertFalse(grid.isCut)
  }

  func testTheScreenShowsTheFirstThousandLines() throws {
    var text = "n\n"
    for line in 0..<1_005 { text += "\(line)\n" }
    let grid = try ArchiveTables.grid(of: .init(name: "long.csv", data: Data(text.utf8)))
    XCTAssertEqual(ArchiveTables.shownLines, 1_000)
    XCTAssertEqual(grid.lines.count, 1_000)
    XCTAssertEqual(grid.totalLines, 1_005)
    XCTAssertTrue(grid.isCut)
    XCTAssertEqual(grid.lines.last?.cells, ["999"])
    XCTAssertEqual(grid.cutNumbers.shown, "1,000")
    XCTAssertEqual(grid.cutNumbers.total, "1,005")
  }

  func testAShortOrLongLineNeverTraps() throws {
    let data = Data("a,b,c\n1\n1,2,3,4\n".utf8)
    let grid = try ArchiveTables.grid(of: .init(name: "odd.csv", data: data))
    XCTAssertEqual(grid.header, ["a", "b", "c", ""], "a longer line widens the grid")
    XCTAssertEqual(grid.lines.map(\.cells), [["1", "", "", ""], ["1", "2", "3", "4"]])
  }

  func testAnEmptyTableAndBytesThatAreNotTextAreSaidNotThrownAtTheScreen() throws {
    let empty = try ArchiveTables.grid(of: .init(name: "empty.csv", data: Data()))
    XCTAssertEqual(empty.header, [])
    XCTAssertEqual(empty.totalLines, 0)
    XCTAssertThrowsError(
      try ArchiveTables.grid(of: .init(name: "bad.csv", data: Data([0xFF, 0xFE, 0x00]))))
  }

  func testTheTablesOfALockedFileAreTheBytesThatWereSealed() throws {
    let opened = try ArchiveOpener.open(
      try Data(contentsOf: try lockedTables()), password: "secret",
      cipher: CryptoKitArchiveCipher(), supportedSchemaVersion: schema)
    XCTAssertTrue(ArchiveTables.holdsOnlyTables(opened))
    let tables = ArchiveTables(opened)
    XCTAssertEqual(tables.tables.map(\.name), [byDay.name, settlement.name])
    XCTAssertEqual(tables.files, [byDay, settlement])
  }

  func testSavingWritesTheSameBytesInTheOpen() throws {
    let tables = ArchiveTables(tables: [
      .init(name: byDay.name, data: byDay.data),
      .init(name: settlement.name, data: settlement.data),
    ])
    let folder = directory.appendingPathComponent("saved", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    XCTAssertEqual(tables.replacing(in: folder), 0)
    XCTAssertEqual(try tables.write(to: folder), 2)
    XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(byDay.name)), byDay.data)
    XCTAssertEqual(
      try Data(contentsOf: folder.appendingPathComponent(settlement.name)), settlement.data)
    XCTAssertEqual(tables.replacing(in: folder), 2, "a second save asks before it replaces")
  }

  func testAnArchiveWithADatabaseIsNoFileOfTables() throws {
    let url = directory.appendingPathComponent("transfer.ohmymoneyarchive")
    try service().exportArchive(to: url)
    let opened = try service().openArchive(at: url)
    XCTAssertFalse(ArchiveTables.holdsOnlyTables(opened))
  }

  func testTheWordsOfTheWindowAreInBothLanguages() {
    let keys = [
      "archive.tables.title", "archive.tables.choose", "archive.tables.note",
      "archive.tables.save", "archive.tables.unreadable", "archive.tables.empty",
      "archive.tables.cut", "export.encrypt.note", "export.locked.working",
    ]
    for language in ["ru", "en"] {
      let bundle = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(
        Bundle.init(path:))
      for key in keys {
        let text = bundle?.localizedString(forKey: key, value: key, table: "Reports") ?? key
        XCTAssertNotEqual(text, key, "\(key) has no \(language) words")
      }
    }
    let russian = Bundle.main.path(forResource: "ru", ofType: "lproj").flatMap(Bundle.init(path:))
    let lock =
      russian?.localizedString(
        forKey: "privacy.export.lock", value: nil, table: "PrivacyExport") ?? ""
    XCTAssertFalse(lock.contains("zip"), "the box promised a zip nobody can open: \(lock)")
  }

  // MARK: The flow

  func testALockedFileOfTablesIsShownAndNothingIsImported() async throws {
    let url = try lockedTables()
    let database = directory.appendingPathComponent("finance.sqlite")
    let before = try Data(contentsOf: database)
    let answers = Answers()

    await FileCommands.importArchive(
      from: url, archives: service(), backups: backups(), questions: answers.questions)?.value

    XCTAssertEqual(answers.passwordsAsked, 1)
    XCTAssertEqual(answers.shown.count, 1, "the tables were not shown")
    XCTAssertEqual(answers.shown.first?.files, [byDay, settlement])
    XCTAssertEqual(answers.reports, [], "a file of tables was told as a failed import")
    XCTAssertEqual(answers.relaunches, 0)
    XCTAssertEqual(answers.confirmations, 0)
    XCTAssertFalse(staged, "a file of tables was staged to replace the books")
    XCTAssertEqual(copies(), [], "an import copy was written for a file of tables")
    XCTAssertEqual(try Data(contentsOf: database), before, "the books changed")
  }

  /// A copy of «Экспорт копии» made as «Только CSV»: every table, the settings and the row counts,
  /// no database — shown, not imported.
  func testACopyOfCSVOnlyIsShownAndNothingIsImported() async throws {
    let url = directory.appendingPathComponent("OhMyMoney-copy.ohmymoneyarchive")
    try ExportCopyService(stack: stack, appVersion: "2.6.1", iterations: rounds, anonymizer: nil)
      .export(ExportCopyRequest(password: "secret", format: .csvOnly), to: url)
    let answers = Answers()

    await FileCommands.importArchive(
      from: url, archives: service(), backups: backups(), questions: answers.questions)?.value

    XCTAssertEqual(answers.shown.count, 1, "the tables of the copy were not shown")
    XCTAssertTrue(answers.shown.first?.tables.contains { $0.name == "transactions.csv" } ?? false)
    XCTAssertEqual(answers.reports, [])
    XCTAssertEqual(answers.relaunches, 0)
    XCTAssertFalse(staged)
    XCTAssertEqual(copies(), [])
  }

  func testAWrongPasswordIsToldInTheWordsOfAnImport() async throws {
    let url = try lockedTables()
    let answers = Answers()
    answers.password = .given("other")
    await FileCommands.importArchive(
      from: url, archives: service(), backups: backups(), questions: answers.questions)?.value
    XCTAssertEqual(answers.reports, ["archive.error.password"])
    XCTAssertEqual(answers.shown.count, 0)
  }

  func testTablesAreShownWhileTheAppIsReadOnly() async throws {
    let url = try lockedTables()
    let answers = Answers()
    ReadOnlyGate.isOn = true
    await FileCommands.importArchive(
      from: url, archives: service(), backups: backups(), questions: answers.questions)?.value
    XCTAssertEqual(answers.shown.count, 1)
    XCTAssertEqual(answers.reports, [])
  }

  func testALockedArchiveWithADatabaseIsStillRefusedWhileReadOnly() async throws {
    let url = directory.appendingPathComponent("sealed.ohmymoneyarchive")
    try service().exportArchive(to: url, password: "secret")
    let answers = Answers()
    ReadOnlyGate.isOn = true
    await FileCommands.importArchive(
      from: url, archives: service(), backups: backups(), questions: answers.questions)?.value
    XCTAssertEqual(answers.reports, ["archive.import.readOnly"])
    XCTAssertEqual(answers.shown.count, 0)
    XCTAssertFalse(staged)
  }

  /// A double-clicked locked archive with a database: the password first, then «Загрузить этот
  /// архив?»; a no stops it with nothing staged.
  func testADoubleClickedLockedArchiveIsConfirmedOnceItIsOpen() async throws {
    let url = directory.appendingPathComponent("sealed.ohmymoneyarchive")
    try service().exportArchive(to: url, password: "secret")
    let answers = Answers()
    answers.confirms = false

    await ArchiveImportFlow.run(
      url, archives: service(), backups: backups(), questions: answers.questions,
      confirmsAfterOpening: true)?.value

    XCTAssertEqual(answers.passwordsAsked, 1)
    XCTAssertEqual(answers.confirmations, 1, "asked once the archive was open")
    XCTAssertEqual(answers.shown.count, 0)
    XCTAssertEqual(answers.reports, [])
    XCTAssertFalse(staged, "staged although the owner said no")
  }

  func testAConfirmedLockedArchiveIsStagedAsBefore() async throws {
    let url = directory.appendingPathComponent("sealed.ohmymoneyarchive")
    try service().exportArchive(to: url, password: "secret")
    try AppPaths.ensureDirectories()
    let answers = Answers()
    answers.confirms = true
    defer {
      try? FileManager.default.removeItem(at: AppPaths.pendingReplacementURL)
      try? FileManager.default.removeItem(
        at: AppPaths.importMark(for: AppPaths.pendingReplacementURL))
    }

    await ArchiveImportFlow.run(
      url, archives: service(), backups: backups(), questions: answers.questions,
      confirmsAfterOpening: true)?.value

    XCTAssertEqual(answers.reports, [])
    XCTAssertEqual(answers.confirmations, 1)
    XCTAssertEqual(answers.relaunches, 1)
    XCTAssertTrue(staged, "the archive with a database was not staged")
  }

  /// A double click on a locked file of tables in Finder: no «Загрузить этот архив?» at all.
  func testADoubleClickedFileOfTablesAsksNoConfirmation() async throws {
    let environment = AppEnvironment()
    await environment.start()
    XCTAssertEqual(environment.state, .ready)
    let onDisk = try XCTUnwrap(environment.stack?.applied.onDisk)
    let url = directory.appendingPathComponent(EncryptedExport.fileName("bank-fees-2026"))
    try EncryptedExport.write(
      [.init(name: "bank-fees-2026.csv", data: Data("month,fees_rub\n2026-01,100\n".utf8))],
      password: "secret", to: url, appVersion: "2.6.1", schemaVersion: onDisk,
      cipher: CryptoKitArchiveCipher(), iterations: rounds)
    let answers = Answers()

    ArchiveImportFlow.begin(with: url, environment: environment, questions: answers.questions)
    let deadline = Date().addingTimeInterval(30)
    while answers.shown.isEmpty, answers.reports.isEmpty, Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }

    XCTAssertEqual(answers.confirmations, 0, "a file of tables asked to replace the books")
    XCTAssertEqual(answers.passwordsAsked, 1)
    XCTAssertEqual(answers.shown.map { $0.tables.map(\.name) }, [["bank-fees-2026.csv"]])
    XCTAssertEqual(answers.reports, [])
    XCTAssertFalse(staged)
    await environment.close()
  }
}
