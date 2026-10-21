import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Я в поездке» against a database: a trip picked or made turns the mode on for it, a new trip
/// is an event that keeps its kind and its currencies, and «Я вернулся» turns the mode off. The
/// event is written first, and the mode goes on only for an event that is there.
@MainActor
final class TripStartActionsTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var directory: URL!

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("trip-start-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: try XCTUnwrap(environment.references),
      planning: try XCTUnwrap(environment.planning))
    compute = ComputeStore(calendar: .system)
  }

  override func tearDown() async throws {
    unsetenv("OHMYMONEY_DATA_DIR")
    try? FileManager.default.removeItem(at: directory)
  }

  private var actions: TripStartActions {
    TripStartActions(
      AppDependencies(environment: environment, store: store, compute: compute))
  }

  private var travel: TravelRepository {
    TravelRepository(writer: environment.stack!.writer)
  }

  private func draft(name: String = "Турция") -> TripStart.Draft {
    let today = environment.today
    return TripStart.Draft(
      name: name, startDate: today, endDate: today.adding(days: 9),
      tripCurrency: CurrencyCode("TRY"), budget: AmountE4(whole: 100_000), budgetCurrency: .rub)
  }

  func testANewTripIsWrittenWithItsKindAndCurrenciesAndTheModeGoesOnForIt() throws {
    XCTAssertTrue(actions.start(draft(), switchingOn: true))
    let trips = try travel.trips()
    let trip = try XCTUnwrap(trips.first)
    XCTAssertEqual(trips.count, 1)
    XCTAssertEqual(trip.kind, .trip)
    XCTAssertEqual(trip.name, "Турция")
    XCTAssertEqual(trip.tripCurrency, CurrencyCode("TRY"))
    XCTAssertEqual(trip.budgetE4, AmountE4(whole: 100_000))
    XCTAssertEqual(trip.budgetCurrency, .rub)
    XCTAssertEqual(try travel.settings().activeEventId, trip.id)
    XCTAssertEqual(
      TripMode.state(
        settings: try travel.settings(), events: trips, today: environment.today), .on(trip))
  }

  func testANewTripWithoutTheModeLeavesTheModeAlone() throws {
    XCTAssertTrue(actions.start(draft(), switchingOn: false))
    XCTAssertEqual(try travel.trips().count, 1)
    XCTAssertNil(try travel.settings().activeEventId)
  }

  func testATripThatCannotBeStartedWritesNothing() throws {
    var bad = draft(name: "  ")
    XCTAssertFalse(actions.start(bad, switchingOn: true))
    bad = draft()
    bad.endDate = bad.startDate.adding(days: -1)
    XCTAssertFalse(actions.start(bad, switchingOn: true))
    XCTAssertEqual(try travel.trips().count, 0)
    XCTAssertNil(try travel.settings().activeEventId)
  }

  func testATripPickedFromTheListTurnsTheModeOnAndIAmBackTurnsItOff() throws {
    XCTAssertTrue(actions.start(draft(name: "Бали"), switchingOn: false))
    XCTAssertTrue(actions.start(draft(name: "Турция"), switchingOn: false))
    let bali = try XCTUnwrap(try travel.trips().first { $0.name == "Бали" })
    XCTAssertTrue(actions.switchOn(bali))
    XCTAssertEqual(try travel.settings().activeEventId, bali.id)
    XCTAssertTrue(actions.switchOff())
    XCTAssertNil(try travel.settings().activeEventId)
    XCTAssertEqual(try travel.trips().count, 2, "the trips stay")
  }

  func testATripBroughtBackFromTheArchiveStaysATripWithItsCurrencies() throws {
    XCTAssertTrue(actions.start(draft(), switchingOn: false))
    var archived = try XCTUnwrap(try travel.trips().first)
    archived.archived = true
    try environment.references!.save(archived)
    XCTAssertEqual(try travel.trips().count, 0)

    XCTAssertTrue(actions.start(draft(), switchingOn: true))
    let trip = try XCTUnwrap(try travel.trips().first)
    XCTAssertEqual(trip.id, archived.id, "the archived one came back, no second beside it")
    XCTAssertEqual(trip.kind, .trip)
    XCTAssertEqual(trip.tripCurrency, CurrencyCode("TRY"))
    XCTAssertEqual(try travel.settings().activeEventId, trip.id)
  }

  func testAGatheredGoalMakesATripWithItsMoneyAsTheBudgetAndTheModeOnForIt() throws {
    let goal = Goal(
      name: "Отпуск", targetE4: AmountE4(whole: 100_000), targetDate: nil, currency: .eur)
    let draft = try XCTUnwrap(
      TripGoal.draft(
        goalName: goal.name, target: goal.targetE4, saved: AmountE4(whole: 120_000),
        currency: goal.currency, targetDate: goal.targetDate, today: environment.today))
    XCTAssertTrue(actions.start(draft, switchingOn: true))
    let trip = try XCTUnwrap(try travel.trips().first)
    XCTAssertEqual(trip.name, "Отпуск")
    XCTAssertEqual(trip.kind, .trip)
    XCTAssertEqual(trip.budgetE4, AmountE4(whole: 120_000))
    XCTAssertEqual(trip.budgetCurrency, .eur)
    XCTAssertEqual(try travel.settings().activeEventId, trip.id)
    XCTAssertNil(
      TripGoal.draft(
        goalName: goal.name, target: goal.targetE4, saved: AmountE4(whole: 99_999),
        currency: goal.currency, targetDate: nil, today: environment.today),
      "a goal not gathered makes no trip")
  }

  func testTheNewTripIsOneStepOfUndo() throws {
    XCTAssertTrue(actions.start(draft(), switchingOn: false))
    XCTAssertEqual(try travel.trips().count, 1)
    XCTAssertTrue(store.canUndo)
    store.undo()
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline, (try environment.references!.events().count) > 0 {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    XCTAssertEqual(try environment.references!.events().count, 0)
  }
}
