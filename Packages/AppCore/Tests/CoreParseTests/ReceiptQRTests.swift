import CoreKit
import Foundation
import Testing

@testable import CoreParse

@Suite("QR кассового чека")
struct ReceiptQRTests {
  @Test func readsAReceiptWithSeconds() throws {
    let receipt = try #require(
      ReceiptQRParser.parse(
        "t=20261029T183245&s=1250.50&fn=9960440300000000&i=12345&fp=2345678901&n=1"))
    #expect(receipt.day == DateOnly(year: 2026, month: 10, day: 29))
    #expect(receipt.time == TimeOfDay(hour: 18, minute: 32))
    #expect(receipt.second == 45)
    #expect(receipt.amountE4.raw == 12_505_000)
    #expect(receipt.operation == .sale)
    #expect(receipt.fiscalDrive == "9960440300000000")
    #expect(receipt.documentNumber == "12345")
    #expect(receipt.fiscalSign == "2345678901")
  }

  @Test func secondsAreOptional() throws {
    let receipt = try #require(ReceiptQRParser.parse("t=20261029T1832&s=99.00&n=1"))
    #expect(receipt.second == nil)
    #expect(receipt.time == TimeOfDay(hour: 18, minute: 32))
  }

  @Test func orderOfParametersAndExtrasDoNotMatter() throws {
    let receipt = try #require(
      ReceiptQRParser.parse("n=1&fp=1&extra=zzz&s=10.00&i=2&fn=3&t=20260102T0305"))
    #expect(receipt.amountE4.raw == 100_000)
    #expect(receipt.day == DateOnly(year: 2026, month: 1, day: 2))
    #expect(receipt.time == TimeOfDay(hour: 3, minute: 5))
  }

  @Test func sumFormats() {
    func sum(_ text: String) -> Int64? {
      ReceiptQRParser.parse("t=20261029T1832&s=\(text)&n=1")?.amountE4.raw
    }
    #expect(sum("250") == 2_500_000)
    #expect(sum("250.5") == 2_505_000)
    #expect(sum("250,05") == 2_500_500)
    #expect(sum("0.01") == 100)
    #expect(sum("0") == nil)
    #expect(sum("0.00") == nil)
    #expect(sum("-5.00") == nil)
    #expect(sum("1.2.3") == nil)
    #expect(sum("") == nil)
    #expect(sum("abc") == nil)
    #expect(sum("1 250.00") == nil)
    #expect(sum("1.23456") == nil)
  }

  @Test func theSumIsExactAndNeverGoesThroughDouble() throws {
    let receipt = try #require(ReceiptQRParser.parse("t=20261029T1832&s=0.07&n=1"))
    #expect(receipt.amountE4.raw == 700)
    let big = try #require(ReceiptQRParser.parse("t=20261029T1832&s=99999999.99&n=1"))
    #expect(big.amountE4.raw == 999_999_999_900)
  }

  @Test func operationKinds() throws {
    func kind(_ n: String) -> ReceiptOperation? {
      ReceiptQRParser.parse("t=20261029T1832&s=10.00&n=\(n)")?.operation
    }
    #expect(kind("1") == .sale)
    #expect(kind("2") == .saleReturn)
    #expect(kind("3") == .payout)
    #expect(kind("4") == .payoutReturn)
    #expect(kind("5") == nil)
    #expect(kind("x") == nil)
    let refund = try #require(ReceiptQRParser.parse("t=20261029T1832&s=10.00&n=2"))
    #expect(refund.isRefund)
    #expect(refund.operation.transactionKind == .refund)
    let withoutN = try #require(ReceiptQRParser.parse("t=20261029T1832&s=10.00"))
    #expect(withoutN.operation == .sale)
    #expect(!withoutN.isRefund)
  }

  @Test func rubbish() {
    #expect(ReceiptQRParser.parse("") == nil)
    #expect(ReceiptQRParser.parse("hello") == nil)
    #expect(ReceiptQRParser.parse("https://example.com/") == nil)
    #expect(ReceiptQRParser.parse("t=20261029T1832") == nil)
    #expect(ReceiptQRParser.parse("s=10.00&n=1") == nil)
    #expect(ReceiptQRParser.parse("t=2026-10-29&s=10.00&n=1") == nil)
    #expect(ReceiptQRParser.parse("t=20261329T1832&s=10.00&n=1") == nil)
    #expect(ReceiptQRParser.parse("t=20260231T1832&s=10.00&n=1") == nil)
    #expect(ReceiptQRParser.parse("t=20261029T2532&s=10.00&n=1") == nil)
    #expect(ReceiptQRParser.parse("t=20261029T1862&s=10.00&n=1") == nil)
    #expect(ReceiptQRParser.parse("t=20261029T183299&s=10.00&n=1") == nil)
    #expect(ReceiptQRParser.parse("t=20261029T18&s=10.00&n=1") == nil)
    #expect(ReceiptQRParser.parse(String(repeating: "a=b&", count: 500)) == nil)
  }

  @Test func tolerantToSurroundingNoise() throws {
    let wrapped = "  \nt=20261029T1832&s=10.00&fn=1&i=2&fp=3&n=1\r\n"
    #expect(ReceiptQRParser.parse(wrapped) != nil)
    let link = try #require(
      ReceiptQRParser.parse("https://check.example/?t=20261029T1832&s=10.00&n=1"))
    #expect(link.amountE4.raw == 100_000)
    let colons = ReceiptQRParser.parse("t=20261029T18:32:10&s=10.00&n=1")
    #expect(colons?.second == 10)
    #expect(ReceiptQRParser.parse("T=20261029t1832&S=10.00&N=1") != nil)
  }

  @Test func theMomentIsReadOnTheClockOfTheOwnersCalendar() throws {
    let receipt = try #require(ReceiptQRParser.parse("t=20261029T183245&s=10.00&n=1"))
    let moscow = receipt.moment(in: .moscow)
    #expect(moscow.timeIntervalSince1970 == 1_793_287_965)  // 2026-10-29 15:32:45 UTC
    let utc = receipt.moment(in: .utc)
    #expect(utc.timeIntervalSince(moscow) == 3 * 3600)
    let tokyo = CalendarContext(timeZone: TimeZone(identifier: "Asia/Tokyo")!)
    #expect(tokyo.timeOfDay(receipt.moment(in: tokyo)) == TimeOfDay(hour: 18, minute: 32))
  }
}
