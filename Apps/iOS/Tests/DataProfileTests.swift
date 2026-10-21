import AppCore
import AppDatabase
import CryptoKit
import XCTest

@testable import OhMyMoney

@MainActor
final class DataProfileTests: XCTestCase {
  private var root: URL!
  private var suite = ""
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ios-profile-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    suite = "profile-tests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
  }

  override func tearDown() {
    AppPaths.placement = nil
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
    super.tearDown()
  }

  private func fingerprint(of directory: URL) throws -> [String: String] {
    var result: [String: String] = [:]
    guard
      let walker = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey])
    else { return result }
    for case let url as URL in walker {
      guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
        continue
      }
      let digest = SHA256.hash(data: try Data(contentsOf: url))
      result[String(url.path.dropFirst(directory.path.count))] =
        digest.map { String(format: "%02x", $0) }.joined()
    }
    return result
  }

  func testTheDemoIsWhatTheAppOpensOnUntilTheOwnerTurnsTheRealOneOn() {
    let store = ProfileStore(defaults: defaults)
    XCTAssertEqual(store.current, .demo)
    store.current = .real
    XCTAssertEqual(ProfileStore(defaults: defaults).current, .real)
  }

  func testEachSetHasAFolderOfItsOwnAndTheDemoIsADataSet() {
    let demo = DataProfile.demo.placement(in: root)
    let real = DataProfile.real.placement(in: root)
    XCTAssertEqual(demo.dataSet, .demo)
    XCTAssertNil(real.dataSet)
    XCTAssertNotEqual(demo.directory, real.directory)
    XCTAssertEqual(demo.directory.deletingLastPathComponent().lastPathComponent, "Sets")
    XCTAssertFalse(real.directory.path.hasPrefix(demo.directory.path))
    XCTAssertFalse(demo.directory.path.hasPrefix(real.directory.path))
  }

  func testSwitchingPointsThePathsAtTheOtherFolderAndOpensNothingThere() async {
    let session = AppSession(
      profiles: ProfileStore(defaults: defaults), root: root, launches: false)
    XCTAssertEqual(session.profile, .demo)
    XCTAssertEqual(AppPaths.dataDirectory, DataProfile.demo.directory(in: root))
    XCTAssertEqual(AppPaths.dataSet, .demo)

    await session.switchProfile(to: .real)
    XCTAssertEqual(session.profile, .real)
    XCTAssertEqual(AppPaths.dataDirectory, DataProfile.real.directory(in: root))
    XCTAssertNil(AppPaths.dataSet)
    XCTAssertEqual(ProfileStore(defaults: defaults).current, .real)
    XCTAssertEqual(session.generation, 1)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: DataProfile.demo.directory(in: root).path),
      "nothing was made in the folder of the set left behind")

    await session.switchProfile(to: .demo)
    XCTAssertEqual(AppPaths.dataSet, .demo)
    XCTAssertEqual(session.generation, 2)
  }

  func testWritingTheDemoLeavesTheRealDatabaseByteForByte() throws {
    let calendar = CalendarContext.system
    let today = calendar.day(of: Date())
    let realDirectory = DataProfile.real.directory(in: root)
    try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
    do {
      let stack = try DatabaseStack(
        url: AppPaths.databaseURL(in: realDirectory), schema: BundleSchemaSource())
      try stack.close()
    }
    let before = try fingerprint(of: realDirectory)
    XCTAssertFalse(before.isEmpty)

    let stack = try DataSetGeneration.prepare(
      directory: DataProfile.demo.directory(in: root), generation: .months(1), today: today,
      calendar: calendar, language: "en", schema: BundleSchemaSource())
    try stack.close()

    XCTAssertEqual(try fingerprint(of: realDirectory), before)
    XCTAssertFalse(try fingerprint(of: DataProfile.demo.directory(in: root)).isEmpty)
  }

  func testTheDemoWritesNothingToAChosenFolder() throws {
    let chosen = root.appendingPathComponent("chosen", isDirectory: true)
    try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
    let session = AppSession(
      profiles: ProfileStore(defaults: defaults), root: root, launches: false)
    let environment = session.deps.environment
    environment.backupFolder.clear()

    let refusal = BackupSettingsView.choose(chosen, in: environment)
    XCTAssertEqual(refusal, BackupSettingsView.dataSetMirrorsNowhereKey)
    XCTAssertFalse(environment.backupFolder.isStored, "no bookmark was made for the demo")
    XCTAssertNil(environment.mirrorFolder)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: chosen.path), [])

    // A demo made in full goes only to its own folder, never into the chosen one.
    let stack = try DataSetGeneration.prepare(
      directory: DataProfile.demo.directory(in: root), generation: .months(1),
      today: environment.today, calendar: environment.calendar, language: "en",
      schema: BundleSchemaSource())
    try stack.close()
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: chosen.path), [])
  }
}
