import AppCore
import XCTest

@testable import OhMyMoney

/// Saving for a holiday and spending on trips: contributions and withdrawals, a goal reached
/// to the kopeck, 99.99 % that must not read as done, a date passed, a plan against the date,
/// the pace of the last months, names that clash in case or «ё», deleting a goal from the
/// archive; and events — a one-day event, a trip over budget, the next one of a series, what to
/// put aside each month, which list an event is in, and next year's dates of a leap-day event.
final class PlanningScenarioTestsGoalsEvents: XCTestCase {
  private typealias S = PlanningScenario

  private let goalsRoot = CoreKit.Category(kind: .expense, name: "Цели", systemRole: .goals)
  private lazy var tripCategory = CoreKit.Category(
    parentId: goalsRoot.id, kind: .expense, name: "Отпуск")
  private let food = CoreKit.Category(kind: .expense, name: "Продукты")

  private func goal(
    _ target: Int64 = 100_000, date: String? = nil, plan: Int64? = nil, archived: Bool = false,
    name: String = "Отпуск"
  ) -> Goal {
    Goal(
      name: name, targetE4: S.rub(target), targetDate: date.map(S.day),
      monthlyPlanE4: plan.map(S.rub), subcategoryId: tripCategory.id, archived: archived)
  }

  private func put(_ whole: Int64, _ day: String, into goal: Goal) -> TransactionEntry {
    S.entry(.expense, S.rub(whole), on: day, category: tripCategory.id, goal: goal.id)
  }

  private func takeBack(_ whole: Int64, _ day: String, from goal: Goal) -> TransactionEntry {
    S.entry(.refund, S.rub(whole), on: day, category: tripCategory.id, goal: goal.id)
  }

  private func status(
    _ goal: Goal, _ entries: [TransactionEntry], today: String
  )
    -> GoalStatus?
  {
    GoalRules.statuses(
      goals: [goal], ledger: S.ledger(entries, categories: [goalsRoot, tripCategory, food]),
      today: S.day(today)
    ).first
  }

  // MARK: Progress

  func testContributionsLessWithdrawalsAreSaved() throws {
    let trip = goal()
    let result = try XCTUnwrap(
      status(
        trip, [put(30_000, "2026-08-01", into: trip), takeBack(5_000, "2026-10-02", from: trip)],
        today: "2026-10-14"))
    XCTAssertEqual(result.saved, S.rub(25_000))
    XCTAssertEqual(result.remaining, S.rub(75_000))
    XCTAssertEqual(result.contributedThisMonth, S.rub(-5_000))
    XCTAssertEqual(result.progressBp, 2_500)
  }

  func testAGoalReachedToTheKopeckIsReached() throws {
    let trip = goal()
    let result = try XCTUnwrap(
      status(trip, [put(100_000, "2026-10-01", into: trip)], today: "2026-10-14"))
    XCTAssertEqual(result.realism, .reached)
    XCTAssertEqual(result.remaining, .zero)
    XCTAssertEqual(result.progressBp, 10_000)
    XCTAssertNil(result.projectedCompletion)
  }

  func testOneKopeckShortIsNotAHundredPercent() throws {
    let trip = goal()
    let short = S.entry(
      .expense, S.kop(9_999_999), on: "2026-10-01", category: tripCategory.id, goal: trip.id)
    let result = try XCTUnwrap(status(trip, [short], today: "2026-10-14"))
    XCTAssertEqual(result.progressBp, 9_999)
    XCTAssertNotEqual(result.realism, .reached)
  }

  func testMoreThanTheTargetStillReadsAsAHundredPercent() throws {
    let trip = goal()
    let result = try XCTUnwrap(
      status(trip, [put(150_000, "2026-10-01", into: trip)], today: "2026-10-14"))
    XCTAssertEqual(result.progressBp, 10_000)
    XCTAssertEqual(result.remaining, .zero)
  }

