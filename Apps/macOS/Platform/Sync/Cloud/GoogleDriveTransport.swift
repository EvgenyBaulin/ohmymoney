import AppCore
import AppDatabase
import Foundation

/// The app keys of Google Drive. They stay empty until the owner registers the app; without a
/// client id the drive cannot be connected and the settings say why.
enum GoogleDriveConfig {
  static let clientID = CloudDriveKeys.google
  static var isConfigured: Bool { !clientID.isEmpty }
  /// The sign-in of Google as the shared OAuth model: an installed-app client, the reversed
  /// client id as the redirect scheme, a refresh token asked for with every consent.
  static func oauth(clientID: String = GoogleDriveConfig.clientID) -> CloudOAuthConfig {
    CloudOAuthConfig(
      providerId: "google", clientId: clientID, authorizeURL: URL(string: authorizeURL)!,
      tokenURL: URL(string: tokenURL)!,
      redirectURI: redirectScheme(clientID: clientID) + ":/oauth2redirect", scopes: [scope],
      extraAuthorizeParameters: ["access_type": "offline", "prompt": "consent"])
  }
  /// Files in the hidden per-app folder only: the app cannot see anything else in the Drive.
  static let scope = "https://www.googleapis.com/auth/drive.appdata"
  static let authorizeURL = "https://accounts.google.com/o/oauth2/v2/auth"
  static let tokenURL = "https://oauth2.googleapis.com/token"
  static let api = "https://www.googleapis.com/drive/v3"
  static let upload = "https://www.googleapis.com/upload/drive/v3"

  /// The redirect of an installed-app client: the reversed client id as a URL scheme.
  static func redirectScheme(clientID: String) -> String {
    let prefix = ".apps.googleusercontent.com"
    let base = clientID.hasSuffix(prefix) ? String(clientID.dropLast(prefix.count)) : clientID
    return "com.googleusercontent.apps.\(base)"
  }
}

/// Exchange files in the hidden app-data folder of Google Drive (Drive API v3).
final class GoogleDriveTransport: ExchangeFileTransport, @unchecked Sendable {
  private let http: CloudHTTPClient
  private let pageSize: Int

  init(client: CloudHTTPClient, pageSize: Int = 100) {
    self.pageSize = pageSize
    self.http = client
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
        let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
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
      let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
      let entries = json["files"] as? [[String: Any]]
    else { throw ExchangeTransportError.unavailable }
    return entries.first?["id"] as? String
  }

  private func download(id: String) throws -> Data {
    guard let url = URL(string: "\(GoogleDriveConfig.api)/files/\(id)?alt=media")
    else { throw ExchangeTransportError.malformed }
    let response = try http.send(URLRequest(url: url))
    switch response.status {
    case 200: return response.body
    case 404: throw ExchangeTransportError.missing
    default: throw ExchangeTransportError.unavailable
    }
  }
}
