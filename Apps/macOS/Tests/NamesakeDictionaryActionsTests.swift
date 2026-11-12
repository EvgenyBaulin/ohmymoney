import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Goals, events, people, places and categories with one name: renaming either of two and
/// bringing an archived one back are separate choices, neither is refused for the name,
/// and a hidden pair stays hidden for that pair only.
@MainActor
final class NamesakeDictionaryActionsTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-namesake-dict-\(UUID().uuidString)", isDirectory: true)
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

  private var references: ReferenceRepository { environment.references! }

  private var actions: PlanningActions {
    PlanningActions(AppDependencies(environment: environment, store: store, compute: compute))
  }

  private func records(_ kind: NamesakeKind) -> [NamesakeRecord] {
    PlanningNamesakeNotice.dictionaryRecords(
      kind, references: references, entries: [], calendar: .utc)
  }

  func testTwoGoalsOfOneNameCanBeRenamedOrRestoredWithoutTouchingTheOther() throws {
    let old = Goal(name: "Trip", targetE4: AmountE4(whole: 10), archived: true)
    let new = Goal(name: "trip", targetE4: AmountE4(whole: 20))
    try references.save(old)
    try references.save(new)
    let proposals = Namesakes.proposals(
      for: NamesakeRecord(kind: .goal, id: UUID(), name: "TRIP"), among: records(.goal))
    XCTAssertEqual(proposals.count, 2)
    let named = try XCTUnwrap(records(.goal).first { $0.id == old.id })
    XCTAssertTrue(actions.renameNamesake(named, to: "Trip (2025)", in: .empty))
    XCTAssertEqual(
      try references.goals(includeArchived: true).first { $0.id == old.id }?.archived, true)
    XCTAssertEqual(try references.goals().first { $0.id == new.id }?.name, "trip")
    XCTAssertTrue(actions.restoreNamesake(named, in: .empty))
    XCTAssertEqual(try references.goals().count, 2)
  }

  func testAnArchivedEventPersonPlaceAndCategoryComeBackBesideALiveNamesake() throws {
    let day = DateOnly(year: 2026, month: 1, day: 1)
    let event = Event(name: "Trip", startDate: day, endDate: day, archived: true)
    let person = Person(name: "Anna", archived: true)
    let place = Place(name: "Cafe", archived: true)
    let category = CoreKit.Category(
      kind: .expense, name: "Food", sort: 0, archived: true, quality: .neutral)
    try references.save(event)
    try references.save(person)
    try references.save(place)
    try references.save(category)
    try references.save(Event(name: "trip", startDate: day, endDate: day))
    try references.save(Person(name: "ANNA"))
    try references.save(Place(name: "cafe"))
    try references.save(CoreKit.Category(kind: .expense, name: "food", sort: 1, quality: .neutral))

    for (kind, id) in [
      (NamesakeKind.event, event.id), (.person, person.id), (.place, place.id),
      (.category, category.id),
    ] {
      let named = try XCTUnwrap(records(kind).first { $0.id == id })
      XCTAssertTrue(named.archived)
      XCTAssertTrue(actions.restoreNamesake(named, in: .empty), "\(kind) was refused")
    }
    XCTAssertEqual(try references.events().count, 2)
    XCTAssertEqual(try references.people().count, 2)
    XCTAssertEqual(try references.places().count, 2)
    XCTAssertEqual(try references.categories().filter { $0.name.lowercased() == "food" }.count, 2)
  }

  func testRenamingADictionaryRecordChangesOnlyItsName() throws {
    let person = Person(name: "Anna", aliases: ["An"], archived: true)
    let place = Place(name: "Cafe")
    try references.save(person)
    try references.save(place)
    let named = try XCTUnwrap(records(.person).first)
    XCTAssertTrue(actions.renameNamesake(named, to: "Anna (2024)", in: .empty))
    let stored = try XCTUnwrap(try references.people(includeArchived: true).first)
    XCTAssertEqual(stored.name, "Anna (2024)")
    XCTAssertEqual(stored.aliases, ["An"])
    XCTAssertTrue(stored.archived)
    XCTAssertFalse(
      actions.renameNamesake(
        NamesakeRecord(kind: .place, id: UUID(), name: "Gone"), to: "New", in: .empty))
  }

  func testHidingOnePairKeepsTheAdviceForAnotherPair() throws {
    let first = NamesakeRecord(kind: .goal, id: UUID(), name: "Trip")
    let second = NamesakeRecord(kind: .goal, id: UUID(), name: "trip")
    let third = NamesakeRecord(kind: .goal, id: UUID(), name: "TRIP")
    let pair = Namesakes.pairKey(first, second)
    XCTAssertTrue(actions.hideNamesake(pair, stored: ""))
    let stored = try XCTUnwrap(try environment.settings?.string(Namesakes.hiddenPairsKey))
    XCTAssertTrue(Namesakes.proposals(for: first, among: [second], hidden: stored).isEmpty)
    XCTAssertEqual(Namesakes.proposals(for: first, among: [third], hidden: stored).count, 1)
  }
}
