import AppCore
import AppDatabase
import CryptoKit
import Foundation

/// The app keys of Google Drive. They stay empty until the owner registers the app; without a
/// client id the drive cannot be connected and the settings say why.
enum GoogleDriveConfig {
  static let clientID = ""
  static var isConfigured: Bool { !clientID.isEmpty }
  /// Files in the hidden per-app folder only: the app cannot see anything else in the Drive.
  static let scope = "https://www.googleapis.com/auth/drive.appdata"
  static let authorizeURL = "https://accounts.google.com/o/oauth2/v2/auth"
  static let tokenURL = "https://oauth2.googleapis.com/token"
  static let api = "https://www.googleapis.com/drive/v3"
  static let upload = "https://www.googleapis.com/upload/drive/v3"
  static let refreshAccount = "google.refresh"

  /// The redirect of an installed-app client: the reversed client id as a URL scheme.
  static func redirectScheme(clientID: String) -> String {
    let prefix = ".apps.googleusercontent.com"
    let base = clientID.hasSuffix(prefix) ? String(clientID.dropLast(prefix.count)) : clientID
    return "com.googleusercontent.apps.\(base)"
  }
}

/// PKCE (RFC 7636): the verifier never leaves the device; only its hash goes to the browser.
struct PKCEPair: Equatable {
  var verifier: String
  var challenge: String

  static func make(verifier: String = random()) -> PKCEPair {
    let hash = SHA256.hash(data: Data(verifier.utf8))
    return PKCEPair(verifier: verifier, challenge: base64URL(Data(hash)))
  }

  static func random() -> String {
    var bytes = [UInt8](repeating: 0, count: 48)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      return base64URL(Data(UUID().uuidString.utf8) + Data(UUID().uuidString.utf8))
    }
    return base64URL(Data(bytes))
  }

  static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

/// Holds the access token in memory and the refresh token in the keychain; refreshes on demand.
final class GoogleDriveSession: @unchecked Sendable {
  private let clientID: String
  private let store: any CloudCredentialStoring
  private let http: CloudHTTPB
  private let now: @Sendable () -> Date
  private let lock = NSLock()
  private var accessToken: String?
  private var expiry = Date.distantPast

  init(
    clientID: String, store: any CloudCredentialStoring, session: URLSession = .shared,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.clientID = clientID
    self.store = store
    self.http = CloudHTTPB(session: session)
    self.now = now
  }

  var isConnected: Bool { store.load(account: GoogleDriveConfig.refreshAccount) != nil }

  func authorizationURL(pkce: PKCEPair, state: String) -> URL? {
    var parts = URLComponents(string: GoogleDriveConfig.authorizeURL)
    parts?.queryItems = [
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(
        name: "redirect_uri",
        value: GoogleDriveConfig.redirectScheme(clientID: clientID) + ":/oauth2redirect"),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "scope", value: GoogleDriveConfig.scope),
      URLQueryItem(name: "code_challenge", value: pkce.challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "access_type", value: "offline"),
      URLQueryItem(name: "prompt", value: "consent"),
      URLQueryItem(name: "state", value: state),
    ]
    return parts?.url
  }

  /// Trades the code of the browser sign-in for tokens (run off the main thread).
  func completeSignIn(code: String, pkce: PKCEPair) throws {
    let redirect = GoogleDriveConfig.redirectScheme(clientID: clientID) + ":/oauth2redirect"
    try tokenRequest([
      "grant_type": "authorization_code", "code": code, "code_verifier": pkce.verifier,
      "client_id": clientID, "redirect_uri": redirect,
    ])
  }

  func signOut() {
    store.remove(account: GoogleDriveConfig.refreshAccount)
    lock.withLock { accessToken = nil }
  }

  /// A valid access token, refreshed a minute before it lapses.
  func token() throws -> String {
    if let cached = lock.withLock({ now() < expiry ? accessToken : nil }) { return cached }
    try refresh()
    guard let fresh = lock.withLock({ accessToken }) else { throw ExchangeTransportError.unavailable }
    return fresh
  }

  func refresh() throws {
    guard let refreshToken = store.load(account: GoogleDriveConfig.refreshAccount) else {
      throw ExchangeTransportError.unavailable
    }
    try tokenRequest([
      "grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID,
    ])
  }

  private func tokenRequest(_ form: [String: String]) throws {
    guard let url = URL(string: GoogleDriveConfig.tokenURL) else {
      throw ExchangeTransportError.unavailable
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    let body = form.sorted { $0.key < $1.key }.map {
      "\($0.key)=\(Self.formEscape($0.value))"
    }.joined(separator: "&")
    let response = try http.send(request, body: Data(body.utf8))
    guard response.status == 200,
      let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
      let access = json["access_token"] as? String
    else { throw ExchangeTransportError.unavailable }
    let lifetime = (json["expires_in"] as? Double) ?? 3600
    if let refresh = json["refresh_token"] as? String {
      do { try store.save(refresh, account: GoogleDriveConfig.refreshAccount) } catch {
        throw ExchangeTransportError.unavailable
      }
    }
    lock.withLock {
      accessToken = access
      expiry = now().addingTimeInterval(max(lifetime - 60, 0))
    }
  }

  private static func formEscape(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
  }
}

