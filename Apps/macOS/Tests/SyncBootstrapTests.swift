import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Загрузить данные из папки»: what the screen is told and says. Synthetic data only.
@MainActor
final class SyncBootstrapTests: XCTestCase {
  @MainActor
  private final class Silent: SyncNotifying {
    func conflictsAppeared(count: Int, title: String, body: String) {}
  }

  private var folder: URL!
  private var stacks: [DatabaseStack] = []
  private var keys: [String] = []

  override func setUp() async throws {
    folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("sync-bootstrap-ui-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    for key in keys { UserDefaults.standard.removeObject(forKey: key) }
    try? FileManager.default.removeItem(at: folder)
    for stack in stacks { try? stack.close() }
    stacks = []
    keys = []
  }

  private func coordinator(_ device: String, stack: DatabaseStack) throws -> SyncCoordinator {
    let key = "tests.sync.bootstrap.ui.\(UUID().uuidString)"
    keys.append(key)
    let exchange = try SyncExchange(writer: stack.writer, deviceId: device, deviceName: device)
    return SyncCoordinator(
      exchange: exchange, bookmarks: BookmarkStore(key: key), notifier: Silent())
  }

  private func makeStack() throws -> DatabaseStack {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    stacks.append(stack)
    return stack
  }

  private func owner(_ stack: DatabaseStack) throws {
    var draft = TransactionDraft(
      kind: .expense, occurredAt: Date(timeIntervalSince1970: 1_789_000_000),
      amount: AmountE4(whole: 250), note: "coffee")
    draft.normalizeSinglePart()
    try TransactionRepository(writer: stack.writer).save(try draft.materialize())
  }

  // MARK: The words

  func testEveryAnswerHasItsOwnKeyInBothLanguages() throws {
    let results: [SyncCoordinator.BootstrapResult] = [
      .staged, .notConfigured, .notEmpty, .noSnapshot, .damaged, .newerVersion, .failed,
    ]
    let keys = results.map(SyncBootstrapText.messageKey(for:))
    XCTAssertEqual(Set(keys).count, results.count)
    let language = AppLanguage()
    let original = language.choice
    defer { language.choice = original }
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      for key in keys + [
        "sync.bootstrap.title", "sync.bootstrap.explain", "sync.bootstrap.load",
        "sync.bootstrap.restart", "sync.bootstrap.reopen", "sync.bootstrap.loading",
        "sync.status.snapshot",
      ] {
        let text = language(key, table: ConflictText.table)
        XCTAssertNotEqual(text, key, "\(key) has no \(choice.rawValue) text")
      }
    }
  }

  func testWhatEachStateDrawsAndOffers() {
    let offer = SyncSnapshotOffer(madeAt: Date(), deviceId: "abcdef0123456789")
    XCTAssertEqual(offer.deviceLabel, "abcdef01")
    XCTAssertFalse(SyncBootstrapText.isVisible(.idle))
    XCTAssertTrue(SyncBootstrapText.isVisible(.offered(offer)))
    XCTAssertTrue(SyncBootstrapText.offersLoad(.offered(offer)))
    XCTAssertFalse(SyncBootstrapText.offersLoad(.loading))
    XCTAssertFalse(SyncBootstrapText.offersLoad(.staged))
    XCTAssertTrue(SyncBootstrapText.offersLoad(.result(.failed)), "a failed try can be repeated")
    XCTAssertTrue(SyncBootstrapText.offersLoad(.result(.damaged)))
    XCTAssertFalse(SyncBootstrapText.offersLoad(.result(.notEmpty)))
    XCTAssertFalse(SyncBootstrapText.offersLoad(.result(.newerVersion)))
    XCTAssertTrue(SyncBootstrapText.asksRestart(.staged))
    XCTAssertFalse(SyncBootstrapText.asksRestart(.result(.failed)))
    XCTAssertEqual(SyncBootstrapText.messageKey(for: .staged), "sync.bootstrap.staged")
    XCTAssertNil(SyncBootstrapText.messageKey(for: .offered(offer)))
    XCTAssertNil(SyncBootstrapText.messageKey(for: .loading))
  }

  func testTheStatusRowTellsWhatWasSeededAndSnapshotted() {
    let environment = AppEnvironment()
    XCTAssertEqual(ConflictText.outcomeLines(nil, environment), [])
    var outcome = SyncOutcome()
    XCTAssertEqual(ConflictText.outcomeLines(outcome, environment), [])
    outcome.rowsSeeded = 3
    outcome.snapshotWritten = true
    XCTAssertEqual(ConflictText.outcomeLines(outcome, environment).count, 2)
  }

  // MARK: The coordinator

  func testAnEmptyDeviceIsOfferedTheSnapshotAndATryStagesIt() async throws {
    let macStack = try makeStack()
    try owner(macStack)
    let mac = try coordinator("mac", stack: macStack)
    XCTAssertEqual(mac.choose(folder: folder), .accepted)
    await mac.syncNow()

    let phoneStack = try makeStack()
    let phone = try coordinator("phone", stack: phoneStack)
    await phone.lookForSnapshot()
    XCTAssertEqual(phone.bootstrap, .idle, "no folder: nothing is offered")
    // No exchange of its own yet: it would race the offer by filling the empty device.
    XCTAssertEqual(phone.choose(folder: folder, thenSync: false), .accepted)
    await phone.lookForSnapshot()
    guard case .offered(let offer) = phone.bootstrap else {
      return XCTFail("expected an offer, got \(phone.bootstrap)")
    }
    XCTAssertEqual(offer.deviceId, "mac")

    // Without a way to copy the current state first, nothing is staged.
    await phone.loadSnapshot(backups: nil)
    XCTAssertEqual(phone.bootstrap, .result(.failed))
    XCTAssertTrue(SyncBootstrapText.offersLoad(phone.bootstrap))

    let work = folder.appendingPathComponent("work", isDirectory: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let backups = BackupService(stack: phoneStack, directory: work.appendingPathComponent("b"))
    let target = work.appendingPathComponent("pending.sqlite")
    await phone.loadSnapshot(
      backups: backups, schema: BundleSchemaSource(bundle: .main), target: target)
    XCTAssertEqual(phone.bootstrap, .staged)
    XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    XCTAssertTrue(SyncBootstrapText.asksRestart(phone.bootstrap))
    await phone.lookForSnapshot()
    XCTAssertEqual(phone.bootstrap, .staged, "a staged copy stays staged until the restart")
  }

  func testADeviceWithRecordsIsOfferedNothing() async throws {
    let macStack = try makeStack()
    try owner(macStack)
    let mac = try coordinator("mac", stack: macStack)
    XCTAssertEqual(mac.choose(folder: folder), .accepted)
    await mac.syncNow()

    let busyStack = try makeStack()
    try owner(busyStack)
    let busy = try coordinator("busy", stack: busyStack)
    XCTAssertEqual(busy.choose(folder: folder), .accepted)
    await busy.lookForSnapshot()
    XCTAssertEqual(busy.bootstrap, .idle)
  }

  func testAFolderWithoutASnapshotSaysSo() async throws {
    let shared = folder.appendingPathComponent("empty", isDirectory: true)
    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
    let phone = try coordinator("phone", stack: try makeStack())
    XCTAssertEqual(phone.choose(folder: shared), .accepted)
    await phone.lookForSnapshot()
    XCTAssertEqual(phone.bootstrap, .result(.noSnapshot))
    XCTAssertEqual(
      SyncBootstrapText.messageKey(for: phone.bootstrap), "sync.bootstrap.noSnapshot")
  }
}
