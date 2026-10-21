import XCTest

@testable import OhMyMoney

final class FolderTests: XCTestCase {
  private var folder: URL!
  private let key = "ios.tests.folder.\(UUID().uuidString)"

  override func setUp() {
    super.setUp()
    folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("ios-folder-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: key)
    try? FileManager.default.removeItem(at: folder)
    super.tearDown()
  }

  func testAFolderThatOpensIsReadyAndNamed() throws {
    let store = BookmarkStore(key: key)
    try store.save(folder)
    XCTAssertTrue(store.isStored)
    let resolved = try XCTUnwrap(store.resolve())
    XCTAssertEqual(
      FolderStatus.of(profile: .real, isStored: true, mirror: resolved, unavailable: false),
      .ready(name: folder.lastPathComponent))
  }

  func testRefusedAccessLeavesTheFolderLostNotForgotten() throws {
    var store = BookmarkStore(key: key)
    try store.save(folder)
    store.startAccess = { _ in false }
    XCTAssertNil(store.resolve())
    XCTAssertTrue(store.isStored, "the choice is kept so the screen can say what happened")
    XCTAssertEqual(
      FolderStatus.of(profile: .real, isStored: store.isStored, mirror: nil, unavailable: true),
      .lost)
    XCTAssertEqual(
      FolderStatus.of(profile: .real, isStored: store.isStored, mirror: nil, unavailable: false),
      .lost)
  }

  func testAFolderThatIsGoneDoesNotResolve() throws {
    let store = BookmarkStore(key: key)
    try store.save(folder)
    try FileManager.default.removeItem(at: folder)
    XCTAssertNil(store.resolve())
    XCTAssertEqual(
      FolderStatus.of(profile: .real, isStored: store.isStored, mirror: nil, unavailable: true),
      .lost)
  }

  func testChoosingAgainReplacesTheLostBookmark() throws {
    var lost = BookmarkStore(key: key)
    try lost.save(folder)
    lost.startAccess = { _ in false }
    XCTAssertNil(lost.resolve())

    let again = folder.deletingLastPathComponent()
      .appendingPathComponent("ios-folder-again-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: again, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: again) }
    let store = BookmarkStore(key: key)
    try store.save(again)
    XCTAssertNotNil(store.resolve())
  }

  func testNothingChosenAndTheDemoSayTheirOwnWords() {
    XCTAssertEqual(
      FolderStatus.of(profile: .real, isStored: false, mirror: nil, unavailable: false),
      .notChosen)
    XCTAssertEqual(
      FolderStatus.of(profile: .demo, isStored: true, mirror: nil, unavailable: true),
      .demoWritesNothing)
  }
}
