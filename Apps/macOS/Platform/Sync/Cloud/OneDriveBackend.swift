import AppCore
import Foundation

/// Microsoft Graph, the app folder (`special/approot`, made by the service on first use; scope
/// `Files.ReadWrite.AppFolder`). Small files go in one request; a larger one (a snapshot) goes
/// through an upload session, which commits the file only when the last piece has arrived.
struct OneDriveBackend: CloudBackend {
  let client: CloudHTTPClient
  var root = "https://graph.microsoft.com/v1.0/me/drive/special/approot"
  var smallLimit = 4_000_000
  /// A multiple of 320 KiB, as the service requires.
  var chunkSize = 320 * 1024 * 12

  static let config = CloudOAuthConfig(
    providerId: "onedrive", clientId: CloudDriveKeys.oneDrive,
    authorizeURL: URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize")!,
    tokenURL: URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/token")!,
    redirectURI: "io.github.evgenybaulin.ohmymoney:/oauth/onedrive",
    scopes: ["Files.ReadWrite.AppFolder", "offline_access"], sendsScopeOnRefresh: true)

  private func item(_ name: String, _ tail: String, query: String = "") -> URL? {
    URL(string: "\(root):/\(name):/\(tail)\(query)")
  }

  func list() throws -> [ExchangeFileInfo] {
    struct Page: Decodable {
      struct Item: Decodable {
        var name: String
        var lastModifiedDateTime: String
        var file: [String: String]?
        enum CodingKeys: String, CodingKey { case name, lastModifiedDateTime, file }
        init(from decoder: any Decoder) throws {
          let c = try decoder.container(keyedBy: CodingKeys.self)
          name = try c.decode(String.self, forKey: .name)
          lastModifiedDateTime = try c.decode(String.self, forKey: .lastModifiedDateTime)
          // Only whether the key exists matters.
          file = c.contains(.file) ? [:] : nil
        }
      }
      var value: [Item]
      var nextLink: String?
      enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
      }
    }
    var files: [ExchangeFileInfo] = []
    var next: URL? = URL(
      string: "\(root)/children?$select=name,lastModifiedDateTime,file&$top=200")
    var pages = 0
    while let address = next {
      try CloudPaging.count(&pages)
      let response = try client.send(.cloud(address))
      if response.status == 404 { return files }
      guard response.status == 200, let page = try? JSONDecoder().decode(Page.self, from: response.body)
      else { throw ExchangeTransportError.unavailable }
      for entry in page.value where entry.file != nil {
        guard let modified = CloudDates.parse(entry.lastModifiedDateTime) else {
          throw ExchangeTransportError.malformed
        }
        files.append(ExchangeFileInfo(name: entry.name, modified: modified))
      }
      // The token goes only to the service's own host.
      next = page.nextLink.flatMap(URL.init(string:)).flatMap {
        $0.scheme == "https" && $0.host == "graph.microsoft.com" ? $0 : nil
      }
      if page.nextLink != nil, next == nil { throw ExchangeTransportError.malformed }
    }
    return files
  }

  func download(_ name: String) throws -> Data? {
    guard let address = item(name, "content") else { throw ExchangeTransportError.malformed }
    let response = try client.send(.cloud(address))
    if response.status == 404 { return nil }
    guard response.status == 200 else { throw ExchangeTransportError.unavailable }
    return response.body
  }

  func create(_ name: String, data: Data) throws -> Bool {
    try upload(name, data: data, behavior: "fail")
  }

  func replace(_ name: String, data: Data) throws {
    // A conflict (a folder at that path) is a refusal, not a written snapshot.
    guard try upload(name, data: data, behavior: "replace") else {
      throw ExchangeTransportError.unavailable
    }
  }

  private func upload(_ name: String, data: Data, behavior: String) throws -> Bool {
    if data.count <= smallLimit {
      guard
        let address = item(
          name, "content", query: "?@microsoft.graph.conflictBehavior=\(behavior)")
      else { throw ExchangeTransportError.malformed }
      let response = try client.send(
        .cloud(
          address, method: "PUT", body: data, headers: ["Content-Type": "application/octet-stream"]))
      if response.status == 409 { return false }
      guard response.status == 200 || response.status == 201 else {
        throw ExchangeTransportError.unavailable
      }
      return true
    }
    return try uploadInPieces(name, data: data, behavior: behavior)
  }

  private func uploadInPieces(_ name: String, data: Data, behavior: String) throws -> Bool {
    struct Session: Decodable { var uploadUrl: String }
    guard let start = item(name, "createUploadSession") else { throw ExchangeTransportError.malformed }
    let body = try JSONSerialization.data(withJSONObject: [
      "item": ["@microsoft.graph.conflictBehavior": behavior]
    ])
    let opened = try client.send(
      .cloud(start, method: "POST", body: body, headers: ["Content-Type": "application/json"]))
    if opened.status == 409 { return false }
    guard opened.status == 200, let session = try? JSONDecoder().decode(Session.self, from: opened.body),
      let upload = URL(string: session.uploadUrl), upload.scheme == "https"
    else { throw ExchangeTransportError.unavailable }
    var offset = 0
    do {
      while offset < data.count {
        let end = min(offset + chunkSize, data.count)
        let piece = data.subdata(in: offset..<end)
        let response = try client.send(
          .cloud(
            upload, method: "PUT", body: piece,
            headers: ["Content-Range": "bytes \(offset)-\(end - 1)/\(data.count)"]),
          authorized: false)
        let last = end == data.count
        switch response.status {
        case 202 where !last: break
        case 200 where last, 201 where last: break
        case 409 where last: return false
        default: throw ExchangeTransportError.unavailable
        }
        offset = end
      }
    } catch {
      // Best effort: an abandoned session commits nothing and expires by itself.
      _ = try? client.send(.cloud(upload, method: "DELETE"), authorized: false)
      throw error
    }
    return true
  }
}
