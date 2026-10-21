import AppCore
import XCTest

@testable import OhMyMoney

/// A month under limits: groceries spent through the month with a refund, a limit on a parent
/// covering its café, rollover over three months and an overspent one, the edge of 90 %, bad
/// spending and «for whom» limits, what the field of a category writes when typed into, which
/// limits a list shows first, and «Предложить лимиты…» on the three full months before today —
/// including over New Year and with a month that gave back more than it spent.
final class PlanningScenarioTestsLimits: XCTestCase {
  private typealias S = PlanningScenario

  private let food = CoreKit.Category(kind: .expense, name: "Продукты")
  private lazy var cafe = CoreKit.Category(parentId: food.id, kind: .expense, name: "Кафе")
  private let fun = CoreKit.Category(kind: .expense, name: "Развлечения")
  private let goals = CoreKit.Category(kind: .expense, name: "Цели", systemRole: .goals)
  private let count = CoreKit.Category(kind: .expense, name: "Сверка")
  private let salary = CoreKit.Category(kind: .income, name: "Зарплата")
  private let old = CoreKit.Category(kind: .expense, name: "Старое", archived: true)

  private var categories: [CoreKit.Category] { [food, cafe, fun, goals, count, salary, old] }
  private var tree: CategoryTree { CategoryTree(categories) }

  private func spend(
    _ whole: Int64, _ day: String, _ category: CoreKit.Category? = nil, quality: Quality? = nil,
    forWhom: ForWhom = .me
  ) -> TransactionEntry {
    S.entry(
      .expense, S.rub(whole), on: day, category: (category ?? food).id, quality: quality,
      forWhom: forWhom)
  }

  private func limit(
    _ whole: Int64, on category: CoreKit.Category? = nil, rollover: Bool = false,
    start: String? = nil
  ) -> Budget {
    Budget(
      scope: .category, categoryId: (category ?? food).id, amountE4: S.rub(whole),
      rollover: rollover, startMonth: start.flatMap { MonthKey(iso: $0) })
  }

  private func line(_ budget: Budget, _ entries: [TransactionEntry], today: String) -> LimitLine {
    LimitRules.line(
      budget: budget, ledger: S.ledger(entries, categories: categories), today: S.day(today))
  }

  // MARK: Spent

  func testALimitOnAParentCountsItsSubcategory() {
    let result = line(
      limit(10_000), [spend(2_000, "2026-10-02"), spend(1_000, "2026-10-03", cafe)],
      today: "2026-10-14")
    XCTAssertEqual(result.spent, S.rub(3_000))
    XCTAssertEqual(result.remaining, S.rub(7_000))
  }

  func testALimitOnASubcategoryCountsOnlyIt() {
    let result = line(
      limit(5_000, on: cafe), [spend(2_000, "2026-10-02"), spend(1_000, "2026-10-03", cafe)],
      today: "2026-10-14")
    XCTAssertEqual(result.spent, S.rub(1_000))
  }

  func testARefundTakesOffWhatWasSpent() {
    let refund = S.entry(.refund, S.rub(500), on: "2026-10-05", category: food.id)
    let result = line(limit(10_000), [spend(2_000, "2026-10-02"), refund], today: "2026-10-14")
    XCTAssertEqual(result.spent, S.rub(1_500))
  }

  func testSpendingOfLastMonthAndOfNextIsNotThisMonths() {
    let result = line(
      limit(10_000),
      [spend(2_000, "2026-09-30"), spend(3_000, "2026-10-31"), spend(4_000, "2026-11-01")],
      today: "2026-10-14")
    XCTAssertEqual(result.spent, S.rub(3_000))
  }

  func testAPartForSomebodyElseIsNotMine() {
    let paid = S.entry(
      .expense, S.rub(3_000), on: "2026-10-02", category: food.id, reimbursable: true)
    XCTAssertEqual(line(limit(10_000), [paid], today: "2026-10-14").spent, .zero)
  }

  func testAGoalContributionNeverCounts() {
    let contribution = S.entry(
      .expense, S.rub(3_000), on: "2026-10-02", category: food.id, goal: UUID())
    XCTAssertEqual(line(limit(10_000), [contribution], today: "2026-10-14").spent, .zero)
  }

