import AppCore
import Foundation

/// Dropbox API v2 with the "App folder" access type: the app sees only its own folder, and
/// the root path `""` is that folder.
struct DropboxBackend: CloudBackend {
  let client: CloudHTTPClient
  var api = URL(string: "https://api.dropboxapi.com/2")!
  var content = URL(string: "https://content.dropboxapi.com/2")!
  var pageSize = 500

  static let config = CloudOAuthConfig(
    providerId: "dropbox", clientId: CloudDriveKeys.dropbox,
    authorizeURL: URL(string: "https://www.dropbox.com/oauth2/authorize")!,
    tokenURL: URL(string: "https://api.dropboxapi.com/oauth2/token")!,
    redirectURI: "io.github.evgenybaulin.ohmymoney:/oauth/dropbox",
    scopes: ["files.content.read", "files.content.write"],
    extraAuthorizeParameters: ["token_access_type": "offline"])

  private struct Listing: Decodable {
    struct Entry: Decodable {
      var tag: String
      var name: String
      var server_modified: String?
      enum CodingKeys: String, CodingKey {
        case tag = ".tag"
        case name, server_modified
      }
    }
    var entries: [Entry]
    var cursor: String
    var has_more: Bool
  }

  private func json(_ object: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
  }

  private func isError(_ response: CloudHTTPResponse, _ tag: String) -> Bool {
    response.status == 409 && String(decoding: response.body, as: UTF8.self).contains(tag)
  }

  func list() throws -> [ExchangeFileInfo] {
    var files: [ExchangeFileInfo] = []
    var response = try client.send(
      .cloud(
        api.appendingPathComponent("files/list_folder"), method: "POST",
        body: json(["path": "", "limit": pageSize]),
        headers: ["Content-Type": "application/json"]))
    while true {
      if isError(response, "not_found") { return files }
      guard response.status == 200,
        let page = try? JSONDecoder().decode(Listing.self, from: response.body)
      else { throw ExchangeTransportError.unavailable }
      for entry in page.entries where entry.tag == "file" {
        guard let text = entry.server_modified, let modified = CloudDates.parse(text) else {
          throw ExchangeTransportError.malformed
        }
        files.append(ExchangeFileInfo(name: entry.name, modified: modified))
      }
      guard page.has_more else { return files }
      response = try client.send(
        .cloud(
          api.appendingPathComponent("files/list_folder/continue"), method: "POST",
          body: json(["cursor": page.cursor]), headers: ["Content-Type": "application/json"]))
    }
  }

  func download(_ name: String) throws -> Data? {
    let response = try client.send(
      .cloud(
        content.appendingPathComponent("files/download"), method: "POST",
        headers: ["Dropbox-API-Arg": String(decoding: json(["path": "/\(name)"]), as: UTF8.self)]))
    if isError(response, "not_found") { return nil }
    guard response.status == 200 else { throw ExchangeTransportError.unavailable }
    return response.body
  }

  func create(_ name: String, data: Data) throws -> Bool {
    try upload(name, data: data, mode: "add")
  }

  func replace(_ name: String, data: Data) throws {
    _ = try upload(name, data: data, mode: "overwrite")
  }

  private func upload(_ name: String, data: Data, mode: String) throws -> Bool {
    let arg = json(["path": "/\(name)", "mode": mode, "autorename": false, "mute": true])
    let response = try client.send(
      .cloud(
        content.appendingPathComponent("files/upload"), method: "POST", body: data,
        headers: [
          "Dropbox-API-Arg": String(decoding: arg, as: UTF8.self),
          "Content-Type": "application/octet-stream",
        ]))
    if isError(response, "conflict") { return false }
    guard response.status == 200 else { throw ExchangeTransportError.unavailable }
    return true
  }
}
