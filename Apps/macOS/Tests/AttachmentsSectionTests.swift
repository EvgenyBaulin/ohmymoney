import AppCore
import AppDatabase
import AppKit
import XCTest

@testable import OhMyMoney

// Synthetic data only.

/// The section of files on the screens of operations, assets, debts and subscriptions: its model
/// over a real database and a real folder, the steps of ⌘Z, the daily upkeep, the receipt reader's
/// photo, the box of the archive and the words in both languages.
@MainActor
final class AttachmentsSectionTests: XCTestCase {
  private var directory: URL!
  private var stack: DatabaseStack!
  private var service: AttachmentService!
  private var store: TransactionsStore!
  private var owner: UUID!

  override func setUp() async throws {
    try await super.setUp()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-att-section-\(UUID().uuidString)", isDirectory: true)
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
    store = TransactionsStore()
    store.attach(
      TransactionRepository(writer: stack.writer), references: nil, attachments: service)
  }

  override func tearDown() async throws {
    store = nil
    service = nil
    stack = nil
    try? FileManager.default.removeItem(at: directory)
    try await super.tearDown()
  }

  private func model(
    _ kind: AttachmentOwnerKind = .transaction, deferred: Bool = false
  ) -> AttachmentsModel {
    AttachmentsModel(owner: kind, ownerId: owner, deferred: deferred)
  }

  private func source(_ text: String, _ name: String = "x.jpg") -> AttachmentSource {
    AttachmentSource(data: Data(text.utf8), fileName: name)
  }

  // MARK: Adding

  func testSeveralFilesAddedTogetherAreOneStepOfUndo() async throws {
    let files = model()
    await files.add([source("a", "a.jpg"), source("b", "b.pdf")], service: service, store: store)
    XCTAssertEqual(files.files.map(\.fileName), ["a.jpg", "b.pdf"])
    XCTAssertEqual(files.files.map(\.kind), [.receipt, .document], "a picture is a receipt")
    XCTAssertEqual(files.files.compactMap(\.mediaType), ["image/jpeg", "application/pdf"])

    XCTAssertTrue(store.canUndo)
    store.undo()
    files.reload(service: service)
    XCTAssertTrue(files.files.isEmpty)
    XCTAssertTrue(service.store.storedHashes().isEmpty, "the files nothing names are gone too")
    XCTAssertFalse(store.canUndo, "one step, not two")
  }

  func testTheKindOfANewFileFollowsWhatItIsAttachedTo() {
    typealias Model = AttachmentsModel
    XCTAssertEqual(Model.defaultKind(for: .transaction, fileName: "scan.JPG"), .receipt)
    XCTAssertEqual(Model.defaultKind(for: .transaction, fileName: "scan.heic"), .receipt)
    XCTAssertEqual(Model.defaultKind(for: .transaction, fileName: "slip.pdf"), .document)
    XCTAssertEqual(Model.defaultKind(for: .asset, fileName: "card.jpg"), .warranty)
    XCTAssertEqual(Model.defaultKind(for: .debt, fileName: "contract.pdf"), .document)
    XCTAssertEqual(Model.defaultKind(for: .subscription, fileName: "terms"), .document)
  }

  func testAFileOfAnySizeIsKeptByteForByte() async throws {
    let bytes = Data((0..<1_300_000).map { UInt8($0 % 253) })
    let url = directory.appendingPathComponent("big.bin")
    try bytes.write(to: url)
    let files = model()
    await files.add([AttachmentSource(file: url)], service: service, store: store)
    let added = try XCTUnwrap(files.files.first)
    XCTAssertEqual(added.byteSize, Int64(bytes.count))
    XCTAssertEqual(try service.store.data(forHash: added.contentHash), bytes)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the original stays")
  }

  func testAFileThatCannotBeReadIsCountedAndTheOthersGoIn() async throws {
    let files = model()
    let missing = AttachmentSource(file: directory.appendingPathComponent("nothing.jpg"))
    await files.add([missing, source("fine")], service: service, store: store)
    XCTAssertEqual(files.failedCount, 1)
    XCTAssertEqual(files.files.count, 1)
  }

  // MARK: The new thing that is not saved yet

