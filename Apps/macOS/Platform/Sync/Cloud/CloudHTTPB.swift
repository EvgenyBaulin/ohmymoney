import AppCore
import AppDatabase
import Foundation
import Security

// Interim blocking HTTP helper of the Google Drive, Mail.ru Cloud and Supabase transports.
// It lives apart from the shared helper of the other drives so the two branches do not collide;
// after the merge the transports move onto the shared one and this file goes.

struct CloudHTTPResponse: Sendable {
  var status: Int
  var data: Data
  var headers: [String: String]

  func header(_ name: String) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }
}

/// Sends one request and returns the answer, hiding the transient failures of a network:
/// 429 and 5xx wait and retry, a lost connection retries, a 401 refreshes the token once.
/// Every other status (404, 409 …) is handed back for the transport to read. No error carries
/// a URL, a body or a token: only the fixed `ExchangeTransportError` cases leave this type.
final class CloudHTTPB: @unchecked Sendable {
  typealias Authorizer = @Sendable (inout URLRequest) throws -> Void

  private let session: URLSession
  private let maxAttempts: Int
  private let pause: @Sendable (TimeInterval) -> Void
  private let authorize: Authorizer?
  private let refresh: (@Sendable () throws -> Void)?

  init(
    session: URLSession = .shared, maxAttempts: Int = 4,
    pause: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
    authorize: Authorizer? = nil, refresh: (@Sendable () throws -> Void)? = nil
  ) {
    self.session = session
    self.maxAttempts = max(1, maxAttempts)
    self.pause = pause
    self.authorize = authorize
    self.refresh = refresh
  }

  func send(_ original: URLRequest, body: Data? = nil) throws -> CloudHTTPResponse {
    guard !Thread.isMainThread else { throw ExchangeTransportError.mainThread }
    var refreshed = false
    var attempt = 0
    while true {
      attempt += 1
      var request = original
      request.timeoutInterval = 60
      try authorize?(&request)
      let outcome = perform(request, body: body)
      switch outcome {
      case .failure:
        guard attempt < maxAttempts else { throw ExchangeTransportError.unavailable }
        pause(Self.backoff(attempt: attempt, retryAfter: nil))
      case .success(let response):
        if response.status == 401 {
          guard let refresh, !refreshed else { throw ExchangeTransportError.unavailable }
          refreshed = true
          do { try refresh() } catch { throw ExchangeTransportError.unavailable }
          continue
        }
        if response.status == 429 || (500...599).contains(response.status) {
          guard attempt < maxAttempts else { throw ExchangeTransportError.unavailable }
          pause(
            Self.backoff(attempt: attempt, retryAfter: response.header("Retry-After")))
          continue
        }
        return response
      }
    }
  }

  static func backoff(attempt: Int, retryAfter: String?) -> TimeInterval {
    if let retryAfter, let seconds = TimeInterval(retryAfter) { return min(max(seconds, 0), 30) }
    return min(0.5 * Double(1 << min(attempt - 1, 5)), 8)
  }

  private func perform(_ request: URLRequest, body: Data?) -> Result<CloudHTTPResponse, Error> {
    let box = ResultBox()
    let done = DispatchSemaphore(value: 0)
    let handler: @Sendable (Data?, URLResponse?, Error?) -> Void = { data, response, error in
      if let http = response as? HTTPURLResponse, error == nil {
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
          if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        box.set(.success(CloudHTTPResponse(status: http.statusCode, data: data ?? Data(), headers: headers)))
      } else {
        box.set(.failure(ExchangeTransportError.unavailable))
      }
      done.signal()
    }
    let task: URLSessionTask
    if let body {
      task = session.uploadTask(with: request, from: body, completionHandler: handler)
    } else {
      task = session.dataTask(with: request, completionHandler: handler)
    }
    task.resume()
    done.wait()
    return box.value ?? .failure(ExchangeTransportError.unavailable)
  }

  private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<CloudHTTPResponse, Error>?
    func set(_ result: Result<CloudHTTPResponse, Error>) { lock.withLock { stored = result } }
    var value: Result<CloudHTTPResponse, Error>? { lock.withLock { stored } }
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

/// Dates of the three services: ISO 8601 with or without fractions, and RFC 1123 for WebDAV.
enum CloudDates {
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

/// Where the tokens and passwords of cloud drives live: the keychain of this device, never the
/// database, the archive or the settings.
protocol CloudCredentialStoring: Sendable {
  func load(account: String) -> String?
  func save(_ value: String, account: String) throws
  func remove(account: String)
}

struct KeychainCloudCredentialStore: CloudCredentialStoring {
  let service: String

  init(
    service: String = (Bundle.main.bundleIdentifier ?? "io.github.EvgenyBaulin.ohmymoney")
      + ".cloud"
  ) {
    self.service = service
  }

  struct Failure: Error { let status: Int32 }

  private func query(_ account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: false,
    ]
  }

  func load(account: String) -> String? {
    var q = query(account)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  func save(_ value: String, account: String) throws {
    let data = Data(value.utf8)
    let status = SecItemUpdate(
      query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecSuccess { return }
    guard status == errSecItemNotFound else { throw Failure(status: status) }
    var add = query(account)
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let added = SecItemAdd(add as CFDictionary, nil)
    guard added == errSecSuccess else { throw Failure(status: added) }
  }

  func remove(account: String) { SecItemDelete(query(account) as CFDictionary) }
}

final class MemoryCloudCredentialStore: CloudCredentialStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: String] = [:]
  func load(account: String) -> String? { lock.withLock { values[account] } }
  func save(_ value: String, account: String) throws { lock.withLock { values[account] = value } }
  func remove(account: String) { lock.withLock { _ = values.removeValue(forKey: account) } }
}
