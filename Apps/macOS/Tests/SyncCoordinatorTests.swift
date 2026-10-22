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
    XCTAssertEqual(coordinator.choose(folder: folder, thenSync: false), .refused, "a folder that holds them")
    XCTAssertFalse(coordinator.hasFolder, "a refused folder is not remembered")
  }

  func testAChosenFolderCarriesTheChangesOutAndTheStatusSaysSo() async throws {
    let stack = try makeStack()
    let coordinator = try makeCoordinator(device: "mac", stack: stack)
    try TransactionRepository(writer: stack.writer).save(try entry("coffee"))
    XCTAssertEqual(coordinator.choose(folder: folder, thenSync: false), .accepted)
    await coordinator.syncNow()
    guard case .synced = coordinator.status else {
      return XCTFail("status \(coordinator.status)")
    }
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    XCTAssertEqual(
      names,
      [
        SyncFormat.fileName(deviceId: "mac", sequence: 0),
        SyncSnapshotName.fileName(deviceId: "mac"),
      ]
      .sorted(), "the journal and the copy of the whole database, nothing else")
    coordinator.forgetFolder()
    XCTAssertEqual(coordinator.status, .notConfigured)
    XCTAssertFalse(coordinator.hasFolder)
  }

  func testAFolderThatIsGoneShowsTheFailureAndRetryDoesTheWorkLater() async throws {
    let stack = try makeStack()
    let coordinator = try makeCoordinator(device: "mac", stack: stack)
    try TransactionRepository(writer: stack.writer).save(try entry("coffee"))
    XCTAssertEqual(coordinator.choose(folder: folder, thenSync: false), .accepted)
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
    XCTAssertEqual(mac.choose(folder: folder, thenSync: false), .accepted)
    await mac.syncNow()
    // The phone shares the same folder through its own bookmark key.
    let phoneBookmarks = "tests.sync.phone.\(UUID().uuidString)"
    defer { UserDefaults.standard.removeObject(forKey: phoneBookmarks) }
    let phoneExchange = try XCTUnwrap(phone.exchange)
    let phoneOwner = SyncCoordinator(
      exchange: phoneExchange, bookmarks: BookmarkStore(key: phoneBookmarks), notifier: Notes())
    XCTAssertEqual(phoneOwner.choose(folder: folder, thenSync: false), .accepted)
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

  // MARK: Books that were there before the exchange

  private func phoneCoordinator(
    _ stack: DatabaseStack, bookmarkKey: String, notes: Notes = Notes()
  ) throws -> SyncCoordinator {
    let exchange = try SyncExchange(writer: stack.writer, deviceId: "phone", deviceName: "phone")
    try exchange.setRecording(true)
    return SyncCoordinator(
      exchange: exchange, bookmarks: BookmarkStore(key: bookmarkKey), notifier: notes)
  }

  func testBooksThatWereThereBeforeTheExchangeReachAnEmptyPhone() async throws {
    let macStack = try makeStack()
    // Written while nothing recorded: the way a restored or imported database holds its rows.
    let saved = try TransactionRepository(writer: macStack.writer).save(try entry("coffee"))
    let mac = try makeCoordinator(device: "mac", stack: macStack)
    XCTAssertEqual(mac.choose(folder: folder, thenSync: false), .accepted)
    await mac.syncNow()

    let phoneStack = try makeStack()
    let phoneKey = "tests.sync.phone.\(UUID().uuidString)"
    defer { UserDefaults.standard.removeObject(forKey: phoneKey) }
    let phone = try phoneCoordinator(phoneStack, bookmarkKey: phoneKey)
    XCTAssertEqual(phone.choose(folder: folder, thenSync: false), .accepted)
    await phone.syncNow()

    XCTAssertEqual(try note(of: saved.id, in: phoneStack), "coffee")
    XCTAssertTrue(mac.conflicts.isEmpty)
    XCTAssertTrue(phone.conflicts.isEmpty)
  }

  func testAReplacedDatabaseStartsTheExchangeOverAndTheMarkIsCleared() async throws {
    let suite = "tests.sync.replaced.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let stack = try makeStack()
    let exchange = try SyncExchange(writer: stack.writer, deviceId: "mac", deviceName: "mac")
    try exchange.setRecording(true)
    let coordinator = SyncCoordinator(
      exchange: exchange, bookmarks: BookmarkStore(key: key), notifier: Notes(),
      defaults: defaults)
    XCTAssertEqual(coordinator.choose(folder: folder, thenSync: false), .accepted)
    await coordinator.syncNow()
    XCTAssertTrue(exchange.isSeeded)

    // A restore put another database in place: rows of its own.
    let restored = try TransactionRepository(writer: stack.writer).save(try entry("restored"))
    defaults.set(true, forKey: SyncWiring.replacedKey)
    await coordinator.syncNow()

    XCTAssertNil(defaults.object(forKey: SyncWiring.replacedKey), "dealt with once")
    XCTAssertEqual(try exchange.pendingCount(), 0)
    let phoneStack = try makeStack()
    let phoneKey = "tests.sync.phone.\(UUID().uuidString)"
    defer { UserDefaults.standard.removeObject(forKey: phoneKey) }
    let phone = try phoneCoordinator(phoneStack, bookmarkKey: phoneKey)
    XCTAssertEqual(phone.choose(folder: folder, thenSync: false), .accepted)
    await phone.syncNow()
    XCTAssertEqual(try note(of: restored.id, in: phoneStack), "restored")
  }

  func testAnEmptyDeviceStagesTheFoldersSnapshotAndABusyOneRefuses() async throws {
    let macStack = try makeStack()
    try TransactionRepository(writer: macStack.writer).save(try entry("coffee"))
    let mac = try makeCoordinator(device: "mac", stack: macStack)
    XCTAssertEqual(mac.choose(folder: folder, thenSync: false), .accepted)
    await mac.syncNow()

    let suite = "tests.sync.bootstrap.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let work = FileManager.default.temporaryDirectory
      .appendingPathComponent("sync-bootstrap-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let phoneKey = "tests.sync.phone.\(UUID().uuidString)"
    defer { UserDefaults.standard.removeObject(forKey: phoneKey) }

    // A phone with books of its own is never replaced.
    let busyStack = try makeStack()
    try TransactionRepository(writer: busyStack.writer).save(try entry("mine"))
    let busyExchange = try SyncExchange(writer: busyStack.writer, deviceId: "busy", deviceName: "b")
    let busy = SyncCoordinator(
      exchange: busyExchange, bookmarks: BookmarkStore(key: phoneKey), notifier: Notes(),
      defaults: defaults)
    XCTAssertEqual(busy.choose(folder: folder, thenSync: false), .accepted)
    let busyBackups = BackupService(
      stack: busyStack, directory: work.appendingPathComponent("busy"))
    let refused = await busy.bootstrapFromSnapshot(
      backups: busyBackups, schema: BundleSchemaSource(bundle: .main),
      target: work.appendingPathComponent("busy.pending.sqlite"))
    XCTAssertEqual(refused, .notEmpty)
    XCTAssertFalse(defaults.bool(forKey: SyncWiring.bootstrapKey))

    // An empty one takes it: checked, the current state copied first, staged for the launch.
    let emptyStack = try DatabaseStack(
      url: work.appendingPathComponent("phone.sqlite"), schema: BundleSchemaSource(bundle: .main))
    let emptyExchange = try SyncExchange(
      writer: emptyStack.writer, deviceId: "phone", deviceName: "phone")
    let empty = SyncCoordinator(
      exchange: emptyExchange, bookmarks: BookmarkStore(key: phoneKey), notifier: Notes(),
      defaults: defaults)
    let backups = BackupService(stack: emptyStack, directory: work.appendingPathComponent("b"))
    let target = work.appendingPathComponent("phone.pending.sqlite")
    let staged = await empty.bootstrapFromSnapshot(
      backups: backups, schema: BundleSchemaSource(bundle: .main), target: target)
    XCTAssertEqual(staged, .staged)
    XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    XCTAssertTrue(defaults.bool(forKey: SyncWiring.bootstrapKey))
    let beforeRestore = try await backups.backups()
    XCTAssertEqual(beforeRestore.count, 1, "the state it had is copied first")
    let reopened = try DatabaseStack(url: target, schema: BundleSchemaSource(bundle: .main))
    defer { try? reopened.close() }
    XCTAssertEqual(try TransactionRepository(writer: reopened.writer).count(), 1)
    try emptyStack.close()
  }

  func testNoFolderAndNoSnapshotAreSaidNotThrown() async throws {
    let stack = try DatabaseStack(
      url: folder.appendingPathComponent("db/phone.sqlite"),
      schema: BundleSchemaSource(bundle: .main))
    defer { try? stack.close() }
    let backups = BackupService(stack: stack, directory: folder.appendingPathComponent("b"))
    let coordinator = try makeCoordinator(device: "phone", stack: try makeStack())
    let unconfigured = await coordinator.bootstrapFromSnapshot(
      backups: backups, schema: BundleSchemaSource(bundle: .main),
      target: folder.appendingPathComponent("x.pending.sqlite"))
    XCTAssertEqual(unconfigured, .notConfigured)
    let shared = folder.appendingPathComponent("shared", isDirectory: true)
    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
    XCTAssertEqual(coordinator.choose(folder: shared), .accepted)
    let none = await coordinator.bootstrapFromSnapshot(
      backups: backups, schema: BundleSchemaSource(bundle: .main),
      target: folder.appendingPathComponent("x.pending.sqlite"))
    XCTAssertEqual(none, .noSnapshot)
  }
}
