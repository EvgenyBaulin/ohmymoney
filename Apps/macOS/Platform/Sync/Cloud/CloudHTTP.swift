import AppCore
import AuthenticationServices
import CryptoKit
import Foundation
import Security

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

// MARK: - One HTTP attempt

/// A reply reduced to what the cloud code reads. Header names are lower-cased.
struct CloudHTTPResponse: Sendable {
  var status: Int
  var headers: [String: String]
  var body: Data

  init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
    self.status = status
    self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
    self.body = body
  }

  func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// One blocking attempt, no retry: the layer below `CloudHTTPClient`. Tests hand the real
/// implementation a session whose protocol classes are a stub server.
protocol CloudHTTPTransporting: Sendable {
  func perform(_ request: URLRequest) throws -> CloudHTTPResponse
}

struct URLSessionCloudHTTP: CloudHTTPTransporting, @unchecked Sendable {
  let session: URLSession

  init(session: URLSession = URLSession(configuration: .ephemeral)) {
    self.session = session
  }

  func perform(_ request: URLRequest) throws -> CloudHTTPResponse {
    let box = ReplyBox()
    let task = session.dataTask(with: request) { data, response, error in
      box.finish(data: data, response: response, error: error)
    }
    task.resume()
    return try box.wait(cancelling: task)
  }

  private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var result: Result<CloudHTTPResponse, any Error>?

    func finish(data: Data?, response: URLResponse?, error: (any Error)?) {
      let outcome: Result<CloudHTTPResponse, any Error>
      if let error {
        outcome = .failure(error)
      } else if let http = response as? HTTPURLResponse {
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
          if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        outcome = .success(
          CloudHTTPResponse(status: http.statusCode, headers: headers, body: data ?? Data()))
      } else {
        outcome = .failure(URLError(.badServerResponse))
      }
      lock.withLock { result = outcome }
      ready.signal()
    }

    func wait(cancelling task: URLSessionTask) throws -> CloudHTTPResponse {
      guard ready.wait(timeout: .now() + .seconds(180)) == .success else {
        task.cancel()
        throw URLError(.timedOut)
      }
      return try lock.withLock { try result?.get() ?? { throw URLError(.unknown) }() }
    }
  }
}

// MARK: - Retry

/// Which failures are tried again and how long to wait: a server asked to slow down (429), a
/// server that failed (5xx) and a connection that dropped. Everything else is the caller's.
struct CloudRetryPolicy: Sendable {
  var maxAttempts = 4
  var baseDelay: TimeInterval = 1
  var maxDelay: TimeInterval = 60
  var sleep: @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

  func delay(afterAttempt attempt: Int, retryAfter: String?) -> TimeInterval {
    if let retryAfter, let seconds = TimeInterval(retryAfter.trimmingCharacters(in: .whitespaces)),
      seconds >= 0
    {
      return min(seconds, maxDelay)
    }
    return min(baseDelay * pow(2, Double(max(attempt - 1, 0))), maxDelay)
  }

  static func isTransient(_ error: URLError) -> Bool {
    switch error.code {
    case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
      .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed:
      return true
    default:
      return false
    }
  }
}

// MARK: - OAuth model

/// What differs between the drives in the sign-in. A drive with an empty `clientId` is shown
/// but cannot be connected: the owner registers the application and pastes the id in
/// `CloudDriveKeys`.
struct CloudOAuthConfig: Sendable, Equatable {
  var providerId: String
  var clientId: String
  var authorizeURL: URL
  var tokenURL: URL
  var redirectURI: String
  var scopes: [String] = []
  var extraAuthorizeParameters: [String: String] = [:]
  /// The word before the token in the `Authorization` header.
  var authorizationScheme = "Bearer"
  /// Microsoft wants the scopes again when a token is renewed.
  var sendsScopeOnRefresh = false

  var isConfigured: Bool { !clientId.trimmingCharacters(in: .whitespaces).isEmpty }
  var callbackScheme: String? { URL(string: redirectURI)?.scheme }
}

struct CloudTokens: Codable, Equatable, Sendable {
  var accessToken: String
  var refreshToken: String?
  var expiresAt: Date?
}

enum CloudSignInError: Error, Equatable {
  case notConfigured
  case cancelled
  case badCallback
  case stateMismatch
  case denied
  case tokenRequestFailed
}

/// Tokens live in the keychain of this device only, one item per drive, never synced.
protocol CloudTokenStoring: Sendable {
  func load() throws -> CloudTokens?
  func save(_ tokens: CloudTokens) throws
  func clear() throws
}

struct KeychainCloudTokenStore: CloudTokenStoring {
  let service: String
  let account: String

