import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Удалить…» of an asset takes its whole history along, and one ⌘Z gives back the asset with
/// every valuation; «Продано / списано…», «Не продано» and a valuation out of «История оценок»
/// are each one step too.
final class AssetDeleteUndoTests: CapitalStoreTestCase {
  func testDeletingAnAssetIsUndoneWithItsHistory() async throws {
    let car = Asset(name: "Машина", kind: .vehicle)
    let flat = Asset(name: "Квартира", kind: .realty)
    XCTAssertEqual(actions.create(car, value: AmountE4(whole: 1_500_000), on: day(1)), .done)
    XCTAssertEqual(actions.create(flat, value: AmountE4(whole: 9_000_000), on: day(1)), .done)
    for (offset, whole) in [1_450_000, 1_400_000].enumerated() {
      let known = try await stored().valuations
      XCTAssertEqual(
        actions.value(
          car.id, value: AmountE4(whole: Int64(whole)), on: day(1, month: 11 + offset),
          among: known), .done)
    }
    let before = try await stored()
    XCTAssertEqual(before.valuations.filter { $0.assetId == car.id }.count, 3)

    let written = try XCTUnwrap(before.assets.first { $0.id == car.id })
    XCTAssertEqual(actions.delete(written), .done)
    let after = try await stored()
    XCTAssertEqual(after.assets.map(\.id), [flat.id])
    XCTAssertEqual(after.valuations.map(\.assetId), [flat.id], "the history stayed behind")

    store.undo()
    let back = try await stored()
    XCTAssertEqual(Set(back.assets), Set(before.assets))
    XCTAssertEqual(back.valuations, before.valuations, "⌘Z lost a valuation")
  }

  func testSoldAndBackAreOneStepEach() async throws {
    let laptop = Asset(name: "Ноутбук", kind: .equipment)
    XCTAssertEqual(actions.create(laptop, value: AmountE4(whole: 120_000), on: day(1)), .done)
    let written = try await stored().assets[0]

    XCTAssertEqual(actions.dispose(written, on: day(15)), .done)
    let sold = try await stored().assets[0]
    XCTAssertEqual(sold.disposedOn, day(15))
    let history = try await stored().valuations
    XCTAssertEqual(history.count, 1, "selling it dropped its history")

    XCTAssertEqual(actions.dispose(sold, on: nil), .done)
    let back = try await stored().assets[0]
    XCTAssertNil(back.disposedOn)

    store.undo()
    let undone = try await stored().assets[0]
    XCTAssertEqual(undone.disposedOn, day(15))
    store.undo()
    let first = try await stored().assets[0]
    XCTAssertNil(first.disposedOn)
  }

  func testAValuationOutOfTheHistoryComesBack() async throws {
    let car = Asset(name: "Машина", kind: .vehicle)
    XCTAssertEqual(actions.create(car, value: AmountE4(whole: 1_500_000), on: day(1)), .done)
    let first = try await stored().valuations[0]

    XCTAssertEqual(actions.delete(valuation: first), .done)
    let after = try await stored()
    XCTAssertEqual(after.assets.count, 1, "the asset went with its last valuation")
    XCTAssertTrue(after.valuations.isEmpty)

    store.undo()
    let back = try await stored().valuations
    XCTAssertEqual(back, [first])
  }

  /// The history of «История оценок» is the asset's own, the latest first.
  func testTheHistoryIsTheLatestFirst() {
    let asset = UUID()
    let valuations = [
      AssetValuation(assetId: asset, day: day(1), valueE4: AmountE4(whole: 3)),
      AssetValuation(assetId: UUID(), day: day(9), valueE4: AmountE4(whole: 9)),
      AssetValuation(assetId: asset, day: day(5), valueE4: AmountE4(whole: 2)),
    ]
    XCTAssertEqual(
      AssetActions.history(of: asset, among: valuations).map(\.day), [day(5), day(1)])
    XCTAssertEqual(AssetActions.latest(of: asset, among: valuations)?.valueE4, AmountE4(whole: 2))
    XCTAssertNil(AssetActions.latest(of: UUID(), among: valuations))
  }
}
