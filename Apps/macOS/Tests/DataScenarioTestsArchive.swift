import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The archive that carries everything to another Mac, written from a real database and read
/// back: every one of the 49 tables arrives as it left, the counts of the manifest are the rows
/// of the files, a password is the same password however it was typed, and a file that was cut,
/// edited or is no archive at all is refused with the words that say why.
final class DataScenarioArchiveRoundTripTests: XCTestCase {
  private var directory: URL!
  private var stack: DatabaseStack!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-f-archive-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    stack = try DatabaseStack(
      url: directory.appendingPathComponent("finance.sqlite"),
      schema: BundleSchemaSource(bundle: .main))
  }

  override func tearDownWithError() throws {
    stack = nil
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  private func service() -> ArchiveService {
    ArchiveService(stack: stack, appVersion: "1.9.1", iterations: 10)
  }

  private func save(_ whole: Int64, note: String) throws {
    var draft = TransactionDraft(amount: AmountE4(whole: whole), note: note)
    draft.normalizeSinglePart()
    try TransactionRepository(writer: stack.writer).save(try draft.materialize())
  }

  private func url(_ name: String) -> URL {
    directory.appendingPathComponent("\(name).ohmymoneyarchive")
  }

  /// An empty database travels too: every table is there with its header and no rows.
  func testAnEmptyDatabaseCarriesEveryTable() throws {
    _ = try service().exportArchive(to: url("empty"))
    let opened = try service().openArchive(at: url("empty"))
    let names = ExportTables.all.map { String($0.fileName.dropLast(4)) }
    XCTAssertEqual(Set(opened.csvTables), Set(names))
    XCTAssertEqual(opened.manifest.rowCounts["transactions"], 0)
  }

  /// Each table's file in the archive is byte for byte the file the CSV export writes.
  func testEveryTableInTheArchiveIsTheFileOfTheExport() throws {
    try save(250, note: "кофе, «латте»")
    try ReferenceRepository(writer: stack.writer).save(Person(name: "Синтетика"))
    _ = try service().exportArchive(to: url("same"))
    let opened = try service().openArchive(at: url("same"))
    let tables = try ExportRepository(writer: stack.writer).tables()
    XCTAssertEqual(tables.count, 49)
    for table in tables {
      XCTAssertEqual(opened.csv(table: table.name), table.data, table.name)
    }
  }

  /// The manifest counts the rows of the files it carries, table by table.
  func testTheManifestCountsTheRowsOfEveryFile() throws {
    for index in 0..<7 { try save(Int64(100 + index), note: "row \(index)") }
    _ = try service().exportArchive(to: url("counts"))
    let opened = try service().openArchive(at: url("counts"))
    XCTAssertEqual(opened.manifest.rowCounts["transactions"], 7)
    XCTAssertEqual(opened.manifest.rowCounts["transaction_parts"], 7)
    for table in opened.csvTables {
      let data = try XCTUnwrap(opened.csv(table: table))
      XCTAssertEqual(opened.manifest.rowCounts[table], ArchiveOpener.countCSVRows(data), table)
    }
  }

  /// Notes with commas, quotes, line breaks, Cyrillic and emoji read back as they were written.
  func testAWkwardTextSurvivesTheRoundTrip() throws {
    let notes = [
      "с запятой, и «кавычками»", "line\nbreak", "quote \"inside\"", "☕️ 🍰", "  spaces  ",
    ]
    for note in notes { try save(10, note: note) }
    _ = try service().exportArchive(to: url("text"))
    let opened = try service().openArchive(at: url("text"))
    let rows = try CSVReader.dictionaries(from: try XCTUnwrap(opened.csv(table: "transactions")))
    XCTAssertEqual(Set(rows.compactMap { $0["note"] }), Set(notes))
  }

  /// More than a hundred operations travel with every count right.
  func testMoreThanAHundredOperationsTravel() throws {
    for index in 0..<120 { try save(Int64(index + 1), note: "n\(index)") }
    _ = try service().exportArchive(to: url("many"))
    let opened = try service().openArchive(at: url("many"))
    XCTAssertEqual(opened.manifest.rowCounts["transactions"], 120)
    XCTAssertEqual(opened.manifest.rowCounts["transaction_parts"], 120)
  }

  /// The database inside the archive opens as a database of this build with the same rows.
  func testTheDatabaseInsideOpensWithTheSameRows() throws {
    try save(999, note: "inside")
    _ = try service().exportArchive(to: url("db"))
    let opened = try service().openArchive(at: url("db"))
    let target = directory.appendingPathComponent("restored.sqlite")
    try service().replaceDatabase(with: opened, at: target)
    XCTAssertTrue(DatabaseStack.integrityCheckPassed(at: target))
    XCTAssertEqual(
      try DatabaseStack.rowCounts(fileAt: target),
      try DatabaseStack.rowCounts(fileAt: directory.appendingPathComponent("finance.sqlite")))
  }

  /// The settings travel as they were handed over, keys this build does not know included: the
  /// archive carries, the import decides.
  func testTheSettingsTravelWordForWord() throws {
    let settings = ["language": "ru", "theme.scheme": "dark", "from.the.future": "42"]
    _ = try service().exportArchive(to: url("settings"), settings: settings)
    let opened = try service().openArchive(at: url("settings"))
    let data = try XCTUnwrap(opened.settings)
    let read = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: String])
    XCTAssertEqual(read, settings)
  }

  func testTheManifestNamesTheAppAndThePlatform() throws {
    let day = DateOnly(year: 2028, month: 2, day: 29)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let noon = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2028, month: 2, day: 29, hour: 12)))
    _ = try service().exportArchive(to: url("manifest"), now: noon)
    let manifest = try service().openArchive(at: url("manifest")).manifest
    XCTAssertEqual(manifest.appVersion, "1.9.1")
    XCTAssertEqual(manifest.platform, "macOS")
    XCTAssertEqual(manifest.createdAt, day)
    XCTAssertEqual(manifest.formatVersion, ArchiveManifest.currentFormatVersion)
  }

  // MARK: Passwords

  /// «й» typed on the keyboard and «й» pasted as «и» with a combining breve are one password.
  func testAPasswordInEitherNormalFormOpensTheArchive() throws {
    let composed = "пароль\u{0439}"
    let decomposed = "пароль\u{0438}\u{0306}"
    XCTAssertNotEqual(Array(composed.unicodeScalars), Array(decomposed.unicodeScalars))
    _ = try service().exportArchive(to: url("nfc"), password: composed)
    XCTAssertNoThrow(try service().openArchive(at: url("nfc"), password: decomposed))
  }

  /// And the other way: written with the combining breve, opened with «й» as typed.
  func testAPasswordWrittenDecomposedOpensComposed() throws {
    _ = try service().exportArchive(to: url("nfd"), password: "и\u{0306}ога")
    XCTAssertNoThrow(try service().openArchive(at: url("nfd"), password: "йога"))
  }

  func testAPasswordOfEmojiAndSpacesWorks() throws {
    let password = "🔐 мой пароль 🗝"
    _ = try service().exportArchive(to: url("emoji"), password: password)
    XCTAssertNoThrow(try service().openArchive(at: url("emoji"), password: password))
  }

  /// A space more is another password.
  func testATrailingSpaceIsAnotherPassword() throws {
    _ = try service().exportArchive(to: url("space"), password: "secret")
    XCTAssertThrowsError(try service().openArchive(at: url("space"), password: "secret ")) {
      XCTAssertEqual($0 as? CoreError, .invalidArchive(reason: .wrongPassword))
    }
  }

  /// Letters of another case are another password.
  func testTheCaseOfAPasswordMatters() throws {
    _ = try service().exportArchive(to: url("case"), password: "Пароль")
    XCTAssertThrowsError(try service().openArchive(at: url("case"), password: "пароль"))
  }

  func testAVeryLongPasswordWorks() throws {
    let password = String(repeating: "длинный-", count: 200)
    _ = try service().exportArchive(to: url("long"), password: password)
    XCTAssertNoThrow(try service().openArchive(at: url("long"), password: password))
    XCTAssertThrowsError(
      try service().openArchive(at: url("long"), password: String(password.dropLast())))
  }

  /// The empty password is «без пароля»: the archive is written in the clear.
  func testTheEmptyPasswordWritesAnOpenArchive() throws {
    _ = try service().exportArchive(to: url("open"), password: "")
    XCTAssertFalse(try service().isEncrypted(at: url("open")))
    XCTAssertNoThrow(try service().openArchive(at: url("open")))
  }

  func testNoPasswordWritesAnOpenArchive() throws {
    _ = try service().exportArchive(to: url("none"))
    XCTAssertFalse(try service().isEncrypted(at: url("none")))
  }

  /// An encrypted archive opened without its password asks for one.
  func testAnEncryptedArchiveWithoutAPasswordAsksForOne() throws {
    _ = try service().exportArchive(to: url("locked"), password: "secret")
    XCTAssertTrue(try service().isEncrypted(at: url("locked")))
    for missing in [nil, ""] as [String?] {
      XCTAssertThrowsError(try service().openArchive(at: url("locked"), password: missing)) {
        XCTAssertEqual(FileCommands.messageKey(for: $0), "archive.error.password")
      }
    }
  }

  /// The empty password of «без пароля» opens an open archive as no password does.
  func testTheEmptyPasswordOpensAnOpenArchive() throws {
    _ = try service().exportArchive(to: url("plain"))
    XCTAssertNoThrow(try service().openArchive(at: url("plain"), password: ""))
  }

  func testOnlyANonEmptyPasswordEncrypts() {
    XCTAssertFalse(ArchiveService.encrypts(nil))
    XCTAssertFalse(ArchiveService.encrypts(""))
    XCTAssertTrue(ArchiveService.encrypts(" "))
    XCTAssertTrue(ArchiveService.encrypts("a"))
  }

  /// Two archives of one password differ: each has a salt and a nonce of its own.
  func testTwoArchivesOfOnePasswordDiffer() throws {
    _ = try service().exportArchive(to: url("one"), password: "same")
    _ = try service().exportArchive(to: url("two"), password: "same")
    XCTAssertNotEqual(try Data(contentsOf: url("one")), try Data(contentsOf: url("two")))
  }

  // MARK: Damaged files

  func testAnArchiveCutShortIsRefused() throws {
    _ = try service().exportArchive(to: url("cut"))
    let data = try Data(contentsOf: url("cut"))
    try data.prefix(data.count / 2).write(to: url("half"))
    XCTAssertThrowsError(try service().openArchive(at: url("half"))) {
      XCTAssertEqual(FileCommands.messageKey(for: $0), "archive.error.damaged")
    }
  }

  func testAnEncryptedArchiveCutShortIsRefused() throws {
    _ = try service().exportArchive(to: url("cut"), password: "secret")
    let data = try Data(contentsOf: url("cut"))
    try data.prefix(data.count - 10).write(to: url("short"))
    XCTAssertThrowsError(try service().openArchive(at: url("short"), password: "secret"))
  }

  /// One byte changed inside an encrypted archive cannot be told from a wrong password.
  func testAByteChangedInAnEncryptedArchiveIsRefused() throws {
    _ = try service().exportArchive(to: url("edit"), password: "secret")
    var bytes = [UInt8](try Data(contentsOf: url("edit")))
    bytes[bytes.count - 40] ^= 0xFF
    try Data(bytes).write(to: url("edited"))
    XCTAssertThrowsError(try service().openArchive(at: url("edited"), password: "secret")) {
      XCTAssertEqual($0 as? CoreError, .invalidArchive(reason: .wrongPassword))
    }
  }

  func testAnEmptyFileIsNoArchive() throws {
    try Data().write(to: url("zero"))
    XCTAssertFalse(try service().isEncrypted(at: url("zero")))
    XCTAssertThrowsError(try service().openArchive(at: url("zero"))) {
      XCTAssertEqual(FileCommands.messageKey(for: $0), "archive.error.damaged")
    }
  }

  func testTextIsNoArchive() throws {
    try Data("this is a shopping list, not an archive".utf8).write(to: url("text"))
    XCTAssertThrowsError(try service().openArchive(at: url("text"))) {
      XCTAssertEqual(FileCommands.messageKey(for: $0), "archive.error.damaged")
    }
  }

  /// A file that starts with the magic of an encrypted archive and has nothing after it.
  func testTheMagicAloneIsNoArchive() throws {
    try Data(EncryptionHeader.magic).write(to: url("magic"))
    XCTAssertTrue(try service().isEncrypted(at: url("magic")))
    XCTAssertThrowsError(try service().openArchive(at: url("magic"), password: "x"))
  }

  func testAFileThatIsNotThereIsAnErrorAndNotEncrypted() {
    XCTAssertThrowsError(try service().isEncrypted(at: url("missing")))
    XCTAssertFalse(service().isEncryptedSafely(at: url("missing")))
    XCTAssertThrowsError(try service().openArchive(at: url("missing")))
  }

  /// An archive whose file was replaced by another of the same size inside is refused by its
  /// checksum.
  func testAFileSwappedInsideAnOpenArchiveIsRefused() throws {
    try save(100, note: "original")
    _ = try service().exportArchive(to: url("swap"))
    var data = try Data(contentsOf: url("swap"))
    let needle = Data("original".utf8)
    let range = try XCTUnwrap(data.range(of: needle))
    data.replaceSubrange(range, with: Data("ORIGINAL".utf8))
    try data.write(to: url("swapped"))
    XCTAssertThrowsError(try service().openArchive(at: url("swapped"))) {
      XCTAssertEqual(FileCommands.messageKey(for: $0), "archive.error.checksum")
    }
  }

  /// A folder that is not there: nothing is written, and the error says so.
  func testAnArchiveIntoAMissingFolderIsNotWritten() throws {
    let target = directory.appendingPathComponent("no/such/folder/a.ohmymoneyarchive")
    XCTAssertThrowsError(try service().exportArchive(to: target))
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
  }

  /// An archive of a newer format is refused with its own words.
  func testANewerFormatHasItsOwnWords() {
    XCTAssertEqual(
      FileCommands.messageKey(for: CoreError.invalidArchive(reason: .unsupportedFormatVersion)),
      "archive.error.newerFormat")
    XCTAssertEqual(
      FileCommands.messageKey(for: CoreError.invalidArchive(reason: .rowCountMismatch)),
      "archive.error.rowCount")
    XCTAssertEqual(
      FileCommands.messageKey(for: CoreError.invalidArchive(reason: .manifestMissing)),
      "archive.error.manifest")
    XCTAssertEqual(
      FileCommands.messageKey(for: CoreError.unsupportedSchemaVersion(found: 99, supported: 9)),
      "archive.error.newerSchema")
    XCTAssertEqual(
      FileCommands.messageKey(for: CocoaError(.fileNoSuchFile)), "archive.import.failed")
  }
}