  // MARK: Status and pace

  func testOverspentIsOver() {
    XCTAssertEqual(
      line(limit(1_000), [spend(1_001, "2026-10-02")], today: "2026-10-14").status,
      .over)
  }

  func testExactlyTheLimitIsNotOver() {
    let result = line(limit(1_000), [spend(1_000, "2026-10-31")], today: "2026-10-31")
    XCTAssertNotEqual(result.status, .over)
    XCTAssertEqual(result.remaining, .zero)
  }

  func testNinetyPercentSpentIsOnTheEdge() {
    // On the last day nothing more is forecast; 9,000 of 10,000 is the edge, 8,999 is not.
    XCTAssertEqual(
      line(limit(10_000), [spend(9_000, "2026-10-31")], today: "2026-10-31").status, .warning)
    XCTAssertEqual(
      line(limit(10_000), [spend(8_999, "2026-10-31")], today: "2026-10-31").status, .ok)
  }

  func testHalfTheLimitOnTheFifteenthOfAThirtyDayMonthIsOnPace() {
    let result = line(limit(10_000), [spend(5_000, "2026-11-01")], today: "2026-11-15")
    XCTAssertEqual(result.paceBp, 10_000)
    XCTAssertEqual(result.elapsedShareBp, 5_000)
    XCTAssertEqual(result.spentShareBp, 5_000)
  }

  func testWithLittleHistoryTheMonthsOwnRateIsUsed() {
    // 3,000 in ten days: 300 a day, 21 days left of October.
    let result = line(limit(20_000), [spend(3_000, "2026-10-01")], today: "2026-10-10")
    XCTAssertTrue(result.lowData)
    XCTAssertEqual(result.forecast, S.rub(3_000 + 300 * 21))
  }

  func testAForecastAboveTheLimitWarnsBeforeItIsReached() {
    let result = line(limit(5_000), [spend(3_000, "2026-10-01")], today: "2026-10-10")
    XCTAssertEqual(result.status, .warning)
  }

  func testWhatIsDueUnderTheLimitIsPlanned() {
    let result = LimitRules.line(
      budget: limit(10_000), ledger: S.ledger([], categories: categories),
      today: S.day("2026-10-31"), planned: S.rub(2_000))
    XCTAssertEqual(result.planned, S.rub(2_000))
    XCTAssertEqual(result.forecast, S.rub(2_000))
  }

  func testAZeroLimitHasNoShareAndNoPace() {
    let budget = Budget(scope: .category, categoryId: food.id, amountE4: .zero)
    let result = line(budget, [], today: "2026-10-14")
    XCTAssertNil(result.spentShareBp)
    XCTAssertNil(result.paceBp)
  }

  // MARK: Bad spending and «for whom»

  func testABadSpendingLimitCountsEveryBadRow() {
    let budget = Budget(scope: .badTotal, amountE4: S.rub(3_000))
    let result = line(
      budget,
      [
        spend(1_000, "2026-10-02", quality: .bad), spend(500, "2026-10-03", fun, quality: .bad),
        spend(9_000, "2026-10-04", quality: .good),
      ],
      today: "2026-10-14")
    XCTAssertEqual(result.spent, S.rub(1_500))
  }

  func testAForWhomLimitCountsItsValueOnly() {
    let budget = Budget(scope: .forWhom, forWhom: .partner, amountE4: S.rub(3_000))
    let result = line(
      budget, [spend(1_000, "2026-10-02", forWhom: .partner), spend(500, "2026-10-03")],
      today: "2026-10-14")
    XCTAssertEqual(result.spent, S.rub(1_000))
  }

  // MARK: Rollover

  func testUnspentMoneyPilesUpOverMonths() {
    let budget = limit(10_000, rollover: true, start: "2026-07")
    let result = line(
      budget,
      [spend(6_000, "2026-07-10"), spend(9_000, "2026-08-10"), spend(10_000, "2026-09-10")],
      today: "2026-10-14")
    XCTAssertEqual(result.carry, S.rub(5_000))
    XCTAssertEqual(result.available, S.rub(15_000))
  }

