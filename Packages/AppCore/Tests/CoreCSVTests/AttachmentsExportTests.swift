import CoreKit
import Foundation
import Testing

@testable import CoreCSV

/// The file schema 17 brought, and the columns it added to the operations.
@Suite("The export of attachments and the warranty columns of schema 17")
struct AttachmentsExportTests {
  private func roundTrip(_ table: ExportTable, row: [String]) throws -> [String: String] {
    #expect(row.count == table.columns.count)
    var writer = CSVWriter(columns: table.columns)
    writer.append(row)
    let dictionaries = try CSVReader.dictionaries(from: writer.data())
    #expect(dictionaries.count == 1)
    return dictionaries[0]
  }

  @Test func anAttachmentIsOneRowWithoutItsBytes() throws {
    let owner = UUID()
    let added = Date(timeIntervalSince1970: 1_800_000_000)
    let file = AttachedFile(
      ownerKind: .debt, ownerId: owner, contentHash: String(repeating: "ab", count: 32),
      fileName: "договор, «№1».pdf", byteSize: 7_000_000_000, mediaType: "application/pdf",
      kind: .document, addedAt: added, keepForever: true, note: "оригинал в сейфе")
    let read = try roundTrip(ExportTables.attachments, row: ExportTables.row(file))
    #expect(read["id"] == file.id.uuidString)
    #expect(read["owner_kind"] == "debt")
    #expect(read["owner_id"] == owner.uuidString)
    #expect(read["content_hash"] == String(repeating: "ab", count: 32))
    #expect(read["file_name"] == "договор, «№1».pdf")
    #expect(read["byte_size"] == "7000000000")
    #expect(read["media_type"] == "application/pdf")
    #expect(read["kind"] == "document")
    #expect(read["trashed_at"] == "")
    #expect(read["keep_forever"] == "true")
    #expect(read["note"] == "оригинал в сейфе")
    #expect(!read.keys.contains("bytes") && !read.keys.contains("data"))
  }

  @Test func theWarrantyOfAnOperationGoesLastAndEmptyForNone() throws {
    let plain = Transaction(
      kind: .expense, occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
      amountE4: AmountE4(whole: 100))
    let none = try roundTrip(ExportTables.transactions, row: ExportTables.row(plain))
    #expect(none["warranty_until"] == "" && none["warranty_where"] == "")
    #expect(none["return_until"] == "")

    var bought = plain
    bought.warrantyUntil = DateOnly(year: 2028, month: 10, day: 29)
    bought.warrantyWhere = "папка «Техника», верхний ящик"
    bought.returnUntil = DateOnly(year: 2026, month: 11, day: 12)
    let read = try roundTrip(ExportTables.transactions, row: ExportTables.row(bought))
    #expect(read["warranty_until"] == "2028-10-29")
    #expect(read["warranty_where"] == "папка «Техника», верхний ящик")
    #expect(read["return_until"] == "2026-11-12")
    #expect(
      Array(ExportTables.transactions.columns.suffix(3)) == [
        "warranty_until", "warranty_where", "return_until",
      ])
  }

  @Test func theAnswersOfTheWeeksAreNotExported() {
    #expect(!ExportTables.all.map(\.fileName).contains("week_answers.csv"))
  }
}
