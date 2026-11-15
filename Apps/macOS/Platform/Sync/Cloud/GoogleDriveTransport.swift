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

/// Exchange files in the hidden app-data folder of Google Drive (Drive API v3). Drive names are
/// not unique: two devices writing at once can leave two files of one name. Every read picks the
/// same one of them, the earliest created (ties by id), on every device and every call.
final class GoogleDriveTransport: ExchangeFileTransport, @unchecked Sendable {
  private let http: CloudHTTPClient
  private let pageSize: Int

  init(client: CloudHTTPClient, pageSize: Int = 100) {
    self.pageSize = pageSize
    self.http = client
  }

  func files() throws -> [ExchangeFileInfo] {
    var chosen: [String: Candidate] = [:]
    var pageToken: String?
    var pages = 0
    repeat {
      try CloudPaging.count(&pages)
      var parts = URLComponents(string: GoogleDriveConfig.api + "/files")
      var items = [
        URLQueryItem(name: "spaces", value: "appDataFolder"),
        URLQueryItem(name: "pageSize", value: String(pageSize)),
        URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,modifiedTime,createdTime)"),
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
        let id = entry["id"] as? String ?? ""
        let created = (entry["createdTime"] as? String).flatMap(CloudDates.iso) ?? date
        let candidate = Candidate(id: id, created: created, modified: date)
        if let known = chosen[name], !candidate.precedes(known) { continue }
        chosen[name] = candidate
      }
      pageToken = json["nextPageToken"] as? String
    } while pageToken != nil
    return chosen.map { ExchangeFileInfo(name: $0.key, modified: $0.value.modified) }
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
      URLQueryItem(name: "fields", value: "files(id,modifiedTime,createdTime)"),
      URLQueryItem(name: "orderBy", value: "createdTime"),
      URLQueryItem(name: "pageSize", value: "100"),
    ]
    guard let url = parts?.url else { throw ExchangeTransportError.malformed }
    let response = try http.send(URLRequest(url: url))
    guard response.status == 200,
      let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
      let entries = json["files"] as? [[String: Any]]
    else { throw ExchangeTransportError.unavailable }
    let candidates: [Candidate] = entries.compactMap { entry in
      guard let id = entry["id"] as? String else { return nil }
      let modified = (entry["modifiedTime"] as? String).flatMap(CloudDates.iso) ?? .distantPast
      let created = (entry["createdTime"] as? String).flatMap(CloudDates.iso) ?? modified
      return Candidate(id: id, created: created, modified: modified)
    }
    guard let first = candidates.min(by: { $0.precedes($1) }) else { return nil }
    guard CloudFileName.isSafeRemoteId(first.id) else { throw ExchangeTransportError.malformed }
    return first.id
  }

  /// One Drive file of a name; the earliest created wins, the id breaks a tie.
  private struct Candidate {
    var id: String
    var created: Date
    var modified: Date

    func precedes(_ other: Candidate) -> Bool {
      created != other.created ? created < other.created : id < other.id
    }
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
