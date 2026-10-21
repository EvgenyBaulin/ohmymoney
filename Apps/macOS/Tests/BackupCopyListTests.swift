import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The two kinds of names of a copy living in one folder, the list of the copies and the small
/// description beside each (1.12, parts 1 and 2).
final class BackupCopyListTests: XCTestCase {
  private var folder: URL!
  private let moscow = TimeZone(identifier: "Europe/Moscow")!

  override func setUpWithError() throws {
    try super.setUpWithError()
    folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-copy-list-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: folder)
    try super.tearDownWithError()
  }

  private func moment(_ day: Int, _ hour: Int = 12, minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return calendar.date(
      from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute))!
  }

  private func newName(
    _ at: Date, _ reason: BackupName.Reason = .change, code: String = "ru", damaged: Bool = false
  ) -> String {
    BackupName(moment: at, appVersion: "1.12.0", reason: reason, damaged: damaged)
      .fileName(words: BackupWords.writer(code: code))
  }

  private func oldName(_ at: Date, label: String? = nil) -> String {
    BackupService.fileName(at: at, label: label)
  }

  @discardableResult
  private func touch(_ name: String, in directory: URL? = nil) throws -> URL {
    let url = (directory ?? folder).appendingPathComponent(name)
    try Data("not a database".utf8).write(to: url)
    return url
  }

  // MARK: One parser for every name

  func testEveryOldKindOfNameIsReadAsBefore() throws {
    let at = moment(5)
    let cases: [(String?, BackupName.Reason, Bool)] = [
      (nil, .change, false),
      ("before-migration", .beforeMigration(to: nil), false),
      ("before-restore", .beforeRestore, false),
      ("before-import", .beforeImport, false),
      ("damaged", .change, true),
      ("before-restore-damaged", .beforeRestore, true),
      ("before-import-damaged", .beforeImport, true),
    ]
    for (label, reason, damaged) in cases {
      let name = oldName(at, label: label)
      let copy = try XCTUnwrap(BackupCopy.parse(name), name)
      XCTAssertTrue(copy.isLegacy, name)
      XCTAssertEqual(copy.reason, reason, name)
      XCTAssertEqual(copy.damaged, damaged, name)
      XCTAssertEqual(copy.moment, Date(timeIntervalSince1970: at.timeIntervalSince1970.rounded()))
      XCTAssertEqual(BackupService.date(in: name), copy.moment)
    }
  }

  func testANameWithoutAnOffsetIsLocalTimeAndStillAnOldName() throws {
    let copy = try XCTUnwrap(BackupCopy.parse("finance-2026-03-05T120000.sqlite"))
    XCTAssertTrue(copy.isLegacy)
    XCTAssertEqual(copy.moment, moment(5, 12))
    XCTAssertEqual(copy.day, "2026-03-05")
  }

  func testTheNewNameIsReadInBothLanguages() throws {
    let reasons: [BackupName.Reason] = [
      .change, .daily, .beforeMigration(to: "10"), .beforeRestore, .beforeImport,
    ]
    for code in ["ru", "en"] {
      for reason in reasons {
        let name = newName(moment(5, 9, minute: 7), reason, code: code)
        let copy = try XCTUnwrap(BackupCopy.parse(name), name)
        XCTAssertFalse(copy.isLegacy, name)
        XCTAssertEqual(copy.reason, reason, name)
        XCTAssertEqual(copy.moment, moment(5, 9, minute: 7), name)
        XCTAssertEqual(copy.day, "2026-03-05", name)
      }
    }
  }

  func testAFileThatIsNoCopyOfOursIsNotRead() {
    for name in ["notes.sqlite", "finance.sqlite", "finance-yesterday.sqlite", "photo.jpg"] {
      XCTAssertNil(BackupCopy.parse(name), name)
    }
  }

  // MARK: One folder, both kinds

  func testOldAndNewCopiesSortByTheirMoment() throws {
    let names = [
      oldName(moment(1)), newName(moment(2)), oldName(moment(3)), newName(moment(4)),
      oldName(moment(5), label: "before-restore"),
    ]
    let urls = try names.map { try touch($0) }
    let sorted = BackupService.newestFirst(urls).map(\.lastPathComponent)
    XCTAssertEqual(sorted, [names[4], names[3], names[2], names[1], names[0]])
    let listed = BackupList.load(in: folder).items.map(\.url.lastPathComponent)
    XCTAssertEqual(listed, sorted)
  }

  func testThinningCountsOldAndNewNamesTogether() async throws {
    let service = BackupService(source: NoSource(), directory: folder)
    let names = [
      oldName(moment(8, 8)), newName(moment(8, 20)), oldName(moment(9, 8)), newName(moment(9, 9)),
    ]
    for name in names { try touch(name) }

    try await service.applyRetention(now: moment(10))

    // Within the last week the latest copy of each day stays, whichever kind of name it has.
    let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    XCTAssertEqual(left, [names[1], names[3]].sorted())
  }

  func testTheCopyBeforeAnUpdateOfEitherKindIsNeverPruned() async throws {
    let service = BackupService(source: NoSource(), directory: folder)
    let oldBefore = oldName(moment(1), label: "before-migration")
    let newBefore = newName(moment(2), .beforeMigration(to: "10"))
    let newBeforeEnglish = newName(moment(3), .beforeMigration(to: nil), code: "en")
    let ordinary = [newName(moment(8, 8)), oldName(moment(8, 9)), newName(moment(8, 20))]
    for name in [oldBefore, newBefore, newBeforeEnglish] + ordinary { try touch(name) }

    try await service.applyRetention(now: moment(10))

    let left = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    XCTAssertTrue(left.isSuperset(of: [oldBefore, newBefore, newBeforeEnglish]), "\(left)")
    XCTAssertEqual(left.subtracting([oldBefore, newBefore, newBeforeEnglish]), [ordinary[2]])
    XCTAssertTrue(BackupService.isBeforeMigration(oldBefore))
    XCTAssertTrue(BackupService.isBeforeMigration(newBefore))
    XCTAssertTrue(BackupService.isBeforeMigration(newBeforeEnglish))
    XCTAssertFalse(BackupService.isBeforeMigration(ordinary[0]))
  }

  func testAFileOfTheOwnersInTheFolderIsNeverPruned() async throws {
    let service = BackupService(source: NoSource(), directory: folder)
    try touch("my-own-notes.sqlite")
    for hour in 1...4 { try touch(newName(moment(8, hour))) }

    try await service.applyRetention(now: moment(10))

    let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    XCTAssertTrue(left.contains("my-own-notes.sqlite"))
    XCTAssertEqual(left.count, 2)
  }

  func testPruningACopyTakesItsDescriptionWithIt() async throws {
    let service = BackupService(source: NoSource(), directory: folder)
    let older = try touch(newName(moment(8, 8)))
    let newer = try touch(newName(moment(8, 9)))
    for copy in [older, newer] {
      try Data("{}".utf8).write(to: BackupDescription.url(forCopyAt: copy))
    }

    try await service.applyRetention(now: moment(10))

    XCTAssertFalse(FileManager.default.fileExists(atPath: older.path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: BackupDescription.url(forCopyAt: older).path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: BackupDescription.url(forCopyAt: newer).path))
  }

  // MARK: The list

  func testTheListReadsDescriptionsWithoutOpeningAnyCopy() throws {
    // The "copies" are not databases: a list that opened them would find nothing in them.
    let described = try touch(newName(moment(2)))
    let bare = try touch(oldName(moment(1)))
    let description = BackupDescription(
      snapshot: BackupSnapshot(
        operations: [:], balances: [], categories: [:]),
      takenAt: moment(2), appVersion: "1.12.0", reason: .change)
    var sample = description
    sample.operations = 42
    sample.balances = [
      BackupDescription.Balance(account: "Main", currency: "RUB", amountE4: 1_000_000)
    ]
    try JSONEncoder.iso.encode(sample).write(to: BackupDescription.url(forCopyAt: described))

    let list = BackupList.load(in: folder)

    XCTAssertEqual(list.count, 2)
    XCTAssertEqual(list.items[0].description?.operations, 42)
    XCTAssertEqual(list.items[0].description?.balances.first?.amountE4, 1_000_000)
    XCTAssertNil(list.items[1].description)
    XCTAssertEqual(list.items[1].url, bare)
  }

  func testTheListCountsSizesWithTheFolderOfReadableFiles() throws {
    let copy = try touch(newName(moment(2), .daily))
    let readable = copy.deletingPathExtension()
    try FileManager.default.createDirectory(at: readable, withIntermediateDirectories: true)
    try Data(count: 1_000).write(to: readable.appendingPathComponent("transactions.csv"))
    let plain = try touch(newName(moment(1)))

    let list = BackupList.load(in: folder)

    let item = try XCTUnwrap(list.items.first { $0.url == copy })
    XCTAssertEqual(item.readableFolder, readable)
    XCTAssertEqual(item.readableBytes, 1_000)
    XCTAssertEqual(item.totalBytes, item.fileBytes + 1_000)
    XCTAssertNil(try XCTUnwrap(list.items.first { $0.url == plain }).readableFolder)
    XCTAssertEqual(list.count, 2)
    XCTAssertEqual(list.totalBytes, list.items.reduce(0) { $0 + $1.totalBytes })
  }

  func testTheSizeOfTheCopiesBeforeUpdatesIsCountedApart() throws {
    try touch(oldName(moment(1), label: "before-migration"))
    try touch(newName(moment(2), .beforeMigration(to: "10")))
    try touch(newName(moment(3)))

    let list = BackupList.load(in: folder)

    XCTAssertEqual(
      list.beforeUpdateBytes,
      list.items.filter { $0.copy.isBeforeMigration }.reduce(0) { $0 + $1.totalBytes })
    XCTAssertEqual(list.items.filter { $0.copy.isBeforeMigration }.count, 2)
  }

  // MARK: The description

  func testANewCopyGetsItsDescriptionBesideIt() async throws {
    let stack = try makeStack()
    defer { try? stack.close() }
    var policy = BackupService.Policy()
    policy.appVersion = "1.12.0"
    let service = BackupService(stack: stack, directory: folder, policy: policy)

    let copy = try await service.writeBackup(now: moment(7, 10, minute: 30))

    let url = BackupDescription.url(forCopyAt: copy)
    XCTAssertEqual(url.lastPathComponent, copy.deletingPathExtension().lastPathComponent + ".json")
    let description = try XCTUnwrap(BackupDescription.read(forCopyAt: copy))
    XCTAssertEqual(description.operations, 2)
    XCTAssertEqual(description.appVersion, "1.12.0")
    XCTAssertEqual(description.reason, "change")
    XCTAssertEqual(description.lastOperation?.note, "second")
    XCTAssertEqual(description.formatVersion, 1)
  }

  func testTheDescriptionOfAnOldCopyIsWorkedOutOnDemandAndKept() throws {
    let stack = try makeStack()
    let old = folder.appendingPathComponent(oldName(moment(3), label: "before-migration"))
    try stack.backup(to: old)
    try stack.close()
    XCTAssertNil(BackupDescription.read(forCopyAt: old))

    let worked = try XCTUnwrap(BackupDescription.compute(forCopyAt: old))

    XCTAssertEqual(worked.operations, 2)
    XCTAssertEqual(worked.reason, "beforeMigration")
    XCTAssertEqual(BackupDescription.read(forCopyAt: old), worked)
  }

  func testAnUnreadableCopyHasNoDescriptionAndNothingIsWritten() throws {
    let broken = try touch(newName(moment(1)))
    XCTAssertNil(BackupDescription.compute(forCopyAt: broken))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: BackupDescription.url(forCopyAt: broken).path))
  }

  func testBalancesPerAccountAreInTheDescription() throws {
    let account = PaymentMethod(id: UUID(), name: "Main", kind: .card, currency: .rub)
    var snapshot = BackupSnapshot(operations: [:], balances: [], categories: [:])
    snapshot.balances = [
      BackupSnapshot.Balance(
        accountId: account.id, account: "Main", currency: "RUB", amountE4: 5_000_000)
    ]
    let description = BackupDescription(
      snapshot: snapshot, takenAt: moment(1), appVersion: "1.12.0", reason: .daily)
    XCTAssertEqual(description.balances.map(\.account), ["Main"])
    XCTAssertEqual(description.balances.first?.amountE4, 5_000_000)
    XCTAssertEqual(description.reason, "daily")
    XCTAssertNil(description.lastOperation)
  }

  // MARK: Words

  func testEveryWordOfANameExistsInBothLanguages() {
    let words: [BackupName.Word] = [
      .reason(.change), .reason(.daily), .reason(.beforeMigration(to: nil)),
      .reason(.beforeMigration(to: "10")), .reason(.beforeRestore), .reason(.beforeImport),
      .damaged,
    ]
    for word in words {
      let russian = BackupWords.text(of: word, in: "ru")
      let english = BackupWords.text(of: word, in: "en")
      XCTAssertFalse(russian.hasPrefix("backups.name"), "\(word)")
      XCTAssertFalse(english.hasPrefix("backups.name"), "\(word)")
      XCTAssertNotEqual(russian, english, "\(word)")
    }
    XCTAssertEqual(BackupWords.text(of: .reason(.change), in: "ru"), "после правки")
    XCTAssertEqual(
      BackupWords.text(of: .reason(.beforeMigration(to: "10")), in: "en"), "before the update to 10"
    )
  }

  @MainActor
  func testTheRowDetailNamesTheKindAndTheSize() throws {
    let copy = try XCTUnwrap(BackupCopy.parse(newName(moment(2), .beforeImport)))
    let item = BackupList.Item(
      url: folder.appendingPathComponent(copy.fileName), copy: copy, description: nil,
      fileBytes: 2048, readableFolder: nil, readableBytes: 0)
    let text = BackupSettingsView.detail(of: item, in: AppEnvironment())
    XCTAssertTrue(text.contains(BackupSettingsView.sizeText(2048)), text)
    XCTAssertTrue(text.contains("импортом") || text.contains("import"), text)
  }

  // MARK: Helpers

  private func makeStack() throws -> DatabaseStack {
    let stack = try DatabaseStack(
      url: folder.appendingPathComponent("live-\(UUID().uuidString).sqlite"),
      schema: BundleSchemaSource(bundle: .main))
    for (index, note) in ["first", "second"].enumerated() {
      var draft = TransactionDraft(
        occurredAt: moment(1 + index), amount: AmountE4(whole: Int64(100 * (index + 1))),
        note: note)
      draft.normalizeSinglePart()
      try TransactionRepository(writer: stack.writer).save(try draft.materialize())
    }
    return stack
  }
}

private struct NoSource: BackupSource {
  func backup(to destination: URL) throws { throw CocoaError(.fileWriteUnknown) }
  func integrityCheckPassed() throws -> Bool { true }
}

extension JSONEncoder {
  fileprivate static var iso: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}
