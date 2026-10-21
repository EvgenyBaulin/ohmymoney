import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// What went into a goal above a month's plan counts towards the following months: the grey
/// line never holds a plan already paid in.
@Suite("Goal plans: money put in ahead is credited to later months")
struct GoalPlanCreditTests {
  typealias Fx = CashFx

  func goal(
    plan: String = "10000", target: String = "1000000",
    start: MonthKey? = MonthKey(year: 2026, month: 9)
  ) -> Goal {
    Goal(
      id: Fx.id(401), name: "Trip", targetE4: Fx.money(target), monthlyPlanE4: Fx.money(plan),
      subcategoryId: Fx.tripGoal, planStartMonth: start)
  }

  func state(_ fx: CashFx, month: MonthKey, goal: Goal) -> GoalPlanState? {
    GoalMath.planState(goal: goal, rows: fx.ledger.rows, month: month, rates: .empty)
  }

  static let september = MonthKey(year: 2026, month: 9)
  static let october = MonthKey(year: 2026, month: 10)

  /// The owner's example: a plan of 10 000 from September, 20 000 put in on the 19th. This
  /// month asks nothing, 10 000 is credit for October: the grey line through October holds
  /// nothing, and 80 000 of the 100 000 can be spent both before and after.
  @Test func twentyThousandInSeptemberCoverOctober() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-01", 9))
    fx.goals = [goal()]
    let october = Fx.day("2026-10-31")
    let before = fx.snapshot().freeMoney(until: october, ledger: fx.ledger)
    #expect(before.grey == Fx.money("80000"))
    fx.add(.expense, "20000", at: Fx.at("2026-09-19", 10), category: Fx.tripGoal, goal: Fx.id(401))
    let state = state(fx, month: Self.september, goal: goal())
    #expect(state?.restThisMonth == .zero)
    #expect(state?.creditOut == Fx.money("10000"))
    let after = fx.snapshot().freeMoney(until: october, ledger: fx.ledger)
    #expect(after.main == Fx.money("80000"))
    #expect(after.grey == Fx.money("80000"))
    // In October the credit of September pays October's plan.
    let inOctober = self.state(fx, month: Self.october, goal: goal())
    #expect(inOctober?.creditIn == Fx.money("10000"))
    #expect(inOctober?.restThisMonth == .zero)
    #expect(inOctober?.creditOut == .zero)
    // Through November the plan of November is held.
    #expect(
      fx.plan(until: "2026-11-30").goalPlans == Fx.money("10000"))
  }

  /// 25 000 ahead on a plan of 10 000, D the end of December: September asks nothing, 15 000 of
  /// credit, and of the three later plans 15 000 is held — half of November and December.
  @Test func twentyFiveThousandAhead() {
    var fx = Fx()
    fx.goals = [goal()]
    fx.add(.expense, "25000", at: Fx.at("2026-09-10", 10), category: Fx.tripGoal, goal: Fx.id(401))
    #expect(state(fx, month: Self.september, goal: goal())?.creditOut == Fx.money("15000"))
    #expect(fx.plan(until: "2026-12-31").goalPlans == Fx.money("15000"))
  }

  /// 10 000 of credit from August and 5 000 taken out this month: this month asks 5 000.
  @Test func aWithdrawalThisMonthIsAskedBack() {
    var fx = Fx()
    let started = goal(start: MonthKey(year: 2026, month: 8))
    fx.goals = [started]
    fx.add(.expense, "20000", at: Fx.at("2026-08-10", 10), category: Fx.tripGoal, goal: Fx.id(401))
    fx.add(.refund, "5000", at: Fx.at("2026-09-10", 10), category: Fx.tripGoal, goal: Fx.id(401))
    let state = state(fx, month: Self.september, goal: started)
    #expect(state?.creditIn == Fx.money("10000"))
    #expect(state?.thisMonth == Fx.money("-5000"))
    #expect(state?.restThisMonth == Fx.money("5000"))
    #expect(state?.creditOut == .zero)
  }

  /// A month below plan uses up credit and never makes a debt: 15 000 in July on a plan of
  /// 10 000 from July, nothing in August — August's plan takes the 5 000 of credit, and
  /// September asks its plan in full, nothing more for the month missed.
  @Test func aMonthBelowPlanUsesTheCreditAndMakesNoDebt() {
    var fx = Fx()
    let started = goal(start: MonthKey(year: 2026, month: 7))
    fx.goals = [started]
    fx.add(.expense, "15000", at: Fx.at("2026-07-10", 10), category: Fx.tripGoal, goal: Fx.id(401))
    let state = state(fx, month: Self.september, goal: started)
    #expect(state?.creditIn == .zero)
    #expect(state?.restThisMonth == Fx.money("10000"))
  }

  /// The plan counts from its start month: money put in before it is savings, not a plan paid
  /// ahead — 100 000 put in in June, a plan of 10 000 from September: September asks 10 000.
  @Test func aOnePointOneGoalCreditsNothingBeforeTheUpdate() {
    var fx = Fx()
    fx.goals = [goal()]
    fx.add(.expense, "100000", at: Fx.at("2026-06-10", 10), category: Fx.tripGoal, goal: Fx.id(401))
    let state = state(fx, month: Self.september, goal: goal())
    #expect(state?.creditIn == .zero)
    #expect(state?.restThisMonth == Fx.money("10000"))
    #expect(
      GoalMath.planLeft(
        goals: [goal()], rows: fx.ledger.rows, month: Self.september, rates: .empty)[Fx.id(401)]
        == Fx.money("10000"))
  }

  /// A goal saved without a start month counts from the month of its first contribution: the
  /// 25 000 of August on a plan of 10 000 is 15 000 of credit, and September asks nothing.
  @Test func aMissingStartFallsBackToTheFirstContribution() {
    var fx = Fx()
    let loose = goal(start: nil)
    fx.goals = [loose]
    fx.add(.expense, "25000", at: Fx.at("2026-08-10", 10), category: Fx.tripGoal, goal: Fx.id(401))
    let state = state(fx, month: Self.september, goal: loose)
    #expect(state?.creditIn == Fx.money("15000"))
    #expect(state?.restThisMonth == .zero)
    #expect(state?.creditOut == Fx.money("5000"))
    // Without any contribution the plan starts this month.
    let empty = GoalMath.planState(goal: loose, rows: [], month: Self.september, rates: .empty)
    #expect(empty?.restThisMonth == Fx.money("10000"))
  }

  /// The rest never asks more than the goal still needs; a goal without a plan or archived has
  /// no state.
  @Test func theRestStopsAtWhatTheGoalNeeds() {
    var fx = Fx()
    let small = goal(target: "23000")
    fx.goals = [small]
    fx.add(.expense, "20000", at: Fx.at("2026-09-02", 10), category: Fx.tripGoal, goal: Fx.id(401))
    #expect(state(fx, month: Self.september, goal: small)?.restThisMonth == .zero)
    #expect(fx.plan(until: "2026-12-31").goalPlans == Fx.money("3000"))
    var none = small
    none.monthlyPlanE4 = nil
    #expect(state(fx, month: Self.september, goal: none) == nil)
    var archived = small
    archived.archived = true
    #expect(state(fx, month: Self.september, goal: archived) == nil)
  }
}