  func testAContributionToAnotherGoalIsNotThisOnes() throws {
    let trip = goal()
    let car = Goal(name: "Машина", targetE4: S.rub(1_000_000))
    let other = S.entry(.expense, S.rub(30_000), on: "2026-10-01", category: food.id, goal: car.id)
    XCTAssertEqual(try XCTUnwrap(status(trip, [other], today: "2026-10-14")).saved, .zero)
  }

  func testArchivedGoalsHaveNoStatus() {
    XCTAssertNil(status(goal(archived: true), [], today: "2026-10-14"))
  }

  // MARK: Date and pace

  func testWithoutADateThereIsNothingToBeLateFor() throws {
    XCTAssertEqual(try XCTUnwrap(status(goal(), [], today: "2026-10-14")).realism, .noDate)
  }

  func testAPassedDateIsOverdueAndNeedsEverythingNow() throws {
    let result = try XCTUnwrap(status(goal(date: "2026-09-30"), [], today: "2026-10-14"))
    XCTAssertEqual(result.realism, .overdue)
    XCTAssertEqual(result.monthsLeft, 0)
    XCTAssertEqual(result.neededMonthly, S.rub(100_000))
  }

  func testTheNeededMonthlyIsRoundedUpToWholeRubles() throws {
    let result = try XCTUnwrap(status(goal(date: "2026-12-31"), [], today: "2026-10-14"))
    XCTAssertEqual(result.monthsLeft, 3)
    XCTAssertEqual(result.neededMonthly, S.rub(33_334))
    XCTAssertEqual(result.realism, .notEnoughData)
  }

  func testADateThisMonthNeedsTheRestThisMonth() throws {
    let result = try XCTUnwrap(status(goal(date: "2026-10-31"), [], today: "2026-10-14"))
    XCTAssertEqual(result.monthsLeft, 1)
    XCTAssertEqual(result.neededMonthly, S.rub(100_000))
  }

  func testADateAcrossNewYearCountsTheMonthsOfBothYears() throws {
    let result = try XCTUnwrap(status(goal(date: "2027-02-01"), [], today: "2026-11-30"))
    XCTAssertEqual(result.monthsLeft, 4)
  }

  func testAPlanThatMeetsTheDateIsOnTrack() throws {
    let result = try XCTUnwrap(
      status(goal(date: "2026-12-31", plan: 34_000), [], today: "2026-10-14"))
    XCTAssertEqual(result.paceSource, .plan)
    XCTAssertEqual(result.realism, .onTrack)
    XCTAssertEqual(result.amountByTargetDate, S.rub(102_000))
  }

  func testAPlanTooSmallForTheDateIsBehind() throws {
    let result = try XCTUnwrap(
      status(goal(date: "2026-12-31", plan: 30_000), [], today: "2026-10-14"))
    XCTAssertEqual(result.realism, .behindPlan)
  }

  func testWithoutAPlanThePaceIsThatOfTheLastMonths() throws {
    let trip = goal(date: "2027-12-31")
    let entries = ["2026-07-10", "2026-08-10", "2026-09-10"].map { put(3_000, $0, into: trip) }
    let result = try XCTUnwrap(status(trip, entries, today: "2026-10-14"))
    XCTAssertEqual(result.paceSource, .history)
    XCTAssertEqual(result.pace, S.rub(3_000))
  }

  func testTheMonthTheGoalIsDoneAtItsPlan() throws {
    let trip = goal(plan: 3_000)
    let result = try XCTUnwrap(
      status(trip, [put(91_000, "2026-09-10", into: trip)], today: "2026-10-14"))
    // 9,000 left: 3,000 this month, then two more months.
    XCTAssertEqual(result.projectedCompletion, MonthKey(iso: "2026-12"))
  }

  // MARK: The plan this month

  private func planLeft(
    _ goal: Goal, _ entries: [TransactionEntry], today: String
  )
    -> AmountE4?
  {
    GoalRules.planStillDue(
      goals: [goal], ledger: S.ledger(entries, categories: [goalsRoot, tripCategory]),
      today: S.day(today)
    )[goal.id]
  }