  enum Failure: Error, Equatable { case status(Int32) }

  init(
    providerId: String,
    service: String = (Bundle.main.bundleIdentifier ?? "io.github.EvgenyBaulin.ohmymoney")
      + ".cloud"
  ) {
    self.service = service
    self.account = providerId
  }

  private var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: false,
    ]
  }

  func load() throws -> CloudTokens? {
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw Failure.status(status) }
    guard let data = item as? Data, let tokens = try? JSONDecoder().decode(CloudTokens.self, from: data)
    else { throw Failure.status(errSecDecode) }
    return tokens
  }

  /// What a new item is stored with: this device only, never synced, readable when unlocked.
  func addAttributes(for data: Data) -> [String: Any] {
    var item = query
    item[kSecValueData as String] = data
    item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    return item
  }

  func save(_ tokens: CloudTokens) throws {
    let data = try JSONEncoder().encode(tokens)
    let attributes: [String: Any] = [kSecValueData as String: data]
    let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updated == errSecSuccess { return }
    guard updated == errSecItemNotFound else { throw Failure.status(updated) }
    let status = SecItemAdd(addAttributes(for: data) as CFDictionary, nil)
    guard status == errSecSuccess else { throw Failure.status(status) }
  }

  func clear() throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw Failure.status(status)
    }
  }
}

final class InMemoryCloudTokenStore: CloudTokenStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var tokens: CloudTokens?

  init(_ tokens: CloudTokens? = nil) { self.tokens = tokens }

  func load() throws -> CloudTokens? { lock.withLock { tokens } }
  func save(_ tokens: CloudTokens) throws { lock.withLock { self.tokens = tokens } }
  func clear() throws { lock.withLock { tokens = nil } }
}

// MARK: - Form bodies

enum CloudForm {
  private static let allowed = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  static func encode(_ pairs: [(String, String)]) -> Data {
    let text: String = pairs.map { key, value -> String in
      let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
      let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
      return "\(k)=\(v)"
    }.joined(separator: "&")
    return Data(text.utf8)
  }
}

// MARK: - Tokens in use

/// Gives the transports a valid access token: renews it a minute before it expires, or at once
/// when the server said 401. Calls block and belong off the main thread.
final class CloudAuthorizer: @unchecked Sendable {
  let config: CloudOAuthConfig
  private let store: any CloudTokenStoring
  private let http: any CloudHTTPTransporting
  private let retry: CloudRetryPolicy
  private let now: @Sendable () -> Date
  private let lock = NSLock()

  init(
    config: CloudOAuthConfig, store: any CloudTokenStoring, http: any CloudHTTPTransporting,
    retry: CloudRetryPolicy = CloudRetryPolicy(), now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.config = config
    self.store = store
    self.http = http
    self.retry = retry
    self.now = now
  }

  var isSignedIn: Bool { ((try? store.load()) ?? nil) != nil }

  func accessToken() throws -> String {
    try lock.withLock {
      guard let tokens = try store.load() else { throw CloudSignInError.notConfigured }
      if let expires = tokens.expiresAt, expires.timeIntervalSince(now()) < 60 {
        return try refreshLocked(tokens)
      }
      return tokens.accessToken
    }
  }

  /// A new token whatever the clock says (after a 401).
  func refresh() throws -> String {
    try lock.withLock {
      guard let tokens = try store.load() else { throw CloudSignInError.notConfigured }
      return try refreshLocked(tokens)
    }
  }

  func exchange(code: String, verifier: String) throws {
    var pairs: [(String, String)] = [
      ("grant_type", "authorization_code"), ("code", code), ("client_id", config.clientId),
      ("redirect_uri", config.redirectURI), ("code_verifier", verifier),
    ]
    if config.sendsScopeOnRefresh { pairs.append(("scope", config.scopes.joined(separator: " "))) }
    let tokens = try tokenRequest(pairs, keepingRefresh: nil)
    try lock.withLock { try store.save(tokens) }
  }

  func disconnect() { lock.withLock { try? store.clear() } }

  private func refreshLocked(_ old: CloudTokens) throws -> String {
    guard let refresh = old.refreshToken else {
      try? store.clear()
      throw CloudSignInError.denied
    }
    var pairs: [(String, String)] = [
      ("grant_type", "refresh_token"), ("refresh_token", refresh), ("client_id", config.clientId),
    ]
    if config.sendsScopeOnRefresh { pairs.append(("scope", config.scopes.joined(separator: " "))) }
    do {
      let tokens = try tokenRequest(pairs, keepingRefresh: refresh)
      try store.save(tokens)
      return tokens.accessToken
    } catch CloudSignInError.denied {
      // The grant was revoked: the next connect starts from the sign-in page.
      try? store.clear()
      throw CloudSignInError.denied
    }
  }

