import CoreKit
import Foundation
import Testing

@testable import CoreCSV

// Synthetic data only.

/// Schema 26 in the CSV: the merchant code and the commission go last in `transactions.csv`, the
/// fee of an account without a card last in `bank_conditions.csv`, the picture address last in
/// `wishes.csv`, and the valuations of things are the 55th file.
@Suite("CSV: MCC, commission, valuations, picture of a wish, fee without a card")
struct MerchantCodeAndFeeExportTests {
  @Test func theMerchantCodeKeepsFourDigitsAndRejectsTheRest() {
    #expect(MerchantCode.normalized("5411") == "5411")
    #expect(MerchantCode.normalized(" 742 ") == "0742")
    #expect(MerchantCode.normalized(742) == "0742")
    #expect(MerchantCode.normalized(0) == "0000")
    #expect(MerchantCode.normalized(10_000) == nil)
    #expect(MerchantCode.normalized(-1) == nil)
    #expect(MerchantCode.normalized("54110") == nil)
    #expect(MerchantCode.normalized("54a1") == nil)
    #expect(MerchantCode.normalized("") == nil)
    #expect(MerchantCode.normalized(String?.none) == nil)
    #expect(Transaction(kind: .expense, occurredAt: Date(), amountE4: .zero, mcc: "742").mcc == "0742")
  }

  @Test func theCodeAndTheFeeGoLastAndEmptyForNone() {
    #expect(Array(ExportTables.transactions.columns.suffix(2)) == ["mcc", "fee"])
    let bought = Transaction(
      kind: .expense, occurredAt: Date(timeIntervalSince1970: 1_768_000_000),
      amountE4: AmountE4(whole: 150), mcc: "0742", feeE4: AmountE4(raw: 12_500))
    let row = ExportTables.row(bought)
    #expect(row.count == ExportTables.transactions.columns.count)
    #expect(Array(row.suffix(2)) == ["0742", "1.25"])
    let plain = Transaction(
      kind: .expense, occurredAt: Date(timeIntervalSince1970: 1_768_000_000),
      amountE4: AmountE4(whole: 150))
    #expect(Array(ExportTables.row(plain).suffix(2)) == ["", ""])
  }

  @Test func theFeeWithoutACardAndThePictureGoLast() {
    #expect(ExportTables.bankConditions.columns.last == "no_card_fee")
    let conditions = BankConditions(accountId: UUID(), noCardFeeE4: AmountE4(whole: 150))
    let row = ExportTables.row(conditions)
    #expect(row.count == ExportTables.bankConditions.columns.count)
    #expect(row.last == "150")
    #expect(ExportTables.row(BankConditions(accountId: UUID())).last == "")
    #expect(!conditions.isEmpty)

    #expect(ExportTables.wishes.columns.last == "image_url")
    let wish = Wish(
      name: "Desk", createdOn: DateOnly(year: 2026, month: 11, day: 11),
      imageURL: "https://shop.example/image.jpg")
    let wishRow = ExportTables.row(wish)
    #expect(wishRow.count == ExportTables.wishes.columns.count)
    #expect(wishRow.last == "https://shop.example/image.jpg")
    #expect(
      ExportTables.row(Wish(name: "Desk", createdOn: DateOnly(year: 2026, month: 11, day: 11)))
        .last == "")
  }

  @Test func theValuationsAreTheLastOfFiftyFiveFiles() {
    #expect(ExportTables.all.count == 55)
    #expect(ExportTables.all.last == ExportTables.thingValuations)
    #expect(
      ExportTables.thingValuations.columns == [
        "id", "owner_kind", "owner_id", "valued_on", "value", "currency", "note", "recorded_at",
      ])
    let owner = UUID()
    let value = ThingValuation(
      owner: .asset, ownerId: owner, day: DateOnly(year: 2026, month: 11, day: 11),
      amountE4: AmountE4(raw: 1_234_500), currency: CurrencyCode("EUR"), note: "market",
      recordedAt: Date(timeIntervalSince1970: 1_790_000_000))
    let row = ExportTables.row(value)
    #expect(row.count == ExportTables.thingValuations.columns.count)
    #expect(row[1...6] == [
      "asset", owner.uuidString, "2026-11-11", "123.45", "EUR", "market",
    ][0...5])
    #expect(!ExportTables.thingValuations.columns.contains { $0.hasSuffix("_e4") })
  }

  @Test func aStatementLineWritesItsCodeToTheOperation() {
    var line = ImportedOperation(
      profileID: "p", sourceIndex: 0,
      moment: StatementMoment(day: DateOnly(year: 2026, month: 9, day: 14), minuteOfDay: 615),
      status: .posted, amount: AmountE4(whole: -100), currency: .rub, kind: .purchase,
      description: "SAMPLE CAFE", counterparty: .init(), merchant: "SAMPLE CAFE")
    line.mcc = "5812"
    let rubles = StatementRubleResolver.resolve(line) { _, _ in nil }!
    let entry = StatementEntryBuilder.entry(
      for: line, accountID: UUID(), accountKey: "a", importID: UUID(),
      zoneID: TravelDay.moscowId, rubles: rubles, choice: StatementEntryChoice(categoryID: nil),
      now: Date(timeIntervalSince1970: 1_800_000_000))
    #expect(entry.transaction.mcc == "5812")
    line.mcc = "not a code"
    let plain = StatementEntryBuilder.entry(
      for: line, accountID: UUID(), accountKey: "a", importID: UUID(),
      zoneID: TravelDay.moscowId, rubles: rubles, choice: StatementEntryChoice(categoryID: nil),
      now: Date(timeIntervalSince1970: 1_800_000_000))
    #expect(plain.transaction.mcc == nil)
  }
}
