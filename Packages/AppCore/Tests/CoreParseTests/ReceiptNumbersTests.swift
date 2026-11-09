import CoreKit
import Foundation
import Testing

@testable import CoreParse

// Synthetic receipts only: drives of the form 9999…, made-up sums and days.

/// One receipt is recorded once: its key is the drive and the document number compared as
/// numbers, the fiscal sign is the check; a refund of a sale never turns into a purchase.
@Suite("Номера чека и повтор")
struct ReceiptNumbersTests {
  static let calendar = CalendarContext(timeZone: TimeZone(identifier: "Europe/Moscow")!)
  static let text = "t=20260115T1030&s=150.00&fn=9999078900001111&i=42&fp=123456789&n=1"

  static func receipt(_ text: String) throws -> ReceiptQR {
    try #require(ReceiptQRParser.parse(text))
  }

  static func candidate(
    _ id: String, day: Int = 15, month: Int = 1, amount: Int64 = 1_500_000,
    kind: TransactionKind = .expense, receipt: ReceiptNumbers? = nil
  ) -> ReceiptCandidate {
    ReceiptCandidate(
      id: Fixture.id(id), kind: kind,
      occurredAt: calendar.moment(
        DateOnly(year: 2026, month: month, day: day), hour: 10, minute: 0),
      amountE4: AmountE4(raw: amount), receipt: receipt)
  }

  // MARK: The key