  private func tokenRequest(_ pairs: [(String, String)], keepingRefresh: String?) throws
    -> CloudTokens
  {
    var request = URLRequest(url: config.tokenURL)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = CloudForm.encode(pairs)
    var attempt = 0
    while true {
      attempt += 1
      let response: CloudHTTPResponse
      do {
        response = try http.perform(request)
      } catch let error as URLError where CloudRetryPolicy.isTransient(error) {
        guard attempt < retry.maxAttempts else { throw CloudSignInError.tokenRequestFailed }
        retry.sleep(retry.delay(afterAttempt: attempt, retryAfter: nil))
        continue
      } catch {
        throw CloudSignInError.tokenRequestFailed
      }
      switch response.status {
      case 200:
        struct Reply: Decodable {
          var access_token: String
          var refresh_token: String?
          var expires_in: Double?
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: response.body),
          !reply.access_token.isEmpty
        else { throw CloudSignInError.tokenRequestFailed }
        return CloudTokens(
          accessToken: reply.access_token, refreshToken: reply.refresh_token ?? keepingRefresh,
          expiresAt: reply.expires_in.map { now().addingTimeInterval($0) })
      case 400, 401:
        throw CloudSignInError.denied
      case 429, 500...599:
        guard attempt < retry.maxAttempts else { throw CloudSignInError.tokenRequestFailed }
        retry.sleep(retry.delay(afterAttempt: attempt, retryAfter: response.header("retry-after")))
      default:
        throw CloudSignInError.tokenRequestFailed
      }
    }
  }
}

// MARK: - What puts credentials on a request

/// Adds the credentials of a drive to a request. A token can be renewed after a 401; a fixed
/// credential (a Basic login, an API key) cannot, and its 401 is final.
protocol CloudRequestAuthorizing: Sendable {
  func authorize(_ request: inout URLRequest) throws
  /// Gets a new token after a 401. Returns `false` when there is nothing to renew.
  func renewAfterRejection() throws -> Bool
}

extension CloudAuthorizer: CloudRequestAuthorizing {
  func authorize(_ request: inout URLRequest) throws {
    let token = try accessToken()
    request.setValue("\(config.authorizationScheme) \(token)", forHTTPHeaderField: "Authorization")
  }

  func renewAfterRejection() throws -> Bool {
    _ = try refresh()
    return true
  }
}

/// Fixed headers on every request: `Authorization: Basic …` of a WebDAV drive, the key of a
/// Supabase project.
struct StaticCloudAuthorizer: CloudRequestAuthorizing {
  var headers: [String: String]

  func authorize(_ request: inout URLRequest) throws {
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
  }

  func renewAfterRejection() throws -> Bool { false }

  static func basic(login: String, password: String) -> StaticCloudAuthorizer {
    let credential = Data("\(login):\(password)".utf8).base64EncodedString()
    return StaticCloudAuthorizer(headers: ["Authorization": "Basic \(credential)"])
  }
}

// MARK: - Requests with a token, retry and one renewal

/// Every request of a drive goes through here. It adds the token, renews it once on a 401,
/// waits and tries again on 429, 5xx and a dropped connection, and gives every other status
/// (404, 409 …) back to the transport, which knows what it means. All failures leave as
/// `ExchangeTransportError`: no server text, URL or token ever reaches a log.
final class CloudHTTPClient: @unchecked Sendable {
  private let http: any CloudHTTPTransporting
  private let authorizer: (any CloudRequestAuthorizing)?
  private let retry: CloudRetryPolicy

  init(
    http: any CloudHTTPTransporting, authorizer: (any CloudRequestAuthorizing)?,
    retry: CloudRetryPolicy = CloudRetryPolicy()
  ) {
    self.http = http
    self.authorizer = authorizer
    self.retry = retry
  }

