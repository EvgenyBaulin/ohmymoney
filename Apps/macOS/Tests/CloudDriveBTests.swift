import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// A fake server: every request of the test session goes to `handler`, no network is touched.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
  struct Seen {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: Data
  }

  nonisolated(unsafe) static var handler: (@Sendable (Seen) throws -> (Int, [String: String], Data))?
  nonisolated(unsafe) static var seen: [Seen] = []
  private static let lock = NSLock()

  static func reset(_ handler: @escaping @Sendable (Seen) throws -> (Int, [String: String], Data)) {
    lock.withLock {
      seen = []
      self.handler = handler
    }
  }

  static var requests: [Seen] { lock.withLock { seen } }

  static func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: configuration)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    var body = request.httpBody ?? Data()
    if let stream = request.httpBodyStream {
      stream.open()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        body.append(buffer, count: count)
      }
      stream.close()
    }
    let seen = Seen(
      method: request.httpMethod ?? "GET", url: request.url ?? URL(fileURLWithPath: "/"),
      headers: request.allHTTPHeaderFields ?? [:], body: body)
    guard let handler = Self.lock.withLock({ Self.handler }) else { return }
    Self.lock.withLock { Self.seen.append(seen) }
    do {
      let (status, headers, data) = try handler(seen)
      let response = HTTPURLResponse(
        url: seen.url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

private func json(_ object: Any) -> Data {
  (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

private let journal = SyncFormat.fileName(deviceId: "dev-a", sequence: 1)
private let journal2 = SyncFormat.fileName(deviceId: "dev-a", sequence: 2)
private let snapshot = SyncSnapshotName.fileName(deviceId: "dev-a")
private let payload = Data([1, 2, 3, 4])

private func tokenAnswer(_ seen: StubProtocol.Seen) -> (Int, [String: String], Data)? {
  seen.url.host == "oauth2.googleapis.com"
    ? (200, [:], json(["access_token": "acc", "expires_in": 3600])) : nil
}

/// Runs off the main thread, as the exchange does: the transports refuse the main thread.
private func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) throws -> T {
  var result: Result<T, Error>?
  let done = DispatchSemaphore(value: 0)
  DispatchQueue.global().async {
    result = Result { try work() }
    done.signal()
  }
  done.wait()
  return try result!.get()
}

final class CloudHTTPBTests: XCTestCase {
  func testRateLimitIsRetriedThenSucceeds() throws {
    let count = Counter()
    StubProtocol.reset { _ in
      count.increment() < 3 ? (429, ["Retry-After": "0"], Data()) : (200, [:], Data("ok".utf8))
    }
    let http = CloudHTTPB(session: StubProtocol.session(), pause: { _ in })
    let response = try offMain { try http.send(URLRequest(url: URL(string: "https://x.test/a")!)) }
    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(StubProtocol.requests.count, 3)
  }

  func testServerErrorsEndAsUnavailable() {
    StubProtocol.reset { _ in (503, [:], Data()) }
    let http = CloudHTTPB(session: StubProtocol.session(), maxAttempts: 3, pause: { _ in })
    XCTAssertThrowsError(
      try offMain { try http.send(URLRequest(url: URL(string: "https://x.test/a")!)) }
    ) { XCTAssertEqual($0 as? ExchangeTransportError, .unavailable) }
    XCTAssertEqual(StubProtocol.requests.count, 3)
  }

  func testUnauthorizedRefreshesOnceAndRetries() throws {
    let token = Counter()
    StubProtocol.reset { seen in
      seen.headers["Authorization"] == "Bearer t1" ? (200, [:], Data()) : (401, [:], Data())
    }
    let http = CloudHTTPB(
      session: StubProtocol.session(), pause: { _ in },
      authorize: { $0.setValue("Bearer t\(max(token.value, 0))", forHTTPHeaderField: "Authorization") },
      refresh: { _ = token.increment() })
    let response = try offMain { try http.send(URLRequest(url: URL(string: "https://x.test/a")!)) }
    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(StubProtocol.requests.count, 2)
  }

  func testUnauthorizedTwiceGivesUp() {
    StubProtocol.reset { _ in (401, [:], Data()) }
    let http = CloudHTTPB(
      session: StubProtocol.session(), pause: { _ in }, authorize: { _ in }, refresh: {})
    XCTAssertThrowsError(
      try offMain { try http.send(URLRequest(url: URL(string: "https://x.test/a")!)) }
    ) { XCTAssertEqual($0 as? ExchangeTransportError, .unavailable) }
    XCTAssertEqual(StubProtocol.requests.count, 2)
  }

  func testDroppedConnectionIsNotACommit() {
    StubProtocol.reset { _ in throw URLError(.networkConnectionLost) }
    let http = CloudHTTPB(session: StubProtocol.session(), maxAttempts: 2, pause: { _ in })
    XCTAssertThrowsError(
      try offMain { try http.send(URLRequest(url: URL(string: "https://x.test/a")!)) }
    ) { XCTAssertEqual($0 as? ExchangeTransportError, .unavailable) }
  }

  func testMainThreadIsRefused() {
    let http = CloudHTTPB(session: StubProtocol.session())
    XCTAssertThrowsError(try http.send(URLRequest(url: URL(string: "https://x.test/a")!))) {
      XCTAssertEqual($0 as? ExchangeTransportError, .mainThread)
    }
  }

  func testOnlyExchangeFileNamesReachAPath() {
    XCTAssertNoThrow(try CloudFileName.validate(journal))
    XCTAssertNoThrow(try CloudFileName.validate(snapshot))
    XCTAssertThrowsError(try CloudFileName.validate("../secret"))
    XCTAssertThrowsError(try CloudFileName.validate("notes.txt"))
  }

  func testBackoffHonoursRetryAfterWithACap() {
    XCTAssertEqual(CloudHTTPB.backoff(attempt: 1, retryAfter: "2"), 2)
    XCTAssertEqual(CloudHTTPB.backoff(attempt: 1, retryAfter: "999"), 30)
    XCTAssertGreaterThan(CloudHTTPB.backoff(attempt: 3, retryAfter: nil), CloudHTTPB.backoff(attempt: 1, retryAfter: nil))
  }
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  /// Increments and returns the new value.
  func increment() -> Int { lock.withLock { count += 1; return count } }
  var value: Int { lock.withLock { count } }
}

final class GoogleDriveTransportTests: XCTestCase {
  private func makeTransport(
    store: MemoryCloudCredentialStore = MemoryCloudCredentialStore(), pageSize: Int = 2
  ) -> GoogleDriveTransport {
    try? store.save("refresh-1", account: GoogleDriveConfig.refreshAccount)
    let urlSession = StubProtocol.session()
    let session = GoogleDriveSession(clientID: "cid.apps.googleusercontent.com", store: store, session: urlSession)
    return GoogleDriveTransport(session: session, urlSession: urlSession, pageSize: pageSize)
  }

  func testPKCEMatchesTheRFCVector() {
    let pair = PKCEPair.make(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
    XCTAssertEqual(pair.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    XCTAssertGreaterThanOrEqual(PKCEPair.random().count, 43)
  }

  func testAuthorizationURLCarriesPKCEAndTheNarrowScope() throws {
    let session = GoogleDriveSession(
      clientID: "abc.apps.googleusercontent.com", store: MemoryCloudCredentialStore())
    let url = try XCTUnwrap(session.authorizationURL(pkce: PKCEPair.make(verifier: "v"), state: "s"))
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
    XCTAssertEqual(value("code_challenge_method"), "S256")
    XCTAssertEqual(value("scope"), GoogleDriveConfig.scope)
    XCTAssertEqual(value("redirect_uri"), "com.googleusercontent.apps.abc:/oauth2redirect")
  }

  func testListingFollowsEveryPageAndSkipsStrangers() throws {
    StubProtocol.reset { seen in
      if let answer = tokenAnswer(seen) { return answer }
      let token = URLComponents(url: seen.url, resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == "pageToken" }?.value
      let time = "2026-11-01T10:00:00.000Z"
      if token == nil {
        return (200, [:], json([
          "nextPageToken": "p2",
          "files": [["name": journal, "modifiedTime": time], ["name": "stranger.txt", "modifiedTime": time]],
        ]))
      }
      return (200, [:], json(["files": [["name": snapshot, "modifiedTime": time]]]))
    }
    let transport = makeTransport()
    let files = try offMain { try transport.files() }
    XCTAssertEqual(Set(files.map(\.name)), [journal, snapshot])
    let listing = StubProtocol.requests.filter { $0.url.path.hasSuffix("/drive/v3/files") }
    XCTAssertEqual(listing.count, 2)
    XCTAssertTrue(listing[0].url.absoluteString.contains("appDataFolder"))
  }

  func testReadReturnsTheBytes() throws {
    StubProtocol.reset { seen in
      if let answer = tokenAnswer(seen) { return answer }
      if seen.url.query?.contains("alt=media") == true { return (200, [:], payload) }
      return (200, [:], json(["files": [["id": "F1"]]]))
    }
    let transport = makeTransport()
    XCTAssertEqual(try offMain { try transport.readFile(named: journal) }, payload)
  }

  func testReadOfAMissingFile() {
    StubProtocol.reset { seen in
      tokenAnswer(seen) ?? (200, [:], json(["files": []]))
    }
    let transport = makeTransport()
    XCTAssertThrowsError(try offMain { try transport.readFile(named: journal) }) {
      XCTAssertEqual($0 as? ExchangeTransportError, .missing)
    }
  }

  func testNewFileIsUploadedIntoTheAppFolder() throws {
    StubProtocol.reset { seen in
      if let answer = tokenAnswer(seen) { return answer }
      if seen.method == "POST" { return (200, [:], json(["id": "N"])) }
      return (200, [:], json(["files": []]))
    }
    let transport = makeTransport()
    try offMain { try transport.writeFile(named: journal, data: payload, replacing: false) }
    let upload = try XCTUnwrap(StubProtocol.requests.first { $0.method == "POST" && $0.url.host == "www.googleapis.com" })
    let text = String(decoding: upload.body, as: UTF8.self)
    XCTAssertTrue(text.contains("appDataFolder"))
    XCTAssertTrue(text.contains(journal))
    XCTAssertNotNil(upload.body.range(of: payload))
  }

  func testExistingFileWithSameBytesIsARetryAndDifferentBytesAreRefused() throws {
    let stored = Counter()
    StubProtocol.reset { seen in
      if let answer = tokenAnswer(seen) { return answer }
      if seen.url.query?.contains("alt=media") == true {
        return (200, [:], stored.value == 0 ? payload : Data([9]))
      }
      return (200, [:], json(["files": [["id": "F1"]]]))
    }
    let transport = makeTransport()
    XCTAssertNoThrow(try offMain { try transport.writeFile(named: journal, data: payload, replacing: false) })
    _ = stored.increment()
    XCTAssertThrowsError(try offMain { try transport.writeFile(named: journal, data: payload, replacing: false) }) {
      XCTAssertEqual($0 as? ExchangeTransportError, .fileChanged)
    }
  }

  func testSnapshotReplacementPatchesTheExistingFile() throws {
    StubProtocol.reset { seen in
      if let answer = tokenAnswer(seen) { return answer }
      if seen.method == "PATCH" { return (200, [:], Data()) }
      return (200, [:], json(["files": [["id": "F1"]]]))
    }
    let transport = makeTransport()
    try offMain { try transport.writeFile(named: snapshot, data: payload, replacing: true) }
    let patch = try XCTUnwrap(StubProtocol.requests.first { $0.method == "PATCH" })
    XCTAssertEqual(patch.body, payload)
    XCTAssertTrue(patch.url.path.hasSuffix("/F1"))
  }

  func testFailedUploadIsNotACommit() {
    StubProtocol.reset { seen in
      if let answer = tokenAnswer(seen) { return answer }
      if seen.method == "POST" { throw URLError(.networkConnectionLost) }
      return (200, [:], json(["files": []]))
    }
    let transport = makeTransport()
    XCTAssertThrowsError(try offMain { try transport.writeFile(named: journal2, data: payload, replacing: false) })
  }

  func testRejectedTokenIsRefreshedAndTheCallRepeated() throws {
    let drive = Counter()
    StubProtocol.reset { seen in
      if seen.url.host == "oauth2.googleapis.com" {
        return (200, [:], json(["access_token": "acc\(drive.increment())", "expires_in": 3600]))
      }
      if seen.headers["Authorization"] == "Bearer acc1" { return (401, [:], Data()) }
      return (200, [:], json(["files": []]))
    }
    let transport = makeTransport()
    XCTAssertEqual(try offMain { try transport.files() }.count, 0)
    XCTAssertEqual(drive.value, 2)
  }

  func testRefreshTokenStaysInTheStoreAndSignOutRemovesIt() throws {
    let store = MemoryCloudCredentialStore()
    StubProtocol.reset { seen in
      (200, [:], json(["access_token": "a", "refresh_token": "r-new", "expires_in": 3600]))
    }
    let session = GoogleDriveSession(clientID: "c", store: store, session: StubProtocol.session())
    try offMain { try session.completeSignIn(code: "code", pkce: PKCEPair.make(verifier: "v")) }
    XCTAssertEqual(store.load(account: GoogleDriveConfig.refreshAccount), "r-new")
    let sent = String(decoding: StubProtocol.requests[0].body, as: UTF8.self)
    XCTAssertTrue(sent.contains("code_verifier=v"))
    XCTAssertTrue(session.isConnected)
    session.signOut()
    XCTAssertFalse(session.isConnected)
  }
}

final class SupabaseStorageTransportTests: XCTestCase {
  private func makeTransport(pageSize: Int = 2) throws -> SupabaseStorageTransport {
    let config = try XCTUnwrap(SupabaseConfig(url: "https://proj.supabase.test/", key: "KEY"))
    return SupabaseStorageTransport(config: config, urlSession: StubProtocol.session(), pageSize: pageSize)
  }

  func testConfigNeedsHTTPSAndAKey() {
    XCTAssertNil(SupabaseConfig(url: "http://proj.supabase.test", key: "k"))
    XCTAssertNil(SupabaseConfig(url: "https://proj.supabase.test", key: " "))
    XCTAssertNil(SupabaseConfig(url: "not a url", key: "k"))
    XCTAssertNotNil(SupabaseConfig(url: "https://proj.supabase.test", key: "k"))
  }

  func testConfigRoundTripsThroughTheStore() throws {
    let store = MemoryCloudCredentialStore()
    let config = try XCTUnwrap(SupabaseConfig(url: "https://proj.supabase.test", key: "k"))
    try config.save(to: store)
    XCTAssertEqual(SupabaseConfig.load(from: store), config)
  }

  func testListingPagesByOffsetAndSendsTheKey() throws {
    StubProtocol.reset { seen in
      let body = (try? JSONSerialization.jsonObject(with: seen.body)) as? [String: Any]
      let offset = body?["offset"] as? Int ?? -1
      let stamp = "2026-11-01T10:00:00.5+00:00"
      switch offset {
      case 0: return (200, [:], json([["name": journal, "updated_at": stamp], ["name": "x.txt", "updated_at": stamp]]))
      case 2: return (200, [:], json([["name": snapshot, "updated_at": stamp]]))
      default: return (200, [:], json([[String: String]]()))
      }
    }
    let transport = try makeTransport()
    let files = try offMain { try transport.files() }
    XCTAssertEqual(Set(files.map(\.name)), [journal, snapshot])
    XCTAssertEqual(StubProtocol.requests.count, 2)
    XCTAssertEqual(StubProtocol.requests[0].headers["apikey"], "KEY")
    XCTAssertEqual(StubProtocol.requests[0].headers["Authorization"], "Bearer KEY")
  }

  func testWriteThenReadBack() throws {
    let stored = Locked()
    StubProtocol.reset { seen in
      if seen.method == "POST", seen.url.path.contains("/object/ohmymoney-exchange/") {
        stored.set(seen.body)
        return (200, [:], json(["Key": "k"]))
      }
      if let data = stored.get() { return (200, [:], data) }
      return (404, [:], json(["error": "not_found"]))
    }
    let transport = try makeTransport()
    try offMain { try transport.writeFile(named: journal, data: payload, replacing: false) }
    XCTAssertEqual(try offMain { try transport.readFile(named: journal) }, payload)
    let post = try XCTUnwrap(StubProtocol.requests.first { $0.method == "POST" })
    XCTAssertEqual(post.headers["x-upsert"], "false")
  }

  func testDifferentExistingBytesAreRefused() throws {
    StubProtocol.reset { _ in (200, [:], Data([7, 7])) }
    let transport = try makeTransport()
    XCTAssertThrowsError(try offMain { try transport.writeFile(named: journal, data: payload, replacing: false) }) {
      XCTAssertEqual($0 as? ExchangeTransportError, .fileChanged)
    }
  }

  func testLostRaceWithIdenticalBytesIsARetry() throws {
    let reads = Counter()
    StubProtocol.reset { seen in
      if seen.method == "POST" { return (409, [:], json(["error": "Duplicate"])) }
      return reads.increment() == 1 ? (404, [:], Data()) : (200, [:], payload)
    }
    let transport = try makeTransport()
    XCTAssertNoThrow(try offMain { try transport.writeFile(named: journal, data: payload, replacing: false) })
  }

  func testSnapshotReplacementUsesUpsert() throws {
    StubProtocol.reset { _ in (200, [:], Data()) }
    let transport = try makeTransport()
    try offMain { try transport.writeFile(named: snapshot, data: payload, replacing: true) }
    XCTAssertEqual(StubProtocol.requests[0].headers["x-upsert"], "true")
  }

  func testServerFailureIsNotACommit() throws {
    StubProtocol.reset { seen in seen.method == "GET" ? (404, [:], Data()) : (500, [:], Data()) }
    let http = try makeTransport()
    XCTAssertThrowsError(try offMain { try http.writeFile(named: journal, data: payload, replacing: false) })
  }
}

private final class Locked: @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?
  func set(_ value: Data) { lock.withLock { data = value } }
  func get() -> Data? { lock.withLock { data } }
}

private func multistatus(_ entries: [(String, String?)]) -> Data {
  let rows = entries.map { href, date in
    "<d:response><d:href>\(href)</d:href><d:propstat><d:prop>"
      + (date.map { "<d:getlastmodified>\($0)</d:getlastmodified>" } ?? "")
      + "</d:prop></d:propstat></d:response>"
  }.joined()
  return Data("<?xml version=\"1.0\"?><d:multistatus xmlns:d=\"DAV:\">\(rows)</d:multistatus>".utf8)
}

final class MailRuCloudTransportTests: XCTestCase {
  private func makeTransport() throws -> MailRuCloudTransport {
    let config = try XCTUnwrap(MailRuCloudConfig(login: "me@mail.test", appPassword: "pw"))
    return MailRuCloudTransport(config: config, urlSession: StubProtocol.session(), base: "https://dav.test")
  }

  func testConfigNeedsALoginAndAnAppPassword() {
    XCTAssertNil(MailRuCloudConfig(login: "nobody", appPassword: "p"))
    XCTAssertNil(MailRuCloudConfig(login: "a@b.c", appPassword: ""))
    XCTAssertNotNil(MailRuCloudConfig(login: "a@b.c", appPassword: "p"))
  }

  func testListingKeepsExchangeFilesOnly() throws {
    let date = "Sun, 01 Nov 2026 10:00:00 GMT"
    StubProtocol.reset { _ in
      (207, [:], multistatus([
        ("/OhMyMoney/", date), ("/OhMyMoney/\(journal)", date), ("/OhMyMoney/\(snapshot)", date),
        ("/OhMyMoney/other.txt", date), ("/OhMyMoney/\(journal2)", nil),
      ]))
    }
    let transport = try makeTransport()
    let files = try offMain { try transport.files() }
    XCTAssertEqual(Set(files.map(\.name)), [journal, snapshot])
    let request = StubProtocol.requests[0]
    XCTAssertEqual(request.method, "PROPFIND")
    XCTAssertEqual(request.headers["Depth"], "1")
    let expected = Data("me@mail.test:pw".utf8).base64EncodedString()
    XCTAssertEqual(request.headers["Authorization"], "Basic \(expected)")
  }

  func testMissingFolderIsCreatedAndListsEmpty() throws {
    StubProtocol.reset { seen in seen.method == "PROPFIND" ? (404, [:], Data()) : (201, [:], Data()) }
    let transport = try makeTransport()
    XCTAssertEqual(try offMain { try transport.files() }.count, 0)
    XCTAssertEqual(StubProtocol.requests.map(\.method), ["PROPFIND", "MKCOL"])
  }

  func testWritePutsTheBytesAndCreatesTheFolderWhenNeeded() throws {
    let puts = Counter()
    StubProtocol.reset { seen in
      switch seen.method {
      case "GET": return (404, [:], Data())
      case "PUT": return puts.increment() == 1 ? (409, [:], Data()) : (201, [:], Data())
      default: return (201, [:], Data())
      }
    }
    let transport = try makeTransport()
    try offMain { try transport.writeFile(named: journal, data: payload, replacing: false) }
    XCTAssertEqual(StubProtocol.requests.map(\.method), ["GET", "PUT", "MKCOL", "PUT"])
    XCTAssertEqual(StubProtocol.requests.last?.body, payload)
  }

  func testReadAndMissing() throws {
    StubProtocol.reset { seen in seen.url.path.hasSuffix(journal) ? (200, [:], payload) : (404, [:], Data()) }
    let transport = try makeTransport()
    XCTAssertEqual(try offMain { try transport.readFile(named: journal) }, payload)
    XCTAssertThrowsError(try offMain { try transport.readFile(named: journal2) }) {
      XCTAssertEqual($0 as? ExchangeTransportError, .missing)
    }
  }

  func testDifferentExistingBytesAreRefusedAndFailedPutIsNotACommit() throws {
    StubProtocol.reset { seen in seen.method == "GET" ? (200, [:], Data([5])) : (500, [:], Data()) }
    let transport = try makeTransport()
    XCTAssertThrowsError(try offMain { try transport.writeFile(named: journal, data: payload, replacing: false) }) {
      XCTAssertEqual($0 as? ExchangeTransportError, .fileChanged)
    }
    XCTAssertThrowsError(try offMain { try transport.writeFile(named: snapshot, data: payload, replacing: true) }) {
      XCTAssertEqual($0 as? ExchangeTransportError, .unavailable)
    }
  }
}

final class CloudDriveRegistryBTests: XCTestCase {
  func testGoogleCannotConnectWithoutAnAppKey() {
    XCTAssertFalse(GoogleDriveConfig.isConfigured)
    XCTAssertFalse(CloudDriveKindB.googleDrive.isConnectable)
    XCTAssertEqual(CloudDriveKindB.googleDrive.unavailableReasonKey, "cloud.keyMissing")
  }

  func testTheOwnersOwnKeyDrivesNeedNoAppKey() {
    XCTAssertNil(CloudDriveKindB.supabase.unavailableReasonKey)
    XCTAssertNil(CloudDriveKindB.mailRuCloud.unavailableReasonKey)
    XCTAssertEqual(CloudDriveKindB.allCases.count, 3)
  }

  func testEveryDriveShowsTheOpenFilesWarning() {
    for kind in CloudDriveKindB.allCases { XCTAssertEqual(kind.openFilesWarningKey, "cloud.openFilesWarning") }
  }

  func testCredentialStoreForgetsOnRemove() {
    let store = MemoryCloudCredentialStore()
    try? store.save("v", account: "a")
    XCTAssertEqual(store.load(account: "a"), "v")
    store.remove(account: "a")
    XCTAssertNil(store.load(account: "a"))
  }
}