  @Test func leadingZerosOfThePrintedNumbersMakeTheSameKey() throws {
    let fromCode = try #require(try Self.receipt(Self.text).numbers)
    let fromPaper = try #require(
      try Self.receipt(
        "t=20260115T1030&s=150.00&fn=9999078900001111&i=0000000042&fp=0123456789&n=1"
      ).numbers)
    #expect(fromPaper.documentNumber == "42")
    #expect(fromPaper.fiscalSign == "123456789")
    #expect(fromCode == fromPaper)
    #expect(fromCode.isSameReceipt(as: fromPaper))
    #expect(fromCode.operation == 1)
  }

  @Test func anotherDocumentOfTheSameDriveIsAnotherReceipt() throws {
    let first = try #require(try Self.receipt(Self.text).numbers)
    let next = try #require(
      try Self.receipt("t=20260115T1030&s=150.00&fn=9999078900001111&i=43&fp=123456789&n=1")
        .numbers)
    #expect(!first.isSameReceipt(as: next))
  }

  @Test func theSameMomentAndSumOnAnotherDriveIsNotARepeat() throws {
    let first = try #require(try Self.receipt(Self.text).numbers)
    let other = try #require(
      try Self.receipt("t=20260115T1030&s=150.00&fn=9999078900002222&i=42&fp=123456789&n=1")
        .numbers)
    #expect(!first.isSameReceipt(as: other))
  }

  @Test func aReceiptWithoutDriveOrDocumentHasNoKey() throws {
    #expect(try Self.receipt("t=20260115T1030&s=150.00&n=1").numbers == nil)
    #expect(try Self.receipt("t=20260115T1030&s=150.00&fn=9999078900001111&n=1").numbers == nil)
    #expect(try Self.receipt("t=20260115T1030&s=150.00&i=42&n=1").numbers == nil)
    #expect(try Self.receipt("t=20260115T1030&s=150.00&fn=99x9&i=42").numbers == nil)
  }

  @Test func aDifferentFiscalSignUnderOneKeyIsNotTheSameReceipt() throws {
    let first = try #require(try Self.receipt(Self.text).numbers)
    let otherSign = try #require(
      ReceiptNumbers(
        fiscalDrive: "9999078900001111", documentNumber: "42", fiscalSign: "987654321"))
    #expect(!first.isSameReceipt(as: otherSign))
    let noSign = try #require(
      ReceiptNumbers(fiscalDrive: "9999078900001111", documentNumber: "42"))
    #expect(first.isSameReceipt(as: noSign), "a missing sign checks nothing")
  }

  @Test func canonicalDigits() {
    #expect(ReceiptNumbers.canonical("0000000042") == "42")
    #expect(ReceiptNumbers.canonical(" 42 ") == "42")
    #expect(ReceiptNumbers.canonical("000") == "0")
    #expect(ReceiptNumbers.canonical("") == nil)
    #expect(ReceiptNumbers.canonical("4 2") == nil)
    #expect(ReceiptNumbers.canonical("-42") == nil)
    #expect(ReceiptNumbers.canonical("٤٢") == nil, "only ASCII digits")
  }

  // MARK: A receipt already recorded

  @Test func theSameReceiptFindsTheOperationAndIsNotRecordedAgain() throws {
    let receipt = try Self.receipt(Self.text)
    let holder = Self.candidate("01", day: 15, receipt: receipt.numbers)
    let free = Self.candidate("02", day: 15)
    let proposal = ReceiptMatch.propose(receipt, among: [free, holder], calendar: Self.calendar)
    #expect(proposal == .alreadyRecorded(holder))
    let paper = try Self.receipt(
      "t=20260115T1030&s=150.00&fn=9999078900001111&i=0000000042&fp=0123456789&n=1")
    #expect(
      ReceiptMatch.propose(paper, among: [free, holder], calendar: Self.calendar)
        == .alreadyRecorded(holder))
  }

  @Test func theOperationIsFoundWhateverItsSumOrDayNow() throws {
    // The owner may have changed the sum or the day of the operation since.
    let receipt = try Self.receipt(Self.text)
    let holder = Self.candidate("01", day: 3, month: 3, amount: 99, receipt: receipt.numbers)
    #expect(
      ReceiptMatch.propose(receipt, among: [holder], calendar: Self.calendar)
        == .alreadyRecorded(holder))
  }

  @Test func anOperationOfAnotherReceiptIsAnotherPurchase() throws {
    let receipt = try Self.receipt(Self.text)
    let other = ReceiptNumbers(fiscalDrive: "9999078900001111", documentNumber: "43")
    let taken = Self.candidate("01", day: 15, receipt: other)
    guard
      case .new(let draft) = ReceiptMatch.propose(
        receipt, among: [taken], calendar: Self.calendar)
    else {
      Issue.record("an operation of another receipt is not this purchase")
      return
    }
    let nearlyTaken = Self.candidate("02", day: 15, amount: 1_510_000, receipt: other)
    #expect(draft.similar.isEmpty)
    #expect(
      ReceiptMatch.similar(to: receipt, among: [nearlyTaken], calendar: Self.calendar).isEmpty)
  }

  @Test func aReceiptWithoutAKeyIsNeverARepeat() throws {
    let receipt = try Self.receipt("t=20260115T1030&s=150.00&n=1")
    let holder = Self.candidate(
      "01", day: 15,
      receipt: ReceiptNumbers(fiscalDrive: "9999078900001111", documentNumber: "42"))
    #expect(ReceiptMatch.recorded(receipt, among: [holder]) == nil)
  }

  @Test func ofTwoHoldersTheEarliestIsShown() throws {
    let receipt = try Self.receipt(Self.text)
    let later = Self.candidate("02", day: 16, receipt: receipt.numbers)
    let earlier = Self.candidate("01", day: 15, receipt: receipt.numbers)
    #expect(ReceiptMatch.recorded(receipt, among: [later, earlier]) == earlier)
  }

  // MARK: A refund of a sale

  @Test func refundsOfASaleOfferANewRefundNeverAPurchase() throws {
    let purchase = Self.candidate("01", day: 15, amount: 10_000_000)
    for sum in ["600.00", "100.00"] {
      let refund = try Self.receipt(
        "t=20260115T1630&s=\(sum)&fn=9999000000000002&i=7&fp=111&n=2")
      guard
        case .new(let draft) = ReceiptMatch.propose(
          refund, among: [purchase], calendar: Self.calendar)
      else {
        Issue.record("a refund of \(sum) must not find the purchase of 1000")
        continue
      }
      #expect(draft.kind == .refund)
      #expect(draft.similar.isEmpty)
    }
  }

  @Test func theKindsOfSettlement() throws {
    #expect(try Self.receipt("t=20260115T1030&s=1.00&n=3").operation.transactionKind == .expense)
    #expect(try Self.receipt("t=20260115T1030&s=1.00&n=4").operation.transactionKind == .refund)
    #expect(try Self.receipt("t=20260115T1030&s=1.00").operation == .sale)
    #expect(ReceiptQRParser.parse("t=20260115T1030&s=1.00&n=5") == nil)
    #expect(ReceiptQRParser.parse("t=20260115T1030&s=1.00&n=0") == nil)
  }

  @Test func theLinkOfAnOperatorOfFiscalDataIsRead() throws {
    let link = try Self.receipt(
      "https://check.example/rec?t=20260115T1030&s=150.00&fn=9999078900001111&i=42&fp=123456789&n=1"
    )
    #expect(link.numbers == (try Self.receipt(Self.text).numbers))
  }
}
