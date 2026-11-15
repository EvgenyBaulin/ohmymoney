import AppCore
import AppDatabase
import Foundation
import XCTest

@testable import OhMyMoney

// MARK: - A stub network

/// Replies for every request of a test from a closure; no socket is opened.
private final class StubNetwork: URLProtocol, @unchecked Sendable {
  typealias Reply = (status: Int, headers: [String: String], body: Data)
  nonisolated(unsafe) static var handler: (@Sendable (URLRequest, Data) throws -> Reply)?
  private static let lock = NSLock()

  static func install(_ handler: @escaping @Sendable (URLRequest, Data) throws -> Reply) {
    lock.withLock { self.handler = handler }
  }

  static func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubNetwork.self]
    return URLSession(configuration: configuration)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    var body = request.httpBody ?? Data()
    if let stream = request.httpBodyStream {
      stream.open()
      var buffer = [UInt8](repeating: 0, count: 16384)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        body.append(buffer, count: count)
      }
      stream.close()
    }
    let handler = Self.lock.withLock { Self.handler }
    do {
      guard let handler, let url = request.url else { throw URLError(.badURL) }
      let reply = try handler(request, body)
      let response = HTTPURLResponse(
        url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: reply.body)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

// MARK: - Fake services

/// A drive server in memory. `script` is consulted first for every request that is not a token
/// request: a queued status is answered instead of the real handling (503, 429, a dropped
/// connection), which is how outages are made.
private class FakeDrive: @unchecked Sendable {
  enum Fault {
    case status(Int, retryAfter: String?)
    case dropConnection
  }

  let lock = NSLock()
  var files: [String: Data] = [:]
  var modified = Date(timeIntervalSince1970: 1_800_000_000)
  var pageSize = 2
  var token = "token-1"
  var refreshCount = 0
  var faults: [Fault] = []
  /// Faults that apply only to requests whose URL contains this text.
  var faultFilter = ""
  var requests: [(url: String, authorization: String?)] = []
  var tokenHost: String { "" }

  func handle(_ request: URLRequest, _ body: Data) throws -> StubNetwork.Reply {
    try lock.withLock {
      let url = request.url!.absoluteString
      if url.contains(tokenHost) && !tokenHost.isEmpty { return try token(request, body) }
      requests.append((url, request.value(forHTTPHeaderField: "Authorization")))
      if !faults.isEmpty, faultFilter.isEmpty || url.contains(faultFilter) {
        switch faults.removeFirst() {
        case .status(let code, let after):
          return (code, after.map { ["Retry-After": $0] } ?? [:], Data())
        case .dropConnection:
          throw URLError(.networkConnectionLost)
        }
      }
      return try route(request, body)
    }
  }

  func token(_ request: URLRequest, _ body: Data) throws -> StubNetwork.Reply {
    refreshCount += 1
    self.token = "token-\(refreshCount + 1)"
    let json = #"{"access_token":"\#(self.token)","expires_in":3600}"#
    return (200, [:], Data(json.utf8))
  }

  func route(_ request: URLRequest, _ body: Data) throws -> StubNetwork.Reply {
    (404, [:], Data())
  }

  func json(_ text: String) -> StubNetwork.Reply { (200, [:], Data(text.utf8)) }

  var iso: String { ISO8601DateFormatter().string(from: modified) }

  func query(_ request: URLRequest, _ name: String) -> String? {
    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
      .first { $0.name == name }?.value
  }

  func page(_ names: [String], offset: Int) -> (slice: [String], next: Int?) {
    let end = min(offset + pageSize, names.count)
    return (Array(names[offset..<end]), end < names.count ? end : nil)
  }
}

private final class FakeYandex: FakeDrive, @unchecked Sendable {
  override var tokenHost: String { "oauth.yandex.ru" }

  override func route(_ request: URLRequest, _ body: Data) throws -> StubNetwork.Reply {
    let url = request.url!
    let host = url.host ?? ""
    if host == "cloud-api.yandex.net" {
      guard request.value(forHTTPHeaderField: "Authorization") == "OAuth \(token)" else {
        return (401, [:], Data())
      }
      let path = query(request, "path") ?? ""
      let name = String(path.dropFirst("app:/".count))
      switch url.path {
      case "/v1/disk/resources":
        let offset = Int(query(request, "offset") ?? "0") ?? 0
        // Like the real listing, folders count in offsets and in the total.
        let entries = ["folder"] + files.keys.sorted()
        let items = page(entries, offset: offset).slice.map { entry in
          #"{"name":"\#(entry)","type":"\#(entry == "folder" ? "dir" : "file")","modified":"\#(iso)"}"#
        }
        return json(#"{"_embedded":{"items":[\#(items.joined(separator: ","))],"total":\#(entries.count)}}"#)
      case "/v1/disk/resources/upload":
        if files[name] != nil, query(request, "overwrite") != "true" { return (409, [:], Data()) }
        return json(#"{"href":"https://uploader.example/put/\#(name)"}"#)
      case "/v1/disk/resources/download":
        guard files[name] != nil else { return (404, [:], Data()) }
        return json(#"{"href":"https://downloader.example/get/\#(name)"}"#)
      default:
        return (404, [:], Data())
      }
    }
    let name = url.lastPathComponent
    if host == "uploader.example", request.httpMethod == "PUT" {
      files[name] = body
      return (201, [:], Data())
    }
    if host == "downloader.example" { return (200, [:], files[name] ?? Data()) }
    return (404, [:], Data())
  }
}

private final class FakeDropbox: FakeDrive, @unchecked Sendable {
  override var tokenHost: String { "oauth2/token" }

  private func argument(_ request: URLRequest) -> [String: Any] {
    let text = request.value(forHTTPHeaderField: "Dropbox-API-Arg") ?? "{}"
    return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
  }

  override func route(_ request: URLRequest, _ body: Data) throws -> StubNetwork.Reply {
    guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)" else {
      return (401, [:], Data())
    }
    let path = request.url!.path
    func listing(_ offset: Int) -> StubNetwork.Reply {
      let names = files.keys.sorted()
      let (slice, next) = page(names, offset: offset)
      var entries = slice.map { #"{".tag":"file","name":"\#($0)","server_modified":"\#(iso)"}"# }
      if offset == 0 { entries.append(#"{".tag":"folder","name":"sub"}"#) }
      return json(
        #"{"entries":[\#(entries.joined(separator: ","))],"cursor":"\#(next ?? offset)","has_more":\#(next != nil)}"#
      )
    }
    switch path {
    case "/2/files/list_folder":
      return listing(0)
    case "/2/files/list_folder/continue":
      let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
      return listing(Int(object?["cursor"] as? String ?? "0") ?? 0)
    case "/2/files/upload":
      let arg = argument(request)
      let name = String((arg["path"] as? String ?? "").dropFirst())
      if files[name] != nil, arg["mode"] as? String == "add" {
        return (409, [:], Data(#"{"error_summary":"path/conflict/file/.."}"#.utf8))
      }
      files[name] = body
      return json("{}")
    case "/2/files/download":
      let name = String((argument(request)["path"] as? String ?? "").dropFirst())
      guard let data = files[name] else {
        return (409, [:], Data(#"{"error_summary":"path/not_found/.."}"#.utf8))
      }
      return (200, [:], data)
    default:
      return (404, [:], Data())
    }
  }
}

private final class FakeOneDrive: FakeDrive, @unchecked Sendable {
  override var tokenHost: String { "oauth2/v2.0/token" }
  var sessions: [String: Data] = [:]
  var abandoned: [String] = []

  private func name(in url: String) -> String? {
    guard let start = url.range(of: "approot:/") else { return nil }
    let rest = url[start.upperBound...]
    guard let end = rest.range(of: ":/") else { return nil }
    return String(rest[..<end.lowerBound])
  }

  override func route(_ request: URLRequest, _ body: Data) throws -> StubNetwork.Reply {
    let url = request.url!.absoluteString
    let host = request.url!.host ?? ""
    if host == "upload.example" {
      let key = request.url!.lastPathComponent
      if request.httpMethod == "DELETE" {
        sessions[key] = nil
        abandoned.append(key)
        return (204, [:], Data())
      }
      sessions[key, default: Data()].append(body)
      let range = request.value(forHTTPHeaderField: "Content-Range") ?? ""
      let total = Int(range.split(separator: "/").last ?? "0") ?? 0
      if sessions[key]!.count == total {
        files[key] = sessions[key]
        sessions[key] = nil
        return (201, [:], Data())
      }
      return (202, [:], Data())
    }
    guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)" else {
      return (401, [:], Data())
    }
    if url.contains("/children") {
      let skip = Int(query(request, "$skiptoken") ?? "0") ?? 0
      let names = files.keys.sorted()
      let (slice, next) = page(names, offset: skip)
      var items = slice.map {
        #"{"name":"\#($0)","lastModifiedDateTime":"\#(iso)","file":{}}"#
      }
      if skip == 0 { items.append(#"{"name":"dir","lastModifiedDateTime":"\#(iso)"}"#) }
      let link =
        next.map {
          #","@odata.nextLink":"https://graph.microsoft.com/v1.0/me/drive/special/approot/children?$skiptoken=\#($0)""#
        } ?? ""
      return json(#"{"value":[\#(items.joined(separator: ","))]\#(link)}"#)
    }
    guard let name = name(in: url) else { return (404, [:], Data()) }
    let behavior = query(request, "@microsoft.graph.conflictBehavior")
    if url.contains("/createUploadSession") {
      if files[name] != nil, behavior != "replace" {
        // The behavior travels in the body for a session.
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let item = object?["item"] as? [String: String]
        if item?["@microsoft.graph.conflictBehavior"] != "replace" { return (409, [:], Data()) }
      }
      return json(#"{"uploadUrl":"https://upload.example/s/\#(name)"}"#)
    }
    if request.httpMethod == "PUT" {
      if files[name] != nil, behavior == "fail" { return (409, [:], Data()) }
      files[name] = body
      return (201, [:], Data())
    }
    guard let data = files[name] else { return (404, [:], Data()) }
    return (200, [:], data)
  }
}

private let device = "11111111-2222-3333-4444-555555555555"

private func sealed(_ text: String) -> Data {
  Data(SealedPayloadCodec.magic)
    + Data(repeating: 7, count: SealedPayloadCodec.nonceByteCount + SealedPayloadCodec.tagByteCount)
    + Data(text.utf8)
}

private func journal(_ sequence: Int) -> String {
  SyncFormat.fileName(deviceId: device, sequence: sequence)
}

// MARK: - Tests

final class CloudDriveTransportTests: XCTestCase {
  private struct Rig {
    var server: FakeDrive
    var transport: any ExchangeFileTransport
    var sleeps: SleepLog
    var store: InMemoryCloudTokenStore
  }

  private final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []
    func add(_ value: TimeInterval) { lock.withLock { values.append(value) } }
    var all: [TimeInterval] { lock.withLock { values } }
  }

  /// A connected drive against its fake server. Pauses are recorded, not slept.
  private func makeRig(
    _ drive: CloudDrive, attempts: Int = 4, expires: Date? = nil,
    build: ((CloudHTTPClient) -> any ExchangeFileTransport)? = nil
  ) -> Rig {
    let server: FakeDrive
    switch drive {
    case .yandexDisk: server = FakeYandex()
    case .dropbox: server = FakeDropbox()
    case .oneDrive: server = FakeOneDrive()
    default: preconditionFailure("only the three drives of this file have a fake server")
    }
    StubNetwork.install { request, body in try server.handle(request, body) }
    let sleeps = SleepLog()
    let retry = CloudRetryPolicy(
      maxAttempts: attempts, baseDelay: 1, maxDelay: 60, sleep: { sleeps.add($0) })
    var config = drive.oauth!
    config.clientId = "test-client"
    let store = InMemoryCloudTokenStore(
      CloudTokens(accessToken: server.token, refreshToken: "refresh", expiresAt: expires))
    let http = URLSessionCloudHTTP(session: StubNetwork.session())
    let authorizer = CloudAuthorizer(config: config, store: store, http: http, retry: retry)
    let client = CloudHTTPClient(http: http, authorizer: authorizer, retry: retry)
    let transport: any ExchangeFileTransport
    if let build {
      transport = build(client)
    } else {
      switch drive {
      case .yandexDisk: transport = CloudFileTransport(backend: YandexDiskBackend(client: client))
      case .dropbox: transport = CloudFileTransport(backend: DropboxBackend(client: client))
      default: transport = CloudFileTransport(backend: OneDriveBackend(client: client))
      }
    }
    return Rig(server: server, transport: transport, sleeps: sleeps, store: store)
  }

  /// The transports block; XCTest runs on the main thread, so the work goes to another one.
  private func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached { try body() }.value
  }

  // Every drive passes the same behaviour.
  private func forEachDrive(_ body: (CloudDrive) async throws -> Void) async throws {
    for drive in [CloudDrive.yandexDisk, .dropbox, .oneDrive] { try await body(drive) }
  }

  func testWriteThenListAndReadAcrossPages() async throws {
    try await forEachDrive { drive in
      let rig = makeRig(drive)
      let transport = rig.transport
      let names = (1...5).map { journal($0) }
      for (index, name) in names.enumerated() {
        let data = sealed("payload-\(index)")
        try await offMain { try transport.writeFile(named: name, data: data, replacing: false) }
      }
      let listed = try await offMain { try transport.files() }
      XCTAssertEqual(Set(listed.map(\.name)), Set(names), "\(drive) lists every page, no folders")
      let read = try await offMain { try transport.readFile(named: names[3]) }
      XCTAssertEqual(read, sealed("payload-3"), "\(drive)")
    }
  }

  func testRetryOfTheSameBytesSucceedsAndDifferentBytesAreRefused() async throws {
    try await forEachDrive { drive in
      let rig = makeRig(drive)
      let transport = rig.transport
      let name = journal(1)
      let data = sealed("one")
      try await offMain { try transport.writeFile(named: name, data: data, replacing: false) }
      try await offMain { try transport.writeFile(named: name, data: data, replacing: false) }
      let other = sealed("two")
      do {
        try await offMain { try transport.writeFile(named: name, data: other, replacing: false) }
        XCTFail("\(drive) must refuse different bytes")
      } catch {
        XCTAssertEqual(error as? ExchangeTransportError, .fileChanged, "\(drive)")
      }
      let kept = try await offMain { try transport.readFile(named: name) }
      XCTAssertEqual(kept, data, "\(drive) keeps the first bytes")
    }
  }

  func testOnlySnapshotsMayBeReplacedAndForeignNamesAreRefused() async throws {
    try await forEachDrive { drive in
      let rig = makeRig(drive)
      let transport = rig.transport
      let snapshot = SyncSnapshotName.fileName(deviceId: device)
      try await offMain {
        try transport.writeFile(named: snapshot, data: sealed("a"), replacing: false)
        try transport.writeFile(named: snapshot, data: sealed("b"), replacing: true)
      }
      let now = try await offMain { try transport.readFile(named: snapshot) }
      XCTAssertEqual(now, sealed("b"), "\(drive)")
      let refused: [(String, Data, Bool)] = [
        (journal(9), sealed("x"), true), ("../evil", sealed("x"), false),
        (journal(8), Data("plain".utf8), false),
      ]
      for (name, data, replacing) in refused {
        do {
          try await offMain { try transport.writeFile(named: name, data: data, replacing: replacing) }
          XCTFail("\(drive) accepted \(name)")
        } catch {
          XCTAssertEqual(error as? ExchangeTransportError, .malformed, "\(drive)")
        }
      }
      do {
        _ = try await offMain { try transport.readFile(named: "../evil") }
        XCTFail("\(drive) read a foreign name")
      } catch {
        XCTAssertEqual(error as? ExchangeTransportError, .malformed)
      }
    }
  }

  func testMissingFileIsMissing() async throws {
    try await forEachDrive { drive in
      let rig = makeRig(drive)
      let transport = rig.transport
      do {
        _ = try await offMain { try transport.readFile(named: journal(1)) }
        XCTFail("\(drive)")
      } catch {
        XCTAssertEqual(error as? ExchangeTransportError, .missing, "\(drive)")
      }
    }
  }

  func testExpiredTokenIsRenewedOnA401AndTheRequestRepeated() async throws {
    try await forEachDrive { drive in
      let rig = makeRig(drive)
      let transport = rig.transport
      // The server stops accepting the token the client holds.
      rig.server.lock.withLock { rig.server.token = "rotated" }
      try await offMain { try transport.writeFile(named: journal(1), data: sealed("a"), replacing: false) }
      XCTAssertEqual(rig.server.refreshCount, 1, "\(drive) renewed once")
      let stored = try rig.store.load()
      XCTAssertEqual(stored?.accessToken, rig.server.token, "\(drive)")
      XCTAssertEqual(stored?.refreshToken, "refresh", "\(drive) keeps the refresh token")
    }
  }

  func testTokenAboutToExpireIsRenewedBeforeTheFirstRequest() async throws {
    let rig = makeRig(.dropbox, expires: Date().addingTimeInterval(10))
    let transport = rig.transport
    rig.server.lock.withLock { rig.server.token = "token-1" }
    _ = try await offMain { try transport.files() }
    XCTAssertEqual(rig.server.refreshCount, 1)
    XCTAssertEqual(rig.server.requests.first?.authorization, "Bearer token-2")
  }

  func testRevokedGrantEndsInUnavailableAndForgetsTheTokens() async throws {
    let rig = makeRig(.yandexDisk)
    let transport = rig.transport
    StubNetwork.install { request, _ in
      request.url?.host == "oauth.yandex.ru" ? (400, [:], Data()) : (401, [:], Data())
    }
    do {
      _ = try await offMain { try transport.files() }
      XCTFail("must fail")
    } catch {
      XCTAssertEqual(error as? ExchangeTransportError, .unavailable)
    }
    XCTAssertNil(try rig.store.load(), "the next connect starts from the sign-in page")
  }

  func testTooManyRequestsAndServerErrorsAreRetriedWithAPause() async throws {
    try await forEachDrive { drive in
      let rig = makeRig(drive)
      let transport = rig.transport
      rig.server.faults = [.status(429, retryAfter: "7"), .status(503, retryAfter: nil)]
      _ = try await offMain { try transport.files() }
      XCTAssertEqual(rig.sleeps.all, [7, 2], "\(drive): Retry-After first, then backoff")
    }
  }

  func testGivesUpAfterTheLastAttempt() async throws {
    let rig = makeRig(.dropbox, attempts: 3)
    let transport = rig.transport
    rig.server.faults = Array(repeating: .status(500, retryAfter: nil), count: 5)
    do {
      _ = try await offMain { try transport.files() }
      XCTFail("must fail")
    } catch {
      XCTAssertEqual(error as? ExchangeTransportError, .unavailable)
    }
    XCTAssertEqual(rig.sleeps.all, [1, 2])
  }

  func testCutConnectionWhileWritingIsNotACommittedFile() async throws {
    try await forEachDrive { drive in
      let rig = makeRig(drive, attempts: 1)
      let transport = rig.transport
      // The upload itself dies; the listing request that follows is not affected.
      rig.server.faultFilter = drive == .yandexDisk ? "uploader.example" : drive == .dropbox ? "files/upload" : "content"
      rig.server.faults = [.dropConnection]
      do {
        try await offMain { try transport.writeFile(named: journal(1), data: sealed("a"), replacing: false) }
        XCTFail("\(drive) reported a cut upload as written")
      } catch {
        XCTAssertEqual(error as? ExchangeTransportError, .unavailable, "\(drive)")
      }
      rig.server.faultFilter = ""
      let listed = try await offMain { try transport.files() }
      XCTAssertTrue(listed.isEmpty, "\(drive) must hold no file")
    }
  }

  func testAReplyLostAfterTheCommitCountsAsWrittenForTheSameBytes() async throws {
    let rig = makeRig(.dropbox, attempts: 1)
    let transport = rig.transport
    let server = rig.server
    let name = journal(1)
    let data = sealed("a")
    // The server stores the file, then the connection drops before the reply.
    StubNetwork.install { request, body in
      let reply = try server.handle(request, body)
      if request.url?.path == "/2/files/upload" { throw URLError(.networkConnectionLost) }
      return reply
    }
    try await offMain { try transport.writeFile(named: name, data: data, replacing: false) }
    XCTAssertEqual(server.files[name], data)
  }

  func testOneDriveLargeFileGoesInPiecesAndCommitsOnlyAtTheEnd() async throws {
    let rig = makeRig(.oneDrive) { client in
      CloudFileTransport(backend: OneDriveBackend(client: client, smallLimit: 10, chunkSize: 20))
    }
    let transport = rig.transport
    let server = rig.server as! FakeOneDrive
    let data = sealed("0123456789abcdefghijklmnopqrstuvwxyz")
    try await offMain { try transport.writeFile(named: journal(1), data: data, replacing: false) }
    XCTAssertEqual(server.files[journal(1)], data)
    let pieces = server.requests.filter { $0.url.contains("upload.example") }
    XCTAssertGreaterThan(pieces.count, 1, "sent in several pieces")
    XCTAssertTrue(pieces.allSatisfy { $0.authorization == nil }, "no token to the upload host")
  }

  func testOneDriveCutInTheMiddleOfPiecesAbandonsTheSession() async throws {
    let rig = makeRig(.oneDrive, attempts: 1) { client in
      CloudFileTransport(backend: OneDriveBackend(client: client, smallLimit: 10, chunkSize: 20))
    }
    let transport = rig.transport
    let server = rig.server as! FakeOneDrive
    server.faultFilter = "upload.example"
    // The first piece passes (the fault queue starts after one good request).
    StubNetwork.install { request, body in
      if request.url?.host == "upload.example", request.httpMethod == "PUT",
        request.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes 20-") == true
      {
        throw URLError(.networkConnectionLost)
      }
      return try server.handle(request, body)
    }
    do {
      try await offMain {
        try transport.writeFile(
          named: journal(1), data: sealed("0123456789abcdefghijklmnopqrstuvwxyz"),
          replacing: false)
      }
      XCTFail("a cut upload is not a write")
    } catch {
      XCTAssertEqual(error as? ExchangeTransportError, .unavailable)
    }
    XCTAssertNil(server.files[journal(1)])
    XCTAssertEqual(server.abandoned.count, 1, "the session is cancelled")
  }

  func testTheTokenIsNotSentToTheStorageHostOfYandex() async throws {
    let rig = makeRig(.yandexDisk)
    let transport = rig.transport
    try await offMain { try transport.writeFile(named: journal(1), data: sealed("a"), replacing: false) }
    _ = try await offMain { try transport.readFile(named: journal(1)) }
    let storage = rig.server.requests.filter {
      $0.url.contains("uploader.example") || $0.url.contains("downloader.example")
    }
    XCTAssertEqual(storage.count, 2)
    XCTAssertTrue(storage.allSatisfy { $0.authorization == nil })
    let api = rig.server.requests.filter { $0.url.contains("cloud-api.yandex.net") }
    XCTAssertTrue(api.allSatisfy { $0.authorization == "OAuth token-1" })
  }

  func testTransportRefusesTheMainThread() throws {
    let rig = makeRig(.dropbox)
    XCTAssertThrowsError(try rig.transport.files()) {
      XCTAssertEqual($0 as? ExchangeTransportError, .mainThread)
    }
  }

  // MARK: sign-in

  func testAuthorizationURLCarriesPKCEAndState() throws {
    var config = CloudDrive.oneDrive.oauth!
    config.clientId = "abc"
    let url = try XCTUnwrap(
      CloudOAuthFlow.authorizationURL(config: config, challenge: "chal", state: "st"))
    let items = Dictionary(
      uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        .map { ($0.name, $0.value ?? "") })
    XCTAssertEqual(items["client_id"], "abc")
    XCTAssertEqual(items["code_challenge"], "chal")
    XCTAssertEqual(items["code_challenge_method"], "S256")
    XCTAssertEqual(items["state"], "st")
    XCTAssertEqual(items["response_type"], "code")
    XCTAssertEqual(items["scope"], "Files.ReadWrite.AppFolder offline_access")
    XCTAssertEqual(CloudDrive.dropbox.oauth!.extraAuthorizeParameters["token_access_type"], "offline")
  }

  func testPKCEChallengeMatchesTheRFCVector() {
    // RFC 7636, appendix B.
    XCTAssertEqual(
      CloudPKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
      "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    let verifier = CloudPKCE.makeVerifier()
    XCTAssertGreaterThanOrEqual(verifier.count, 43)
    XCTAssertNotEqual(verifier, CloudPKCE.makeVerifier())
  }

  func testCallbackCodeIsReadAndAWrongStateOrDenialIsRefused() throws {
    let good = URL(string: "io.github.evgenybaulin.ohmymoney:/oauth/x?code=C1&state=S")!
    XCTAssertEqual(try CloudOAuthFlow.code(from: good, state: "S"), "C1")
    XCTAssertThrowsError(try CloudOAuthFlow.code(from: good, state: "other")) {
      XCTAssertEqual($0 as? CloudSignInError, .stateMismatch)
    }
    let denied = URL(string: "io.github.evgenybaulin.ohmymoney:/oauth/x?error=access_denied&state=S")!
    XCTAssertThrowsError(try CloudOAuthFlow.code(from: denied, state: "S")) {
      XCTAssertEqual($0 as? CloudSignInError, .denied)
    }
    let none = URL(string: "io.github.evgenybaulin.ohmymoney:/oauth/x?state=S")!
    XCTAssertThrowsError(try CloudOAuthFlow.code(from: none, state: "S")) {
      XCTAssertEqual($0 as? CloudSignInError, .badCallback)
    }
  }

  func testCodeExchangeStoresTokensAndSendsThePKCEVerifierWithoutASecret() async throws {
    let captured = SleepLog()
    final class Body: @unchecked Sendable { var text = "" }
    let body = Body()
    StubNetwork.install { _, data in
      body.text = String(decoding: data, as: UTF8.self)
      captured.add(1)
      return (200, [:], Data(#"{"access_token":"A","refresh_token":"R","expires_in":3600}"#.utf8))
    }
    var config = CloudDrive.dropbox.oauth!
    config.clientId = "app-key"
    let store = InMemoryCloudTokenStore()
    let authorizer = CloudAuthorizer(
      config: config, store: store, http: URLSessionCloudHTTP(session: StubNetwork.session()),
      now: { Date(timeIntervalSince1970: 1000) })
    try await offMain { try authorizer.exchange(code: "the code", verifier: "ver") }
    XCTAssertTrue(body.text.contains("code_verifier=ver"))
    XCTAssertTrue(body.text.contains("code=the%20code"))
    XCTAssertTrue(body.text.contains("client_id=app-key"))
    XCTAssertFalse(body.text.contains("client_secret"))
    let stored = try store.load()
    XCTAssertEqual(stored, CloudTokens(accessToken: "A", refreshToken: "R", expiresAt: Date(timeIntervalSince1970: 4600)))
    XCTAssertTrue(authorizer.isSignedIn)
    authorizer.disconnect()
    XCTAssertFalse(authorizer.isSignedIn)
  }
}
