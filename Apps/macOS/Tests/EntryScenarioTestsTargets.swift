import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// What a line may point at besides a category, followed to the database: «цель отпуск 5000» is
/// a contribution to the goal under Goals, always rated good, and never a plan; «долг машина
/// 7000» is a payment of a debt I owe — its journal line written with the operation and taken
/// back with it by one ⌘Z —; an event covering the day is only suggested.
@MainActor
final class EntryScenarioTargetsTests: EntryScenarioCase {
  private var trip: Goal!
  private var car: Debt!

  override func setUp() async throws {
    try await super.setUp()
    trip = Goal(name: "Отпуск", targetE4: AmountE4(whole: 100_000))
    try book.references.save(trip)
    car = Debt(
      direction: .iOwe, type: .loan, name: "Машина", monthlyPaymentE4: AmountE4(whole: 7_000),
      paymentsAreExpenses: true)
    var rows = PlanningRows.empty
    rows.debts = [car]
    rows.debtEntries = [
      DebtRules.makeEntry(debtId: car.id, kind: .borrowed, amountE4: AmountE4(whole: 300_000))
    ]
    _ = try XCTUnwrap(book.environment.planning).apply(PlanningChange(upsert: rows))
    book.environment.refreshVocabulary()
  }

  private func line(_ text: String, on day: DateOnly? = nil) throws -> EntryDraftModel {
    let model = book.model()
    try book.enter(text, into: model, on: day)
    return model
  }

  // MARK: Goals

  func testAContributionToAGoalIsFiledUnderGoals() throws {
    let model = try line("цель отпуск 5000")
    XCTAssertEqual(model.draft.parts[0].goalId, trip.id)
    let goals = try XCTUnwrap(try book.system(.goals))
    XCTAssertEqual(model.draft.parts[0].categoryId, goals.id)
    XCTAssertNil(model.gapToAsk(), "the goal answers where the money goes")
    let entry = try book.save(model)
    XCTAssertEqual(entry.parts[0].goalId, trip.id)
    XCTAssertEqual(entry.parts[0].quality, .good)
  }

  func testAnEnglishGoal() throws {
    let model = try line("goal отпуск 5000")
    XCTAssertEqual(model.draft.parts[0].goalId, trip.id)
  }

  func testAContributionIsAlwaysGoodWhateverIsChosen() throws {
    let model = try line("цель отпуск 5000")
    model.draft.parts[0].quality = .bad
    model.draft.parts[0].qualitySource = .manual
    model.applyDefaults(today: book.today)
    XCTAssertEqual(model.draft.parts[0].quality, .good)
  }

  func testAContributionDatedAheadIsNoPlan() throws {
    let day = book.today.adding(days: 5)
    let model = try line("цель отпуск 5000 \(EntryScenarioQuestionTests.dotted(day))")
    XCTAssertNil(model.planAhead(today: book.today))
  }

  func testUndoTakesTheContributionBack() throws {
    try book.save(try line("цель отпуск 5000"))
    book.store.undo()
    XCTAssertTrue(try book.entries().isEmpty)
  }

  func testUnderGoalsWithoutAGoalCannotBeSaved() throws {
    let model = try line("абв 5000")
    let goals = try XCTUnwrap(try book.system(.goals))
    model.setCategory(goals.id, forPartAt: 0)
    XCTAssertFalse(model.canSave)
    model.setGoal(trip.id, forPartAt: 0)
    XCTAssertTrue(model.canSave)
  }

  func testAContributionIsNotMySpendingOfTheMonth() throws {
    try book.save(try line("цель отпуск 5000"))
    let entry = try XCTUnwrap(try book.entries().first)
    XCTAssertEqual(entry.parts[0].goalId, trip.id)
  }

  // MARK: Debts I owe

