import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// What is saved in a goal of another currency, in rubles: at today's rate (the default), or
/// at the rubles its contributions cost — «по курсу взносов», a running average cost.
@Suite("Goal savings valued at today's rate or at the rates of the contributions")
struct GoalValuationTests {
  typealias Fx = CashFx

  static let camera = Goal(
    id: Fx.id(402), name: "Camera", targetE4: Fx.money("1000"), subcategoryId: Fx.tripGoal,
    currency: .usd)

  static let rates = DayRates(series: [
    .usd: [
      DayRate(day: Fx.day("2026-09-05"), perUnit: 90),
      DayRate(day: Fx.day("2026-09-12"), perUnit: 100),
    ]
  ])

  func snapshot(_ fx: CashFx) -> PlanningSnapshot {
    PlanningSnapshot.build(
      ledger: fx.ledger, today: Fx.today, now: Fx.now, rubPerUnit: [.usd: 100],
      dayRates: Self.rates)
  }

  /// 9 000 ₽ put in at 90 is 100 $. Today a dollar is 100 ₽: at today's rate 10 000 ₽ of the
  /// account are not spendable — 90 000 are; at the rate of the contribution 9 000 — 91 000.
  @Test func todayOrTheRateOfTheContribution() {
    var fx = Fx()
    fx.settings.reserveGoalPlan = false
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-01", 9))
    fx.goals = [Self.camera]
    fx.add(
      .expense, "9000", at: Fx.at("2026-09-05", 12), category: Fx.tripGoal, goal: Self.camera.id)
    #expect(fx.settings.goalSavingsValuation == .today)
    let today = snapshot(fx).freeMoney
    #expect(today.goalSavings == Fx.money("10000"))
    #expect(today.main == Fx.money("90000"))
    fx.settings.goalSavingsValuation = .deposits
    let deposits = snapshot(fx).freeMoney
    #expect(deposits.goalSavings == Fx.money("9000"))
    #expect(deposits.main == Fx.money("91000"))
  }

  /// 9 000 ₽ at 90 (100 $) and 10 000 ₽ at 100 (100 $ more): 200 $ that cost 19 000 ₽. 50 $
  /// taken out take a quarter of the cost: 14 250 ₽ are left — at today's rate it would be
  /// 150 × 100 = 15 000.
  @Test func aWithdrawalTakesTheAverageCost() {
    var fx = Fx()
    fx.goals = [Self.camera]
    fx.add(
      .expense, "9000", at: Fx.at("2026-09-05", 12), category: Fx.tripGoal, goal: Self.camera.id)
    fx.add(
      .expense, "10000", at: Fx.at("2026-09-12", 12), category: Fx.tripGoal, goal: Self.camera.id)
    fx.add(
      .refund, "50", at: Fx.at("2026-09-15", 12), currency: .usd, category: Fx.tripGoal,
      goal: Self.camera.id)
    let saved = GoalMath.savedRubAtContributions(
      goals: [Self.camera], rows: fx.ledger.rows, rates: Self.rates)
    #expect(saved[Self.camera.id] == Fx.money("14250"))
    fx.settings.reserveGoalPlan = false
    fx.settings.goalSavingsValuation = .deposits
    #expect(snapshot(fx).freeMoney.plan.goalSavings == Fx.money("14250"))
    fx.settings.goalSavingsValuation = .today
    #expect(snapshot(fx).freeMoney.plan.goalSavings == Fx.money("15000"))
  }

  /// A ruble goal is its rubles either way; everything taken out leaves nothing, never less.
  @Test func aRubleGoalIsEqualBothWays() {
    var fx = Fx()
    let trip = Goal(
      id: Fx.id(401), name: "Trip", targetE4: Fx.money("100000"), subcategoryId: Fx.tripGoal)
    fx.goals = [trip]
    fx.add(.expense, "12000", at: Fx.at("2026-09-05", 12), category: Fx.tripGoal, goal: trip.id)
    fx.add(.refund, "2000", at: Fx.at("2026-09-06", 12), category: Fx.tripGoal, goal: trip.id)
    let saved = GoalMath.savedRubAtContributions(goals: [trip], rows: fx.ledger.rows, rates: .empty)
    #expect(saved[trip.id] == Fx.money("10000"))
    fx.add(.refund, "10000", at: Fx.at("2026-09-07", 12), category: Fx.tripGoal, goal: trip.id)
    #expect(
      GoalMath.savedRubAtContributions(goals: [trip], rows: fx.ledger.rows, rates: .empty)[trip.id]
        == nil)
  }

  /// A contribution in rubles to a dollar goal while no dollar rate is known at all is left out
  /// of both valuations, as it is left out of what is saved; one in dollars counts.
  @Test func aRowWithoutARateIsSkipped() {
    var fx = Fx()
    fx.goals = [Self.camera]
    fx.add(
      .expense, "9000", at: Fx.at("2026-09-05", 12), category: Fx.tripGoal, goal: Self.camera.id)
    #expect(
      GoalMath.savedRubAtContributions(goals: [Self.camera], rows: fx.ledger.rows, rates: .empty)
        .isEmpty)
    fx.add(
      .expense, "10", at: Fx.at("2026-09-06", 12), currency: .usd, category: Fx.tripGoal,
      goal: Self.camera.id)
    #expect(
      GoalMath.savedRubAtContributions(goals: [Self.camera], rows: fx.ledger.rows, rates: .empty)[
        Self.camera.id] == Fx.money("900"))
  }
}
