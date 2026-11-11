import CoreKit
import Foundation
import Testing

@testable import CoreParse

@Suite("Чек по печатному тексту")
struct PrintedReceiptTests {
  private func receipt(_ lines: [String]) throws -> PrintedReceipt {
    guard case .receipt(let printed) = PrintedReceiptReader.read(lines: lines) else {
      throw ReadFailure()
    }
    return printed
  }
  private struct ReadFailure: Error {}

  private let fiscal = [
    "ООО Ромашка", "КАССОВЫЙ ЧЕК", "Приход", "Хлеб 1 x 45.00", "ИТОГ 1 250.50", "НДС 20% 208.42",
    "29.10.2026 18:32", "ФН 9960 4403 0000 0000", "ФД 0000012345", "ФП 2345678901",
  ]

  @Test func fiscalReceiptGivesSumMomentAndNumbers() throws {
    let printed = try receipt(fiscal)
    #expect(printed.kind == .fiscal)
    #expect(!printed.numbersRejected)
    #expect(printed.receipt.amountE4.raw == 12_505_000)
    #expect(printed.receipt.day == DateOnly(year: 2026, month: 10, day: 29))
    #expect(printed.receipt.time == TimeOfDay(hour: 18, minute: 32))
    #expect(printed.receipt.currency == .rub)
    let numbers = try #require(printed.receipt.numbers)
    // The same receipt read from its QR (no leading zeros) is the same key.
    let fromQR = try #require(
      ReceiptQRParser.parse("t=20261029T1832&s=1250.50&fn=9960440300000000&i=12345&fp=2345678901&n=1")
    )
    #expect(numbers.isSameReceipt(as: try #require(fromQR.numbers)))
  }

  @Test func cameraLettersInsteadOfZerosAreRead() throws {
    var lines = fiscal
    lines[7] = "ФН: 9960 44O3 OOOO OOOO"
    #expect(try receipt(lines).receipt.fiscalDrive == "9960440300000000")
  }

  @Test func badDriveNumberKeepsSumAndDateButNoKey() throws {
    var lines = fiscal
    lines[7] = "ФН 9960 4403 000"
    let printed = try receipt(lines)
    #expect(printed.numbersRejected)
    #expect(printed.receipt.numbers == nil)
    #expect(printed.receipt.amountE4.raw == 12_505_000)
  }

  @Test func missingSignGivesNoKey() throws {
    let printed = try receipt(Array(fiscal.dropLast()))
    // ФН and ФД make it a fiscal receipt, but without the sign the numbers do not pass.
    #expect(printed.kind == .fiscal)
    #expect(printed.numbersRejected)
  }

  @Test func refundIsRecognised() throws {
    var lines = fiscal
    lines[2] = "Возврат прихода"
    let printed = try receipt(lines)
    #expect(printed.receipt.operation == .saleReturn)
    #expect(printed.receipt.isRefund)
  }

  @Test func slipIsASourceOfSumAndMoment() throws {
    let printed = try receipt([
      "TERMINAL 12345678", "VISA ****1234", "SALE", "AMOUNT AZN 23.50", "RRN 123456789012",
      "AUTH CODE 123456", "12/11/2026 14:05:33", "APPROVED",
    ])
    #expect(printed.kind == .slip)
    #expect(printed.receipt.amountE4.raw == 235_000)
    #expect(printed.receipt.currency == CurrencyCode("AZN"))
    #expect(printed.receipt.day == DateOnly(year: 2026, month: 11, day: 12))
    #expect(printed.receipt.time == TimeOfDay(hour: 14, minute: 5))
    #expect(printed.receipt.second == 33)
    #expect(printed.receipt.numbers == nil)
  }

  @Test func guestBillIsNotASource() {
    let reading = PrintedReceiptReader.read(lines: [
      "Restaurant", "Guest bill", "Total 120.00 AZN", "Service 10 %", "12.11.2026 20:10",
    ])
    #expect(reading == .bill)
  }

  @Test func billWithRussianWordIsABill() {
    #expect(
      PrintedReceiptReader.read(lines: ["СЧЁТ № 4", "ИТОГО 3 500,00", "01.11.2026 21:00"]) == .bill)
  }

  @Test func slipBesideABillWinsOverTheBill() throws {
    let printed = try receipt([
      "BILL", "TOTAL 50.00", "TERMINAL 1", "VISA", "AMOUNT AZN 55.00", "12.11.2026 21:00",
    ])
    #expect(printed.kind == .slip)
    #expect(printed.receipt.amountE4.raw == 550_000)
  }

  @Test func foreignReceiptGivesOnlyTotalAndMoment() throws {
    let printed = try receipt(["Cəmi: 7.40 ₼", "Tarix 02.11.2026", "Vaxt 10:15"])
    #expect(printed.kind == .other)
    #expect(printed.receipt.currency == CurrencyCode("AZN"))
    #expect(printed.receipt.amountE4.raw == 74_000)
    #expect(printed.receipt.time == TimeOfDay(hour: 10, minute: 15))
  }

  @Test func subtotalAndVatLinesAreNotTheTotal() throws {
    let printed = try receipt(["Subtotal 100.00", "VAT 18.00", "Total 118.00", "01.11.2026 09:00"])
    #expect(printed.receipt.amountE4.raw == 1_180_000)
  }

  @Test func totalOnTheNextLine() throws {
    let printed = try receipt(["ИТОГО", "2 400,00 руб", "03.11.2026 12:00"])
    #expect(printed.receipt.amountE4.raw == 24_000_000)
  }

  @Test func thousandsSeparatorsAreNotDecimals() throws {
    let printed = try receipt(["TOTAL 1,250.50 USD", "03.11.2026 12:00"])
    #expect(printed.receipt.amountE4.raw == 12_505_000)
    #expect(printed.receipt.currency == .usd)
  }

  @Test func integerSumNeedsACurrency() throws {
    #expect(PrintedReceiptReader.read(lines: ["ИТОГ 3 поз.", "03.11.2026 12:00"]) == .nothing)
    #expect(try receipt(["ИТОГ 300 руб", "03.11.2026 12:00"]).receipt.amountE4.raw == 3_000_000)
  }

  @Test func noMomentOrNoTotalIsNothing() {
    #expect(PrintedReceiptReader.read(lines: ["ИТОГ 10.00"]) == .nothing)
    #expect(PrintedReceiptReader.read(lines: ["03.11.2026 12:00", "hello"]) == .nothing)
    #expect(PrintedReceiptReader.read(lines: []) == .nothing)
    #expect(PrintedReceiptReader.read(lines: ["ИТОГ 10.00", "31.02.2026 12:00"]) == .nothing)
  }

  @Test func monthFirstDateIsSwappedOnlyWhenDayFirstIsImpossible() throws {
    let printed = try receipt(["TOTAL 10.00", "11/25/2026 08:00"])
    #expect(printed.receipt.day == DateOnly(year: 2026, month: 11, day: 25))
    let ambiguous = try receipt(["TOTAL 10.00", "05/06/2026 08:00"])
    #expect(ambiguous.receipt.day == DateOnly(year: 2026, month: 6, day: 5))
  }

  @Test func dateAndTimeOnSeparateLines() throws {
    let printed = try receipt(["ИТОГ 10.00", "2026-11-03", "09:41"])
    #expect(printed.receipt.day == DateOnly(year: 2026, month: 11, day: 3))
    #expect(printed.receipt.time == TimeOfDay(hour: 9, minute: 41))
  }

  @Test func foreignCurrencyDoesNotMatchARoubleOperation() {
    let receipt = ReceiptQR(
      day: DateOnly(year: 2026, month: 11, day: 3), time: TimeOfDay(hour: 9, minute: 0),
      amountE4: AmountE4(raw: 1_000_000), operation: .sale, currency: CurrencyCode("AZN"))
    let operation = ReceiptCandidate(
      id: UUID(), kind: .expense,
      occurredAt: CalendarContext.utc.moment(receipt.day, hour: 8, minute: 0),
      currency: .rub, amountE4: AmountE4(raw: 1_000_000))
    guard case .new(let draft) = ReceiptMatch.propose(receipt, among: [operation], calendar: .utc)
    else {
      Issue.record("a rouble operation must not take an AZN receipt")
      return
    }
    #expect(draft.currency == CurrencyCode("AZN"))
  }
}
