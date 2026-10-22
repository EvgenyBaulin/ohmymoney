import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// How the exchange is put into the app: only the real database gets a coordinator and records
/// changes, the device keeps one identity on this device, the folders of the books are
/// protected, a burst of changes makes one exchange, and «Конфликты» is a row of «Ещё» only
/// while something waits. Synthetic data only.
@MainActor
final class SyncWiringTests: XCTestCase {
  @MainActor
  private final class Silent: SyncNotifying {
    func conflictsAppeared(count: Int, title: String, body: String) {}
  }

  private var key = ""
  private var suite = ""
  private var defaults: UserDefaults!
  private var folder: URL!
  private var stacks: [DatabaseStack] = []

  override func setUp() async throws {
    key = "tests.sync.wiring.\(UUID().uuidString)"
    suite = "tests.sync.wiring.defaults.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
    folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("sync-wiring-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    UserDefaults.standard.removeObject(forKey: key)
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: folder)
    for stack in stacks { try? stack.close() }
    stacks = []
  }

  private func makeStack() throws -> DatabaseStack {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    stacks.append(stack)
    return stack
  }

  private func wired(real: Bool, stack: DatabaseStack) -> AppEnvironment {
    let environment = AppEnvironment()
    environment.wireSync(
      writer: stack.writer, isRealDatabase: real, defaults: defaults,
      bookmarks: BookmarkStore(key: key), notifier: Silent())
    return environment
  }

  func testADataSetOrADemoGetsNoCoordinatorAndRecordsNothing() throws {
    let stack = try makeStack()
    let environment = wired(real: false, stack: stack)
    XCTAssertNil(environment.sync)
    let probe = try SyncExchange(writer: stack.writer, deviceId: "probe", deviceName: "probe")
    XCTAssertFalse(probe.isRecording, "a generated database never records")
    XCTAssertNil(defaults.string(forKey: SyncWiring.deviceIdKey), "no identity is made for it")
  }

  func testTheRealDatabaseGetsACoordinatorAndRecords() throws {
    let stack = try makeStack()
    let environment = wired(real: true, stack: stack)
    let sync = try XCTUnwrap(environment.sync)
    XCTAssertTrue(sync.isAvailable)
    XCTAssertEqual(sync.exchange?.isRecording, true)
    XCTAssertEqual(sync.status, .notConfigured, "no folder is chosen yet")
    XCTAssertEqual(sync.language === environment.language, true)
  }

  func testTheDeviceKeepsOneIdentityInTheSettingsOfThisDevice() throws {
    let first = SyncWiring.deviceId(in: defaults)
    XCTAssertTrue(SyncDevice.isValid(id: first))
    XCTAssertEqual(SyncWiring.deviceId(in: defaults), first)
    let stack = try makeStack()
    let environment = wired(real: true, stack: stack)
    XCTAssertEqual(environment.sync?.exchange?.deviceId, first)
    // A stored value that cannot sit in a file name is replaced, not used.
    defaults.set("bad name/with slash", forKey: SyncWiring.deviceIdKey)
    XCTAssertTrue(SyncDevice.isValid(id: SyncWiring.deviceId(in: defaults)))
  }

  func testTheFoldersOfTheBooksAndTheMirrorAreRefusedAsTheExchangeFolder() throws {
    let stack = try makeStack()
    let environment = wired(real: true, stack: stack)
    let sync = try XCTUnwrap(environment.sync)
    XCTAssertEqual(sync.choose(folder: AppPaths.backupsDirectory), .refused)
    XCTAssertEqual(sync.choose(folder: AppPaths.dataDirectory), .refused)
    let mirror = folder.appendingPathComponent("Mirror", isDirectory: true)
    environment.useMirrorFolder(mirror)
    XCTAssertEqual(sync.choose(folder: mirror), .refused, "the mirror of the copies")
    XCTAssertFalse(sync.hasFolder)
  }

  func testABurstOfChangesMakesOneExchangeAfterTheDelay() async throws {
    let stack = try makeStack()
    let environment = wired(real: true, stack: stack)
    let sync = try XCTUnwrap(environment.sync)
    sync.debounceDelay = .milliseconds(150)
    // Without a folder a change only shows what waits; nothing runs.
    sync.changed()
    XCTAssertEqual(sync.status, .notConfigured)
    XCTAssertEqual(sync.choose(folder: folder), .accepted)
    for _ in 0..<5 { sync.changed() }
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
      if case .synced = sync.status { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    guard case .synced = sync.status else { return XCTFail("status \(sync.status)") }
    await sync.stop()
    sync.changed()
    XCTAssertTrue(sync.isAvailable)
  }

  func testStoppingTheCoordinatorEndsTheTriggers() async throws {
    let stack = try makeStack()
    let sync = try XCTUnwrap(wired(real: true, stack: stack).sync)
    XCTAssertEqual(sync.choose(folder: folder), .accepted)
    await sync.stop()
    sync.debounceDelay = .milliseconds(20)
    sync.changed()
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertNotEqual(sync.status, .running)
  }

  func testTheConflictsRowIsInMoreOnlyWhileSomethingWaits() {
    let none = MoreMenu.make(more: [], tripIsOn: false)
    XCTAssertFalse((none.sections + none.app).contains(.conflicts))
    let waiting = MoreMenu.make(more: [], tripIsOn: false, hasConflicts: true)
    XCTAssertTrue(waiting.sections.contains(.conflicts))
    XCTAssertEqual(MoreRow.conflicts.id, "conflicts")
    XCTAssertEqual(
      PhoneNavigation.route(forSection: .debts).more, .debts, "other routes are unchanged")
  }

  func testTheNewTextsHaveWordsInBothLanguages() {
    for code in ["ru", "en"] {
      let bundle = Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:))
      for (table, key) in [
        ("Sync", "sync.folder.title"), ("Sync", "sync.conflicts.title"),
        ("Overview", "overview.small.field.title"),
      ] {
        let words = (bundle ?? .main).localizedString(forKey: key, value: "", table: table)
        XCTAssertNotEqual(words, "", "\(key) in \(code)")
        XCTAssertNotEqual(words, key, "\(key) in \(code)")
      }
    }
  }
}
