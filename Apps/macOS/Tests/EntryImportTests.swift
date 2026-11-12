import AppCore
import AppKit
import UniformTypeIdentifiers
import XCTest

@testable import OhMyMoney

@MainActor
final class EntryImportTests: XCTestCase {
  func testSupportedFilesUseTheExistingFlows() {
    for (name, expected) in [
      ("bank.CSV", EntryImportFileKind.statement), ("bank.txt", .statement),
      ("bank.xlsx", .spreadsheet), ("receipt.PDF", .document),
      ("operation.PNG", .document), ("photo.heic", .document),
    ] {
      XCTAssertEqual(EntryImportFileKind.of(name), expected, name)
    }
    XCTAssertNil(EntryImportFileKind.of("archive.zip"))
    XCTAssertNil(EntryImportFileKind.of("folder"))
  }

  func testMixedDropsAreQueuedWithoutLosingOrDuplicatingFiles() throws {
    let queue = EntryImportQueue()
    let urls = ["bank.csv", "receipt.pdf", "operation.png", "book.xlsx"].map {
      URL(fileURLWithPath: "/synthetic/\($0)")
    }
    XCTAssertTrue(queue.append(urls: urls))
    for url in urls {
      XCTAssertEqual(try XCTUnwrap(queue.active).url, url)
      queue.active = nil
      queue.didDismiss(isCovered: false)
    }
    XCTAssertNil(queue.active)
    let unsupported = URL(fileURLWithPath: "/synthetic/archive.zip")
    XCTAssertTrue(queue.append(urls: [unsupported]))
    XCTAssertEqual(queue.active?.url, unsupported, "unsupported files get a visible error")
    XCTAssertFalse(queue.append(urls: [URL(string: "https://example.invalid/bank.csv")!]))
  }

  func testLockDismissalKeepsTheCurrentFile() throws {
    let queue = EntryImportQueue()
    XCTAssertTrue(queue.append(urls: [URL(fileURLWithPath: "/synthetic/receipt.pdf")]))
    let id = try XCTUnwrap(queue.active).id
    queue.didDismiss(isCovered: true)
    XCTAssertEqual(queue.active?.id, id)
  }

  func testPastePrefersAFileURLToItsPreviewImage() async throws {
    let url = URL(fileURLWithPath: "/synthetic/bank.csv")
    let provider = NSItemProvider()
    provider.registerDataRepresentation(
      forTypeIdentifier: UTType.fileURL.identifier, visibility: .all
    ) {
      completion in
      completion(url.dataRepresentation, nil)
      return nil
    }
    provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all)
    {
      completion in
      completion(Data([1, 2, 3]), nil)
      return nil
    }
    let source = try await EntryImportProvider.read(provider)
    XCTAssertEqual(source.url, url)
    XCTAssertNil(source.file)
  }

  func testPastedImagesAndPDFsKeepTheirOriginalBytes() async throws {
    for type in [UTType.png, .pdf] {
      let bytes = Data([1, 2, 3, 4])
      let provider = NSItemProvider()
      provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) {
        completion in
        completion(bytes, nil)
        return nil
      }
      let source = try await EntryImportProvider.read(provider)
      XCTAssertEqual(source.file?.data, bytes)
      XCTAssertEqual(source.file?.filename, "import.\(type.preferredFilenameExtension!)")
    }
  }

  func testAttachmentPasteLeavesPlainSMSForTheNativeTextEditor() {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("Покупка 450 ₽. Карта *7788", forType: .string)
    XCTAssertTrue(EntryImportPasteboard.sources(in: pasteboard).isEmpty)
    let data = Data([1, 2, 3])
    pasteboard.clearContents()
    pasteboard.setData(data, forType: .png)
    XCTAssertEqual(EntryImportPasteboard.sources(in: pasteboard).first?.file?.data, data)
    pasteboard.clearContents()
    let url = URL(fileURLWithPath: "/synthetic/bank.csv")
    pasteboard.writeObjects([url as NSURL])
    XCTAssertEqual(EntryImportPasteboard.sources(in: pasteboard).first?.url, url)
  }

  func testOnlyCommandVIsHandledAsAttachmentPaste() {
    XCTAssertTrue(
      EntryImportPaste.Receiver.isPaste(EntryHost.key("v", code: 9, modifiers: .command)))
    XCTAssertFalse(EntryImportPaste.Receiver.isPaste(EntryHost.key("v", code: 9)))
    XCTAssertFalse(
      EntryImportPaste.Receiver.isPaste(EntryHost.key("v", code: 9, modifiers: [.command, .shift])))
    XCTAssertFalse(
      EntryImportPaste.Receiver.isPaste(EntryHost.key("c", code: 8, modifiers: .command)))
  }
}
