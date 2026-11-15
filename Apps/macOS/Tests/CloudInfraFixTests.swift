import AppCore
import Foundation
import XCTest

@testable import OhMyMoney

/// Reliability of three cloud transports against fake servers: a dropped Mail.ru write leaves no
/// half file under the real name, a Yandex 202 is waited out, and two Google files of one name
/// are read the same way every time.
final class CloudInfraFixTests: XCTestCase {
  private struct Scripted: CloudHTTPTransporting {
    let reply: @Sendable (URLRequest) throws -> CloudHTTPResponse
    func perform(_ request: URLRequest) throws -> CloudHTTPResponse { try reply(request) }
  }

  private func client(
    _ reply: @escaping @Sendable (URLRequest) throws -> CloudHTTPResponse
  )
    -> CloudHTTPClient
  {
    CloudHTTPClient(
      http: Scripted(reply: reply), authorizer: StaticCloudAuthorizer(headers: [:]),
      retry: CloudRetryPolicy(maxAttempts: 1, sleep: { _ in }))
  }

  private let snapshot = "snapshot-device1.ohmymoney-snapshot"
  private let journal = "journal-device1-0000000001.json"

  // MARK: Mail.ru

  private final class FakeWebDAV: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private var broken = false
    private(set) var methods: [String] = []

    var files: [String: Data] { lock.withLock { storage } }
    func breakConnection(_ value: Bool) { lock.withLock { broken = value } }