/// Exchange files in the hidden app-data folder of Google Drive (Drive API v3).
final class GoogleDriveTransport: ExchangeFileTransport, @unchecked Sendable {
  private let http: CloudHTTPB
  private let pageSize: Int

  init(session: GoogleDriveSession, urlSession: URLSession = .shared, pageSize: Int = 100) {
    self.pageSize = pageSize
    self.http = CloudHTTPB(
      session: urlSession,
      authorize: { request in
        request.setValue("Bearer \(try session.token())", forHTTPHeaderField: "Authorization")
      },
      refresh: { try session.refresh() })
  }

  func files() throws -> [ExchangeFileInfo] {
    var latest: [String: Date] = [:]
    var pageToken: String?
    repeat {
      var parts = URLComponents(string: GoogleDriveConfig.api + "/files")
      var items = [
        URLQueryItem(name: "spaces", value: "appDataFolder"),
        URLQueryItem(name: "pageSize", value: String(pageSize)),
        URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,modifiedTime)"),
        URLQueryItem(name: "q", value: "trashed=false"),
      ]
      if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
      parts?.queryItems = items
      guard let url = parts?.url else { throw ExchangeTransportError.malformed }
      let response = try http.send(URLRequest(url: url))
      guard response.status == 200,
        let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
        let entries = json["files"] as? [[String: Any]]
      else { throw ExchangeTransportError.unavailable }
      for entry in entries {
        guard let name = entry["name"] as? String, CloudFileName.isExchangeFile(name),
          let text = entry["modifiedTime"] as? String, let date = CloudDates.iso(text)
        else { continue }
        latest[name] = max(latest[name] ?? .distantPast, date)
      }
      pageToken = json["nextPageToken"] as? String
    } while pageToken != nil
    return latest.map { ExchangeFileInfo(name: $0.key, modified: $0.value) }
  }

  func readFile(named name: String) throws -> Data {
    try CloudFileName.validate(name)
    guard let id = try identifier(of: name) else { throw ExchangeTransportError.missing }
    return try download(id: id)
  }

  func writeFile(named name: String, data: Data, replacing: Bool) throws {
    try CloudFileName.validate(name)
    if let id = try identifier(of: name) {
      if !replacing {
        guard try download(id: id) == data else { throw ExchangeTransportError.fileChanged }
        return
      }
      guard let url = URL(string: "\(GoogleDriveConfig.upload)/files/\(id)?uploadType=media")
      else { throw ExchangeTransportError.malformed }
      var request = URLRequest(url: url)
      request.httpMethod = "PATCH"
      request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
      guard try http.send(request, body: data).status == 200 else {
        throw ExchangeTransportError.unavailable
      }
      return
    }
    let boundary = "omm-" + UUID().uuidString
    let metadata = try JSONSerialization.data(withJSONObject: [
      "name": name, "parents": ["appDataFolder"],
    ])
    var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
    body.append(metadata)
    body.append(Data("\r\n--\(boundary)\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
    body.append(data)
    body.append(Data("\r\n--\(boundary)--".utf8))
    guard let url = URL(string: GoogleDriveConfig.upload + "/files?uploadType=multipart")
    else { throw ExchangeTransportError.malformed }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    let response = try http.send(request, body: body)
    guard response.status == 200 || response.status == 201 else {
      throw ExchangeTransportError.unavailable
    }
  }

  private func identifier(of name: String) throws -> String? {
    var parts = URLComponents(string: GoogleDriveConfig.api + "/files")
    parts?.queryItems = [
      URLQueryItem(name: "spaces", value: "appDataFolder"),
      URLQueryItem(name: "q", value: "name='\(name)' and trashed=false"),
      URLQueryItem(name: "fields", value: "files(id,modifiedTime)"),
      URLQueryItem(name: "orderBy", value: "modifiedTime desc"),
      URLQueryItem(name: "pageSize", value: "1"),
    ]
    guard let url = parts?.url else { throw ExchangeTransportError.malformed }
    let response = try http.send(URLRequest(url: url))
    guard response.status == 200,
      let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
      let entries = json["files"] as? [[String: Any]]
    else { throw ExchangeTransportError.unavailable }
    return entries.first?["id"] as? String
  }

  private func download(id: String) throws -> Data {
    guard let url = URL(string: "\(GoogleDriveConfig.api)/files/\(id)?alt=media")
    else { throw ExchangeTransportError.malformed }
    let response = try http.send(URLRequest(url: url))
    switch response.status {
    case 200: return response.data
    case 404: throw ExchangeTransportError.missing
    default: throw ExchangeTransportError.unavailable
    }
  }
}