  func testThePlanAsksWhatThisMonthHasNotPutIn() {
    var trip = goal(plan: 5_000)
    trip.planStartMonth = MonthKey(iso: "2026-01")
    XCTAssertEqual(
      planLeft(trip, [put(2_000, "2026-10-03", into: trip)], today: "2026-10-14"), S.rub(3_000))
  }

  func testThePlanNeverAsksMoreThanTheGoalNeeds() {
    var trip = goal(plan: 5_000)
    // The plan starts this month: what went in before it is not paid ahead of it.
    trip.planStartMonth = MonthKey(iso: "2026-10")
    XCTAssertEqual(
      planLeft(trip, [put(99_000, "2026-09-03", into: trip)], today: "2026-10-14"), S.rub(1_000))
  }

  func testMoneyPutInAboveThePlanSinceItsStartCoversThisMonth() {
    var trip = goal(plan: 5_000)
    trip.planStartMonth = MonthKey(iso: "2026-08")
    // August and September asked 10,000; 15,000 went in, so October is paid ahead.
    XCTAssertNil(planLeft(trip, [put(15_000, "2026-08-03", into: trip)], today: "2026-10-14"))
    XCTAssertEqual(
      planLeft(trip, [put(12_000, "2026-08-03", into: trip)], today: "2026-10-14"), S.rub(3_000))
  }

  func testAReachedGoalAsksNothing() {
    var trip = goal(plan: 5_000)
    trip.planStartMonth = MonthKey(iso: "2026-01")
    XCTAssertNil(planLeft(trip, [put(100_000, "2026-09-03", into: trip)], today: "2026-10-14"))
  }

  func testThePlanStartsTheMonthItAppears() {
    let today = S.day("2026-10-14")
    let planned = GoalRules.withPlanStart(goal(plan: 5_000), previous: goal(), today: today)
    XCTAssertEqual(planned.planStartMonth, MonthKey(iso: "2026-10"))
    var stored = goal(plan: 5_000)
    stored.planStartMonth = MonthKey(iso: "2026-03")
    var edited = stored
    edited.monthlyPlanE4 = S.rub(7_000)
    XCTAssertEqual(
      GoalRules.withPlanStart(edited, previous: stored, today: today).planStartMonth,
      MonthKey(iso: "2026-03"))
    var zero = stored
    zero.monthlyPlanE4 = .zero
    XCTAssertNil(GoalRules.withPlanStart(zero, previous: stored, today: today).planStartMonth)
  }

  // MARK: Names

  func testALiveNameIsTakenWhateverItsCaseAndYo() {
    let tree = goal(name: "Ёлка")
    XCTAssertEqual(GoalRules.liveNamesake(of: "  елка ", among: [tree])?.id, tree.id)
    XCTAssertNil(GoalRules.liveNamesake(of: "Ёлка", excluding: tree.id, among: [tree]))
    XCTAssertNil(GoalRules.liveNamesake(of: "Ёлка", among: [goal(archived: true, name: "Ёлка")]))
    XCTAssertNil(GoalRules.liveNamesake(of: "   ", among: [tree]))
  }

  func testAnArchivedNamesakeOnlyWhenNoLiveGoalHasTheName() {
    let old = goal(archived: true, name: "Машина")
    XCTAssertEqual(GoalRules.archivedNamesake(of: "машина", among: [old])?.id, old.id)
    XCTAssertNil(
      GoalRules.archivedNamesake(of: "машина", among: [old, goal(name: "МАШИНА")]))
  }

  // MARK: Deleting

  private var tree: CategoryTree { CategoryTree([goalsRoot, tripCategory, food]) }

  func testOnlyAnArchivedGoalIsDeleted() {
    XCTAssertEqual(
      try? GoalRules.deletion(of: goal(), parts: [], tree: tree).get(), nil)
    if case .failure(let refusal) = GoalRules.deletion(of: goal(), parts: [], tree: tree) {
      XCTAssertEqual(refusal, .notArchived)
    } else {
      XCTFail("a live goal is not deleted")
    }
  }

