import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// A database in memory with the store the screen writes through, for the actions of
/// «Капитал»: what an action wrote is read back from the database, not from a snapshot.
@MainActor
class CapitalStoreTestCase: XCTestCase {
  var environment: AppEnvironment!
  var store: TransactionsStore!
  var compute: ComputeStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-capital-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
    compute = ComputeStore(calendar: .system, rebuildsInline: true)
  }

  override func tearDown() async throws {
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  var actions: AssetActions {
    AssetActions(AppDependencies(environment: environment, store: store, compute: compute))
  }

  /// The assets and valuations as the database holds them now.
  func stored() async throws -> (assets: [Asset], valuations: [AssetValuation]) {
    let stack = try XCTUnwrap(environment.stack)
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    return (dataset.assets, dataset.assetValuations.sorted { $0.day < $1.day })
  }

  func day(_ day: Int, month: Int = 10) -> DateOnly {
    DateOnly(year: 2026, month: month, day: day)
  }
}

/// The editor of an asset: «Сохранить» of a new one writes the asset and its first valuation in
/// one step of ⌘Z; an empty name writes nothing; an edit leaves the valuations as they were;
/// «Новая оценка…» of a day that has one takes its place, and ⌘Z gives the old value back.
final class AssetEditorTests: CapitalStoreTestCase {
  func testANewAssetAndItsFirstValuationAreOneStep() async throws {
    let car = Asset(name: "  Машина ", kind: .vehicle, note: "  ")
    XCTAssertEqual(
      AssetEditor.save(
        car, isNew: true, value: AmountE4(whole: 1_500_000), on: day(1), with: actions),
      .done)
    let written = try await stored()
    XCTAssertEqual(written.assets.map(\.name), ["Машина"], "the spaces around the name stayed")
    XCTAssertEqual(written.assets.first?.kind, .vehicle)
    XCTAssertNil(written.assets.first?.note, "an empty note was kept as text")
    XCTAssertEqual(written.valuations.map(\.valueE4), [AmountE4(whole: 1_500_000)])
    XCTAssertEqual(written.valuations.first?.day, day(1))
    XCTAssertEqual(written.valuations.first?.assetId, car.id)
    XCTAssertTrue(store.canUndo)

    store.undo()
    let undone = try await stored()
    XCTAssertTrue(undone.assets.isEmpty, "one ⌘Z left the asset")
    XCTAssertTrue(undone.valuations.isEmpty, "one ⌘Z left the valuation")
    XCTAssertFalse(store.canUndo, "the save took more than one step")
  }

  func testANameOfSpacesOrAValueBelowZeroWritesNothing() async throws {
    XCTAssertEqual(
      actions.create(Asset(name: "   "), value: AmountE4(whole: 1), on: day(1)),
      .refused(.emptyName))
    XCTAssertEqual(
      actions.create(Asset(name: "Ноутбук"), value: AmountE4(whole: -1), on: day(1)),
      .refused(.negativeValue))
    let written = try await stored()
    XCTAssertTrue(written.assets.isEmpty)
    XCTAssertFalse(store.canUndo, "a step of ⌘Z was left for nothing written")
  }

  func testAnEditKeepsTheValuations() async throws {
    var flat = Asset(name: "Квартира", kind: .realty)
    XCTAssertEqual(actions.create(flat, value: AmountE4(whole: 9_000_000), on: day(1)), .done)
    flat.name = "Квартира на Ленина"
    flat.note = "ипотека закрыта"
    XCTAssertEqual(
      AssetEditor.save(flat, isNew: false, value: .zero, on: day(5), with: actions), .done)
    let written = try await stored()
    XCTAssertEqual(written.assets.first?.name, "Квартира на Ленина")
    XCTAssertEqual(written.assets.first?.note, "ипотека закрыта")
    XCTAssertEqual(
      written.valuations.map(\.valueE4), [AmountE4(whole: 9_000_000)],
      "an edit wrote a valuation")

    store.undo()
    let undone = try await stored().assets
    XCTAssertEqual(undone.first?.name, "Квартира", "⌘Z left the edit")
  }

  /// A valuation on a day that has one keeps one row for the day, with the new value; ⌘Z gives
  /// the old value back.
  func testAValuationOfTheSameDayTakesThePlace() async throws {
    let car = Asset(name: "Машина", kind: .vehicle)
    XCTAssertEqual(actions.create(car, value: AmountE4(whole: 1_500_000), on: day(1)), .done)
    var known = try await stored().valuations
    XCTAssertEqual(
      actions.value(car.id, value: AmountE4(whole: 1_400_000), on: day(20), among: known), .done)
    known = try await stored().valuations
    XCTAssertEqual(
      actions.value(
        car.id, value: AmountE4(whole: 1_350_000), on: day(20), note: " торг ", among: known),
      .done)

    let written = try await stored().valuations
    XCTAssertEqual(written.map(\.day), [day(1), day(20)], "a second valuation of one day")
    XCTAssertEqual(written.last?.valueE4, AmountE4(whole: 1_350_000))
    XCTAssertEqual(written.last?.note, "торг")

    store.undo()
    let undone = try await stored().valuations
    XCTAssertEqual(undone.map(\.day), [day(1), day(20)])
    XCTAssertEqual(undone.last?.valueE4, AmountE4(whole: 1_400_000), "⌘Z left the new value")
    XCTAssertNil(undone.last?.note)
  }

  /// The rule alone: the same day keeps the id of the valuation there; another day gets its own.
  func testTheChangeOfAValuation() {
    let asset = UUID()
    let there = AssetValuation(assetId: asset, day: day(3), valueE4: AmountE4(whole: 10))
    let other = AssetValuation(assetId: UUID(), day: day(4), valueE4: AmountE4(whole: 10))
    let same = try? AssetActions.valuing(
      asset, value: AmountE4(whole: 12), on: day(3), note: nil, among: [there, other],
      at: Date()
    ).get()
    XCTAssertEqual(same?.upsert.assetValuations.map(\.id), [there.id])
    XCTAssertEqual(same?.upsert.assetValuations.first?.valueE4, AmountE4(whole: 12))
    let fresh = try? AssetActions.valuing(
      asset, value: AmountE4(whole: 12), on: day(4), note: nil, among: [there, other],
      at: Date()
    ).get()
    XCTAssertNotEqual(fresh?.upsert.assetValuations.first?.id, other.id)
    XCTAssertNotEqual(fresh?.upsert.assetValuations.first?.id, there.id)
    XCTAssertEqual(
      AssetActions.refusal(saving: Asset(name: "X"), value: AmountE4(whole: -1)), .negativeValue)
  }

  /// The order of the list: the live ones before the ones sold by today, then as dragged, then
  /// by name.
  func testTheOrderOfTheList() {
    let sold = Asset(name: "Аквариум", disposedOn: day(1))
    let later = Asset(name: "Велосипед", disposedOn: day(30))
    let bike = Asset(name: "Байк")
    let dragged = Asset(name: "Яхта", sort: -1)
    let ordered = AssetActions.ordered(
      [sold, later, bike, dragged], today: day(10), locale: Locale(identifier: "ru"))
    XCTAssertEqual(ordered.map(\.name), ["Яхта", "Байк", "Велосипед", "Аквариум"])
  }
}