  func testAnOverspentMonthHandsOnNothingAndCarriesNoDebt() {
    let budget = limit(10_000, rollover: true, start: "2026-08")
    let result = line(
      budget, [spend(4_000, "2026-08-10"), spend(20_000, "2026-09-10")], today: "2026-10-14")
    XCTAssertEqual(result.carry, .zero)
  }

  func testRolloverCrossesNewYear() {
    let budget = limit(10_000, rollover: true, start: "2026-12")
    let result = line(budget, [spend(4_000, "2026-12-10")], today: "2027-01-05")
    XCTAssertEqual(result.carry, S.rub(6_000))
  }

  func testWithoutAStartMonthOrRolloverNothingIsCarried() {
    XCTAssertEqual(line(limit(10_000, rollover: true), [], today: "2026-10-14").carry, .zero)
    XCTAssertEqual(line(limit(10_000, start: "2026-01"), [], today: "2026-10-14").carry, .zero)
  }

  func testEditingTheAmountStartsTheRolloverAgain() {
    let month = MonthKey(iso: "2026-10")!
    let stored = limit(10_000, rollover: true, start: "2026-01")
    var edited = stored
    edited.amountE4 = S.rub(12_000)
    XCTAssertEqual(LimitRules.saving(edited, over: stored, in: month).startMonth, month)
    var renamed = stored
    renamed.rollover = true
    XCTAssertEqual(
      LimitRules.saving(renamed, over: stored, in: month).startMonth, MonthKey(iso: "2026-01"))
  }

  func testTurningRolloverOnStartsItThisMonth() {
    let month = MonthKey(iso: "2026-10")!
    let stored = limit(10_000, start: "2026-01")
    var on = stored
    on.rollover = true
    XCTAssertEqual(LimitRules.saving(on, over: stored, in: month).startMonth, month)
  }

  // MARK: Saving

  func testWhatALimitCannotBeSavedOn() {
    func issue(_ budget: Budget, existing: [Budget] = []) -> BudgetIssue? {
      LimitRules.validate(budget, tree: tree, existing: existing, limitless: [count.id])
    }
    XCTAssertEqual(issue(limit(1, on: goals)), .systemCategory)
    XCTAssertEqual(issue(limit(1, on: salary)), .incomeCategory)
    XCTAssertEqual(issue(limit(1, on: count)), .reconciliationCategory)
    XCTAssertEqual(issue(limit(0)), .nonPositive)
    XCTAssertEqual(issue(limit(1, on: CoreKit.Category(kind: .expense, name: "?"))), .missingTarget)
    XCTAssertEqual(issue(limit(1), existing: [limit(5)]), .duplicate)
    XCTAssertEqual(issue(Budget(scope: .forWhom, amountE4: S.rub(1))), .missingTarget)
    XCTAssertEqual(
      issue(
        Budget(scope: .badTotal, amountE4: S.rub(1)),
        existing: [Budget(scope: .badTotal, amountE4: S.rub(2))]),
      .duplicate)
    XCTAssertNil(issue(limit(1, on: cafe), existing: [limit(5)]))
  }

  func testAnEditNeverDuplicatesItself() {
    let budget = limit(5_000)
    var edit = budget
    edit.amountE4 = S.rub(6_000)
    XCTAssertNil(LimitRules.validate(edit, tree: tree, existing: [budget]))
  }

  func testTypingIntoACategorysField() {
    let month = MonthKey(iso: "2026-10")!
    let stored = limit(5_000, start: "2026-01")
    XCTAssertEqual(
      LimitRules.settingCategoryLimit(food.id, to: nil, budgets: [], tree: tree, in: month),
      .unchanged)
    XCTAssertEqual(
      LimitRules.settingCategoryLimit(food.id, to: nil, budgets: [stored], tree: tree, in: month),
      .delete(stored))
    XCTAssertEqual(
      LimitRules.settingCategoryLimit(
        food.id, to: S.rub(5_000), budgets: [stored], tree: tree, in: month),
      .unchanged)
    XCTAssertEqual(
      LimitRules.settingCategoryLimit(
        food.id, to: .zero, budgets: [stored], tree: tree, in: month),
      .refused(.nonPositive))
    guard
      case .save(let saved) = LimitRules.settingCategoryLimit(
        food.id, to: S.rub(7_000), budgets: [stored], tree: tree, in: month)
    else { return XCTFail("a new amount is saved") }
    XCTAssertEqual(saved.id, stored.id)
    XCTAssertEqual(saved.startMonth, month)
  }