/// What an archive's `settings.json` puts into the defaults of this Mac: only what this build can
/// name. Each scenario hands an archive to a suite of its own, never to the owner's defaults.
final class DataScenarioPortableSettingsTests: XCTestCase {
  private var suite: String!
  private var defaults: UserDefaults!

  override func setUpWithError() throws {
    try super.setUpWithError()
    suite = "ohmymoney.tests.f.\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
  }

  override func tearDownWithError() throws {
    defaults.removePersistentDomain(forName: suite)
    defaults = nil
    try super.tearDownWithError()
  }

  private func archive(_ settings: [String: String]?) throws -> ArchiveOpener.OpenedArchive {
    var files: [String: Data] = [:]
    if let settings {
      files[ArchivePaths.settings] = try JSONSerialization.data(withJSONObject: settings)
    }
    let manifest = ArchiveManifest(
      appVersion: "1.9.1", schemaVersion: 9, createdAt: DateOnly(year: 2026, month: 10, day: 14),
      platform: "macOS", rowCounts: [:], checksums: [:])
    return ArchiveOpener.OpenedArchive(manifest: manifest, files: files)
  }

  private func apply(_ settings: [String: String]?) throws {
    ArchiveImportFlow.applyPortableSettings(try archive(settings), to: defaults)
  }

