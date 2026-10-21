import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The copy of the day, the readable version beside it and beside a copy made before an update,
/// and the room the copies have (1.12, parts 3 and 4).
final class BackupDailyAndReadableTests: XCTestCase {
  private var directory: URL!
  private var stack: DatabaseStack!
  private var backupsFolder: URL { directory.appendingPathComponent("backups", isDirectory: true) }
  private var mirrorFolder: URL { directory.appendingPathComponent("iCloud", isDirectory: true) }

  private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2
    calendar.minimumDaysInFirstWeek = 4
    return calendar
  }

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-daily-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    stack = try DatabaseStack(
      url: directory.appendingPathComponent("finance.sqlite"),
      schema: BundleSchemaSource(bundle: .main))
    var draft = TransactionDraft(amount: AmountE4(whole: 250), note: "synthetic")
    draft.normalizeSinglePart()
    try TransactionRepository(writer: stack.writer).save(try draft.materialize())
  }

  override func tearDownWithError() throws {
    stack = nil
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  private func service(
    free: @escaping @Sendable (URL) -> Int64? = { _ in 50_000_000_000 }
  ) -> BackupService {
    var policy = BackupService.Policy()
    policy.calendar = utc
    policy.languageCode = { "en" }
    policy.freeBytes = free
    return BackupService(stack: stack, directory: backupsFolder, policy: policy)
  }

  private func day(_ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
    utc.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
  }

  private func names(in folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
  }

  // MARK: The readable version

  func testTheCopyOfTheDayHasAReadableFolderWithTheFilesOfTheExportAndAReadme() async throws {
    let copy = try await service().writeBackup(now: day(10, 5), label: "daily")

    let folder = BackupReadable.folder(forCopyAt: copy)
    XCTAssertEqual(folder.lastPathComponent, copy.deletingPathExtension().lastPathComponent)
    let files = names(in: folder)
    XCTAssertTrue(files.contains("README.txt"))
    for table in ExportTables.all { XCTAssertTrue(files.contains(table.fileName), table.fileName) }
    // The rows of the copy are in the files.
    let rows = try CSVReader.dictionaries(
      from: Data(contentsOf: folder.appendingPathComponent("transactions.csv")))
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows.first?["note"], "synthetic")
  }

  func testTheReadmeIsInRussianAndEnglishInOneFile() async throws {
    let copy = try await service().writeBackup(now: day(10, 5), label: "daily")
    let text = try String(
      contentsOf: BackupReadable.folder(forCopyAt: copy).appendingPathComponent("README.txt"),
      encoding: .utf8)
    XCTAssertTrue(text.contains("По-русски") && text.contains("English"))
    XCTAssertTrue(text.contains(".sqlite") && text.contains("pandas.read_csv"))
    XCTAssertTrue(text.contains("только на этом Mac") && text.contains("this Mac only"))
  }

  func testACopyAfterAChangeHasNoReadableFolder() async throws {
    let copy = try await service().writeBackup(now: day(10, 5))
    XCTAssertFalse(BackupReadable.exists(forCopyAt: copy))
    let restore = try await service().writeBackup(now: day(10, 6), label: "before-restore")
    XCTAssertFalse(BackupReadable.exists(forCopyAt: restore))
    let imported = try await service().writeBackup(now: day(10, 7), label: "before-import")
    XCTAssertFalse(BackupReadable.exists(forCopyAt: imported))
  }

  func testTheMirroredFolderGetsTheDatabaseOfTheDayAndNothingElse() async throws {
    try FileManager.default.createDirectory(at: mirrorFolder, withIntermediateDirectories: true)
    let backups = service()
    await backups.setMirror(mirrorFolder)

    let copy = try await backups.writeBackup(now: day(10, 5), label: "daily")

    XCTAssertEqual(names(in: mirrorFolder), [copy.lastPathComponent])
  }

  func testACopyBeforeAnUpdateGetsItsReadableFolderWhenTheStartIsOver() async throws {
    let copy = try BackupService.copyBeforeMigration(
      of: stack.url, into: backupsFolder, now: day(10, 1))
    XCTAssertFalse(BackupReadable.exists(forCopyAt: copy), "the start path writes the CSV")
    XCTAssertNil(
      BackupDescription.read(forCopyAt: copy), "the start path works out a description")

    let written = await service().fillReadableFolders()

    XCTAssertEqual(written, 1)
    XCTAssertTrue(BackupReadable.exists(forCopyAt: copy))
    let description = try XCTUnwrap(BackupDescription.read(forCopyAt: copy))
    XCTAssertEqual(description.operations, 1)
    XCTAssertEqual(description.reason, "beforeMigration")
    let again = await service().fillReadableFolders()
    XCTAssertEqual(again, 0, "a copy that has its folder is not written twice")
  }

  func testAReadableFolderCutShortIsRemovedWithTheNextCopy() async throws {
    let first = try await service().writeBackup(now: day(10, 5), label: "daily")
    let unfinished = URL(
      fileURLWithPath: BackupReadable.folder(forCopyAt: first).path + BackupReadable.unfinished,
      isDirectory: true)
    try FileManager.default.createDirectory(at: unfinished, withIntermediateDirectories: true)

    _ = try await service().writeBackup(now: day(10, 6))

    XCTAssertFalse(FileManager.default.fileExists(atPath: unfinished.path))
    XCTAssertTrue(BackupReadable.exists(forCopyAt: first))
  }

  func testTheDescriptionSaysHowTheCopyWasChecked() async throws {
    let daily = try await service().writeBackup(now: day(10, 5), label: "daily")
    let change = try await service().writeBackup(now: day(10, 6))
    XCTAssertEqual(BackupDescription.read(forCopyAt: daily)?.check, "full")
    XCTAssertEqual(BackupDescription.read(forCopyAt: change)?.check, "quick")
  }

  // MARK: The copy of the day

  func testTheCopyOfTheDayIsMadeOnceADay() async throws {
    let backups = service()
    let first = await backups.writeDailyIfDue(now: day(10, 5, 9))
    XCTAssertNotNil(first)
    let second = await backups.writeDailyIfDue(now: day(10, 5, 21))
    XCTAssertNil(second, "a second launch the same day made a second copy")
    let dailies = names(in: backupsFolder).filter { $0.hasSuffix(".sqlite") }
    XCTAssertEqual(dailies.count, 1)
    XCTAssertTrue(dailies[0].contains("daily"), dailies[0])
  }

  /// The copy of the morning, and a copy after a change every hour after it: a week later the
  /// copy of the day is still there, with its readable folder — the copies of the evening do not
  /// take its place.
  func testTheCopyOfTheDayAndItsFolderSurviveTheCopiesAfterChanges() async throws {
    let backups = service()
    let daily = try await backups.writeBackup(now: day(10, 5, 9), label: "daily")
    var changes: [URL] = []
    for hour in 10...20 {
      changes.append(try await backups.writeBackup(now: day(10, 5, hour)))
    }
    try await backups.applyRetention(now: day(10, 12, 12))

    XCTAssertTrue(FileManager.default.fileExists(atPath: daily.path))
    XCTAssertTrue(BackupReadable.exists(forCopyAt: daily), "the readable folder went")
    XCTAssertNotNil(BackupDescription.read(forCopyAt: daily))
    let left = changes.filter { FileManager.default.fileExists(atPath: $0.path) }
    XCTAssertEqual(left, [changes.last!], "the others keep the latest of their day")
  }

  func testTheNextDayGetsItsOwnCopyAndAMissedDayIsNotMadeUp() async throws {
    let backups = service()
    await backups.writeDailyIfDue(now: day(10, 5))
    // Nothing on the 6th, 7th and 8th.
    let later = await backups.writeDailyIfDue(now: day(10, 9, 3))
    XCTAssertNotNil(later)
    let dailies = names(in: backupsFolder).filter { $0.hasSuffix(".sqlite") }
    XCTAssertEqual(dailies.count, 2, "\(dailies)")
  }

  /// The copy itself is the mark: a new service over the same folder knows the day is done.
  func testTheMarkIsTheCopyNotAnythingInTheSettings() async throws {
    await service().writeDailyIfDue(now: day(10, 5, 8))
    let fresh = await service().writeDailyIfDue(now: day(10, 5, 20))
    XCTAssertNil(fresh)
  }

  func testACopyAfterAChangeDoesNotCountAsTheCopyOfTheDay() async throws {
    let backups = service()
    _ = try await backups.writeBackup(now: day(10, 5, 8))
    let daily = await backups.writeDailyIfDue(now: day(10, 5, 9))
    XCTAssertNotNil(daily)
  }

  func testTheDayIsTheLocalDayOfTheOwner() async throws {
    var policy = BackupService.Policy()
    var moscow = Calendar(identifier: .gregorian)
    moscow.timeZone = TimeZone(identifier: "Europe/Moscow")!
    policy.calendar = moscow
    let backups = BackupService(stack: stack, directory: backupsFolder, policy: policy)
    // 18:00 UTC is 21:00 in Moscow on the 5th; 20:00 UTC is 23:00 there, the same day; 22:00 UTC
    // is 01:00 on the 6th there — a new day, though still the 5th in UTC.
    let first = await backups.writeDailyIfDue(now: day(10, 5, 18))
    let sameDay = await backups.writeDailyIfDue(now: day(10, 5, 20))
    let nextDay = await backups.writeDailyIfDue(now: day(10, 5, 22))
    XCTAssertNotNil(first)
    XCTAssertNil(sameDay)
    XCTAssertNotNil(nextDay)
  }

  func testAClosingServiceMakesNoCopy() async throws {
    let backups = service()
    await backups.disable()
    let copy = await backups.writeDailyIfDue(now: day(10, 5))
    XCTAssertNil(copy)
  }

  func testTheNextRunIsAtThree() {
    let now = day(10, 5, 12)
    let next = BackupSpace.nextDailyRun(after: now, calendar: utc)
    XCTAssertEqual(next, utc.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 3)))
  }

  // MARK: Room

  func testTheWarningIsBelowAGigabyteExactly() async {
    let below = await service(free: { _ in 999_999_999 }).space()
    XCTAssertTrue(below.isLow)
    let exactly = await service(free: { _ in 1_000_000_000 }).space()
    XCTAssertFalse(exactly.isLow)
    let unknown = await service(free: { _ in nil }).space()
    XCTAssertFalse(unknown.isLow, "no number, no warning")
  }

  func testFreeingUpShowsWhatWillGoAndRemovesExactlyThat() async throws {
    let backups = service(free: { _ in 100 })
    for hour in 1...3 { try writeFakeCopy(day(1, 10, hour)) }
    for hour in 1...2 { try writeFakeCopy(day(10, 1, hour)) }
    let kept = try writeFakeCopy(day(10, 2), reason: .beforeMigration(to: nil))

    let plan = await backups.freeUpPlan(now: day(10, 20))
    let shown = plan.removals.map(\.id)
    XCTAssertFalse(shown.isEmpty)
    XCTAssertFalse(shown.contains(kept.lastPathComponent))

    let removed = await backups.remove(plan.removals)
    XCTAssertEqual(removed, shown.count)
    let left = names(in: backupsFolder).filter { $0.hasSuffix(".sqlite") }
    XCTAssertTrue(left.contains(kept.lastPathComponent))
    XCTAssertTrue(Set(left).isDisjoint(with: shown))
    XCTAssertEqual(left.count + shown.count, 6)
  }

  func testNothingIsRemovedWithoutTheWordYes() async throws {
    let backups = service(free: { _ in 100 })
    for hour in 1...3 { try writeFakeCopy(day(1, 10, hour)) }
    try writeFakeCopy(day(10, 1))
    let before = names(in: backupsFolder)

    // Looking at the plan, and saying «Нет», is not removing it.
    let plan = await backups.freeUpPlan(now: day(10, 20))
    XCTAssertFalse(plan.isEmpty)

    XCTAssertEqual(names(in: backupsFolder), before)
  }

  func testRemovingTakesTheDescriptionAndTheFolderToo() async throws {
    let copy = try writeFakeCopy(day(1, 10))
    try Data("{}".utf8).write(to: BackupDescription.url(forCopyAt: copy))
    let folder = BackupReadable.folder(forCopyAt: copy)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("a".utf8).write(to: folder.appendingPathComponent("a.csv"))
    let entry = BackupService.entries(in: backupsFolder).first!.entry
    XCTAssertGreaterThan(entry.bytes, 1)

    await service().remove([entry])

    XCTAssertEqual(names(in: backupsFolder), [])
  }

  func testOnlyANameOfACopyOfOursIsRemoved() async throws {
    try FileManager.default.createDirectory(at: backupsFolder, withIntermediateDirectories: true)
    try Data("mine".utf8).write(to: backupsFolder.appendingPathComponent("my.sqlite"))
    let stranger = BackupEntry(id: "my.sqlite", moment: day(1, 1), kind: .change)
    let removed = await service().remove([stranger])
    XCTAssertEqual(removed, 0)
    XCTAssertEqual(names(in: backupsFolder), ["my.sqlite"])
  }

  func testTheCopiesBeforeUpdatesOlderThanAYearAreListedWithoutTheNewest() async throws {
    let old1 = try writeFakeCopy(day(1, 5), reason: .beforeMigration(to: nil))
    let old2 = try writeFakeCopy(day(2, 5), reason: .beforeMigration(to: nil))
    try writeFakeCopy(day(8, 5), reason: .beforeMigration(to: nil))
    let backups = service()
    let now = utc.date(from: DateComponents(year: 2027, month: 9, day: 1))!

    let older = await backups.beforeUpdateOlderThanAYear(now: now)

    XCTAssertEqual(
      Set(older.map(\.id)), [old1.lastPathComponent, old2.lastPathComponent])
  }

  /// A copy of the sizes the plan counts: a file of a known size, named like a real copy.
  @discardableResult
  private func writeFakeCopy(
    _ moment: Date, reason: BackupName.Reason = .change
  ) throws -> URL {
    try FileManager.default.createDirectory(at: backupsFolder, withIntermediateDirectories: true)
    let name = BackupName(moment: moment, appVersion: "1.12.0", reason: reason)
      .fileName(in: utc.timeZone, words: BackupWords.writer(code: "en"))
    let url = backupsFolder.appendingPathComponent(name)
    try Data(repeating: 0x78, count: 4_000).write(to: url)
    return url
  }
}
