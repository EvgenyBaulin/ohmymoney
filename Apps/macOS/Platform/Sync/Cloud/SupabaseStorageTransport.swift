import AppCore
import AppDatabase
import Foundation

/// A Supabase project the owner runs: its address and key are typed by the owner and kept in
/// the keychain. The bucket must exist and stay private; the app never creates or deletes one.
struct SupabaseConfig: Equatable, Sendable {
  var projectURL: URL
  var key: String
  var bucket: String

  static let defaultBucket = "ohmymoney-exchange"
  static let urlAccount = "supabase.url"
  static let keyAccount = "supabase.key"

  /// Only an https address with a host is accepted; the key must not be empty.
  init?(url: String, key: String, bucket: String = SupabaseConfig.defaultBucket) {
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    let secret = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let parsed = URL(string: trimmed), parsed.scheme == "https",
      let host = parsed.host, !host.isEmpty, !secret.isEmpty,
      !bucket.isEmpty, bucket.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) })
    else { return nil }
    self.projectURL = parsed
    self.key = secret
    self.bucket = bucket
  }

  static func load(from store: any CloudCredentialStoring) -> SupabaseConfig? {
    guard let url = store.load(account: urlAccount), let key = store.load(account: keyAccount)
    else { return nil }
    return SupabaseConfig(url: url, key: key)
  }

  func save(to store: any CloudCredentialStoring) throws {
    try store.save(projectURL.absoluteString, account: Self.urlAccount)
    try store.save(key, account: Self.keyAccount)
  }
}

/// Exchange files in a private Supabase Storage bucket (Storage REST API).
final class SupabaseStorageTransport: ExchangeFileTransport, @unchecked Sendable {
  private let config: SupabaseConfig
  private let http: CloudHTTPClient
  private let pageSize: Int

  init(config: SupabaseConfig, client: CloudHTTPClient, pageSize: Int = 100) {
    self.config = config
    self.pageSize = pageSize
    self.http = client
  }

  /// The client of this drive: the project key as `apikey` and as the bearer, no renewal.
  static func client(
    config: SupabaseConfig, http: any CloudHTTPTransporting = URLSessionCloudHTTP(),
    retry: CloudRetryPolicy = CloudRetryPolicy()
  ) -> CloudHTTPClient {
    CloudHTTPClient(
      http: http,
      authorizer: StaticCloudAuthorizer(headers: [
        "apikey": config.key, "Authorization": "Bearer \(config.key)",
      ]), retry: retry)
  }

  private func url(_ path: String) throws -> URL {
    guard let url = URL(string: config.projectURL.absoluteString.trimmingSlash + path) else {
      throw ExchangeTransportError.malformed
    }
    return url
  }

  func files() throws -> [ExchangeFileInfo] {
    var result: [String: Date] = [:]
    var offset = 0
    while true {
      var request = URLRequest(url: try url("/storage/v1/object/list/\(config.bucket)"))
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      let body = try JSONSerialization.data(withJSONObject: [
        "prefix": "", "limit": pageSize, "offset": offset,
        "sortBy": ["column": "name", "order": "asc"],
      ])
      let response = try http.send(request, body: body)
      guard response.status == 200,
        let entries = try? JSONSerialization.jsonObject(with: response.body) as? [[String: Any]]
      else { throw ExchangeTransportError.unavailable }
      for entry in entries {
        guard let name = entry["name"] as? String, CloudFileName.isExchangeFile(name) else {
          continue
        }
        let stamp = (entry["updated_at"] as? String) ?? (entry["created_at"] as? String)
        guard let stamp, let date = CloudDates.iso(stamp) else { continue }
        result[name] = date
      }
      guard entries.count >= pageSize else { break }
      offset += entries.count
    }
    return result.map { ExchangeFileInfo(name: $0.key, modified: $0.value) }
  }

  func readFile(named name: String) throws -> Data {
    try CloudFileName.validate(name)
    var request = URLRequest(url: try url("/storage/v1/object/authenticated/\(config.bucket)/\(name)"))
    request.httpMethod = "GET"
    let response = try http.send(request)
    switch response.status {
    case 200: return response.body
    case 400, 404: throw ExchangeTransportError.missing
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
    var request = URLRequest(url: try url("/storage/v1/object/\(config.bucket)/\(name)"))
    request.httpMethod = "POST"
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    request.setValue(replacing ? "true" : "false", forHTTPHeaderField: "x-upsert")
    let response = try http.send(request, body: data)
    switch response.status {
    case 200, 201: return
    case 400, 409:
      // Lost the race with another writer: identical bytes are a retry, anything else a clash.
      if !replacing, (try? readFile(named: name)) == data { return }
      throw replacing ? ExchangeTransportError.unavailable : ExchangeTransportError.fileChanged
    default: throw ExchangeTransportError.unavailable
    }
  }
}

extension String {
  fileprivate var trimmingSlash: String { hasSuffix("/") ? String(dropLast()) : self }
}
