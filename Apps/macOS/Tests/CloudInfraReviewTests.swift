import AppCore
import Foundation
import XCTest

@testable import OhMyMoney

/// Hardening of the cloud transports found in review: a refused replace is never a written
/// snapshot, a listing that never ends gives up, a server-made id never reaches a path, the
/// token item is kept on this device, and a report's temporary folder is not left behind.
final class CloudInfraReviewTests: XCTestCase {
  private struct Scripted: CloudHTTPTransporting {
    let reply: @Sendable (URLRequest) -> CloudHTTPResponse
    func perform(_ request: URLRequest) throws -> CloudHTTPResponse { reply(request) }
  }

  private func client(
    _ reply: @escaping @Sendable (URLRequest) -> CloudHTTPResponse
  )
    -> CloudHTTPClient
  {
    CloudHTTPClient(
      http: Scripted(reply: reply), authorizer: StaticCloudAuthorizer(headers: [:]),
      retry: CloudRetryPolicy(sleep: { _ in }))
  }

  private static let snapshot = "snapshot-device1.ohmymoney-snapshot"

  /// The transports refuse the main thread, so every call here runs on a background one.
  private func assertUnavailable(
    _ body: @escaping @Sendable () throws -> Void, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(try offMainThread(body), file: file, line: line) {
      XCTAssertEqual($0 as? ExchangeTransportError, .unavailable, file: file, line: line)
    }
  }

  func testDropboxReplaceRefusedByTheServerIsAFailure() {
    let backend = DropboxBackend(
      client: client { _ in
        CloudHTTPResponse(
          status: 409, body: Data(#"{"error_summary":"path/conflict/folder/"}"#.utf8))
      })
    assertUnavailable { try backend.replace(Self.snapshot, data: Data([1])) }
  }

  func testOneDriveReplaceRefusedByTheServerIsAFailure() {
    let backend = OneDriveBackend(client: client { _ in CloudHTTPResponse(status: 409) })
    assertUnavailable { try backend.replace(Self.snapshot, data: Data([1])) }
  }

  func testDropboxListingThatRepeatsItsCursorGivesUp() {
    let page = #"{"entries":[],"cursor":"same","has_more":true}"#
    let backend = DropboxBackend(
      client: client { _ in CloudHTTPResponse(status: 200, body: Data(page.utf8)) })
    assertUnavailable { _ = try backend.list() }
  }

  func testYandexListingThatNeverEndsGivesUp() {
    let page =
      #"{"_embedded":{"items":[{"name":"x","type":"dir","modified":"2026-01-01T00:00:00+00:00"}],"total":999999999}}"#
    let backend = YandexDiskBackend(
      client: client { _ in CloudHTTPResponse(status: 200, body: Data(page.utf8)) })
    assertUnavailable { _ = try backend.list() }
  }

  func testGoogleListingThatRepeatsItsTokenGivesUp() {
    let page = #"{"files":[],"nextPageToken":"same"}"#
    let transport = GoogleDriveTransport(
      client: client { _ in CloudHTTPResponse(status: 200, body: Data(page.utf8)) })
    XCTAssertThrowsError(try offMainThread { _ = try transport.files() })
  }

  func testGoogleFileIdFromTheServerIsNotPutInAPath() {
    let sent = SentPaths()
    let transport = GoogleDriveTransport(
      client: client { request in
        sent.add(request.url?.absoluteString ?? "")
        return CloudHTTPResponse(
          status: 200,
          body: Data(
            #"{"files":[{"id":"../../about?x=","modifiedTime":"2026-01-01T00:00:00Z"}]}"#.utf8))
      })
    XCTAssertThrowsError(
      try offMainThread { _ = try transport.readFile(named: "journal-device1-0000000001.json") })
    XCTAssertEqual(sent.all.count, 1, "no request was made with the foreign id")
  }

  func testRemoteIdRules() {
    XCTAssertTrue(CloudFileName.isSafeRemoteId("1aB-_9"))
    for bad in ["", "../x", "a/b", "a?b", "a b", "é", String(repeating: "a", count: 201)] {
      XCTAssertFalse(CloudFileName.isSafeRemoteId(bad), bad)
    }
  }

  func testTokenItemIsKeptOnThisDeviceOnly() {
    let store = KeychainCloudTokenStore(providerId: "test", service: "review.test")
    let item = store.addAttributes(for: Data([1]))
    XCTAssertEqual(
      item[kSecAttrAccessible as String] as? String,
      kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    XCTAssertEqual(item[kSecAttrSynchronizable as String] as? Bool, false)
  }

  func testReportFolderIsRemovedAfterTheMoveIsDone() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      SharedReportModel.folderPrefix + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("report.pdf")
    try Data([1]).write(to: file)
    SharedReportModel.discard(file)
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
  }

  func testDiscardTouchesOnlyAFolderTheReportMade() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "other-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    SharedReportModel.discard(folder.appendingPathComponent("x"))
    SharedReportModel.discard(nil)
    XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
  }
}

private final class SentPaths: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String] = []
  func add(_ value: String) { lock.withLock { items.append(value) } }
  var all: [String] { lock.withLock { items } }
}

private func offMainThread(_ work: @escaping @Sendable () throws -> Void) throws {
  final class Box: @unchecked Sendable { var result: Result<Void, Error>? }
  let box = Box()
  let done = DispatchSemaphore(value: 0)
  DispatchQueue.global().async {
    box.result = Result { try work() }
    done.signal()
  }
  done.wait()
  try box.result?.get()
}
