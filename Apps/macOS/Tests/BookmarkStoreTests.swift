import Foundation
import XCTest

@testable import OhMyMoney

/// «Доступ к выбранным мной папкам — через стандартный диалог и сохранённую закладку
/// (security-scoped bookmark)». A bookmark resolved after the folder was
/// renamed or moved comes back stale, and it has to be written again while it still opens:
/// the old one keeps finding the folder only for a while. In the sandbox a new
/// security-scoped bookmark can be made only for a folder access is open to, so it is written
/// after access is opened, never before.
///
/// The folders here lie in the test host's own container, where access is open anyway; what
/// the sandbox would refuse outside it is seen through the moment access is asked for.
final class BookmarkStoreTests: XCTestCase {
  private var directory: URL!
  private var key: String!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-bookmarks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // A key of the test's own: the defaults of the test host are the owner's.
    key = "tests.bookmark.\(UUID().uuidString)"
  }

  override func tearDownWithError() throws {
    UserDefaults.standard.removeObject(forKey: key)
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  private var stored: Data? { UserDefaults.standard.data(forKey: key) }

  /// A folder chosen once, its bookmark saved, and then renamed by the owner — the way
  /// «OhMyMoney Backups» becomes «Финансы» in iCloud Drive.
  private func renamedFolder() throws -> (store: BookmarkStore, renamed: URL, original: Data) {
    let chosen = directory.appendingPathComponent("OhMyMoney Backups", isDirectory: true)
    try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
    let store = BookmarkStore(key: key)
    try store.save(chosen)
    let original = try XCTUnwrap(stored)
    let renamed = directory.appendingPathComponent("Финансы", isDirectory: true)
    try FileManager.default.moveItem(at: chosen, to: renamed)
    return (store, renamed, original)
  }

  private func isStale(_ data: Data) throws -> Bool {
    var stale = false
    _ = try URL(
      resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
      bookmarkDataIsStale: &stale)
    return stale
  }

  /// What was stored at the moment access was asked for.
  private final class Moment: @unchecked Sendable {
    var stored: Data?
    var asked = 0
  }

  func testAStaleBookmarkIsWrittenAgainOnlyOnceAccessIsOpen() throws {
    var (store, renamed, original) = try renamedFolder()
    XCTAssertTrue(try isStale(original), "a rename did not make the bookmark stale")
    let moment = Moment()
    let key = self.key!
    store.startAccess = { _ in
      moment.stored = UserDefaults.standard.data(forKey: key)
      moment.asked += 1
      return true
    }

    let url = try XCTUnwrap(store.resolve(), "a renamed folder did not resolve")

    XCTAssertEqual(url.standardizedFileURL.path, renamed.standardizedFileURL.path)
    XCTAssertEqual(moment.asked, 1)
    XCTAssertEqual(
      moment.stored, original,
      "the bookmark was written again before access to the folder was open")
    let refreshed = try XCTUnwrap(stored)
    XCTAssertNotEqual(refreshed, original, "a stale bookmark was not written again")
    XCTAssertFalse(try isStale(refreshed), "the bookmark written again is stale itself")
  }

  /// Access refused — outside the container, a bookmark the sandbox no longer honours: nothing
  /// is written, and the bookmark the owner made stays as it was.
  func testAFolderAccessIsRefusedToKeepsItsBookmark() throws {
    var (store, _, original) = try renamedFolder()
    store.startAccess = { _ in false }

    XCTAssertNil(store.resolve())

    XCTAssertEqual(stored, original, "a bookmark was written for a folder access was refused to")
  }

  /// The point of writing it again: the folder is still found after the next move.
  func testAFolderMovedTwiceIsStillFound() throws {
    var (store, renamed, _) = try renamedFolder()
    store.startAccess = { _ in true }
    XCTAssertNotNil(store.resolve())
    let movedAgain = directory.appendingPathComponent("Архив", isDirectory: true)
    try FileManager.default.moveItem(at: renamed, to: movedAgain)

    let url = try XCTUnwrap(store.resolve(), "the folder was lost after a second move")

    XCTAssertEqual(url.standardizedFileURL.path, movedAgain.standardizedFileURL.path)
  }
}