  func testRussianIsPutBackWithTheLanguageOfTheMenus() throws {
    try apply(["language": "ru"])
    XCTAssertEqual(defaults.string(forKey: "app.language"), "ru")
    XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["ru"])
  }

  func testEnglishIsPutBackWithTheLanguageOfTheMenus() throws {
    try apply(["language": "en"])
    XCTAssertEqual(defaults.string(forKey: "app.language"), "en")
    XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])
  }

  /// «Как в системе» takes away a language set before, so the Mac's language rules again.
  func testTheSystemLanguageRemovesAnOverride() throws {
    defaults.set(["ru"], forKey: "AppleLanguages")
    try apply(["language": "system"])
    XCTAssertEqual(defaults.string(forKey: "app.language"), "system")
    XCTAssertNil(defaults.persistentDomain(forName: suite)?["AppleLanguages"])
  }

  func testALanguageThisBuildDoesNotSpeakIsIgnored() throws {
    try apply(["language": "de"])
    XCTAssertNil(defaults.string(forKey: "app.language"))
  }

  func testEveryThemeIsPutBack() throws {
    for scheme in ["system", "light", "dark"] {
      try apply(["theme.scheme": scheme])
      XCTAssertEqual(defaults.string(forKey: AppTheme.schemeKey), scheme)
    }
  }

  func testEveryAccentIsPutBack() throws {
    for accent in ["system", "amber", "blue", "teal", "green", "indigo", "purple", "pink"] {
      try apply(["theme.accent": accent])
      XCTAssertEqual(defaults.string(forKey: AppTheme.accentKey), accent)
    }
  }

  func testAThemeAndAnAccentThisBuildCannotNameAreIgnored() throws {
    defaults.set("dark", forKey: AppTheme.schemeKey)
    defaults.set("blue", forKey: AppTheme.accentKey)
    try apply(["theme.scheme": "sepia", "theme.accent": "neon"])
    XCTAssertEqual(defaults.string(forKey: AppTheme.schemeKey), "dark")
    XCTAssertEqual(defaults.string(forKey: AppTheme.accentKey), "blue")
  }

  func testTheStyleOfTheEntryIsPutBackWhenKnown() throws {
    try apply([AppEnvironment.entryStyleKey: "form"])
    XCTAssertEqual(defaults.string(forKey: AppEnvironment.entryStyleKey), "form")
    try apply([AppEnvironment.entryStyleKey: "voice"])
    XCTAssertEqual(defaults.string(forKey: AppEnvironment.entryStyleKey), "form")
    try apply([AppEnvironment.entryStyleKey: "line"])
    XCTAssertEqual(defaults.string(forKey: AppEnvironment.entryStyleKey), "line")
  }

  /// Keys that are only this Mac's — the hidden amounts, the lock, the size of the text — are
  /// never taken from an archive, whatever it carries.
  func testKeysOfThisMacOnlyAreNeverTaken() throws {
    try apply([
      "privacy.hideAmounts": "true", "privacy.lock.enabled": "true", "app.fontSize": "xlarge",
      "app.currencyStyle": "name", "backup.folder": "/tmp", "whatever": "1",
    ])
    for key in [
      "privacy.hideAmounts", "privacy.lock.enabled", "app.fontSize", "app.currencyStyle",
      "backup.folder", "whatever",
    ] {
      XCTAssertNil(defaults.object(forKey: key), key)
    }
  }

  /// An archive without `settings.json`, or with one that is not a dictionary of strings,
  /// changes nothing.
  func testNoSettingsOrUnreadableSettingsChangeNothing() throws {
    defaults.set("dark", forKey: AppTheme.schemeKey)
    try apply(nil)
    var files = [ArchivePaths.settings: Data("[1, 2, 3]".utf8)]
    let manifest = try archive(nil).manifest
    ArchiveImportFlow.applyPortableSettings(
      ArchiveOpener.OpenedArchive(manifest: manifest, files: files), to: defaults)
    files[ArchivePaths.settings] = Data("{\"theme.scheme\": 7}".utf8)
    ArchiveImportFlow.applyPortableSettings(
      ArchiveOpener.OpenedArchive(manifest: manifest, files: files), to: defaults)
    XCTAssertEqual(defaults.string(forKey: AppTheme.schemeKey), "dark")
  }

  /// An archive of a build before groups carries only the list of tiles: the layout of this Mac
  /// goes, so the list is what the next launch reads.
  func testAListOfTilesWithoutALayoutDropsTheLayoutOfThisMac() throws {
    defaults.set("money:monthToDate", forKey: AppEnvironment.overviewLayoutKey)
    try apply([AppEnvironment.overviewTilesKey: "monthToDate,limits"])
    XCTAssertNil(defaults.string(forKey: AppEnvironment.overviewLayoutKey))
    XCTAssertNotNil(defaults.string(forKey: AppEnvironment.overviewTilesKey))
  }

  /// The order of the blocks of Planning is put back as an order of every block once.
  func testTheOrderOfPlanningIsPutBackWhole() throws {
    try apply(["planning.blockOrder": "goals,bogus"])
    let stored = try XCTUnwrap(defaults.string(forKey: "planning.blockOrder"))
    XCTAssertTrue(stored.hasPrefix("goals"), stored)
    XCTAssertFalse(stored.contains("bogus"))
  }
}