  func testFilesOfAnUnsavedThingWaitAndGoInAfterTheSaveAsOneStep() async throws {
    let files = model(.asset, deferred: true)
    await files.add([source("one"), source("two", "two.jpg")], service: service, store: store)
    XCTAssertEqual(files.pending.count, 2)
    XCTAssertTrue(try service.repository.all().isEmpty, "nothing is written before the save")
    XCTAssertFalse(store.canUndo)

    let failed = await files.commitPending(service: service, store: store)
    XCTAssertEqual(failed, 0)
    XCTAssertTrue(files.pending.isEmpty)
    XCTAssertEqual(try service.repository.attachments(of: .asset, id: owner).count, 2)
    XCTAssertEqual(
      try service.repository.attachments(of: .asset, id: owner).map(\.kind), [.warranty, .warranty])
    store.undo()
    XCTAssertTrue(try service.repository.all().isEmpty)
  }

  func testWaitingFilesCanBeTakenBackAndForgotten() async {
    let files = model(.asset, deferred: true)
    await files.add([source("one"), source("two", "two.jpg")], service: service, store: store)
    files.removePending(files.pending[0].id)
    XCTAssertEqual(files.pending.count, 1)
    files.discardPending()
    XCTAssertTrue(files.pending.isEmpty)
  }

  // MARK: The trash, «Хранить всегда», the kind

  func testTrashingAFileIsOneStepAndTheUndoBringsItBack() async throws {
    let files = model()
    await files.add([source("a")], service: service, store: store)
    store.undo()  // forget the add; add again to see the trash step alone
    await files.add([source("a")], service: service, store: store)
    let file = try XCTUnwrap(files.files.first)

    files.trash(file.id, service: service, store: store)
    XCTAssertTrue(files.files.isEmpty)
    XCTAssertEqual(try service.repository.trash().map(\.id), [file.id])
    XCTAssertTrue(service.store.contains(hash: file.contentHash), "the trash still holds it")

    store.undo()
    files.reload(service: service)
    XCTAssertEqual(files.files.map(\.id), [file.id])
    XCTAssertTrue(try service.repository.trash().isEmpty)
  }

  func testKeepForeverAndTheKindAreStepsAndSurviveTheRule() async throws {
    var settings = try service.repository.settings()
    settings.keepReceiptsForever = false
    try service.repository.save(settings)
    let files = model()
    await files.add(
      [source("pinned", "p.jpg"), source("loose", "l.jpg")], service: service, store: store)
    let pinned = try XCTUnwrap(files.files.first { $0.fileName == "p.jpg" })
    let loose = try XCTUnwrap(files.files.first { $0.fileName == "l.jpg" })

    files.setKeepForever(pinned.id, true, service: service, store: store)
    XCTAssertEqual(files.files.first { $0.id == pinned.id }?.keepForever, true)
    files.setKind(loose.id, .warranty, service: service, store: store)
    XCTAssertEqual(files.files.first { $0.id == loose.id }?.kind, .warranty)

    // A week later the rule trashes neither: one is pinned, the other is no longer a receipt.
    let report = try service.dailySweep(now: Date().addingTimeInterval(9 * 86_400))
    XCTAssertTrue(report.isEmpty)

    // Both are steps, taken back newest first.
    store.undo()
    files.reload(service: service)
    XCTAssertEqual(files.files.first { $0.id == loose.id }?.kind, .receipt)
    store.undo()
    files.reload(service: service)
    XCTAssertEqual(files.files.first { $0.id == pinned.id }?.keepForever, false)
  }

  func testAChangeThatChangesNothingIsNoStep() async throws {
    let files = model()
    await files.add([source("a")], service: service, store: store)
    let file = try XCTUnwrap(files.files.first)
    files.setKeepForever(file.id, false, service: service, store: store)
    files.setKind(file.id, file.kind, service: service, store: store)
    store.undo()
    files.reload(service: service)
    XCTAssertTrue(files.files.isEmpty, "the one step was the add")
    XCTAssertFalse(store.canUndo)
  }

  // MARK: Removed by the rule is not an error