  func testDeletingArchivesItsSubcategoryAndLetsGoOfTheParts() throws {
    let old = goal(archived: true)
    let deletion = try GoalRules.deletion(
      of: old, parts: [(UUID(), tripCategory.id), (UUID(), tripCategory.id)], tree: tree
    ).get()
    XCTAssertEqual(deletion.unlinkedParts, 2)
    XCTAssertEqual(deletion.archivedSubcategory?.id, tripCategory.id)
    XCTAssertEqual(deletion.archivedSubcategory?.archived, true)
  }

  func testASubcategoryALiveGoalUsesStaysLive() throws {
    let old = goal(archived: true)
    let deletion = try GoalRules.deletion(
      of: old, parts: [], tree: tree, goals: [old, goal(name: "Новая")]
    ).get()
    XCTAssertNil(deletion.archivedSubcategory)
  }

  func testContributionsOutsideGoalsStopTheDeletion() {
    let result = GoalRules.deletion(
      of: goal(archived: true), parts: [(UUID(), food.id), (UUID(), tripCategory.id)], tree: tree)
    if case .failure(let refusal) = result {
      XCTAssertEqual(refusal, .contributionsOutsideGoals(1))
    } else {
      XCTFail("the deletion is refused")
    }
  }

  // MARK: Contribute and withdraw

  func testAContributionIsAGoodExpenseOfTheAmountWithoutItsSign() {
    let trip = goal()
    let draft = GoalRules.contributionDraft(
      goal: trip, subcategoryId: nil, amount: S.rub(-2_000), occurredAt: Date())
    XCTAssertEqual(draft.kind, .expense)
    XCTAssertEqual(draft.amount, S.rub(2_000))
    XCTAssertEqual(draft.parts.first?.quality, .good)
    XCTAssertEqual(draft.parts.first?.goalId, trip.id)
    XCTAssertEqual(draft.parts.first?.categoryId, tripCategory.id)
    let back = GoalRules.withdrawalDraft(
      goal: trip, subcategoryId: nil, amount: S.rub(500), occurredAt: Date(), currency: .usd)
    XCTAssertEqual(back.kind, .refund)
    XCTAssertEqual(back.currency, .usd)
  }

  // MARK: Events

  private func event(
    _ start: String, _ end: String, budget: Int64? = nil, series: UUID? = nil,
    archived: Bool = false
  ) -> Event {
    Event(
      name: "Поездка", startDate: S.day(start), endDate: S.day(end), budgetE4: budget.map(S.rub),
      seriesId: series, archived: archived)
  }

  private func plans(
    _ events: [Event], _ entries: [TransactionEntry], today: String
  )
    -> [EventPlan]
  {
    EventPlanning.plans(
      ledger: S.ledger(entries, categories: [food], events: events), today: S.day(today))
  }

  private func spend(_ whole: Int64, _ day: String, on event: Event) -> TransactionEntry {
    S.entry(.expense, S.rub(whole), on: day, category: food.id, event: event.id)
  }

  func testAOneDayEventIsUnderWayOnItsDay() throws {
    let party = event("2026-10-14", "2026-10-14", budget: 5_000)
    let plan = try XCTUnwrap(plans([party], [], today: "2026-10-14").first)
    XCTAssertTrue(plan.isActive)
    XCTAssertEqual(plan.daysUntilStart, 0)
    XCTAssertNil(plan.monthlySaving)
    XCTAssertFalse(try XCTUnwrap(plans([party], [], today: "2026-10-15").first).isActive)
  }

  func testATripOverItsBudgetSaysSo() throws {
    let trip = event("2026-10-10", "2026-10-20", budget: 10_000)
    let plan = try XCTUnwrap(
      plans(
        [trip], [spend(7_000, "2026-09-01", on: trip), spend(4_000, "2026-10-11", on: trip)],
        today: "2026-10-14"
      ).first)
    XCTAssertEqual(plan.spent, S.rub(11_000))
    XCTAssertEqual(plan.remaining, S.rub(-1_000))
    XCTAssertTrue(plan.overBudget)
  }

