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

  @Test func independentValuationsLoadIntoDatasetAndTravelInSettingsCSV() async throws {
    let stack = try TestSupport.makeStack()
    let item = OwnedItem(name: "Synthetic", boughtOn: day, priceE4: AmountE4(whole: 100))
    try OwnedItemRepository(writer: stack.writer).insert(item)
    let values = ThingValuationRepository(writer: stack.writer)
    let first = ThingValuation(
      owner: .ownedItem, ownerId: item.id, day: day,
      amountE4: AmountE4(whole: 80), currency: CurrencyCode("USD"), note: "First")
    let second = ThingValuation(
      owner: .ownedItem, ownerId: item.id, day: day,
      amountE4: AmountE4(whole: 75), currency: CurrencyCode("EUR"), note: "Second")
    try values.save(first)
    try values.save(second)
    #expect(try values.all().count == 2)
    let loaded = try await DatasetRepository(writer: stack.writer).load(version: 1)
    #expect(Set(loaded.thingValuations) == Set([first, second]))
    #expect(
      try SettingsRepository(writer: stack.writer).string(first.storageKey)
        == (try first.storedValue))
    let tables = try ExportRepository(writer: stack.writer).tables()
    let csv = try #require(tables.first { $0.fileName == "settings.csv" })
    let rows = try CSVReader.dictionaries(from: csv.data)
    let exported = try #require(rows.first { $0["key"] == first.storageKey }?["value"])
    #expect(try ThingValuation.decode(exported) == first)
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
  }

  @Test func assetDeletionAndUndoIncludeNewValuations() throws {
    let stack = try TestSupport.makeStack()
    let planning = PlanningRepository(writer: stack.writer)
    let asset = Asset(name: "Synthetic")
    _ = try planning.apply(PlanningChange(upsert: PlanningRows(assets: [asset])))
    let value = ThingValuation(
      owner: .asset, ownerId: asset.id, day: day,
      amountE4: AmountE4(whole: 1), currency: .rub)
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
    try SettingsRepository(writer: stack.writer).set(
      WishRepository.imageKey(UUID()),
      to: "https://shop.example/private-image")
    try SQLAnonymizer().anonymize(copy: ExportCopyDatabase(writer: stack.writer))
    let cleaned = try #require(try ThingValuationRepository(writer: stack.writer).all().first)
    #expect(cleaned.note == nil)
    #expect(cleaned.amountE4 == value.amountE4)
    let tables = try ExportRepository(writer: stack.writer).tables()
    let settings = try #require(tables.first { $0.fileName == "settings.csv" })
    #expect(!String(decoding: settings.data, as: UTF8.self).contains("Private text"))
    #expect(!String(decoding: settings.data, as: UTF8.self).contains("private-image"))
  }
}