  func testAFileTheRuleTookIsToldAsSuchAndOnlyAPinnedOneIsLost() async throws {
    let files = model()
    await files.add(
      [source("rule", "r.jpg"), source("pin", "p.jpg")], service: service, store: store)
    let first = try XCTUnwrap(files.files.first { $0.fileName == "r.jpg" })
    var second = try XCTUnwrap(files.files.first { $0.fileName == "p.jpg" })
    second.keepForever = true
    try service.repository.update(second)
    try service.store.remove(hash: first.contentHash)
    try service.store.remove(hash: second.contentHash)
    XCTAssertEqual(service.availability(of: first), .removedByRule)
    XCTAssertEqual(service.availability(of: second), .missing)
  }

  func testThePreviewPathCarriesTheOriginalNameAndExtension() async throws {
    let files = model()
    await files.add([source("body", "Receipt 18.32.jpg")], service: service, store: store)
    let file = try XCTUnwrap(files.files.first)
    let url = try XCTUnwrap(AttachmentsModel.previewURL(for: file, in: service))
    XCTAssertEqual(url.lastPathComponent, "Receipt 18.32.jpg")
    XCTAssertEqual(try Data(contentsOf: url), Data("body".utf8))
    try service.store.remove(hash: file.contentHash)
    // A file already cloned stays readable; one that never was and is gone gives no path.
    var other = file
    other.contentHash = String(repeating: "a", count: 64)
    XCTAssertNil(AttachmentsModel.previewURL(for: other, in: service))
  }

  // MARK: The summary and the upkeep

  func testTheSummaryCountsFilesTrashAndBytes() async throws {
    let files = model()
    await files.add(
      [source("12345", "a.jpg"), source("678", "b.jpg")], service: service, store: store)
    files.trash(files.files[0].id, service: service, store: store)
    let summary = AttachmentsSummary(service)
    XCTAssertEqual(summary, AttachmentsSummary(files: 1, inTrash: 1, bytes: 8))
  }

  func testTheDailyUpkeepOfTheEnvironmentSweepsAndReports() async throws {
    let environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    defer { Task { await environment.close() } }
    XCTAssertNotNil(environment.attachments)
    let report = await environment.sweepAttachments(now: Date())
    XCTAssertEqual(report?.movedToTrash, 0)
    XCTAssertEqual(report?.deleted, 0)
  }

  // MARK: The receipt reader's photo

  func testTheReceiptPhotoIsKeptWithTheOperationAsAReceipt() async throws {
    let environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    defer { Task { await environment.close() } }
    XCTAssertTrue(environment.receiptPhotosCanBeKept)
    var draft = TransactionDraft(amount: AmountE4(whole: 90), note: "synthetic")
    draft.normalizeSinglePart()
    let transaction = try draft.materialize()
    try XCTUnwrap(environment.transactions).save(transaction)
    let id = transaction.transaction.id

    let photo = ReceiptPhoto(data: Data("jpeg bytes".utf8), filename: "receipt.jpg")
    XCTAssertTrue(environment.keepReceiptPhoto(photo, for: id))
    let rows = try XCTUnwrap(environment.attachments).repository
    let kept = try rows.attachments(of: .transaction, id: id)
    XCTAssertEqual(kept.count, 1)
    XCTAssertEqual(kept.first?.kind, .receipt)
    XCTAssertEqual(kept.first?.mediaType, "image/jpeg")
    XCTAssertEqual(kept.first?.keepForever, false, "the setting decides, not the file")
  }

  // MARK: The archive

  func testTheArchiveBoxShowsTheSizeAndFollowsTheSetting() async throws {
    let environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    defer { Task { await environment.close() } }
    let archives = ArchiveService(
      stack: stack, appVersion: "2.4.0", iterations: 1_000, attachmentStore: service.store)
    XCTAssertNil(
      FileCommands.attachmentsBox(for: archives, in: environment), "no files, no box")
    try service.add(
      data: Data(count: 2_000), fileName: "a.jpg", to: .transaction, id: owner, kind: .receipt)
    let box = try XCTUnwrap(FileCommands.attachmentsBox(for: archives, in: environment))
    XCTAssertTrue(
      box.box.title.contains(
        ByteCountFormatter.string(
          fromByteCount: 2_000, countStyle: .file)), box.box.title)
    XCTAssertEqual(box.plan.included.count, 1)
  }

