import CoreKit
import Foundation
import Testing

@testable import CoreCSV

// Synthetic data only.

/// Schema 23 in the CSV: the numbers of the receipt go last in `transactions.csv`, the English
/// name of a category last in `categories.csv`; the files grew to 54.
@Suite("CSV: номера чека и английское название")
struct ReceiptAndEnglishExportTests {
  @Test func theReceiptNumbersGoLastAndEmptyForNone() throws {
    #expect(
      Array(ExportTables.transactions.columns.dropLast(2).suffix(4))
        == ["receipt_fn", "receipt_i", "receipt_fp", "receipt_n"])
    let numbers = try #require(
      ReceiptNumbers(
        fiscalDrive: "9999078900001111", documentNumber: "0000000042", fiscalSign: "0123456789",
        operation: 2))
    let operation = Transaction(
      kind: .refund, occurredAt: Date(timeIntervalSince1970: 1_768_000_000),
      amountE4: AmountE4(whole: 150), receipt: numbers)
    let row = ExportTables.row(operation)
    #expect(row.count == ExportTables.transactions.columns.count)
    #expect(Array(row.dropLast(2).suffix(4)) == ["9999078900001111", "42", "123456789", "2"])
    let plain = Transaction(
      kind: .expense, occurredAt: Date(timeIntervalSince1970: 1_768_000_000),
      amountE4: AmountE4(whole: 150))
    #expect(Array(ExportTables.row(plain).dropLast(2).suffix(4)) == ["", "", "", ""])
  }

  @Test func theEnglishNameAndItsSourceGoLast() {
    // The mark of schema 24 comes after them.
    #expect(
      Array(ExportTables.categories.columns.suffix(4))
        == ["name_en", "name_en_source", "icon", "color"])
    let category = Category(
      kind: .expense, name: "Продукты",
      translation: CategoryTranslation(english: "Groceries", source: "Продукты"))
    let row = ExportTables.row(category)
    #expect(row.count == ExportTables.categories.columns.count)
    #expect(Array(row.suffix(4).prefix(2)) == ["Groceries", "Продукты"])
    #expect(
      Array(ExportTables.row(Category(kind: .expense, name: "Такси")).suffix(4)) == ["", "", "", ""])
  }

  @Test func theFilesStayFiftyThreeAndNoColumnEndsInE4() {
    #expect(ExportTables.all.count == 55)
    for table in [ExportTables.transactions, ExportTables.categories] {
      #expect(!table.columns.contains { $0.hasSuffix("_e4") })
    }
  }
}
