import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// The assets and their valuations are rows of the planning: a new asset with its first
/// valuation, a valuation put in place of another of the same day, the marks of the cushion and
/// of essential spending, and the deletion of an asset with its history are each one write and
/// one step of ⌘Z, and ⌘Z gives back the database it found, value for value.
@Suite("Assets, valuations and the marks of the cushion are one step of ⌘Z")
struct AssetPlanningUndoTests {
  func tables(_ stack: DatabaseStack) throws -> [String: ExactTable] {
    try stack.writer.read { db in try ExactTables.read(db) }
  }

  func valuation(_ asset: Asset, _ day: Int, _ whole: Int64) -> AssetValuation {
    AssetValuation(
      assetId: asset.id, day: DateOnly(year: 2026, month: 10, day: day),
      valueE4: AmountE4(whole: whole))
  }

  @Test func anAssetWithItsFirstValuationIsOneStep() throws {
    let stack = try TestSupport.makeStack()
    let repository = PlanningRepository(writer: stack.writer)
    let before = try tables(stack)
    let car = Asset(name: "Машина", kind: .vehicle)
    let first = valuation(car, 1, 1_500_000)
    // The valuation comes first in the list: the asset is written before it all the same.
    let undo = try repository.apply(
      PlanningChange(upsert: PlanningRows(assets: [car], assetValuations: [first])))
    #expect(undo.inserted.assets == [car.id])
    #expect(undo.inserted.assetValuations == [first.id])
    try stack.writer.read { (db: Database) throws in
      #expect(try Asset.fetchAll(db) == [car])
      #expect(try AssetValuation.fetchAll(db) == [first])
    }
    try repository.revert(undo)
    #expect(try tables(stack) == before)
  }

  /// A valuation of a day that has one already takes its place under a new id: the old one is
  /// deleted before the new one is written, so the one-per-day rule never meets two.
  @Test func aValuationTakesThePlaceOfAnotherOfTheSameDay() throws {
    let stack = try TestSupport.makeStack()
    let repository = PlanningRepository(writer: stack.writer)
    let car = Asset(name: "Машина", kind: .vehicle)
    let first = valuation(car, 1, 1_500_000)
    _ = try repository.apply(
      PlanningChange(upsert: PlanningRows(assets: [car], assetValuations: [first])))
    let before = try tables(stack)
    let again = valuation(car, 1, 1_400_000)
    let undo = try repository.apply(
      PlanningChange(
        upsert: PlanningRows(assetValuations: [again]),
        delete: PlanningRowIDs(assetValuations: [first.id])))
    #expect(undo.before.assetValuations == [first])
    try stack.writer.read { (db: Database) throws in
      #expect(try AssetValuation.fetchAll(db) == [again])
    }
    try repository.revert(undo)
    #expect(try tables(stack) == before)
  }

  /// Deleting an asset takes its valuations along (`ON DELETE CASCADE`); they are kept in the
  /// step, so ⌘Z gives back the whole history at the rowids it had.
  @Test func deletingAnAssetKeepsItsHistoryForUndo() throws {
    let stack = try TestSupport.makeStack()
    let repository = PlanningRepository(writer: stack.writer)
    let car = Asset(name: "Машина", kind: .vehicle, sort: 1)
    let flat = Asset(name: "Квартира", kind: .realty)
    let history = [valuation(car, 1, 1_500_000), valuation(car, 2, 1_450_000)]
    let kept = valuation(flat, 1, 9_000_000)
    _ = try repository.apply(
      PlanningChange(
        upsert: PlanningRows(assets: [car, flat], assetValuations: history + [kept])))
    let before = try tables(stack)
    let undo = try repository.apply(PlanningChange(delete: PlanningRowIDs(assets: [car.id])))
    #expect(undo.before.assets == [car])
    #expect(undo.before.assetValuations == history)
    try stack.writer.read { (db: Database) throws in
      #expect(try Asset.fetchAll(db) == [flat])
      #expect(try AssetValuation.fetchAll(db) == [kept])
    }
    try repository.revert(undo)
    #expect(try tables(stack) == before)
  }

  /// The marks of the cushion and of essential spending, and the settings of the cushion, in one
  /// change: one step back.
  @Test func theMarksAndTheSettingsOfTheCushionAreOneStep() throws {
    let stack = try TestSupport.makeStack()
    let references = try TestSupport.seedReferences(stack)
    let repository = PlanningRepository(writer: stack.writer)
    let before = try tables(stack)
    var account = try #require(
      try stack.writer.read { (db: Database) throws in
        try PaymentMethod.fetchOne(db, key: references.paymentMethod.id.uuidString)
      })
    account.cushion = true
    var category = references.category
    category.essential = true
    let settings = CapitalSettings(targetMonths: 6)
    let undo = try repository.apply(
      PlanningChange(
        upsert: PlanningRows(categories: [category], paymentMethods: [account]),
        settings: settings.storedValues))
    let dataset = try stack.writer.read { db in try DatasetRepository.dataset(db, version: 0) }
    #expect(dataset.paymentMethods.first { $0.id == account.id }?.cushion == true)
    #expect(dataset.categories.first { $0.id == category.id }?.essential == true)
    #expect(dataset.capitalSettings == settings)
    try repository.revert(undo)
    #expect(try tables(stack) == before)
  }
}
