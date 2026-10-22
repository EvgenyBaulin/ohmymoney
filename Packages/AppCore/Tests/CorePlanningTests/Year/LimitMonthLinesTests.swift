import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("A limit set for one month shows in the limit lines of that month only")
struct LimitMonthLinesTests {
  typealias Fx = CashFx

  static let budget = Budget(
    id: Fx.id(900), scope: .category, categoryId: Fx.groceries, amountE4: Fx.money("5000"))

  static func ledger(exceptions: [LimitMonthException]) -> Ledger {
    var fx = Fx()
    fx.add(.expense, "1200", at: Fx.at("2026-09-10", 12))
    var dataset = Dataset(
      entries: fx.entries, categories: Fx.categories, paymentMethods: fx.accounts,
      planning: PlanningBook(budgets: [budget]))
    dataset.yearPlan = YearPlanData(monthExceptions: exceptions)
    return Ledger(dataset: dataset, calendar: .utc)
  }

  @Test func theMonthOfTheExceptionUsesItsAmount() throws {
    let exception = LimitMonthException(
      budgetId: Self.budget.id, month: Fx.today.monthKey, amountE4: Fx.money("20000"))
    let ledger = Self.ledger(exceptions: [exception])
    let line = try #require(
      LimitRules.lines(book: ledger.dataset.planning, ledger: ledger, today: Fx.today).first)
    #expect(line.amount == Fx.money("20000") && line.available == Fx.money("20000"))
    // The stored limit is untouched, so an edit changes the usual amount.
    #expect(line.budget.amountE4 == Fx.money("5000"))
    #expect(line.remaining == Fx.money("18800"))
  }

  @Test func anotherMonthKeepsTheUsualLimit() throws {
    let exception = LimitMonthException(
      budgetId: Self.budget.id, month: Fx.today.monthKey.next, amountE4: Fx.money("20000"))
    let ledger = Self.ledger(exceptions: [exception])
    let line = try #require(
      LimitRules.lines(book: ledger.dataset.planning, ledger: ledger, today: Fx.today).first)
    #expect(line.amount == Fx.money("5000"))
    let later = try #require(
      LimitRules.lines(
        book: ledger.dataset.planning, ledger: ledger, today: Fx.today.adding(days: 30)
      ).first)
    #expect(later.month == Fx.today.monthKey.next && later.amount == Fx.money("20000"))
  }

  @Test func withoutExceptionsNothingChanges() throws {
    let ledger = Self.ledger(exceptions: [])
    let line = try #require(
      LimitRules.lines(book: ledger.dataset.planning, ledger: ledger, today: Fx.today).first)
    #expect(line.amount == Fx.money("5000") && line.remaining == Fx.money("3800"))
  }
}
