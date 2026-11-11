import AppCore
import UniformTypeIdentifiers
import XCTest

@testable import OhMyMoney

@MainActor
final class SharedItemProviderReaderTests: XCTestCase {
  private func provider(_ type: UTType, data: Data) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) {
      completion in
      completion(data, nil)
      return nil
    }
    return provider
  }

  func testImagePDFAndSMSArePassedToTheSameSharedEnvelope() async throws {
    for (type, kind, bytes) in [
      (UTType.png, SharedImportItem.Kind.image, Data([1, 2, 3])),
      (.pdf, .pdf, Data("%PDF-synthetic".utf8)),
      (.utf8PlainText, .text, Data("Покупка 450 ₽. Карта *7788".utf8)),
    ] {
      let item = try await SharedItemProviderReader.read(provider(type, data: bytes))
      XCTAssertEqual(item.kind, kind)
      XCTAssertEqual(item.data, bytes)
      XCTAssertEqual(try SharedImportItem.decode(item.encoded()), item)
    }
  }

  func testUnsupportedAttachmentsAreRefused() async {
    do {
      _ = try await SharedItemProviderReader.read(provider(.zip, data: Data([1])))
      XCTFail("a zip is not a receipt or a bank message")
    } catch {
      XCTAssertEqual(error as? SharedImportItem.Failure, .invalid)
    }
  }
}
