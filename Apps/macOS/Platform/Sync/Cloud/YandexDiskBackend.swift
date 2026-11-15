import AppCore
import Foundation

/// Yandex.Disk REST API, the application folder (`app:/`) only. A file is uploaded to a
/// one-time address and exists only when the upload has finished, so a dropped connection
/// leaves nothing behind.
struct YandexDiskBackend: CloudBackend {
  let client: CloudHTTPClient
  var base = URL(string: "https://cloud-api.yandex.net/v1/disk/resources")!
  var pageSize = 100

  static let config = CloudOAuthConfig(
    providerId: "yandex", clientId: CloudDriveKeys.yandex,
    authorizeURL: URL(string: "https://oauth.yandex.ru/authorize")!,
    tokenURL: URL(string: "https://oauth.yandex.ru/token")!,
    redirectURI: "io.github.evgenybaulin.ohmymoney:/oauth/yandex",
    scopes: ["cloud_api:disk.app_folder"], authorizationScheme: "OAuth")

  private func url(_ suffix: String, _ query: [(String, String)]) -> URL {
    let target = suffix.isEmpty ? base : base.appendingPathComponent(suffix)
    var components = URLComponents(url: target, resolvingAgainstBaseURL: false)!
    components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
    return components.url!
  }

  func list() throws -> [ExchangeFileInfo] {
    struct Page: Decodable {
      struct Embedded: Decodable {
        struct Item: Decodable {
          var name: String
          var type: String
          var modified: String
        }
        var items: [Item]
        var total: Int?
      }
      var _embedded: Embedded
    }
    var files: [ExchangeFileInfo] = []
    var offset = 0
    while true {
      let response = try client.send(
        .cloud(
          url(
            "",
            [
              ("path", "app:/"), ("limit", String(pageSize)), ("offset", String(offset)),
              (
                "fields",
                "_embedded.items.name,_embedded.items.type,_embedded.items.modified,_embedded.total"
              ),
            ])))
      if response.status == 404 { return files }
      guard response.status == 200, let page = try? JSONDecoder().decode(Page.self, from: response.body)
      else { throw ExchangeTransportError.unavailable }
      for item in page._embedded.items where item.type == "file" {
        guard let modified = CloudDates.parse(item.modified) else {
          throw ExchangeTransportError.malformed
        }
        files.append(ExchangeFileInfo(name: item.name, modified: modified))
      }
      offset += page._embedded.items.count
      if page._embedded.items.isEmpty || offset >= (page._embedded.total ?? offset) {
        return files
      }
    }
  }

  func download(_ name: String) throws -> Data? {
    struct Link: Decodable { var href: String }
    let first = try client.send(.cloud(url("download", [("path", "app:/\(name)")])))
    if first.status == 404 { return nil }
    guard first.status == 200, let link = try? JSONDecoder().decode(Link.self, from: first.body),
      let address = URL(string: link.href), address.scheme == "https"
    else { throw ExchangeTransportError.unavailable }
    // The address is signed; the token is not sent to the storage host.
    let second = try client.send(.cloud(address), authorized: false)
    if second.status == 404 { return nil }
    guard second.status == 200 else { throw ExchangeTransportError.unavailable }
    return second.body
  }

  func create(_ name: String, data: Data) throws -> Bool {
    try upload(name, data: data, overwrite: false)
  }

  func replace(_ name: String, data: Data) throws {
    guard try upload(name, data: data, overwrite: true) else {
      throw ExchangeTransportError.unavailable
    }
  }

  private func upload(_ name: String, data: Data, overwrite: Bool) throws -> Bool {
    struct Link: Decodable { var href: String }
    let ask = try client.send(
      .cloud(url("upload", [("path", "app:/\(name)"), ("overwrite", overwrite ? "true" : "false")])))
    if ask.status == 409 { return false }
    guard ask.status == 200, let link = try? JSONDecoder().decode(Link.self, from: ask.body),
      let address = URL(string: link.href), address.scheme == "https"
    else { throw ExchangeTransportError.unavailable }
    let put = try client.send(.cloud(address, method: "PUT", body: data), authorized: false)
    if put.status == 409 { return false }
    guard put.status == 201 || put.status == 202 else { throw ExchangeTransportError.unavailable }
    return true
  }
}
