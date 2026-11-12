import AppCore
import Foundation
import Observation

/// One explicitly requested page. Redirects and authentication challenges end the request;
/// cookies, credentials and cache are absent, and nothing follows an image or a script URL.
struct SinglePageProductClient: Sendable {
  struct Page: Sendable {
    var data: Data
    var status: Int
    var encoding: String?
  }

  typealias Fetch = @Sendable (URL) async throws -> Page
  private let fetch: Fetch

  init(fetch: @escaping Fetch) { self.fetch = fetch }

  init() {
    self.init { url in
      let session = URLSession(
        configuration: Self.configuration(), delegate: PageDelegate(),
        delegateQueue: nil)
      defer { session.invalidateAndCancel() }
      var request = URLRequest(url: url)
      request.httpMethod = "GET"
      request.setValue("text/html, application/xhtml+xml", forHTTPHeaderField: "Accept")
      let (data, response) = try await session.data(for: request)
      return Page(
        data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0,
        encoding: response.textEncodingName)
    }
  }

  static func configuration() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 20
    config.timeoutIntervalForResource = 25
    config.httpShouldSetCookies = false
    config.httpCookieAcceptPolicy = .never
    config.httpCookieStorage = nil
    config.urlCredentialStorage = nil
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    return config
  }

  func metadata(at url: URL) async throws -> ProductPageMetadata {
    let page = try await fetch(url)
    guard (200..<300).contains(page.status) else { throw Failure.response }
    let encoding: String.Encoding =
      switch page.encoding?.lowercased() {
      case "windows-1251": .windowsCP1251
      case "iso-8859-1": .isoLatin1
      default: .utf8
      }
    guard let html = String(data: page.data, encoding: encoding),
      let metadata = ProductPageParser.parse(html, pageURL: url)
    else { throw Failure.markup }
    return metadata
  }

  enum Failure: Error { case response, markup }

  final class PageDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
      completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) { completionHandler(nil) }

    func urlSession(
      _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
      completionHandler:
        @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
      if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
        completionHandler(.performDefaultHandling, nil)
      } else {
        completionHandler(.cancelAuthenticationChallenge, nil)
      }
    }
  }
}

/// Constructing a model has no side effects. Only the button calls `load`.
@MainActor
@Observable
final class ProductLinkModel {
  private let client: SinglePageProductClient
  private(set) var isBusy = false
  private(set) var messageKey: String?

  init(client: SinglePageProductClient = SinglePageProductClient()) { self.client = client }

  func load(_ text: String?) async -> ProductPageMetadata? {
    guard !isBusy else { return nil }
    guard let url = PurchaseActions.link(text), url.user == nil, url.password == nil else {
      messageKey = "purchases.link.failure.address"
      return nil
    }
    isBusy = true
    messageKey = nil
    defer { isBusy = false }
    do {
      let result = try await client.metadata(at: url)
      messageKey = "purchases.link.success"
      return result
    } catch SinglePageProductClient.Failure.response {
      messageKey = "purchases.link.failure.response"
    } catch SinglePageProductClient.Failure.markup {
      messageKey = "purchases.link.failure.markup"
    } catch {
      messageKey = "purchases.link.failure.network"
    }
    return nil
  }
}