/// Choosing the folder for copies in the Backups tab. The folder is used for as long as the app
/// runs, but found again after a restart only through its bookmark — so a folder whose bookmark
/// could not be saved is not taken at all. Taken, it was mirrored into until the quit and then
/// forgotten, while the owner believed the copies went there («Бэкапы и экспорт»: копия — в
/// выбранную папку в iCloud Drive).
@MainActor
final class ChoosingTheCopiesFolderTests: XCTestCase {
  private var directory: URL!
  private var key: String!
  private var environment: AppEnvironment!

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-choose-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    key = "tests.backup.folder.\(UUID().uuidString)"
    environment = AppEnvironment()
    environment.backupFolder = BookmarkStore(key: key)
  }

  override func tearDown() async throws {
    UserDefaults.standard.removeObject(forKey: key)
    try? FileManager.default.removeItem(at: directory)
    environment = nil
  }

  private func journal(contains needle: String) async -> Bool {
    for _ in 0..<50 {
      if Logbook.shared.lines().contains(where: { $0.contains(needle) }) { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return false
  }

  /// A bookmark is made of a folder that is there; one that is gone — a volume unmounted
  /// between the panel and the save — throws, like a volume that refuses security-scoped
  /// bookmarks does.
  func testABookmarkOfAFolderThatIsNotThereIsNotSaved() {
    let store = BookmarkStore(key: key)
    let gone = directory.appendingPathComponent("gone", isDirectory: true)

    XCTAssertThrowsError(try store.save(gone))
    XCTAssertFalse(store.isStored)
  }

  func testAFolderWhoseBookmarkCannotBeSavedIsNotTaken() async throws {
    Logbook.shared.open(
      directory: directory.appendingPathComponent("Logs", isDirectory: true), threshold: .debug)
    defer { Task { Logbook.shared.close() } }
    let gone = directory.appendingPathComponent("gone", isDirectory: true)

    let failure = BackupSettingsView.choose(gone, in: environment)

    XCTAssertEqual(failure, BackupSettingsView.folderNotRememberedKey)
    XCTAssertNil(environment.mirrorFolder, "a folder that will be forgotten at the quit is in use")
    XCTAssertFalse(environment.backupFolder.isStored)
    let logged = await journal(contains: "backup.bookmarkFailed")
    XCTAssertTrue(logged, "the journal is not told the folder was not remembered")
  }

  /// The folder in use stays in use, and its bookmark stays the one found at the next launch.
  func testAFailedChoiceKeepsTheFolderInUse() throws {
    let chosen = directory.appendingPathComponent("OhMyMoney Backups", isDirectory: true)
    try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
    XCTAssertNil(BackupSettingsView.choose(chosen, in: environment))
    let stored = UserDefaults.standard.data(forKey: key)

    _ = BackupSettingsView.choose(
      directory.appendingPathComponent("gone", isDirectory: true), in: environment)

    XCTAssertEqual(environment.mirrorFolder, chosen)
    XCTAssertEqual(UserDefaults.standard.data(forKey: key), stored)
  }

  func testAFolderWhoseBookmarkIsSavedIsTaken() throws {
    let chosen = directory.appendingPathComponent("OhMyMoney Backups", isDirectory: true)
    try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)

    XCTAssertNil(BackupSettingsView.choose(chosen, in: environment))

    XCTAssertEqual(environment.mirrorFolder, chosen)
    XCTAssertTrue(environment.backupFolder.isStored)
  }

  /// A data set's copies stay in its own folder (`AppEnvironment.open`): synthetic history has
  /// no place beside the owner's copies. A folder chosen in a data-set launch was mirrored into
  /// all the same — the owner's iCloud folder, most likely — and its bookmark took the place of
  /// the owner's, under the one key both launches read.
  func testADataSetLaunchTakesNoFolderAndKeepsTheOwnersBookmark() throws {
    let owners = directory.appendingPathComponent("OhMyMoney Backups", isDirectory: true)
    try FileManager.default.createDirectory(at: owners, withIntermediateDirectories: true)
    try environment.backupFolder.save(owners)
    let stored = UserDefaults.standard.data(forKey: key)
    let other = directory.appendingPathComponent("Elsewhere", isDirectory: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

    let failure = BackupSettingsView.choose(other, in: environment, dataSet: .sample)

    XCTAssertEqual(failure, BackupSettingsView.dataSetMirrorsNowhereKey)
    XCTAssertNil(environment.mirrorFolder, "a data set mirrors its copies into a chosen folder")
    XCTAssertEqual(
      UserDefaults.standard.data(forKey: key), stored,
      "a data-set launch replaced the bookmark of the owner's folder")
  }
}
