import AppCore
import AppDatabase
import Foundation

/// Mail.ru Cloud is reached over its WebDAV door with an app password the owner makes in the
/// Mail.ru account settings (the account password is never asked for). Login and app password
/// stay in the keychain.
struct MailRuCloudConfig: Equatable, Sendable {
  var login: String
  var appPassword: String

  static let loginAccount = "mailru.login"
  static let passwordAccount = "mailru.password"
  static let host = "https://webdav.cloud.mail.ru"
  static let folder = "OhMyMoney"

  init?(login: String, appPassword: String) {
    let user = login.trimmingCharacters(in: .whitespacesAndNewlines)
    let secret = appPassword.trimmingCharacters(in: .whitespacesAndNewlines)
    guard user.contains("@"), !secret.isEmpty else { return nil }
    self.login = user
    self.appPassword = secret
  }

  static func load(from store: any CloudCredentialStoring) -> MailRuCloudConfig? {
    guard let login = store.load(account: loginAccount),
      let password = store.load(account: passwordAccount)
    else { return nil }
    return MailRuCloudConfig(login: login, appPassword: password)
  }

  func save(to store: any CloudCredentialStoring) throws {
    try store.save(login, account: Self.loginAccount)
    try store.save(appPassword, account: Self.passwordAccount)
  }
}

/// Exchange files in one folder of Mail.ru Cloud (WebDAV: PROPFIND, GET, PUT, MOVE, MKCOL).
final class MailRuCloudTransport: ExchangeFileTransport, @unchecked Sendable {
  private let http: CloudHTTPClient
  private let base: String

  init(client: CloudHTTPClient, base: String = MailRuCloudConfig.host) {
    self.base = base
    self.http = client
  }

  /// The client of this drive: the app password as a Basic login, no renewal.
  static func client(
    config: MailRuCloudConfig, http: any CloudHTTPTransporting = URLSessionCloudHTTP(),
    retry: CloudRetryPolicy = CloudRetryPolicy()
  ) -> CloudHTTPClient {
    CloudHTTPClient(
      http: http,
      authorizer: StaticCloudAuthorizer.basic(login: config.login, password: config.appPassword),
      retry: retry)
  }

  private func url(_ name: String?) throws -> URL {
    let path = "/" + MailRuCloudConfig.folder + (name.map { "/" + $0 } ?? "/")
    guard let url = URL(string: base + path) else { throw ExchangeTransportError.malformed }
    return url
  }

  func files() throws -> [ExchangeFileInfo] {
    var request = URLRequest(url: try url(nil))
    request.httpMethod = "PROPFIND"
    request.setValue("1", forHTTPHeaderField: "Depth")
    request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
    let body = Data(
      "<?xml version=\"1.0\"?><propfind xmlns=\"DAV:\"><prop><getlastmodified/></prop></propfind>"
        .utf8)
    let response = try http.send(request, body: body)
    switch response.status {
    case 207, 200:
      guard let list = MultistatusParser.parse(response.body) else {
        throw ExchangeTransportError.malformed
      }
      return list
    case 404:
      try makeFolder()
      return []
    default: throw ExchangeTransportError.unavailable
    }
  }

  func readFile(named name: String) throws -> Data {
    try CloudFileName.validate(name)
    let response = try http.send(URLRequest(url: try url(name)))
    switch response.status {
    case 200: return response.body
    case 404: throw ExchangeTransportError.missing
    default: throw ExchangeTransportError.unavailable
    }
  }

  func writeFile(named name: String, data: Data, replacing: Bool) throws {
    try CloudFileName.validate(name)
    if !replacing {
      do {
        guard try readFile(named: name) == data else { throw ExchangeTransportError.fileChanged }
        return
      } catch ExchangeTransportError.missing {}
    }
    // The bytes land under a temporary name and are moved onto the real one, so a dropped
    // connection leaves a stray temporary file (never listed) and no half-written exchange file.
    let temporary = "\(name).part-\(UUID().uuidString)"
    var status = try put(temporary, data)
    if status == 404 || status == 409 {
      try makeFolder()
      status = try put(temporary, data)
    }
    guard (200...204).contains(status) else { throw ExchangeTransportError.unavailable }
    let moved: Int
    do {
      moved = try move(temporary, to: name, overwrite: replacing)
    } catch {
      discard(temporary)
      throw error
    }
    guard (200...204).contains(moved) else {
      discard(temporary)
      throw moved == 412 ? ExchangeTransportError.fileChanged : ExchangeTransportError.unavailable
    }
  }

  private func move(_ source: String, to name: String, overwrite: Bool) throws -> Int {
    var request = URLRequest(url: try url(source))
    request.httpMethod = "MOVE"
    request.setValue(try url(name).absoluteString, forHTTPHeaderField: "Destination")
    request.setValue(overwrite ? "T" : "F", forHTTPHeaderField: "Overwrite")
    return try http.send(request).status
  }

  /// Best effort: a leftover temporary file is harmless, the listing ignores it.
  private func discard(_ name: String) {
    guard var request = (try? url(name)).map({ URLRequest(url: $0) }) else { return }
    request.httpMethod = "DELETE"
    _ = try? http.send(request)
  }

  private func put(_ name: String, _ data: Data) throws -> Int {
    var request = URLRequest(url: try url(name))
    request.httpMethod = "PUT"
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    return try http.send(request, body: data).status
  }

  private func makeFolder() throws {
    var request = URLRequest(url: try url(nil))
    request.httpMethod = "MKCOL"
    let status = try http.send(request).status
    // 405: the folder already exists.
    guard (200...204).contains(status) || status == 405 else {
      throw ExchangeTransportError.unavailable
    }
  }
}

/// Reads the `href` and `getlastmodified` of every entry of a WebDAV multistatus answer and keeps
/// the exchange files; the folder itself and strangers are dropped.
private final class MultistatusParser: NSObject, XMLParserDelegate {
  private var entries: [ExchangeFileInfo] = []
  private var text = ""
  private var href: String?
  private var modified: Date?

  static func parse(_ data: Data) -> [ExchangeFileInfo]? {
    let parser = XMLParser(data: data)
    let delegate = MultistatusParser()
    parser.delegate = delegate
    parser.shouldProcessNamespaces = true
    return parser.parse() ? delegate.entries : nil
  }

  func parser(
    _ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String] = [:]
  ) {
    text = ""
    if element == "response" {
      href = nil
      modified = nil
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

  func parser(
    _ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
    qualifiedName: String?
  ) {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    switch element {
    case "href": href = value
    case "getlastmodified": modified = CloudDates.rfc1123(value)
    case "response":
      guard let href, let modified else { return }
      let decoded = href.removingPercentEncoding ?? href
      let name = decoded.split(separator: "/").last.map(String.init) ?? ""
      if CloudFileName.isExchangeFile(name) {
        entries.append(ExchangeFileInfo(name: name, modified: modified))
      }
    default: break
    }
  }
}
