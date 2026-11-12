import AppCore
import Foundation
import GRDB
import Testing

@testable import AppDatabase

@Suite("Wishes, things, files and valuation persistence")
struct ThingsWishesStorageTests {
  private let day = DateOnly(year: 2026, month: 11, day: 11)

  @Test func newAttachmentOwnersRoundTripAndAreDeletedWithTheirOwner() throws {
    let stack = try TestSupport.makeStack()
    let wishes = WishRepository(writer: stack.writer)
    let items = OwnedItemRepository(writer: stack.writer)
    let files = AttachmentRepository(writer: stack.writer)
    let wish = Wish(name: "Synthetic", createdOn: day)
    let item = OwnedItem(name: "Synthetic")
    try wishes.insert(wish)
    try items.insert(item)
    for (owner, id) in [(AttachmentOwnerKind.wish, wish.id), (.ownedItem, item.id)] {
      for (name, type) in [
        ("photo.jpg", "image/jpeg"), ("video.mov", "video/quicktime"),
        ("file.bin", "application/octet-stream"),
      ] {
        let file = AttachedFile(
          ownerKind: owner, ownerId: id,
          contentHash: String(repeating: "a", count: 64), fileName: name, byteSize: 42,
          mediaType: type)
        try files.insert(file)
      }
      #expect(try files.attachments(of: owner, id: id).count == 3)
    }
    try wishes.delete(ids: [wish.id])
    try items.delete(ids: [item.id])
    #expect(try files.all().isEmpty)
  }

