import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The owner's actions on the Planning screen against a database, each followed by ⌘Z: a bill
/// saved with a name full of spaces and without a date, «Провести» of an ordinary and of a one-off
/// bill, «Пропустить» on the 31st, «Уже списано до сверки», a new price, a bill deleted;
/// expectations saved as one form, closed, brought back, deleted; a limit saved, refused on
/// «Цели», deleted, and suggested limits added at once; a goal archived; an event saved.
@MainActor
final class PlanningScenarioTestsActions: XCTestCase {
  private typealias S = PlanningScenario
  private var store: TransactionsStore!
  private var transactions: TransactionRepository!
  private var planning: PlanningRepository!
  private var references: ReferenceRepository!
  private var compute: ComputeStore!
  private var environment: AppEnvironment!
  private let today = S.day("2026-10-14")

  private let food = CoreKit.Category(kind: .expense, name: "Продукты")
  private let home = CoreKit.Category(kind: .expense, name: "Дом")
  private let goalsRoot = CoreKit.Category(
    kind: .expense, name: "Цели", quality: .good, systemRole: .goals)

  override func setUp() async throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    transactions = TransactionRepository(writer: stack.writer)
    references = ReferenceRepository(writer: stack.writer)
    planning = PlanningRepository(writer: stack.writer)
    store = TransactionsStore()
    store.attach(transactions, references: references, planning: planning)
    compute = ComputeStore(calendar: .utc, rebuildsInline: true)
    environment = AppEnvironment()
    let noon = S.calendar.noon(of: today)
    environment.now = { noon }
    for category in [food, home, goalsRoot] { try references.save(category) }
  }

  private var actions: PlanningActions {
    PlanningActions(AppDependencies(environment: environment, store: store, compute: compute))
  }

  /// The data the actions read, as the pipeline would show it.
  private func show(entries: [TransactionEntry] = [], budgets: [Budget] = []) {
    compute.applyLight(
      DataSnapshot.build(
        dataset: Dataset(
          entries: entries, categories: [food, home, goalsRoot],
          planning: PlanningBook(budgets: budgets)),
        calendar: .utc, today: today, context: SnapshotContext(), version: DataVersion(load: 0)))
  }

  private func operations() throws -> [TransactionEntry] {
    try transactions.entries(from: .distantPast, to: .distantFuture)
  }

  private func bill(
    _ next: String = "2026-10-20", end: String? = nil, day: Int? = nil
  )
    -> ScheduledPayment
  {
    ScheduledPayment(
      name: "Квартира", amountE4: S.rub(30_000), categoryId: home.id,
      day: day ?? S.day(next).day, nextDate: S.day(next), endDate: end.map(S.day))
  }

  // MARK: Bills

  func testASavedBillLosesItsSpacesAndOneUndoTakesItAway() throws {
    var payment = bill()
    payment.name = "  Квартира \n"
    XCTAssertTrue(actions.save(payment, previous: nil))
    XCTAssertEqual(try planning.scheduled().map(\.name), ["Квартира"])
    store.undo()
    XCTAssertTrue(try planning.scheduled().isEmpty)
  }

  func testABillWithoutADateStartsOnTheFirstDayOfItsRuleFromToday() throws {
    var payment = bill()
    payment.nextDate = nil
    payment.day = 5
    XCTAssertTrue(actions.save(payment, previous: nil))
    XCTAssertEqual(try planning.scheduled().first?.nextDate, S.day("2026-11-05"))
  }

  func testPayingABillWritesItsOperationAndMovesItOnAndUndoBringsItBack() throws {
    let payment = bill()
    XCTAssertTrue(actions.save(payment, previous: nil))
    XCTAssertTrue(
      actions.markAsPaid(
        payment, due: S.day("2026-10-20"), amount: S.rub(30_000), on: S.calendar.noon(of: today),
        paymentMethodId: nil, updatePrice: false))
    let paid = try XCTUnwrap(try operations().first)
    XCTAssertEqual(paid.transaction.amountE4, S.rub(30_000))
    XCTAssertEqual(paid.parts.first?.categoryId, home.id)
    XCTAssertEqual(
      paid.transaction.externalId,
      OperationLink.scheduled(paymentId: payment.id, due: S.day("2026-10-20")).externalId)
    XCTAssertEqual(try planning.scheduled().first?.nextDate, S.day("2026-11-20"))
    store.undo()
    XCTAssertTrue(try operations().isEmpty)
    XCTAssertEqual(try planning.scheduled().first?.nextDate, S.day("2026-10-20"))
  }

  func testPayingAOneOffBillLeavesItWithNoDateAhead() throws {
    let payment = bill(end: "2026-10-20")
    XCTAssertTrue(payment.isOneOff)
    XCTAssertTrue(actions.save(payment, previous: nil))
    XCTAssertTrue(
      actions.markAsPaid(
        payment, due: S.day("2026-10-20"), amount: S.rub(30_000), on: S.calendar.noon(of: today),
        paymentMethodId: nil, updatePrice: false))
    XCTAssertNil(try planning.scheduled().first?.nextDate)
    store.undo()
    XCTAssertEqual(try planning.scheduled().first?.nextDate, S.day("2026-10-20"))
  }

  func testPayingADifferentAmountCanBecomeTheNewPrice() throws {
    var payment = bill()
    payment.kind = .subscription
    XCTAssertTrue(actions.save(payment, previous: nil))
    XCTAssertTrue(
      actions.markAsPaid(
        payment, due: S.day("2026-10-20"), amount: S.rub(32_000), on: S.calendar.noon(of: today),
        paymentMethodId: nil, updatePrice: true))
    let prices = try planning.book().prices
    XCTAssertEqual(prices.map(\.amountE4), [S.rub(32_000)])
    XCTAssertEqual(prices.first?.date, S.day("2026-10-20"))
    store.undo()
    XCTAssertTrue(try planning.book().prices.isEmpty)
  }

  func testSkippingRentOnThe31stGoesToTheLastDayOfNovember() throws {
    let payment = bill("2026-10-31", day: 31)
    XCTAssertTrue(actions.save(payment, previous: nil))
    XCTAssertTrue(actions.skip(payment, due: S.day("2026-10-31")))
    XCTAssertEqual(try planning.scheduled().first?.nextDate, S.day("2026-11-30"))
    XCTAssertTrue(try operations().isEmpty)
    store.undo()
    XCTAssertEqual(try planning.scheduled().first?.nextDate, S.day("2026-10-31"))
  }

  func testSkippingTheLastDateOfABillEndsIt() throws {
    let payment = bill("2026-12-20", end: "2026-12-31")
    XCTAssertTrue(actions.save(payment, previous: nil))
    XCTAssertTrue(actions.skip(payment, due: S.day("2026-12-20")))
    XCTAssertNil(try planning.scheduled().first?.nextDate)
  }

  func testSkippingADateAlreadyPassedChangesNothing() throws {
    let payment = bill("2026-11-20")
    XCTAssertTrue(actions.save(payment, previous: nil))
    XCTAssertTrue(actions.skip(payment, due: S.day("2026-10-20")))
    XCTAssertEqual(try planning.scheduled().first?.nextDate, S.day("2026-11-20"))
  }

  func testTakenBeforeACountClosesTheDateWithoutAnOperation() throws {
    let payment = bill("2026-10-05")
    XCTAssertTrue(actions.save(payment, previous: nil))
    XCTAssertTrue(actions.settle(payment: payment, due: S.day("2026-10-05")))
    XCTAssertEqual(try planning.scheduled().first?.nextDate, S.day("2026-11-05"))
    XCTAssertTrue(try operations().isEmpty)
    store.undo()
    XCTAssertEqual(try planning.scheduled().first?.nextDate, S.day("2026-10-05"))
  }

  func testANewAmountKeepsThePastAtTheOldPrice() throws {
    let payment = bill()
    XCTAssertTrue(actions.save(payment, previous: nil))
    var dearer = payment
    dearer.amountE4 = S.rub(33_000)
    XCTAssertTrue(actions.save(dearer, previous: payment))
    let prices = try planning.book().prices.sorted { $0.date < $1.date }
    // The old price is anchored yesterday, the new one starts today.
    XCTAssertEqual(prices.map(\.amountE4), [S.rub(30_000), S.rub(33_000)])
    XCTAssertEqual(prices.map(\.date), [S.day("2026-10-13"), today])
    XCTAssertEqual(try planning.scheduled().first?.amountE4, S.rub(33_000))
    store.undo()
    XCTAssertEqual(try planning.scheduled().first?.amountE4, S.rub(30_000))
    XCTAssertTrue(try planning.book().prices.isEmpty)
  }

  func testADeletedBillComesBackWithUndo() throws {
    let payment = bill()
    XCTAssertTrue(actions.save(payment, previous: nil))
    XCTAssertTrue(actions.delete(payment))
    XCTAssertTrue(try planning.scheduled().isEmpty)
    store.undo()
    XCTAssertEqual(try planning.scheduled().map(\.id), [payment.id])
  }

  // MARK: Expected income

  private func expected(_ name: String, _ due: String, whole: Int64 = 50_000) -> ExpectedIncome {
    ExpectedIncome(
      name: name, kind: .recurring, totalE4: S.rub(whole), dueDate: S.day(due), freq: .monthly,
      day: S.day(due).day)
  }

  func testTwoTermsOfOneFormAreOneStepOfUndo() throws {
    XCTAssertTrue(
      actions.save([expected(" Аванс ", "2026-10-15"), expected("Зарплата", "2026-10-31")]))
    XCTAssertEqual(Set(try planning.expected().map(\.name)), ["Аванс", "Зарплата"])
    store.undo()
    XCTAssertTrue(try planning.expected().isEmpty)
  }

  func testClosingAndBringingBackAnExpectation() throws {
    let bonus = ExpectedIncome(
      name: "Премия", totalE4: S.rub(20_000), dueDate: S.day("2026-10-20"))
    XCTAssertTrue(actions.save(bonus))
    XCTAssertTrue(actions.close(bonus))
    XCTAssertEqual(try planning.expected().first?.closed, true)
    store.undo()
    XCTAssertEqual(try planning.expected().first?.closed, false)
    XCTAssertTrue(actions.close(bonus))
    var closed = bonus
    closed.closed = true
    XCTAssertTrue(actions.reopen(closed))
    XCTAssertEqual(try planning.expected().first?.closed, false)
  }

  func testAnOpenExpectationCannotBeBroughtBack() throws {
    let bonus = ExpectedIncome(name: "Премия", totalE4: S.rub(20_000))
    XCTAssertTrue(actions.save(bonus))
    XCTAssertFalse(actions.reopen(bonus))
  }

  func testADeletedExpectationComesBackWithUndo() throws {
    let salary = expected("Зарплата", "2026-10-31")
    XCTAssertTrue(actions.save(salary))
    XCTAssertTrue(actions.delete(salary))
    XCTAssertTrue(try planning.expected().isEmpty)
    store.undo()
    XCTAssertEqual(try planning.expected().map(\.id), [salary.id])
  }

  // MARK: Limits

  func testALimitIsSavedThisMonthAndDeletedAndBroughtBack() throws {
    show()
    let budget = Budget(scope: .category, categoryId: food.id, amountE4: S.rub(15_000))
    XCTAssertTrue(actions.save(budget))
    let stored = try XCTUnwrap(try planning.budgets().first)
    XCTAssertEqual(stored.startMonth, MonthKey(iso: "2026-10"))
    XCTAssertTrue(actions.delete(stored))
    XCTAssertTrue(try planning.budgets().isEmpty)
    store.undo()
    XCTAssertEqual(try planning.budgets().map(\.id), [budget.id])
  }

  func testALimitOnGoalsIsRefusedAndNothingIsWritten() throws {
    show()
    let budget = Budget(scope: .category, categoryId: goalsRoot.id, amountE4: S.rub(1_000))
    XCTAssertEqual(actions.issue(of: budget), .systemCategory)
    XCTAssertFalse(actions.save(budget))
    XCTAssertTrue(try planning.budgets().isEmpty)
    XCTAssertFalse(store.canUndo)
  }

  func testASecondLimitOnTheSameCategoryIsADuplicate() throws {
    let first = Budget(scope: .category, categoryId: food.id, amountE4: S.rub(1_000))
    show(budgets: [first])
    XCTAssertEqual(
      actions.issue(of: Budget(scope: .category, categoryId: food.id, amountE4: S.rub(2_000))),
      .duplicate)
  }

  func testSuggestedLimitsAreAddedInOneStepOfUndo() throws {
    let spent = ["2026-08-10", "2026-09-10"].flatMap { day in
      [
        S.entry(.expense, S.rub(9_000), on: day, category: food.id),
        S.entry(.expense, S.rub(4_000), on: day, category: home.id),
      ]
    }
    show(entries: spent)
    let suggestions = actions.suggestedLimits()
    XCTAssertEqual(suggestions.map(\.categoryId), [food.id, home.id])
    XCTAssertEqual(
      actions.addSuggestedLimits(suggestions.map { ($0.categoryId, $0.usual) }), 2)
    XCTAssertEqual(
      Set(try planning.budgets().map(\.amountE4)), [S.rub(9_000), S.rub(4_000)])
    store.undo()
    XCTAssertTrue(try planning.budgets().isEmpty)
  }

  // MARK: Goals and events

  func testArchivingAGoalIsOneStepOfUndo() throws {
    show()
    let trip = Goal(name: "Отпуск", targetE4: S.rub(100_000))
    XCTAssertTrue(actions.save(trip))
    XCTAssertTrue(actions.archive(trip))
    XCTAssertEqual(try references.goals(includeArchived: true).first?.archived, true)
    store.undo()
    XCTAssertEqual(try references.goals(includeArchived: true).first?.archived, false)
  }

  func testAnEventWithoutANameOrClashingWithALiveOneIsRefused() {
    let trip = Event(name: "Поездка", startDate: today, endDate: S.day("2026-10-20"))
    XCTAssertEqual(
      PlanningActions.issue(
        of: Event(name: "", startDate: today, endDate: today), among: []), .emptyName)
    XCTAssertEqual(
      PlanningActions.issue(
        of: Event(name: "поездка", startDate: S.day("2026-10-20"), endDate: S.day("2026-10-22")),
        among: [trip]),
      .sameNameAndDays)
    XCTAssertNil(
      PlanningActions.issue(
        of: Event(name: "Поездка", startDate: S.day("2026-10-21"), endDate: S.day("2026-10-22")),
        among: [trip]))
    var archived = trip
    archived.archived = true
    XCTAssertNil(
      PlanningActions.issue(
        of: Event(name: "Поездка", startDate: today, endDate: today), among: [archived]))
  }

  func testTheMomentOfPayingAnOverdueDateIsNoonOfItsDay() {
    let now = Date()
    XCTAssertEqual(
      PlanningActions.paidAt(due: S.day("2026-10-05"), today: today, calendar: .utc, now: now),
      S.calendar.noon(of: S.day("2026-10-05")))
    XCTAssertEqual(PlanningActions.paidAt(due: today, today: today, calendar: .utc, now: now), now)
    XCTAssertEqual(
      PlanningActions.paidAt(due: S.day("2026-10-20"), today: today, calendar: .utc, now: now),
      now)
  }
}
