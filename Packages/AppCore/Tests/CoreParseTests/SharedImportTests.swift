import Foundation
import Testing

@testable import CoreParse

@Suite("Shared pictures, PDFs and bank messages")
struct SharedImportTests {
  @Test func everySupportedKindComesBackByteForByte() throws {
    for (kind, data, filename) in [
      (SharedImportItem.Kind.image, Data([1, 2, 3]), "receipt.heic"),
      (.pdf, Data("%PDF-synthetic".utf8), "receipt.pdf"),
      (.text, Data("Покупка 450 ₽, карта *7788".utf8), "message.txt"),
    ] {
      let item = try SharedImportItem(kind: kind, data: data, filename: filename)
      let bytes = try item.encoded()
      #expect(try SharedImportItem.decode(bytes) == item)
      #expect(item.data == data)
    }
  }

  @Test func textIsDecodedAsUTF8AndEmptyInputIsRefused() throws {
    let text = "Покупка 450 ₽\nКарта *7788"
    #expect(try SharedImportItem(kind: .text, data: Data(text.utf8)).text == text)
    for bytes in [Data(), Data(" \n ".utf8), Data([0xff, 0xfe])] {
      #expect(throws: SharedImportItem.Failure.invalid) {
        try SharedImportItem(kind: .text, data: bytes)
      }
    }
    #expect(throws: SharedImportItem.Failure.invalid) {
      try SharedImportItem(kind: .image, data: Data())
    }
  }

  @Test func filenamesCannotEscapeTheInbox() throws {
    for name in ["../receipt.jpg", "/tmp/receipt.jpg", "..", "a\\b.jpg", "a\0b.jpg"] {
      #expect(throws: SharedImportItem.Failure.invalid) {
        try SharedImportItem(kind: .image, data: Data([1]), filename: name)
      }
    }
  }

  @Test func unknownVersionsAndInvalidDecodedFieldsAreRefused() throws {
    let item = try SharedImportItem(kind: .text, data: Data("synthetic".utf8))
    let bytes = try item.encoded()
    var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    object["version"] = 2
    #expect(throws: SharedImportItem.Failure.newerVersion) {
      try SharedImportItem.decode(JSONSerialization.data(withJSONObject: object))
    }
    object["version"] = 1
    object["filename"] = "../outside"
    #expect(throws: SharedImportItem.Failure.invalid) {
      try SharedImportItem.decode(JSONSerialization.data(withJSONObject: object))
    }
  }
}
