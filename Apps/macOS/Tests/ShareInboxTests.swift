import AppCore
import XCTest

@testable import OhMyMoney

final class ShareInboxTests: XCTestCase {
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