  func testADebtPaymentFromTheLineWritesItsJournalLine() throws {
    let model = try line("долг машина 7000")
    XCTAssertEqual(model.draft.debtId, car.id)
    XCTAssertNil(model.gapToAsk(), "a payment of a debt is not asked for a category")
    let entry = try book.save(model)
    let lines = try book.references.debtEntries(debtId: car.id)
    XCTAssertEqual(lines.count, 2)
    let paid = try XCTUnwrap(lines.first { $0.transactionId == entry.id })
    XCTAssertEqual(paid.amountE4.raw.magnitude, AmountE4(whole: 7_000).raw.magnitude)
  }

  func testUndoTakesThePaymentAndItsLine() throws {
    try book.save(try line("долг машина 7000"))
    book.store.undo()
    XCTAssertTrue(try book.entries().isEmpty)
    XCTAssertEqual(try book.references.debtEntries(debtId: car.id).count, 1)
  }

  func testAnEnglishLoanPayment() throws {
    let model = try line("loan машина 7000")
    XCTAssertEqual(model.draft.debtId, car.id)
  }

  func testThePaymentIsTheDebtBeingPaid() throws {
    let model = try line("долг машина 3000")
    XCTAssertEqual(model.debtBeingPaid?.id, car.id)
  }

  func testAPaymentAheadIsNoPlan() throws {
    let day = book.today.adding(days: 3)
    let model = try line("долг машина 7000 \(EntryScenarioQuestionTests.dotted(day))")
    XCTAssertNil(model.planAhead(today: book.today))
  }

  func testAClosedDebtIsNotPaidByTheLine() throws {
    var closed = car!
    closed.closed = true
    _ = try XCTUnwrap(book.environment.planning).apply(
      PlanningChange(upsert: PlanningRows(debts: [closed])))
    book.environment.refreshVocabulary()
    let model = try line("долг машина 7000")
    XCTAssertNil(model.debtBeingPaid)
  }

  func testAPaymentInAnotherCurrencyIsRefused() throws {
    let model = try line("долг машина 100 usd")
    model.setManualRate("90")
    XCTAssertThrowsError(
      try EntrySave.write(model, environment: book.environment, store: book.store)
    ) {
      XCTAssertEqual(EntryCommit.errorKey(of: $0), "entry.error.debtCurrency")
    }
    XCTAssertTrue(try book.entries().isEmpty)
  }

  func testAnIncomeOnADebtIOweGrowsIt() throws {
    let model = try line("+10000 долг машина")
    XCTAssertEqual(model.draft.kind, .income)
    let entry = try book.save(model)
    let line = try XCTUnwrap(
      try book.references.debtEntries(debtId: car.id).first { $0.transactionId == entry.id })
    XCTAssertEqual(line.kind, .borrowed)
  }

  // MARK: Events

  func testAnEventCoveringTheDayIsOnlySuggested() throws {
    let event = Event(
      name: "Поездка", kind: .trip, startDate: book.today.adding(days: -2),
      endDate: book.today.adding(days: 2))
    try book.references.save(event)
    book.environment.refreshVocabulary()
    let model = book.model()
    try book.enter("кофе 200", into: model)
    XCTAssertEqual(model.suggestedEvent?.id, event.id)
    XCTAssertNil(model.draft.parts[0].eventId)
  }

  func testAnEventNamedInTheLineIsWritten() throws {
    let event = Event(
      name: "Поездка", kind: .trip, startDate: book.today.adding(days: -2),
      endDate: book.today.adding(days: 2))
    try book.references.save(event)
    book.environment.refreshVocabulary()
    let model = book.model()
    try book.enter("кофе 200 поездка", into: model)
    model.setCategory(book.coffeeShops.id, forPartAt: 0)
    let entry = try book.save(model)
    XCTAssertEqual(entry.parts[0].eventId, event.id)
  }

  func testAnEventOfLastWeekIsNotSuggestedToday() throws {
    let event = Event(
      name: "Поездка", kind: .trip, startDate: book.today.adding(days: -9),
      endDate: book.today.adding(days: -7))
    try book.references.save(event)
    let model = book.model()
    try book.enter("кофе 200", into: model)
    XCTAssertNil(model.suggestedEvent)
  }
}
