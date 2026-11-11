import UniformTypeIdentifiers
import XCTest

@testable import OhMyMoney

@MainActor
final class EntryImportTests: XCTestCase {
  func testFileSelectionAndDropKeepTheSameRoutingOnPhoneAndPad() {
    XCTAssertEqual(EntryImportFileKind.of("bank.csv"), .statement)
    XCTAssertEqual(EntryImportFileKind.of("bank.xlsx"), .spreadsheet)
    XCTAssertEqual(EntryImportFileKind.of("receipt.pdf"), .document)
    XCTAssertEqual(EntryImportFileKind.of("operation.png"), .document)
    let queue = EntryImportQueue()
    let urls = ["bank.csv", "receipt.pdf"].map { URL(fileURLWithPath: "/synthetic/\($0)") }
    XCTAssertTrue(queue.append(urls: urls))
    XCTAssertEqual(queue.active?.url, urls[0])
    queue.didDismiss(isCovered: true)
    XCTAssertEqual(queue.active?.url, urls[0])
    queue.active = nil
    queue.didDismiss(isCovered: false)
    XCTAssertEqual(queue.active?.url, urls[1])
  }

  func testDroppedPhotoKeepsItsBytesForReceiptOrScreenshotReading() async throws {
    let provider = NSItemProvider()
    let data = Data([1, 2, 3])
    provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all)
    {
      completion in
      completion(data, nil)
      return nil
    }
    let source = try await EntryImportProvider.read(provider)
    XCTAssertEqual(source.file?.data, data)
    XCTAssertEqual(source.file?.filename, "import.png")
  }
}