  func testANewLimitTypedStartsThisMonth() {
    let month = MonthKey(iso: "2026-10")!
    guard
      case .save(let saved) = LimitRules.settingCategoryLimit(
        fun.id, to: S.rub(3_000), budgets: [], tree: tree, in: month)
    else { return XCTFail("a new limit is saved") }
    XCTAssertEqual(saved.categoryId, fun.id)
    XCTAssertEqual(saved.startMonth, month)
  }

  func testChangingAGoneLimitWritesNothing() {
    XCTAssertEqual(
      LimitRules.changingAmount(
        of: UUID(), to: S.rub(1), budgets: [limit(5)], tree: tree,
        in: MonthKey(iso: "2026-10")!),
      .unchanged)
  }

  func testWhichRowsOfferALimitField() {
    XCTAssertTrue(LimitRules.offersLimit(on: food.id, tree: tree))
    XCTAssertTrue(LimitRules.offersLimit(on: cafe.id, tree: tree))
    XCTAssertFalse(LimitRules.offersLimit(on: goals.id, tree: tree))
    XCTAssertFalse(LimitRules.offersLimit(on: salary.id, tree: tree))
    XCTAssertFalse(LimitRules.offersLimit(on: old.id, tree: tree))
    XCTAssertFalse(LimitRules.offersLimit(on: count.id, tree: tree, limitless: [count.id]))
    XCTAssertFalse(LimitRules.offersLimit(on: fun.id, tree: tree, taxCategoryId: fun.id))
  }

  // MARK: Which come first

  func testOverComesFirstThenTheEdgeThenTheBiggerShare() {
    let ledger = S.ledger(
      [spend(11_000, "2026-10-31"), spend(950, "2026-10-31", fun), spend(500, "2026-10-31", cafe)],
      categories: categories)
    let budgets = [limit(1_000, on: fun), limit(10_000), limit(1_000, on: cafe)]
    let lines = budgets.map {
      LimitRules.line(budget: $0, ledger: ledger, today: S.day("2026-10-31"))
    }
    let ranked = LimitRules.ranked(lines, topN: nil, tree: tree)
    XCTAssertEqual(ranked.shown.map(\.budget.categoryId), [food.id, fun.id, cafe.id])
    XCTAssertEqual(ranked.total, 3)
    let top = LimitRules.ranked(lines, topN: 2, tree: tree)
    XCTAssertEqual(top.shown.count, 2)
    XCTAssertEqual(top.total, 3)
    XCTAssertTrue(LimitRules.ranked(lines, topN: -1, tree: tree).shown.isEmpty)
  }

  func testALimitOfAnArchivedCategoryIsHidden() {
    let lines = [line(limit(1_000, on: old), [], today: "2026-10-14")]
    XCTAssertEqual(LimitRules.ranked(lines, topN: nil, tree: tree).total, 0)
  }

  // MARK: Suggestions

  private func suggest(
    _ entries: [TransactionEntry], budgets: [Budget] = [], today: String
  )
    -> [LimitSuggestion]
  {
    LimitSuggestions.suggestions(
      ledger: S.ledger(entries, categories: categories), budgets: budgets, today: S.day(today),
      limitless: [count.id])
  }

  func testTheThreeMonthsBeforeJanuaryCrossTheYear() {
    XCTAssertEqual(
      LimitSuggestions.months(before: S.day("2027-01-15")).map(\.iso),
      ["2026-10", "2026-11", "2026-12"])
  }