  func testTicketsBoughtEarlyDoNotMakeTheFirstDayRunAway() throws {
    let trip = event("2026-10-14", "2026-10-23", budget: 10_000)
    let plan = try XCTUnwrap(
      plans(
        [trip], [spend(6_000, "2026-09-01", on: trip), spend(300, "2026-10-14", on: trip)],
        today: "2026-10-14"
      ).first)
    // 6,000 committed + 300 × 10 days = 9,000: within the budget.
    XCTAssertFalse(plan.pacing)
    let fast = try XCTUnwrap(
      plans(
        [trip], [spend(6_000, "2026-09-01", on: trip), spend(500, "2026-10-14", on: trip)],
        today: "2026-10-14"
      ).first)
    XCTAssertTrue(fast.pacing)
  }

  func testWhatToPutAsideEachMonthUntilItStarts() throws {
    let trip = event("2027-01-05", "2027-01-15", budget: 30_000)
    let plan = try XCTUnwrap(plans([trip], [], today: "2026-10-14").first)
    XCTAssertEqual(plan.monthsUntilStart, 3)
    XCTAssertEqual(plan.monthlySaving, S.rub(10_000))
  }

  func testAnEventThisMonthPutsAsideAllOfItAtOnce() throws {
    let trip = event("2026-10-25", "2026-10-26", budget: 30_000)
    let plan = try XCTUnwrap(plans([trip], [], today: "2026-10-14").first)
    XCTAssertEqual(plan.monthsUntilStart, 0)
    XCTAssertEqual(plan.monthlySaving, S.rub(30_000))
  }

  func testTheNextEventOfASeriesAimsAtWhatTheLastOneCost() throws {
    let series = UUID()
    let last = event("2025-12-30", "2026-01-02", series: series)
    let next = event("2026-12-30", "2027-01-02", series: series)
    let all = plans([last, next], [spend(25_000, "2025-12-31", on: last)], today: "2026-10-14")
    let plan = try XCTUnwrap(all.first { $0.event.id == next.id })
    XCTAssertEqual(plan.lastTimeEventId, last.id)
    XCTAssertEqual(plan.lastTimeTotal, S.rub(25_000))
    XCTAssertEqual(plan.target, S.rub(25_000))
    XCTAssertNil(plan.budget)
  }

  func testWhichListAnEventIsIn() {
    let today = S.day("2026-10-14")
    let soon = event("2027-02-11", "2027-02-12")  // in 120 days
    let late = event("2027-02-12", "2027-02-13")  // in 121 days
    let ended = event("2026-09-10", "2026-09-14", budget: 1_000)  // 30 days ago
    let long = event("2026-08-01", "2026-09-13", budget: 1_000)  // 31 days ago
    let hidden = event("2026-10-14", "2026-10-15", archived: true)
    let built = EventPlanning.build(
      ledger: S.ledger([], events: [soon, late, ended, long, hidden]), today: today)
    XCTAssertEqual(built.upcoming.map(\.event.id), [soon.id])
    XCTAssertEqual(built.withBudget.map(\.event.id), [ended.id])
    XCTAssertTrue(built.active.isEmpty)
  }

  func testOnlyEventsNotOverYetAreBudgetedAhead() {
    let today = "2026-10-14"
    let ended = event("2026-10-01", "2026-10-13", budget: 1_000)
    let ending = event("2026-10-01", "2026-10-14", budget: 1_000)
    let far = event("2027-10-01", "2027-10-14", budget: 1_000)
    let free = event("2026-11-01", "2026-11-02")
    let ahead = EventPlanning.budgetedAhead(
      plans([far, ended, ending, free], [], today: today), today: S.day(today))
    XCTAssertEqual(ahead.map(\.event.id), [ending.id, far.id])
  }

  func testNextYearOfALeapDayEventKeepsItsLength() {
    let next = EventPlanning.nextYear(of: DayRange(S.day("2028-02-29"), S.day("2028-03-09")))
    XCTAssertEqual(next.start, S.day("2029-02-28"))
    XCTAssertEqual(next.dayCount, 10)
  }
}
