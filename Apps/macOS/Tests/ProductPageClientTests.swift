import AppCore
import XCTest

@testable import OhMyMoney

@MainActor
final class ProductPageClientTests: XCTestCase {
  actor Requests {
    var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
  }

  func testOnlyTheExplicitLoadMakesOneRequestAndDoesNotLoadTheImage() async throws {
    let requests = Requests()
    let client = SinglePageProductClient(fetch: { url in
      await requests.record(url)
      return SinglePageProductClient.Page(
        data: Data(
          "<meta property='og:title' content='Desk'><meta property='og:image' content='/desk.jpg'>"
            .utf8),
        status: 200, encoding: nil)
    })
    let model = ProductLinkModel(client: client)
    let before = await requests.urls
    XCTAssertTrue(before.isEmpty)
    let result = await model.load("https://shop.example/desk")
    XCTAssertEqual(result?.name, "Desk")
    XCTAssertEqual(result?.imageURL?.absoluteString, "https://shop.example/desk.jpg")
    let after = await requests.urls
    XCTAssertEqual(after.map(\.absoluteString), ["https://shop.example/desk"])
  }

  func testHTTPFailureAndInvalidLinkExplainFailureWithoutRetry() async {
    let requests = Requests()
    let model = ProductLinkModel(
      client: SinglePageProductClient(fetch: { url in
        await requests.record(url)
        return SinglePageProductClient.Page(data: Data(), status: 302, encoding: nil)
      }))
    let invalid = await model.load("file:///private/test")
    XCTAssertNil(invalid)
    var recorded = await requests.urls
    XCTAssertTrue(recorded.isEmpty)
    let failed = await model.load("https://shop.example/desk")
    XCTAssertNil(failed)
    XCTAssertEqual(model.messageKey, "purchases.link.failure.response")
    recorded = await requests.urls
    XCTAssertEqual(recorded.count, 1)
  }

  func testSessionDoesNotPersistCookiesCredentialsOrCache() {
    let config = SinglePageProductClient.configuration()
    XCTAssertFalse(config.httpShouldSetCookies)
    XCTAssertEqual(config.httpCookieAcceptPolicy, .never)
    XCTAssertNil(config.httpCookieStorage)
    XCTAssertNil(config.urlCredentialStorage)
    XCTAssertNil(config.urlCache)
  }

  func testRedirectDelegateRefusesASecondRequest() async throws {
    let delegate = SinglePageProductClient.PageDelegate()
    let session = URLSession(configuration: SinglePageProductClient.configuration())
    defer { session.invalidateAndCancel() }
    let original = URL(string: "https://shop.example/product")!
    let elsewhere = URL(string: "https://elsewhere.example/product")!
    let task = session.dataTask(with: original)
    let response = try XCTUnwrap(
      HTTPURLResponse(
        url: original, statusCode: 302,
        httpVersion: nil, headerFields: ["Location": elsewhere.absoluteString]))
    let proposed: URLRequest? = await withCheckedContinuation { continuation in
      delegate.urlSession(
        session, task: task, willPerformHTTPRedirection: response,
        newRequest: URLRequest(url: elsewhere)
      ) { continuation.resume(returning: $0) }
    }
    XCTAssertNil(proposed)
  }
}