  func testACategorySpentOnInTwoOfThreeMonthsIsSuggestedAtItsMedian() throws {
    let found = suggest(
      [spend(8_200, "2026-07-10"), spend(9_100, "2026-08-10", cafe)], today: "2026-10-14")
    let suggestion = try XCTUnwrap(found.first)
    XCTAssertEqual(suggestion.categoryId, food.id)
    XCTAssertEqual(suggestion.months, [S.rub(8_200), S.rub(9_100), .zero])
    XCTAssertEqual(suggestion.median, S.rub(8_200))
    XCTAssertEqual(suggestion.usual, S.rub(8_500))
    XCTAssertEqual(suggestion.amount(.tenPercentLess), S.rub(7_500))
  }

  func testOneBigPurchaseIsNoHabit() {
    XCTAssertTrue(suggest([spend(50_000, "2026-08-10")], today: "2026-10-14").isEmpty)
  }

  func testThisMonthIsNotLookedAt() {
    XCTAssertTrue(
      suggest([spend(5_000, "2026-10-01"), spend(5_000, "2026-09-01")], today: "2026-10-14")
        .isEmpty)
  }

  func testACategoryWithALimitIsNotSuggestedAgain() {
    XCTAssertTrue(
      suggest(
        [spend(5_000, "2026-08-01"), spend(5_000, "2026-09-01")], budgets: [limit(1)],
        today: "2026-10-14"
      ).isEmpty)
  }

  func testSystemCountAndArchivedCategoriesAreNeverSuggested() {
    let entries = [goals, count, old].flatMap { category in
      [spend(5_000, "2026-08-01", category), spend(5_000, "2026-09-01", category)]
    }
    XCTAssertTrue(suggest(entries, today: "2026-10-14").isEmpty)
  }

  func testAMonthThatGaveBackMoreThanItSpentIsZero() throws {
    let refund = S.entry(.refund, S.rub(3_000), on: "2026-07-20", category: fun.id)
    let found = suggest(
      [
        spend(1_000, "2026-07-10", fun), refund, spend(4_000, "2026-08-10", fun),
        spend(4_000, "2026-09-10", fun),
      ],
      today: "2026-10-14")
    XCTAssertEqual(try XCTUnwrap(found.first).months.first, .zero)
  }

  func testTheBiggestSuggestionComesFirst() {
    let found = suggest(
      [
        spend(2_000, "2026-08-10", fun), spend(2_000, "2026-09-10", fun),
        spend(20_000, "2026-08-10"), spend(20_000, "2026-09-10"),
      ],
      today: "2026-10-14")
    XCTAssertEqual(found.map(\.categoryId), [food.id, fun.id])
  }

  func testRoundingUpByFiveHundredAndByAThousand() {
    XCTAssertEqual(LimitSuggestions.roundedUp(S.kop(1)), S.rub(500))
    XCTAssertEqual(LimitSuggestions.roundedUp(S.rub(500)), S.rub(500))
    XCTAssertEqual(LimitSuggestions.roundedUp(S.kop(999_999)), S.rub(10_000))
    XCTAssertEqual(LimitSuggestions.roundedUp(S.rub(10_000)), S.rub(10_000))
    XCTAssertEqual(LimitSuggestions.roundedUp(S.kop(1_000_001)), S.rub(11_000))
    XCTAssertEqual(LimitSuggestions.roundedUp(S.rub(-5)), .zero)
    XCTAssertEqual(LimitSuggestions.roundedUp(AmountE4(raw: .max)), AmountE4(raw: .max))
  }

  func testTheMedianOfAnEvenCountIsTheMeanOfTheMiddle() {
    XCTAssertEqual(
      LimitSuggestions.median(of: [S.rub(1), S.rub(4), S.rub(2), S.rub(3)]), S.kop(250))
    XCTAssertEqual(LimitSuggestions.median(of: []), .zero)
  }

  func testTheKeptRowsSkipWhatCannotBeSaved() {
    let month = MonthKey(iso: "2026-10")!
    let written = LimitSuggestions.budgets(
      for: [
        (food.id, S.rub(5_000)), (food.id, S.rub(6_000)), (goals.id, S.rub(1_000)),
        (fun.id, .zero), (cafe.id, S.rub(2_000)),
      ],
      existing: [], tree: tree, in: month)
    XCTAssertEqual(written.map(\.categoryId), [food.id, cafe.id])
    XCTAssertTrue(written.allSatisfy { $0.startMonth == month && !$0.rollover })
  }
}
