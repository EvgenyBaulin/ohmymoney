import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("The rest of the month")
struct MonthRestTests {
  typealias B = B3Book

  func free(main: String, scheduled: String = "0", debts: String = "0") -> FreeMoney {
    var free = FreeMoney(
      accounts: .empty, plan: CashPlan(scheduled: B.rub(scheduled), debts: B.rub(debts)),
      stillExpected: .zero, today: B.day(10, 1), until: B.day(10, 31))
    free.main = B.rub(main)
    return free
  }

  func cushion(goalReached: Bool?) -> CushionStatus {
    var status = CushionStatus.empty
    status.state = .ready
    if let goalReached {
      status.goal = CushionGoalStatus(
        targetMonths: 6, targetRub: B.rub("600000"),
        missingRub: goalReached ? .zero : B.rub("100000"), perMonthRub: nil,
        defaultPerMonthRub: B.rub("10000"), pacePerMonthRub: nil, reachedBy: nil,
        reached: goalReached)
    }
    return status
  }

  @Test func onTheFirstTheRestLessThePayments() {
    let offer = MonthRest.offer(
      today: B.day(10, 1), free: free(main: "30000", scheduled: "8000", debts: "2000"),
      settings: .standard, cushion: cushion(goalReached: false), goals: [])
    #expect(
      offer
        == MonthRestOffer(
          month: MonthKey(year: 2026, month: 9), amountE4: B.rub("20000"), target: .cushion))
  }

  @Test func afterTheTenthOrOnceDoneNothing() {
    #expect(
      MonthRest.offer(
        today: B.day(10, 11), free: free(main: "30000"), settings: .standard,
        cushion: cushion(goalReached: false), goals: []) == nil)
    #expect(
      MonthRest.offer(
        today: B.day(10, 3), free: free(main: "30000"),
        settings: AllocationSettings(monthRestDone: MonthKey(year: 2026, month: 9)),
        cushion: cushion(goalReached: false), goals: []) == nil)
    #expect(
      MonthRest.offer(
        today: B.day(10, 3), free: free(main: "1000", scheduled: "5000"), settings: .standard,
        cushion: cushion(goalReached: false), goals: []) == nil)
  }

  @Test func withoutACushionGoalTheLastChoiceElseAsk() {
    let goal = Goal(name: "Отпуск", targetE4: B.rub("100000"))
    let status = GoalStatusFixture.status(of: goal)
    let remembered = MonthRest.offer(
      today: B.day(10, 2), free: free(main: "30000"),
      settings: AllocationSettings(monthRestTarget: .goal(goal.id)),
      cushion: cushion(goalReached: true), goals: [status])
    #expect(remembered?.target == .goal(goal.id))
    let asked = MonthRest.offer(
      today: B.day(10, 2), free: free(main: "30000"), settings: .standard,
      cushion: cushion(goalReached: nil), goals: [status])
    #expect(asked?.target == nil)
    #expect(asked?.amountE4 == B.rub("30000"))
  }
}

/// A goal's status from a book with only the goal in it.
enum GoalStatusFixture {
  static func status(of goal: Goal) -> GoalStatus {
    let book = B3Book(goals: [goal])
    return GoalRules.statuses(
      goals: [goal], ledger: book.ledger, today: B3Book.day(10, 2), rates: .empty,
      rubPerUnit: [:])[0]
  }
}
