import CoreKit
import Foundation
import Testing

@testable import CoreParse

@Suite("Ссылки ОФД на чек")
struct ReceiptLinkTests {
  static let full =
    "https://check.example/rec?t=20260115T1030&s=150.00&fn=9999078900001111&i=42&fp=123456789&n=1"

  private func receipt(_ text: String) -> ReceiptQR? {
    if case .receipt(let receipt) = ReceiptLinkParser.read(text) { return receipt }
    return nil
  }

  private func keyOnly(_ text: String) -> ReceiptNumbers? {
    if case .keyOnly(let numbers) = ReceiptLinkParser.read(text) { return numbers }
    return nil
  }

  @Test func aLinkWithAllTheParametersIsTheReceipt() {
    let read = receipt(Self.full)
    #expect(read?.amountE4 == AmountE4(raw: 1_500_000))
    #expect(read?.numbers?.fiscalDrive == "9999078900001111")
    #expect(read?.numbers?.documentNumber == "42")
    #expect(read?.numbers?.fiscalSign == "123456789")
  }

  @Test func theLinkInsideAMessageIsFound() {
    let text = "Ваш чек от 15.01: \(Self.full). Спасибо за покупку!"
    #expect(receipt(text)?.amountE4 == AmountE4(raw: 1_500_000))
    #expect(receipt("<\(Self.full)>") != nil)
    #expect(receipt("(\(Self.full))") != nil)
  }

  /// A link copied from the HTML of a mail has its ampersands escaped.
  @Test func escapedAmpersandsAreRead() {
    let escaped = Self.full.replacingOccurrences(of: "&", with: "&amp;")
    #expect(receipt(escaped)?.numbers?.documentNumber == "42")
  }

  /// An operator that keeps the receipt behind a hash route puts the query after the `#`.
  @Test func aQueryAfterTheHashIsRead() {
    let link =
      "https://consumer.example/#/receipt?fn=9999078900001111&i=42&fp=123456789&t=20260115T103015&s=150.00&n=1"
    #expect(receipt(link)?.second == 15)
  }

  @Test func aFragmentStuckToTheLastValueIsDropped() {
    let link = Self.full + "#top"
    #expect(receipt(link)?.operation == .sale)
  }

  /// Without the sum and the time no operation can be made, but the numbers are still the key:
  /// the receipt can be told to be already written.
  @Test func aLinkWithOnlyTheNumbersIsAKey() {
    let link = "https://lk.example/web/noauth/cheque?fn=9999078900001111&fp=123456789&i=42"
    let numbers = keyOnly(link)
    #expect(numbers?.fiscalDrive == "9999078900001111")
    #expect(numbers?.documentNumber == "42")
    #expect(numbers?.fiscalSign == "123456789")
    #expect(ReceiptLinkParser.read("https://lk.example/cheque?fn=9999078900001111&fp=1") == nil)
  }

  @Test func theDriveDocumentAndSignInThePathAreAKey() {
    let numbers = keyOnly("https://check.example/rec/9999078900001111/42/123456789")
    #expect(numbers?.documentNumber == "42")
    #expect(numbers?.fiscalSign == "123456789")
    // A path of other numbers is not a receipt.
    #expect(ReceiptLinkParser.read("https://shop.example/item/123/42/7") == nil)
  }

  @Test func theKeyOfALinkMatchesTheSameReceiptFromItsCode() throws {
    let fromLink = keyOnly("https://x.example/c?fn=9999078900001111&i=0042&fp=0123456789")
    let fromCode = ReceiptQRParser.parse(
      "t=20260115T1030&s=150.00&fn=9999078900001111&i=42&fp=123456789&n=1")
    let codeNumbers = try #require(fromCode?.numbers)
    #expect(fromLink?.isSameReceipt(as: codeNumbers) == true)
  }

  @Test func otherLinksAreNotReceipts() {
    #expect(ReceiptLinkParser.read("https://x5l.example/loyalty") == nil)
    #expect(ReceiptLinkParser.read("https://tips.example/guest/abc?receiptSum=100") == nil)
    #expect(ReceiptLinkParser.read("https://tracker.example/?utm_source=mail&i=42") == nil)
    #expect(ReceiptLinkParser.read("just words") == nil)
    #expect(ReceiptLinkParser.read("") == nil)
  }

  /// A bare code with no link behaves as before: no sum, no receipt.
  @Test func aBareNumbersTextWithoutALinkIsNotAKey() {
    #expect(ReceiptLinkParser.read("fn=9999078900001111&i=42&fp=1") == nil)
    #expect(receipt("t=20260115T1030&s=150.00&fn=1&i=2&fp=3&n=1") != nil)
  }

  @Test func aSignButNoDocumentIsNoKey() {
    #expect(ReceiptLinkParser.read("https://x.example/c?fn=9999078900001111&fp=1") == nil)
  }
}