  @Test func independentValuationsLoadIntoDatasetAndTravelInTheirOwnCSVFile() async throws {
    let stack = try TestSupport.makeStack()
    let item = OwnedItem(name: "Synthetic", boughtOn: day, priceE4: AmountE4(whole: 100))
    try OwnedItemRepository(writer: stack.writer).insert(item)
    let values = ThingValuationRepository(writer: stack.writer)
    let first = ThingValuation(
      owner: .ownedItem, ownerId: item.id, day: day,
      amountE4: AmountE4(whole: 80), currency: CurrencyCode("USD"), note: "First",
      recordedAt: Date(timeIntervalSince1970: 1_790_000_000))
    let second = ThingValuation(
      owner: .ownedItem, ownerId: item.id, day: day,
      amountE4: AmountE4(whole: 75), currency: CurrencyCode("EUR"), note: "Second",
      recordedAt: Date(timeIntervalSince1970: 1_790_000_100))
    try values.save(first)
    try values.save(second)
    #expect(try values.all() == [first, second])
    let loaded = try await DatasetRepository(writer: stack.writer).load(version: 1)
    #expect(Set(loaded.thingValuations) == Set([first, second]))
    let tables = try ExportRepository(writer: stack.writer).tables()
    let csv = try #require(tables.first { $0.fileName == "thing_valuations.csv" })
    let rows = try CSVReader.dictionaries(from: csv.data)
    #expect(rows.count == 2)
    let exported = try #require(rows.first { $0["id"] == first.id.uuidString })
    #expect(exported["owner_kind"] == "owned_item" && exported["owner_id"] == item.id.uuidString)
    #expect(exported["valued_on"] == day.iso && exported["value"] == "80")
    #expect(exported["currency"] == "USD" && exported["note"] == "First")
    let settings = try #require(tables.first { $0.fileName == "settings.csv" })
    #expect(!String(decoding: settings.data, as: UTF8.self).contains("First"))
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let copyURL = folder.appendingPathComponent("copy.sqlite")
    _ = try ExportRepository(writer: stack.writer).snapshot(to: copyURL)
    let copy = try DatabaseQueue(path: copyURL.path)
    #expect(try Set(ThingValuationRepository(writer: copy).all()) == Set([first, second]))
    #expect(
      try OwnedItemRepository(writer: stack.writer).item(id: item.id)?.priceE4
        == AmountE4(whole: 100))
    try OwnedItemRepository(writer: stack.writer).delete(ids: [item.id])
    #expect(try values.all().isEmpty)
  }

  @Test func aValuationNeedsItsOwnerAndAnAmountOfZeroOrMore() throws {
    let stack = try TestSupport.makeStack()
    let values = ThingValuationRepository(writer: stack.writer)
    #expect(throws: ThingValuationWriteError.ownerMissing) {
      try values.save(
        ThingValuation(
          owner: .asset, ownerId: UUID(), day: day, amountE4: .zero, currency: .rub))
    }
    let item = OwnedItem(name: "Synthetic")
    try OwnedItemRepository(writer: stack.writer).insert(item)
    #expect(throws: ThingValuationWriteError.negativeAmount) {
      try values.save(
        ThingValuation(
          owner: .ownedItem, ownerId: item.id, day: day, amountE4: AmountE4(raw: -1),
          currency: .rub))
    }
    #expect(try values.all().isEmpty)
  }

  @Test func aValuationOfAnUnknownOwnerKindIsKeptInTheDatabaseButNotRead() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO thing_valuations
            (id, owner_kind, owner_id, valued_on, value_e4, currency, recorded_at)
          VALUES (?, 'from_a_newer_build', ?, '2026-11-11', 10000, 'RUB', '2026-11-11 10:00:00.000')
          """, arguments: [UUID().uuidString, UUID().uuidString])
    }
    #expect(try ThingValuationRepository(writer: stack.writer).all().isEmpty)
    let rows = try stack.writer.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM thing_valuations")
    }
    #expect(rows == 1)
    let text = try ExportRepository(writer: stack.writer).tables()
      .first { $0.fileName == "thing_valuations.csv" }
    let csv = try CSVReader.dictionaries(from: try #require(text).data)
    #expect(csv.count == 1 && csv[0]["owner_kind"] == "from_a_newer_build")
  }

  @Test func theCheckReportsAValuationWhoseOwnerIsGone() throws {
    let stack = try TestSupport.makeStack()
    #expect(try DatabaseCheck.run(stack.writer).isHealthy)
    let lost = UUID().uuidString
    try stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO thing_valuations
            (id, owner_kind, owner_id, valued_on, value_e4, currency, recorded_at)
          VALUES (?, 'asset', ?, '2026-11-11', 10000, 'RUB', '2026-11-11 10:00:00.000')
          """, arguments: [lost, UUID().uuidString])
    }
    let report = try DatabaseCheck.run(stack.writer)
    let finding = try #require(report.findings.first { $0.rule == .valuationWithoutOwner })
    #expect(finding.count == 1 && finding.ids == [lost] && !finding.isRepairable)
  }

  @Test func theValuationsOfAnAssetAreOneStepOfUndoAndTravelAsRows() throws {
    let stack = try TestSupport.makeStack()
    let planning = PlanningRepository(writer: stack.writer)
    let asset = Asset(name: "Synthetic")
    let value = ThingValuation(
      owner: .asset, ownerId: asset.id, day: day, amountE4: AmountE4(whole: 5), currency: .eur,
      recordedAt: Date(timeIntervalSince1970: 1_790_000_000))
    var change = PlanningChange()
    change.upsert.assets = [asset]
    change.upsert.thingValuations = [value]
    let added = try planning.apply(change)
    #expect(try ThingValuationRepository(writer: stack.writer).all() == [value])
    try planning.revert(added)
    #expect(try ThingValuationRepository(writer: stack.writer).all().isEmpty)
  }

  @Test func aFailedLookupStillAllowsTheEnteredLinkToBeSaved() throws {
    let stack = try TestSupport.makeStack()
    let wishes = WishRepository(writer: stack.writer)
    let wish = Wish(
      name: "Manual", priceE4: AmountE4(whole: 10),
      url: "https://shop.example/unavailable", createdOn: day)
    try wishes.save(wish, isNew: true, imageURL: nil)
    #expect(try wishes.wish(id: wish.id) == wish)
    let image = URL(string: "https://shop.example/image.jpg")!
    try wishes.save(wish, isNew: false, imageURL: image)
    #expect(try wishes.imageURL(of: wish.id) == image)
    try wishes.save(wish, isNew: false, imageURL: nil)
    #expect(try wishes.imageURL(of: wish.id) == image)
    #expect(try wishes.wish(id: wish.id)?.imageURL == image.absoluteString)
    let csv = try #require(
      try ExportRepository(writer: stack.writer).tables().first { $0.fileName == "wishes.csv" })
    let rows = try CSVReader.dictionaries(from: csv.data)
    #expect(rows.first?["image_url"] == image.absoluteString)
  }

  @Test func assetDeletionAndUndoIncludeNewValuations() throws {
    let stack = try TestSupport.makeStack()
    let planning = PlanningRepository(writer: stack.writer)
    let asset = Asset(name: "Synthetic")
    _ = try planning.apply(PlanningChange(upsert: PlanningRows(assets: [asset])))
    let value = ThingValuation(
      owner: .asset, ownerId: asset.id, day: day,
      amountE4: AmountE4(whole: 1), currency: .rub,
      recordedAt: Date(timeIntervalSince1970: 1_790_000_000))
    try ThingValuationRepository(writer: stack.writer).save(value)
    let undo = try planning.apply(PlanningChange(delete: PlanningRowIDs(assets: [asset.id])))
    #expect(try ThingValuationRepository(writer: stack.writer).all().isEmpty)
    try planning.revert(undo)
    #expect(try ThingValuationRepository(writer: stack.writer).all() == [value])
  }

  @Test func anonymizedCopyDropsValuationNotesAndProductImageAddresses() throws {
    let stack = try TestSupport.makeStack()
    let item = OwnedItem(name: "Synthetic")
    try OwnedItemRepository(writer: stack.writer).insert(item)
    let value = ThingValuation(
      owner: .ownedItem, ownerId: item.id, day: day,
      amountE4: AmountE4(whole: 1), currency: .rub, note: "Private text")
    try ThingValuationRepository(writer: stack.writer).save(value)
    let wish = Wish(name: "Synthetic", createdOn: day)
    try WishRepository(writer: stack.writer).save(
      wish, isNew: true, imageURL: URL(string: "https://shop.example/private-image"))
    try SQLAnonymizer().anonymize(copy: ExportCopyDatabase(writer: stack.writer))
    let cleaned = try #require(try ThingValuationRepository(writer: stack.writer).all().first)
    #expect(cleaned.note == nil)
    #expect(cleaned.amountE4 == value.amountE4 && cleaned.currency == value.currency)
    #expect(try WishRepository(writer: stack.writer).imageURL(of: wish.id) == nil)
    let tables = try ExportRepository(writer: stack.writer).tables()
    for table in tables {
      let text = String(decoding: table.data, as: UTF8.self)
      #expect(!text.contains("Private text"), "\(table.fileName)")
      #expect(!text.contains("private-image"), "\(table.fileName)")
    }
  }
}
