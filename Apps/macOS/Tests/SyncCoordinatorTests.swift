import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The exchange as the screens drive it: the folder, the status, «Повторить», the conflicts and
/// the choice. Synthetic data only.
@MainActor
final class SyncCoordinatorTests: XCTestCase {
  @MainActor
  private final class Notes: SyncNotifying {
    var counts: [Int] = []
    func conflictsAppeared(count: Int, title: String, body: String) { counts.append(count) }
  }

  private var key = ""
  private var folder: URL!
  private var stacks: [DatabaseStack] = []

  override func setUp() async throws {
    key = "tests.sync.folder.\(UUID().uuidString)"
    folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("sync-coordinator-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    UserDefaults.standard.removeObject(forKey: key)
    try? FileManager.default.removeItem(at: folder)
    for stack in stacks { try? stack.close() }
    stacks = []
  }

  private func makeStack() throws -> DatabaseStack {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    stacks.append(stack)
    return stack
  }

  private func makeCoordinator(
    device: String, stack: DatabaseStack, notes: Notes = Notes(), protected: [URL] = []
  ) throws -> SyncCoordinator {
    let exchange = try SyncExchange(writer: stack.writer, deviceId: device, deviceName: device)
    try exchange.setRecording(true)
    return SyncCoordinator(
      exchange: exchange, bookmarks: BookmarkStore(key: key), protectedFolders: { protected },
      notifier: notes)
  }

  private func entry(_ note: String) throws -> TransactionEntry {
    var draft = TransactionDraft(
      kind: .expense, occurredAt: Date(timeIntervalSince1970: 1_789_000_000),
      amount: AmountE4(whole: 250), note: note)
    draft.normalizeSinglePart()
    return try draft.materialize()
  }

  private func setNote(_ note: String, of id: UUID, in stack: DatabaseStack) throws {
    let repository = TransactionRepository(writer: stack.writer)
    var entry = try XCTUnwrap(try repository.entry(id: id))
    entry.transaction.note = note
    try repository.save(entry)
  }

  private func note(of id: UUID, in stack: DatabaseStack) throws -> String? {
    try TransactionRepository(writer: stack.writer).entry(id: id)?.transaction.note
  }

  func testADataSetNeverExchanges() async throws {
    let coordinator = SyncCoordinator(
      exchange: nil, bookmarks: BookmarkStore(key: key), notifier: Notes())
    XCTAssertFalse(coordinator.isAvailable)
    await coordinator.syncNow()
    XCTAssertEqual(coordinator.status, .notConfigured)
    XCTAssertTrue(coordinator.conflicts.isEmpty)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
  }

  func testNoFolderMeansNoExchange() async throws {
    let coordinator = try makeCoordinator(device: "mac", stack: try makeStack())
    await coordinator.syncNow()
    XCTAssertEqual(coordinator.status, .notConfigured)
    XCTAssertFalse(coordinator.hasFolder)
  }

  func testTheDatabaseAndItsCopiesAreRefusedAsTheFolder() throws {
    let support = folder.appendingPathComponent("Real", isDirectory: true)
    let backups = folder.appendingPathComponent("Backups", isDirectory: true)
    let coordinator = try makeCoordinator(
      device: "mac", stack: try makeStack(), protected: [support, backups])
    XCTAssertEqual(coordinator.choose(folder: support), .refused)
    XCTAssertEqual(coordinator.choose(folder: backups), .refused)
    XCTAssertEqual(coordinator.choose(folder: folder), .refused, "a folder that holds them")
    XCTAssertFalse(coordinator.hasFolder, "a refused folder is not remembered")
  }

  func testAChosenFolderCarriesTheChangesOutAndTheStatusSaysSo() async throws {
    let stack = try makeStack()
    let coordinator = try makeCoordinator(device: "mac", stack: stack)
    try TransactionRepository(writer: stack.writer).save(try entry("coffee"))
    XCTAssertEqual(coordinator.choose(folder: folder), .accepted)
    await coordinator.syncNow()
    guard case .synced = coordinator.status else {
      return XCTFail("status \(coordinator.status)")
    }
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    XCTAssertEqual(names, [SyncFormat.fileName(deviceId: "mac", sequence: 0)])
    coordinator.forgetFolder()
    XCTAssertEqual(coordinator.status, .notConfigured)
    XCTAssertFalse(coordinator.hasFolder)
  }

  func testAFolderThatIsGoneShowsTheFailureAndRetryDoesTheWorkLater() async throws {
    let stack = try makeStack()
    let coordinator = try makeCoordinator(device: "mac", stack: stack)
    try TransactionRepository(writer: stack.writer).save(try entry("coffee"))
    XCTAssertEqual(coordinator.choose(folder: folder), .accepted)
    try FileManager.default.removeItem(at: folder)
    await coordinator.syncNow()
    XCTAssertEqual(coordinator.status, .failed(.folderMissing))
    XCTAssertTrue(coordinator.status.offersRetry)
    XCTAssertEqual(SyncFailure.folderMissing.messageKey, "sync.error.folderMissing")
    // Nothing was lost: the change still waits.
    XCTAssertEqual(try coordinator.exchange?.pendingCount(), 2, "the operation and its part")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    await coordinator.retry()
    guard case .synced = coordinator.status else {
      return XCTFail("status \(coordinator.status)")
    }
    XCTAssertEqual(try coordinator.exchange?.pendingCount(), 0)
  }

  func testAConflictAppearsIsAnnouncedAndTheChoiceSettlesIt() async throws {
    let macStack = try makeStack()
    let phoneStack = try makeStack()
    let macNotes = Notes()
    let mac = try makeCoordinator(device: "mac", stack: macStack, notes: macNotes)
    let phone = try makeCoordinator(device: "phone", stack: phoneStack)
    let saved = try TransactionRepository(writer: macStack.writer).save(try entry("coffee"))
    let id = saved.id
    XCTAssertEqual(mac.choose(folder: folder), .accepted)
    await mac.syncNow()
    // The phone shares the same folder through its own bookmark key.
    let phoneBookmarks = "tests.sync.phone.\(UUID().uuidString)"
    defer { UserDefaults.standard.removeObject(forKey: phoneBookmarks) }
    let phoneExchange = try XCTUnwrap(phone.exchange)
    let phoneOwner = SyncCoordinator(
      exchange: phoneExchange, bookmarks: BookmarkStore(key: phoneBookmarks), notifier: Notes())
    XCTAssertEqual(phoneOwner.choose(folder: folder), .accepted)
    await phoneOwner.syncNow()

    try setNote("coffee 250", of: id, in: macStack)
    try setNote("coffee 300", of: id, in: phoneStack)
    await phoneOwner.syncNow()
    await mac.syncNow()
    XCTAssertEqual(mac.conflicts.count, 1)
    XCTAssertEqual(macNotes.counts, [1], "the owner is told once")
    await mac.syncNow()
    XCTAssertEqual(macNotes.counts, [1], "and not again for the same conflict")

    let conflict = try XCTUnwrap(mac.conflicts.first)
    await mac.takeTheirs(conflict)
    XCTAssertTrue(mac.conflicts.isEmpty)
    let note = try note(of: id, in: macStack)
    XCTAssertEqual(note, "coffee 300")
    await phoneOwner.syncNow()
    XCTAssertTrue(phoneOwner.conflicts.isEmpty)
  }
}