  func send(_ request: URLRequest, authorized: Bool = true) throws -> CloudHTTPResponse {
    guard !Thread.isMainThread else { throw ExchangeTransportError.mainThread }
    var renewed = false
    var attempt = 0
    while true {
      attempt += 1
      var outgoing = request
      if authorized {
        guard let authorizer else { throw ExchangeTransportError.unavailable }
        do { try authorizer.authorize(&outgoing) } catch { throw ExchangeTransportError.unavailable }
      }
      let response: CloudHTTPResponse
      do {
        response = try http.perform(outgoing)
      } catch let error as URLError where CloudRetryPolicy.isTransient(error) {
        guard attempt < retry.maxAttempts else { throw ExchangeTransportError.unavailable }
        retry.sleep(retry.delay(afterAttempt: attempt, retryAfter: nil))
        continue
      } catch {
        throw ExchangeTransportError.unavailable
      }
      switch response.status {
      case 401 where authorized && !renewed:
        renewed = true
        attempt -= 1
        do {
          guard try authorizer?.renewAfterRejection() == true else {
            throw ExchangeTransportError.unavailable
          }
        } catch { throw ExchangeTransportError.unavailable }
      case 401 where authorized:
        throw ExchangeTransportError.unavailable
      case 429, 500...599:
        guard attempt < retry.maxAttempts else { throw ExchangeTransportError.unavailable }
        retry.sleep(retry.delay(afterAttempt: attempt, retryAfter: response.header("retry-after")))
      default:
        return response
      }
    }
  }
}

extension CloudHTTPClient {
  func send(_ request: URLRequest, body: Data) throws -> CloudHTTPResponse {
    var withBody = request
    withBody.httpBody = body
    return try send(withBody)
  }
}

// MARK: - Sign-in page

enum CloudPKCE {
  static func makeVerifier() -> String {
    var bytes = [UInt8](repeating: 0, count: 48)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    if status != errSecSuccess { bytes = (0..<48).map { _ in UInt8.random(in: 0...255) } }
    return base64URL(Data(bytes))
  }

  static func challenge(for verifier: String) -> String {
    base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
  }

  static func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
}

enum CloudOAuthFlow {
  static func authorizationURL(config: CloudOAuthConfig, challenge: String, state: String) -> URL? {
    guard var components = URLComponents(url: config.authorizeURL, resolvingAgainstBaseURL: false)
    else { return nil }
    var items = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: config.clientId),
      URLQueryItem(name: "redirect_uri", value: config.redirectURI),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "state", value: state),
    ]
    if !config.scopes.isEmpty {
      items.append(URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")))
    }
    for (key, value) in config.extraAuthorizeParameters.sorted(by: { $0.key < $1.key }) {
      items.append(URLQueryItem(name: key, value: value))
    }
    components.queryItems = (components.queryItems ?? []) + items
    return components.url
  }

  /// The code in the address the sign-in page returned to; refuses a different `state`.
  static func code(from callback: URL, state: String) throws -> String {
    guard let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems
    else { throw CloudSignInError.badCallback }
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
    if value("error") != nil { throw CloudSignInError.denied }
    guard value("state") == state else { throw CloudSignInError.stateMismatch }
    guard let code = value("code"), !code.isEmpty else { throw CloudSignInError.badCallback }
    return code
  }

  /// Opens the system sign-in sheet and stores the tokens. The token request blocks, so it runs
  /// off the main actor.
  @MainActor
  static func signIn(config: CloudOAuthConfig, authorizer: CloudAuthorizer) async throws {
    guard config.isConfigured, let scheme = config.callbackScheme else {
      throw CloudSignInError.notConfigured
    }
    let verifier = CloudPKCE.makeVerifier()
    let state = CloudPKCE.makeVerifier()
    guard
      let url = authorizationURL(
        config: config, challenge: CloudPKCE.challenge(for: verifier), state: state)
    else { throw CloudSignInError.badCallback }
    let callback = try await presentSheet(url: url, scheme: scheme)
    let code = try code(from: callback, state: state)
    try await Task.detached { try authorizer.exchange(code: code, verifier: verifier) }.value
  }

  @MainActor
  private static func presentSheet(url: URL, scheme: String) async throws -> URL {
    let anchor = SignInAnchor()
    return try await withCheckedThrowingContinuation { continuation in
      let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { url, error in
        if let url {
          continuation.resume(returning: url)
        } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
          continuation.resume(throwing: CloudSignInError.cancelled)
        } else {
          continuation.resume(throwing: CloudSignInError.badCallback)
        }
      }
      session.presentationContextProvider = anchor
      session.prefersEphemeralWebBrowserSession = false
      // The session keeps itself alive while the sheet is up; the anchor must outlive it too.
      objc_setAssociatedObject(session, &anchorKey, anchor, .OBJC_ASSOCIATION_RETAIN)
      if !session.start() { continuation.resume(throwing: CloudSignInError.badCallback) }
    }
  }
}

nonisolated(unsafe) private var anchorKey: UInt8 = 0

private final class SignInAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
  @MainActor
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    #if canImport(AppKit)
      return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()
    #else
      let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      return scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? UIWindow()
    #endif
  }
}
