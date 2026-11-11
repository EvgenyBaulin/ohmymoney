import AppCore
import XCTest

@testable import OhMyMoney

final class ShareInboxTests: XCTestCase {
  @MainActor
  func testOneWindowClaimsAnItemAndLockingLeavesItForTheNextPresentation() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("share-claim-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let inbox = ShareInbox(directory: directory)
    let file = try inbox.enqueue(SharedImportItem(kind: .text, data: Data("synthetic".utf8)))
    let session = ShareInboxSession()
    XCTAssertEqual(try session.claimNext(in: inbox), file)
    XCTAssertNil(try session.claimNext(in: inbox), "another window cannot present the same file")
    session.release(file)
    XCTAssertEqual(try session.claimNext(in: inbox), file, "locking did not consume the file")
    session.postpone(file)
    XCTAssertNil(
      try session.claimNext(in: inbox), "keeping a broken file must not reopen it in a loop")
    XCTAssertEqual(try inbox.pending(), [file])
    XCTAssertEqual(
      try ShareInboxSession().claimNext(in: inbox), file, "a new launch tries it again")
  }

  func testAppGroupSharingIsOffUntilTheCapabilityIsEnabled() {
    XCTAssertFalse(ShareInbox.isEnabled)
    XCTAssertNil(ShareInbox.configured())
  }

  func testInboxSurvivesRelaunchAndRemovesOnlyAcknowledgedItems() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("share-inbox-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let inbox = ShareInbox(directory: directory)
    let item = try SharedImportItem(
      kind: .pdf, data: Data("%PDF-synthetic".utf8), filename: "r.pdf")
    let first = try inbox.enqueue(item)
    let second = try inbox.enqueue(item)
    let relaunched = ShareInbox(directory: directory)
    XCTAssertEqual(Set(try relaunched.pending()), Set([first, second]))
    XCTAssertEqual(try relaunched.read(first), item)
    try relaunched.acknowledge(first)
    XCTAssertEqual(try relaunched.pending(), [second])
    XCTAssertEqual(try relaunched.read(second), item)
    XCTAssertThrowsError(try relaunched.read(directory.deletingLastPathComponent()))
  }

  func testBrokenFilesStayAvailableAndUnrelatedFilesAreIgnored() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("share-inbox-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let inbox = ShareInbox(directory: directory)
    let broken = directory.appendingPathComponent("\(UUID().uuidString).ommshare")
    try Data("broken".utf8).write(to: broken)
    try Data("other".utf8).write(to: directory.appendingPathComponent("unrelated.txt"))
    XCTAssertEqual(try inbox.pending(), [broken])
    XCTAssertThrowsError(try inbox.read(broken))
    XCTAssertTrue(FileManager.default.fileExists(atPath: broken.path))
  }
}
