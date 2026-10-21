import CoreAccounting
import CoreKit
import CorePlanning
import Foundation
import Testing

/// Which limits the lists of limits show first, and what a limit field typed next to a
/// category or on a limit's amount writes.
@Suite("Limits: the ranking and the amount typed in place")
struct LimitRankingTests {
  static func uid(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number)) ?? UUID()
  }

  let food = Self.uid(1)
  let cafe = Self.uid(2)
  let taxi = Self.uid(3)
  let books = Self.uid(4)
  let oldHobby = Self.uid(5)
  let underOld = Self.uid(6)
  let goals = Self.uid(7)
  let trip = Self.uid(8)
  let unknown = Self.uid(9)
  let salary = Self.uid(10)
  let alpha = Self.uid(11)
  let beta = Self.uid(12)
  let month = MonthKey(year: 2026, month: 9)

  var tree: CategoryTree {
    CategoryTree([
      CoreKit.Category(id: food, kind: .expense, name: "Food"),
      CoreKit.Category(id: cafe, parentId: food, kind: .expense, name: "Cafe"),
      CoreKit.Category(id: taxi, kind: .expense, name: "Taxi"),
      CoreKit.Category(id: books, kind: .expense, name: "books"),
      CoreKit.Category(id: oldHobby, kind: .expense, name: "Old hobby", archived: true),
      CoreKit.Category(id: underOld, parentId: oldHobby, kind: .expense, name: "Paints"),
      CoreKit.Category(id: goals, kind: .expense, name: "Goals", systemRole: .goals),
      CoreKit.Category(id: trip, parentId: goals, kind: .expense, name: "Trip"),
      CoreKit.Category(id: unknown, kind: .expense, name: "Unknown", systemRole: .unknown),
      CoreKit.Category(id: salary, kind: .income, name: "Salary"),
      CoreKit.Category(id: alpha, kind: .expense, name: "Alpha"),
      CoreKit.Category(id: beta, kind: .expense, name: "Beta"),
    ])
  }

  func money(_ text: String) -> AmountE4 { amountLiteral(text) }

  /// A line as the rules would give it: only what the ranking reads is chosen.
  func line(
    _ category: UUID, spent: String, of available: String, _ status: LimitStatus = .ok,
    id: Int? = nil
  ) -> LimitLine {
    let budget = Budget(
      id: id.map(Self.uid) ?? UUID(), scope: .category, categoryId: category,
      amountE4: money(available))
    return LimitLine(
      budget: budget, month: month, amount: money(available), carry: .zero,
      spent: money(spent), spentShareBp: nil, elapsedShareBp: 5_000, paceBp: nil,
      planned: .zero, forecast: money(spent), lowData: false, status: status)
  }

  func names(_ lines: [LimitLine]) -> [String] {
    lines.map { PlanningNames.path($0.budget.categoryId, in: tree) }
  }

  // MARK: - The ranking

  /// Over first, then close to the limit, then within: a limit within at 99 % comes after one
  /// on the edge at 95 %, and a limit over by 1 % before both.
  @Test func overComesBeforeWarningAndWarningBeforeOk() {
    let lines = [
      line(taxi, spent: "100", of: "1000", .ok),
      line(food, spent: "950", of: "1000", .warning),
      line(books, spent: "1010", of: "1000", .over),
      line(alpha, spent: "990", of: "1000", .ok),
    ]
    let ranked = LimitRules.ranked(lines, topN: nil, tree: tree)
    #expect(names(ranked.shown) == ["books", "Food", "Alpha", "Taxi"])
    #expect(ranked.total == 4)
  }

  /// Within one status, the bigger share spent first — compared exactly: 3 333.4 of 10 000
  /// and 10 000 of 30 000 are both «33.33 %», and the first is more.
  @Test func withinAStatusTheBiggerShareSpentComesFirstComparedExactly() {
    let lines = [
      line(taxi, spent: "10000", of: "30000"),
      line(food, spent: "3333.4", of: "10000"),
      line(books, spent: "5000", of: "10000"),
      line(alpha, spent: "-50", of: "1000"),
    ]
    #expect(
      names(LimitRules.ranked(lines, topN: nil, tree: tree).shown)
        == ["books", "Food", "Taxi", "Alpha"])
  }

  /// The same share: by name, whatever the case, «Food › Cafe» under its parent's name.
  @Test func theSameShareIsOrderedByNameIgnoringCase() {
    let lines = [
      line(taxi, spent: "0", of: "1000"),
      line(cafe, spent: "0", of: "500"),
      line(books, spent: "0", of: "700"),
      line(beta, spent: "0", of: "100"),
      line(alpha, spent: "0", of: "100"),
    ]
    #expect(
      names(LimitRules.ranked(lines, topN: nil, tree: tree).shown)
        == ["Alpha", "Beta", "books", "Food › Cafe", "Taxi"])
  }

  /// The app names a bad-spending or a «for whom» limit in its language; the caller hands the
  /// names in, and the tie follows them.
  @Test func theCallerNamesTheLimitsTheCoreCannot() {
    let bad = LimitLine(
      budget: Budget(scope: .badTotal, amountE4: money("100")), month: month,
      amount: money("100"), carry: .zero, spent: .zero, spentShareBp: 0, elapsedShareBp: 0,
      paceBp: 0, planned: .zero, forecast: .zero, lowData: false, status: .ok)
    let taxi = line(taxi, spent: "0", of: "100")
    let ranked = LimitRules.ranked([taxi, bad], topN: nil, tree: tree) { line in
      line.budget.scope == .badTotal ? "Плохие траты" : "Такси"
    }
    #expect(ranked.shown.map(\.budget.scope) == [.badTotal, .category])
  }

  /// A limit of an archived category, or of a subcategory of one, is hidden and not counted;
  /// the others are counted even when only the top ones are shown.
  @Test func aLimitOfAnArchivedCategoryIsHiddenAndNotCounted() {
    let lines = [
      line(oldHobby, spent: "2000", of: "100", .over),
      line(underOld, spent: "2000", of: "100", .over),
      line(taxi, spent: "90", of: "100", .warning),
      line(food, spent: "10", of: "100"),
      line(books, spent: "20", of: "100"),
    ]
    let top = LimitRules.ranked(lines, topN: 2, tree: tree)
    #expect(names(top.shown) == ["Taxi", "books"])
    #expect(top.total == 3)
    #expect(LimitRules.ranked(lines, topN: nil, tree: tree).shown.count == 3)
    #expect(LimitRules.ranked(lines, topN: 10, tree: tree).shown.count == 3)
  }

  @Test func nothingAvailableAndSpentRanksAboveEveryShare() {
    let empty = line(food, spent: "10", of: "0", .over)
    let over = line(taxi, spent: "5000", of: "100", .over)
    let ranked = LimitRules.ranked([over, empty], topN: nil, tree: tree)
    #expect(names(ranked.shown) == ["Food", "Taxi"])
  }

  @Test func theOrderIsTheSameWhateverOrderTheLinesCameIn() {
    let lines = [
      line(taxi, spent: "0", of: "100", id: 20),
      line(food, spent: "50", of: "100", .warning, id: 21),
      line(books, spent: "0", of: "100", id: 22),
      line(alpha, spent: "200", of: "100", .over, id: 23),
    ]
    let once = LimitRules.ranked(lines, topN: nil, tree: tree).shown
    #expect(LimitRules.ranked(lines.reversed(), topN: nil, tree: tree).shown == once)
    #expect(LimitRules.ranked(lines.shuffled(), topN: nil, tree: tree).shown == once)
  }

  // MARK: - Which category takes a limit in its row

  @Test func aRowOffersALimitOnlyWhereOneCanBeSaved() {
    #expect(LimitRules.offersLimit(on: food, tree: tree))
    #expect(LimitRules.offersLimit(on: cafe, tree: tree))
    #expect(!LimitRules.offersLimit(on: oldHobby, tree: tree), "an archived category")
    #expect(!LimitRules.offersLimit(on: underOld, tree: tree), "under an archived category")
    #expect(!LimitRules.offersLimit(on: goals, tree: tree), "a system category")
    #expect(!LimitRules.offersLimit(on: trip, tree: tree), "a goal's subcategory")
    #expect(!LimitRules.offersLimit(on: unknown, tree: tree), "«Не помню»")
    #expect(!LimitRules.offersLimit(on: salary, tree: tree), "an income category")
    #expect(!LimitRules.offersLimit(on: Self.uid(99), tree: tree), "a category that is gone")
  }

  // MARK: - The amount typed next to a category

  @Test func anAmountTypedForACategoryWithoutALimitMakesOneStartingThisMonth() throws {
    let change = LimitRules.settingCategoryLimit(
      food, to: money("5000"), budgets: [], tree: tree, in: month)
    guard case .save(let budget) = change else {
      Issue.record("nothing to save: \(change)")
      return
    }
    #expect(budget.scope == .category)
    #expect(budget.categoryId == food)
    #expect(budget.amountE4 == money("5000"))
    #expect(budget.startMonth == month)
    #expect(!budget.rollover)
  }

  @Test func aNewAmountKeepsTheLimitAndStartsItsCarryAgain() {
    let june = MonthKey(year: 2026, month: 6)
    let stored = Budget(
      scope: .category, categoryId: food, amountE4: money("5000"), rollover: true,
      startMonth: june)
    let other = Budget(scope: .category, categoryId: taxi, amountE4: money("100"))
    let change = LimitRules.settingCategoryLimit(
      food, to: money("7000"), budgets: [other, stored], tree: tree, in: month)
    var expected = stored
    expected.amountE4 = money("7000")
    expected.startMonth = month
    #expect(change == .save(expected))
  }

  @Test func theSameAmountWritesNothing() {
    let stored = Budget(scope: .category, categoryId: food, amountE4: money("5000"))
    #expect(
      LimitRules.settingCategoryLimit(
        food, to: money("5000"), budgets: [stored], tree: tree, in: month) == .unchanged)
  }

  @Test func anEmptyFieldDeletesTheLimitAndWithoutOneWritesNothing() {
    let stored = Budget(scope: .category, categoryId: food, amountE4: money("5000"))
    #expect(
      LimitRules.settingCategoryLimit(food, to: nil, budgets: [stored], tree: tree, in: month)
        == .delete(stored))
    #expect(
      LimitRules.settingCategoryLimit(taxi, to: nil, budgets: [stored], tree: tree, in: month)
        == .unchanged)
  }

  /// Zero is not «no limit»: it is refused, and so is a negative amount.
  @Test func zeroIsRefusedNotTakenForNoLimit() {
    let stored = Budget(scope: .category, categoryId: food, amountE4: money("5000"))
    #expect(
      LimitRules.settingCategoryLimit(food, to: .zero, budgets: [stored], tree: tree, in: month)
        == .refused(.nonPositive))
    #expect(
      LimitRules.settingCategoryLimit(taxi, to: .zero, budgets: [stored], tree: tree, in: month)
        == .refused(.nonPositive))
    #expect(
      LimitRules.settingCategoryLimit(
        taxi, to: money("-10"), budgets: [stored], tree: tree, in: month)
        == .refused(.nonPositive))
  }

  @Test func aSystemOrIncomeCategoryIsRefused() {
    #expect(
      LimitRules.settingCategoryLimit(trip, to: money("10"), budgets: [], tree: tree, in: month)
        == .refused(.systemCategory))
    #expect(
      LimitRules.settingCategoryLimit(salary, to: money("10"), budgets: [], tree: tree, in: month)
        == .refused(.incomeCategory))
  }

  /// The field of a category is its own limit: a bad-spending or a «for whom» limit is left
  /// alone, and so is the limit of the parent.
  @Test func theFieldOfACategoryIsOnlyItsOwnCategoryLimit() {
    let parent = Budget(scope: .category, categoryId: food, amountE4: money("5000"))
    let bad = Budget(scope: .badTotal, amountE4: money("100"))
    #expect(LimitRules.categoryLimit(of: cafe, in: [parent, bad]) == nil)
    #expect(LimitRules.categoryLimit(of: food, in: [bad, parent]) == parent)
    guard
      case .save(let budget) = LimitRules.settingCategoryLimit(
        cafe, to: money("300"), budgets: [parent, bad], tree: tree, in: month)
    else {
      Issue.record("a subcategory under a limited parent took no limit of its own")
      return
    }
    #expect(budget.categoryId == cafe)
    #expect(budget.id != parent.id)
  }

  // MARK: - The amount of a limit edited in place

  @Test func anAmountEditedInPlaceIsSavedOverTheStoredRow() {
    let june = MonthKey(year: 2026, month: 6)
    let stored = Budget(
      scope: .forWhom, forWhom: .friends, amountE4: money("3000"), rollover: true,
      startMonth: june)
    var shown = stored
    shown.rollover = false  // the screen had not caught up with the last edit yet
    let change = LimitRules.changingAmount(
      of: shown.id, to: money("4000"), budgets: [stored], tree: tree, in: month)
    var expected = stored
    expected.amountE4 = money("4000")
    expected.startMonth = month
    #expect(change == .save(expected))
  }

  @Test func inPlaceTheSameAmountOrAGoneLimitWritesNothingAndZeroIsRefused() {
    let stored = Budget(scope: .category, categoryId: food, amountE4: money("3000"))
    #expect(
      LimitRules.changingAmount(
        of: stored.id, to: money("3000"), budgets: [stored], tree: tree, in: month)
        == .unchanged)
    #expect(
      LimitRules.changingAmount(
        of: Self.uid(77), to: money("10"), budgets: [stored], tree: tree, in: month)
        == .unchanged)
    #expect(
      LimitRules.changingAmount(of: stored.id, to: .zero, budgets: [stored], tree: tree, in: month)
        == .refused(.nonPositive))
  }
}

/// A category as the lists name it, for the checks above.
private enum PlanningNames {
  static func path(_ id: UUID?, in tree: CategoryTree) -> String {
    guard let category = tree.category(id) else { return "—" }
    guard let parent = tree.parent(of: category.id) else { return category.name }
    return "\(parent.name) › \(category.name)"
  }
}
