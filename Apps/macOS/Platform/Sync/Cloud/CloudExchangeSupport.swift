import AppCore
import AppDatabase
import Foundation

/// What a drive has to offer, in four plain calls. Everything the exchange demands of a
/// transport (names, sealed bytes, same-bytes retry, snapshots-only replace) is in
/// `CloudFileTransport`, once, for every drive.
protocol CloudBackend: Sendable {
  /// Every committed file of the app folder, all pages.
  func list() throws -> [ExchangeFileInfo]
  /// `nil` when the file does not exist.
  func download(_ name: String) throws -> Data?
  /// Commits the whole file only if no file of that name exists; `false` when one does.
  func create(_ name: String, data: Data) throws -> Bool
  func replace(_ name: String, data: Data) throws
}

enum CloudExchangeNames {
  /// Only the journal and snapshot names the exchange itself makes. Nothing else is ever put
  /// into a drive path or request, so a name cannot carry a path or a query.
  static func isExchangeFile(_ name: String) -> Bool { CloudFileName.isExchangeFile(name) }

  static func isSnapshot(_ name: String) -> Bool { SyncSnapshotName.parse(name) != nil }

  static func isSealed(_ data: Data) -> Bool {
    SealedPayloadCodec.isSealed(data)
      && data.count >= SealedPayloadCodec.magic.count + SealedPayloadCodec.nonceByteCount
        + SealedPayloadCodec.tagByteCount
  }
}

final class CloudFileTransport<Backend: CloudBackend>: ExchangeFileTransport, @unchecked Sendable {
  private let backend: Backend

  init(backend: Backend) { self.backend = backend }

  func files() throws -> [ExchangeFileInfo] {
    try offMain {
      try backend.list().filter { CloudExchangeNames.isExchangeFile($0.name) }
    }
  }

  func readFile(named name: String) throws -> Data {
    try offMain {
      guard CloudExchangeNames.isExchangeFile(name) else { throw ExchangeTransportError.malformed }
      guard let data = try backend.download(name) else { throw ExchangeTransportError.missing }
      return data
    }
  }

  func writeFile(named name: String, data: Data, replacing: Bool) throws {
    try offMain {
      guard CloudExchangeNames.isExchangeFile(name),
        !replacing || CloudExchangeNames.isSnapshot(name), CloudExchangeNames.isSealed(data)
      else { throw ExchangeTransportError.malformed }
      if replacing {
        try backend.replace(name, data: data)
        return
      }
      do {
        if try backend.create(name, data: data) { return }
      } catch {
        // A reply lost after the server committed: the same bytes are already there.
        if (try? backend.download(name)) == data { return }
        throw error
      }
      guard try backend.download(name) == data else { throw ExchangeTransportError.fileChanged }
    }
  }

  private func offMain<T>(_ body: () throws -> T) throws -> T {
    guard !Thread.isMainThread else { throw ExchangeTransportError.mainThread }
    do { return try body() } catch let error as ExchangeTransportError { throw error } catch {
      throw ExchangeTransportError.unavailable
    }
  }
}

/// Names that may reach a remote path: only exchange files, only safe characters, so a name can
/// never climb out of the app folder or break a query.
enum CloudFileName {
  static func validate(_ name: String) throws {
    guard SyncFormat.parse(fileName: name) != nil || SyncSnapshotName.parse(name) != nil,
      name.count <= 200,
      name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) })
    else { throw ExchangeTransportError.malformed }
  }

  static func isExchangeFile(_ name: String) -> Bool { (try? validate(name)) != nil }
}

/// A listing that never ends is a server fault (or a hostile one): a drive gives up after this
/// many pages instead of holding the exchange for ever.
enum CloudPaging {
  static let maxPages = 1_000

  static func count(_ pages: inout Int) throws {
    pages += 1
    guard pages <= maxPages else { throw ExchangeTransportError.unavailable }
  }
}

extension CloudFileName {
  /// An identifier a server hands back (a Drive file id): it goes into a request path, so
  /// anything but the plain characters of such an id is refused, never trusted.
  static func isSafeRemoteId(_ id: String) -> Bool {
    !id.isEmpty && id.count <= 200
      && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) }
  }
}

/// Dates of the three services: ISO 8601 with or without fractions, and RFC 1123 for WebDAV.
enum CloudDates {
  static func parse(_ text: String) -> Date? { iso(text) }

  static func iso(_ text: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: text) { return date }
    return ISO8601DateFormatter().date(from: text)
  }

  static func rfc1123(_ text: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: text)
  }
}

extension URLRequest {
  static func cloud(
    _ url: URL, method: String = "GET", body: Data? = nil, headers: [String: String] = [:]
  )
    -> URLRequest
  {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    return request
  }
}