    func handle(_ request: URLRequest) throws -> CloudHTTPResponse {
      try lock.withLock {
        let method = request.httpMethod ?? "GET"
        methods.append(method)
        let name = request.url?.lastPathComponent ?? ""
        switch method {
        case "PUT":
          let body = request.httpBody ?? Data()
          if broken {
            // The connection drops after half of the bytes have been stored.
            storage[name] = body.prefix(body.count / 2)
            throw URLError(.networkConnectionLost)
          }
          storage[name] = body
          return CloudHTTPResponse(status: 201)
        case "MOVE":
          guard let destination = request.value(forHTTPHeaderField: "Destination"),
            let target = URL(string: destination)?.lastPathComponent,
            let data = storage[name]
          else { return CloudHTTPResponse(status: 404) }
          if request.value(forHTTPHeaderField: "Overwrite") == "F", storage[target] != nil {
            return CloudHTTPResponse(status: 412)
          }
          storage[name] = nil
          storage[target] = data
          return CloudHTTPResponse(status: 201)
        case "DELETE":
          storage[name] = nil
          return CloudHTTPResponse(status: 204)
        case "MKCOL": return CloudHTTPResponse(status: 201)
        default:
          if let data = storage[name] { return CloudHTTPResponse(status: 200, body: data) }
          return CloudHTTPResponse(status: 404)
        }
      }
    }
  }

  private func mailRu(_ server: FakeWebDAV) -> MailRuCloudTransport {
    MailRuCloudTransport(client: client(server.handle), base: "https://dav.test")
  }

  func testMailRuDroppedWriteLeavesNothingUnderTheRealNameAndTheRetryPasses() throws {
    let server = FakeWebDAV()
    let transport = mailRu(server)
    let journal = self.journal
    let data = Data(repeating: 7, count: 400)
    server.breakConnection(true)
    XCTAssertThrowsError(
      try offMain { try transport.writeFile(named: journal, data: data, replacing: false) })
    XCTAssertNil(server.files[journal], "a half file must never sit under the exchange name")
    XCTAssertThrowsError(try offMain { try transport.readFile(named: journal) }) {
      XCTAssertEqual($0 as? ExchangeTransportError, .missing)
    }
    server.breakConnection(false)
    try offMain { try transport.writeFile(named: journal, data: data, replacing: false) }
    XCTAssertEqual(server.files[journal], data)
    XCTAssertTrue(server.methods.contains("MOVE"))
  }

  func testMailRuReplaceMovesOverTheOldFileAndSecondWriteOfTheSameBytesIsAccepted() throws {
    let server = FakeWebDAV()
    let transport = mailRu(server)
    let snapshot = self.snapshot
    try offMain { try transport.writeFile(named: snapshot, data: Data([1]), replacing: true) }
    try offMain { try transport.writeFile(named: snapshot, data: Data([2]), replacing: true) }
    XCTAssertEqual(server.files[snapshot], Data([2]))
    try offMain { try transport.writeFile(named: snapshot, data: Data([2]), replacing: false) }
    XCTAssertThrowsError(
      try offMain { try transport.writeFile(named: snapshot, data: Data([3]), replacing: false) }
    ) { XCTAssertEqual($0 as? ExchangeTransportError, .fileChanged) }
    XCTAssertEqual(server.files.keys.sorted(), [snapshot], "no temporary file is left behind")
  }

  // MARK: Yandex

  private final class FakeYandex: @unchecked Sendable {
    private let lock = NSLock()
    var statuses: [String]
    let withOperationId: Bool
    private(set) var polls = 0
    private(set) var metadataChecks = 0

    init(statuses: [String], withOperationId: Bool = true) {
      self.statuses = statuses
      self.withOperationId = withOperationId
    }

    func handle(_ request: URLRequest) -> CloudHTTPResponse {
      lock.withLock {
        let url = request.url!
        if url.host == "uploader.example" { return CloudHTTPResponse(status: 202) }
        if url.path.hasSuffix("/resources/upload") {
          let extra = withOperationId ? #","operation_id":"op1""# : ""
          return CloudHTTPResponse(
            status: 200, body: Data(#"{"href":"https://uploader.example/put/x"\#(extra)}"#.utf8))
        }
        if url.path.hasSuffix("/operations/op1") {
          polls += 1
          let status = statuses.isEmpty ? "in-progress" : statuses.removeFirst()
          return CloudHTTPResponse(status: 200, body: Data(#"{"status":"\#(status)"}"#.utf8))
        }
        if url.path.hasSuffix("/disk/resources") {
          metadataChecks += 1
          if statuses.isEmpty { return CloudHTTPResponse(status: 200) }
          statuses.removeFirst()
          return CloudHTTPResponse(status: 404)
        }
        return CloudHTTPResponse(status: 404)
      }
    }
  }

  private func yandex(_ server: FakeYandex, maxPolls: Int = 5) -> (YandexDiskBackend, Slept) {
    let slept = Slept()
    var backend = YandexDiskBackend(client: client { server.handle($0) })
    backend.maxPolls = maxPolls
    backend.pollSleep = { slept.add($0) }
    return (backend, slept)
  }

  func testYandexAcceptedUploadIsWaitedForUntilTheOperationSucceeds() throws {
    let server = FakeYandex(statuses: ["in-progress", "in-progress", "success"])
    let (backend, slept) = yandex(server)
    let snapshot = self.snapshot
    XCTAssertTrue(try offMain { try backend.create(snapshot, data: Data([1])) })
    XCTAssertEqual(server.polls, 3)
    XCTAssertEqual(slept.count, 2)
  }

  func testYandexUploadThatNeverFinishesIsNotWritten() {
    let server = FakeYandex(statuses: [])
    let (backend, _) = yandex(server, maxPolls: 3)
    let snapshot = self.snapshot
    XCTAssertThrowsError(try offMain { _ = try backend.create(snapshot, data: Data([1])) }) {
      XCTAssertEqual($0 as? ExchangeTransportError, .unavailable)
    }
    XCTAssertEqual(server.polls, 3)
  }

  func testYandexFailedOperationIsNotWritten() {
    let server = FakeYandex(statuses: ["in-progress", "failed"])
    let (backend, _) = yandex(server)
    let snapshot = self.snapshot
    XCTAssertThrowsError(try offMain { try backend.replace(snapshot, data: Data([1])) }) {
      XCTAssertEqual($0 as? ExchangeTransportError, .unavailable)
    }
  }

  func testYandexWithoutAnOperationIdWaitsForTheFileToAppear() throws {
    let server = FakeYandex(statuses: ["x", "x"], withOperationId: false)
    let (backend, _) = yandex(server)
    let snapshot = self.snapshot
    XCTAssertTrue(try offMain { try backend.create(snapshot, data: Data([1])) })
    XCTAssertEqual(server.metadataChecks, 3)
  }

  // MARK: Google

  private struct GoogleFile {
    var id: String
    var created: String
    var modified: String
    var content: Data
  }

  private func google(_ files: [GoogleFile], name: String) -> GoogleDriveTransport {
    GoogleDriveTransport(
      client: client { request in
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let filter = query.first { $0.name == "q" }?.value ?? ""
        if url.path.hasSuffix("/files"), let _ = filter.range(of: "name=") {
          return Self.json(files, name: name)
        }
        if url.path.hasSuffix("/files") { return Self.json(files, name: name) }
        let id = url.lastPathComponent
        if let found = files.first(where: { $0.id == id }) {
          return CloudHTTPResponse(status: 200, body: found.content)
        }
        return CloudHTTPResponse(status: 404)
      })
  }

  private static func json(_ files: [GoogleFile], name: String) -> CloudHTTPResponse {
    let items = files.map {
      #"{"id":"\#($0.id)","name":"\#(name)","createdTime":"\#($0.created)","modifiedTime":"\#($0.modified)"}"#
    }
    return CloudHTTPResponse(
      status: 200, body: Data(#"{"files":[\#(items.joined(separator: ","))]}"#.utf8))
  }

  func testGoogleTwoFilesOfOneNameAreReadAsTheEarliestCreatedInAnyOrder() throws {
    let early = GoogleFile(
      id: "bbb", created: "2026-11-01T10:00:00.000Z", modified: "2026-11-01T10:00:00.000Z",
      content: Data([1]))
    let late = GoogleFile(
      id: "aaa", created: "2026-11-01T10:00:05.000Z", modified: "2026-11-02T10:00:00.000Z",
      content: Data([2]))
    for order in [[early, late], [late, early]] {
      let journal = self.journal
      let transport = google(order, name: journal)
      XCTAssertEqual(try offMain { try transport.readFile(named: journal) }, Data([1]))
      let listed = try offMain { try transport.files() }
      XCTAssertEqual(listed.count, 1)
      XCTAssertEqual(listed.first?.modified, CloudDates.iso(early.modified))
    }
  }

  func testGoogleTieOnCreationTimeIsBrokenByTheSmallerId() throws {
    let one = GoogleFile(
      id: "id-b", created: "2026-11-01T10:00:00.000Z", modified: "2026-11-01T10:00:00.000Z",
      content: Data([1]))
    let two = GoogleFile(
      id: "id-a", created: "2026-11-01T10:00:00.000Z", modified: "2026-11-01T10:00:00.000Z",
      content: Data([2]))
    for order in [[one, two], [two, one]] {
      let journal = self.journal
      let transport = google(order, name: journal)
      XCTAssertEqual(try offMain { try transport.readFile(named: journal) }, Data([2]))
    }
  }
}

private final class Slept: @unchecked Sendable {
  private let lock = NSLock()
  private var seen = 0
  func add(_ value: TimeInterval) { lock.withLock { seen += 1 } }
  var count: Int { lock.withLock { seen } }
}

/// The semaphore of `offMain` orders the write on the global queue before the read.
private final class OffMainBox<T>: @unchecked Sendable { var result: Result<T, Error>? }

/// Runs off the main thread, as the exchange does: the transports refuse the main thread.
private func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) throws -> T {
  let box = OffMainBox<T>()
  let done = DispatchSemaphore(value: 0)
  DispatchQueue.global().async {
    box.result = Result { try work() }
    done.signal()
  }
  done.wait()
  return try XCTUnwrap(box.result).get()
}
