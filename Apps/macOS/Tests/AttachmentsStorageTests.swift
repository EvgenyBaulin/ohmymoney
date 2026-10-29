import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

// Synthetic data only.

/// The attached files in the places a copy of the book goes: the folder chosen for copies, and the
/// transfer archive. The rows are in the database wherever the database goes; the bytes travel
/// only where this says.
final class AttachmentsStorageTests: XCTestCase {
  private var directory: URL!
  private var stack: DatabaseStack!
  private var service: AttachmentService!
  private var owner: UUID!

  private var backupsFolder: URL { directory.appendingPathComponent("backups", isDirectory: true) }
  private var mirrorFolder: URL { directory.appendingPathComponent("iCloud", isDirectory: true) }

  private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-attachments-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    stack = try DatabaseStack(
      url: directory.appendingPathComponent("finance.sqlite"),
      schema: BundleSchemaSource(bundle: .main))
    var draft = TransactionDraft(amount: AmountE4(whole: 250), note: "synthetic")
    draft.normalizeSinglePart()
    let transaction = try draft.materialize()
    try TransactionRepository(writer: stack.writer).save(transaction)
    owner = transaction.transaction.id
    service = AttachmentService(
      repository: AttachmentRepository(writer: stack.writer),
      store: AttachmentFileStore(
        root: directory.appendingPathComponent("Attachments", isDirectory: true)))
  }

  override func tearDownWithError() throws {
    service = nil
    stack = nil
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  private func backups(mirrorsFiles: Bool = true) -> BackupService {
    var policy = BackupService.Policy()
    policy.calendar = utc
    policy.languageCode = { "en" }
    policy.freeBytes = { _ in 50_000_000_000 }
    return BackupService(stack: stack, directory: backupsFolder, policy: policy)
  }

  private func day(_ month: Int, _ day: Int) -> Date {
    utc.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
  }

  @discardableResult
  private func attach(_ text: String) throws -> AttachedFile {
    try service.add(
      data: Data(text.utf8), fileName: "\(text).jpg", to: .transaction, id: owner,
      kind: .receipt)
  }

  private func mirrored(_ file: AttachedFile) -> URL {
    AttachmentMirror(chosenFolder: mirrorFolder).folder
      .appendingPathComponent(AttachmentHash.relativePath(for: file.contentHash)!)
  }

  // MARK: The folder chosen for copies

  func testTheCopyOfTheDayTakesTheFilesToTheMirrorOnceEach() async throws {
    let first = try attach("first")
    let second = try attach("second")
    try FileManager.default.createDirectory(at: mirrorFolder, withIntermediateDirectories: true)
    let service = backups()
    let store = self.service.store
    await service.setAttachments(store) { true }
    await service.setMirror(mirrorFolder)

    // The files go to the mirror as soon as the folder and the store are both known; a copy
    // after a change does not go to the mirror, only its files do.
    XCTAssertTrue(FileManager.default.fileExists(atPath: mirrored(first).path))
    _ = try await service.writeBackup(now: day(10, 4))

    _ = try await service.writeBackup(now: day(10, 5), label: "daily")
    XCTAssertEqual(try Data(contentsOf: mirrored(first)), Data("first".utf8))
    XCTAssertEqual(try Data(contentsOf: mirrored(second)), Data("second".utf8))

    // The next copy of a day writes nothing again: the file is there.
    let stamp = try FileManager.default.attributesOfItem(atPath: mirrored(first).path)[
      .modificationDate] as? Date
    _ = try await service.writeBackup(now: day(10, 6), label: "daily")
    XCTAssertEqual(
      try FileManager.default.attributesOfItem(atPath: mirrored(first).path)[.modificationDate]
        as? Date, stamp)
    // A file added since is carried, the earlier ones are not copied again.
    let third = try attach("third")
    let outcome = await service.mirrorAttachmentFiles()
    XCTAssertEqual(outcome?.copied, 1)
    XCTAssertEqual(outcome?.alreadyThere, 2)
    XCTAssertTrue(FileManager.default.fileExists(atPath: mirrored(third).path))
  }

  func testTheOwnerCanLeaveTheFilesOutOfTheMirror() async throws {
    let file = try attach("kept at home")
    try FileManager.default.createDirectory(at: mirrorFolder, withIntermediateDirectories: true)
    let service = backups()
    await service.setAttachments(self.service.store) { false }
    await service.setMirror(mirrorFolder)
    _ = try await service.writeBackup(now: day(10, 5), label: "daily")
    XCTAssertFalse(FileManager.default.fileExists(atPath: mirrored(file).path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: mirrorFolder.appendingPathComponent(AttachmentMirror.folderName).path))
  }

  func testTheCopiesBeforeAnUpdateBringTheFilesToo() async throws {
    let file = try attach("before the update")
    _ = try BackupService.copyBeforeMigration(
      of: stack.url, into: backupsFolder, now: day(10, 1))
    try FileManager.default.createDirectory(at: mirrorFolder, withIntermediateDirectories: true)
    let service = backups()
    await service.setAttachments(self.service.store) { true }
    await service.setMirror(mirrorFolder)
    XCTAssertTrue(FileManager.default.fileExists(atPath: mirrored(file).path))
  }

  func testAMacSetUpFromTheMirrorPullsTheFilesBack() throws {
    let file = try attach("only in the cloud now")
    let mirror = AttachmentMirror(chosenFolder: mirrorFolder)
    XCTAssertEqual(mirror.push(from: service.store).copied, 1)
    try service.store.remove(hash: file.contentHash)
    XCTAssertFalse(service.store.contains(hash: file.contentHash))
    let outcome = mirror.pull(into: service.store)
    XCTAssertEqual(outcome.copied, 1)
    XCTAssertEqual(try service.store.data(forHash: file.contentHash), Data("only in the cloud now".utf8))
    // A file whose content does not match its name is not taken.
    let bad = mirror.folder.appendingPathComponent(
      AttachmentHash.relativePath(for: String(repeating: "c", count: 64))!)
    try FileManager.default.createDirectory(
      at: bad.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("tampered".utf8).write(to: bad)
    XCTAssertEqual(mirror.pull(into: service.store).failed, 1)
    XCTAssertFalse(service.store.contains(hash: String(repeating: "c", count: 64)))
  }

  // MARK: The transfer archive

  private func archives(iterations: Int = 1_000) -> ArchiveService {
    ArchiveService(
      stack: stack, appVersion: "2.4.0", iterations: iterations, attachmentStore: service.store)
  }

  func testTheArchiveCarriesTheFilesAndAnotherMacRestoresThem() throws {
    let a = try attach("alpha")
    let b = try attach("beta")
    _ = try attach("alpha")  // the same content again: one entry
    let url = directory.appendingPathComponent("with.ohmymoneyarchive")
    _ = try archives().exportArchive(to: url)
    let opened = try archives().openArchive(at: url)
    XCTAssertEqual(opened.manifest.formatVersion, 1)
    XCTAssertEqual(Set(opened.attachmentHashes), [a.contentHash, b.contentHash])
    XCTAssertEqual(opened.attachmentHashes.count, 2)

    // Another Mac: an empty folder.
    let other = AttachmentFileStore(root: directory.appendingPathComponent("Other"))
    let there = ArchiveService(stack: stack, appVersion: "2.4.0", attachmentStore: other)
    let result = there.restoreAttachments(from: opened)
    XCTAssertEqual(result.restored, 2)
    XCTAssertEqual(result.refused, 0)
    XCTAssertEqual(try other.data(forHash: a.contentHash), Data("alpha".utf8))
  }

  func testTheOwnerCanLeaveTheFilesOutOfTheArchive() throws {
    try attach("alpha")
    let url = directory.appendingPathComponent("without.ohmymoneyarchive")
    _ = try archives().exportArchive(to: url, attachments: .leaveOut)
    XCTAssertTrue(try archives().openArchive(at: url).attachmentHashes.isEmpty)

    // The setting does the same without being told.
    var settings = try service.repository.settings()
    settings.withAttachmentsInArchive = false
    try service.repository.save(settings)
    let bySetting = directory.appendingPathComponent("by-setting.ohmymoneyarchive")
    _ = try archives().exportArchive(to: bySetting)
    XCTAssertTrue(try archives().openArchive(at: bySetting).attachmentHashes.isEmpty)
    // And an explicit yes beats the setting.
    let forced = directory.appendingPathComponent("forced.ohmymoneyarchive")
    _ = try archives().exportArchive(to: forced, attachments: .include)
    XCTAssertEqual(try archives().openArchive(at: forced).attachmentHashes.count, 1)
  }

  func testAnArchiveWithoutFilesOpensAndRestoresNothing() throws {
    let plain = ArchiveService(stack: stack, appVersion: "2.3.0")
    let url = directory.appendingPathComponent("older.ohmymoneyarchive")
    _ = try plain.exportArchive(to: url)
    let opened = try archives().openArchive(at: url)
    XCTAssertTrue(opened.attachmentHashes.isEmpty)
    XCTAssertTrue(opened.database != nil)
    let result = archives().restoreAttachments(from: opened)
    XCTAssertEqual(result.restored, 0)
    XCTAssertEqual(result.refused, 0)
  }

  func testAnEncryptedArchiveCarriesTheFilesToo() throws {
    let file = try attach("secret receipt")
    let url = directory.appendingPathComponent("sealed.ohmymoneyarchive")
    _ = try archives().exportArchive(to: url, password: "пароль")
    let opened = try archives().openArchive(at: url, password: "пароль")
    XCTAssertEqual(opened.attachmentHashes, [file.contentHash])
    // The file is not readable in the sealed container.
    let raw = try Data(contentsOf: url)
    XCTAssertNil(raw.range(of: Data("secret receipt".utf8)))
  }

  func testTheSizeIsKnownBeforeTheArchiveIsWritten() throws {
    try attach("one")
    try attach("two")
    let plan = try archives().attachmentPlan()
    XCTAssertEqual(plan.included.count, 2)
    XCTAssertEqual(plan.includedBytes, 6)
    XCTAssertTrue(plan.isComplete)
  }

  func testAFileThatIsNotInTheFolderIsLeftOutOfTheArchiveWithoutAnError() throws {
    let file = try attach("gone")
    try service.store.remove(hash: file.contentHash)
    let url = directory.appendingPathComponent("gap.ohmymoneyarchive")
    XCTAssertNoThrow(try archives().exportArchive(to: url))
    XCTAssertTrue(try archives().openArchive(at: url).attachmentHashes.isEmpty)
  }
}