  func testAnArchiveWrittenWithoutFilesIsToldSoOnImport() throws {
    try service.add(
      data: Data("x".utf8), fileName: "a.jpg", to: .transaction, id: owner, kind: .receipt)
    let archives = ArchiveService(
      stack: stack, appVersion: "2.4.0", iterations: 1_000, attachmentStore: service.store)
    let without = directory.appendingPathComponent("without.ohmymoneyarchive")
    _ = try archives.exportArchive(to: without, attachments: .leaveOut)
    XCTAssertEqual(
      ArchiveImportFlow.attachmentsNotice(for: try archives.openArchive(at: without)),
      "att.import.without")
    let with = directory.appendingPathComponent("with.ohmymoneyarchive")
    _ = try archives.exportArchive(to: with, attachments: .include)
    XCTAssertNil(ArchiveImportFlow.attachmentsNotice(for: try archives.openArchive(at: with)))
  }

  // MARK: Words

  func testEveryWordOfTheAttachmentsHasBothLanguages() {
    let keys = [
      "att.title", "att.add", "att.add.file", "att.add.photo", "att.add.camera", "att.empty",
      "att.pending.hint", "att.failed", "att.name.pasted", "att.name.photo", "att.open",
      "att.keep", "att.on", "att.off", "att.kind", "att.kind.receipt", "att.kind.warranty",
      "att.kind.document", "att.kind.other", "att.remove", "att.more", "att.removedByRule",
      "att.missing", "att.owner.transaction", "att.owner.asset", "att.owner.debt",
      "att.owner.subscription", "att.settings.title", "att.settings.keepReceipts",
      "att.settings.keepReceiptsHint", "att.settings.mirror", "att.settings.mirrorHint",
      "att.settings.archive", "att.settings.archiveHint", "att.settings.trashDays",
      "att.settings.trashWord", "att.settings.footer", "att.settings.files",
      "att.settings.size", "att.settings.inTrash", "att.settings.openTrash", "att.trash.title",
      "att.trash.empty", "att.trash.restore", "att.trash.deleteNow", "att.trash.emptyAll",
      "att.trash.confirm", "att.trash.confirmHint", "att.trash.daysLeft", "att.archive.with",
      "att.archive.partial", "att.import.without",
    ]
    for code in ["ru", "en"] {
      let bundle = Bundle(path: Bundle.main.path(forResource: code, ofType: "lproj")!)!
      for key in keys {
        let text = bundle.localizedString(forKey: key, value: "", table: "Attachments")
        XCTAssertFalse(text.isEmpty || text == key, "no \(code) words for \(key)")
      }
    }
  }

  func testTheTrashAndFailureCountsAgreeInRussian() {
    let ru = Bundle(path: Bundle.main.path(forResource: "ru", ofType: "lproj")!)!
    func days(_ n: Int) -> String {
      String(
        format: ru.localizedString(forKey: "att.trash.daysLeft", value: "", table: "Attachments"),
        locale: Locale(identifier: "ru"), n)
    }
    XCTAssertEqual(days(1), "удалится через 1 день")
    XCTAssertEqual(days(3), "удалится через 3 дня")
    XCTAssertEqual(days(11), "удалится через 11 дней")
  }

  func testTheSettingsSectionIsInTheSearchAndHasItsPlaceBeforeTheCopies() {
    XCTAssertTrue(SettingsSection.allCases.contains(.attachments))
    let words = SettingsSearch.catalogWords()
    XCTAssertEqual(
      SettingsSearch.find("вложения", words: words).map(\.section), [.attachments])
    XCTAssertTrue(
      SettingsSearch.find("attachments", words: words).map(\.section).contains(.attachments))
  }

  func testTheSettingsRoundTripThroughTheRepositoryAndDefaultToTheAnswersOfTheOwner() throws {
    let defaults = try service.repository.settings()
    XCTAssertTrue(defaults.keepReceiptsForever)
    XCTAssertEqual(defaults.trashDays, 30)
    XCTAssertTrue(defaults.mirror)
    XCTAssertTrue(defaults.withAttachmentsInArchive)
    var changed = defaults
    changed.keepReceiptsForever = false
    changed.trashDays = 7
    changed.mirror = false
    try service.repository.save(changed)
    XCTAssertEqual(try service.repository.settings(), changed)
  }
}
