import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite struct ScenarioEngineTests {
  let today = DateOnly(year: 2026, month: 10, day: 20)

  func base(
    free: Int64 = 100_000, income: Int64 = 100_000, spending: Int64 = 70_000
  )
    -> ScenarioBaseline
  {
    ScenarioBaseline(
      today: today, freeMoneyE4: AmountE4(raw: free * 10_000),
      incomeMonthlyE4: AmountE4(raw: income * 10_000),
      spendingMonthlyE4: AmountE4(raw: spending * 10_000))
  }

  @Test func noChangesGrowByTheMonthlySurplus() {
    let run = ScenarioEngine.run(ScenarioSpec(horizonMonths: 3), from: base())
    #expect(run.points.count == 4)
    #expect(run.points[0].freeE4.raw == 100_000 * 10_000)
    #expect(run.points[3].freeE4.raw == 190_000 * 10_000)
    #expect(run.firstShortMonth == nil)
  }

  @Test func aPurchaseTakesItsMoneyOnce() {
    let spec = ScenarioSpec(
      changes: [ScenarioChange(kind: .purchase, amountE4: 150_000 * 10_000)], horizonMonths: 2)
    let run = ScenarioEngine.run(spec, from: base())
    #expect(run.points[0].freeE4.raw == -50_000 * 10_000)
    #expect(run.firstShortMonth == 0)
    #expect(run.points[2].freeE4.raw == 10_000 * 10_000)
  }

  @Test func aLoanCostsItsPaymentsAndLeavesTheDebtFalling() {
    let loan = ScenarioChange(
      kind: .loan, amountE4: 120_000 * 10_000, months: 12, rateBp: 0, payment: .annuity)
    let run = ScenarioEngine.run(ScenarioSpec(changes: [loan], horizonMonths: 12), from: base())
    #expect(run.points[0].debtE4.raw == 120_000 * 10_000)
    #expect(run.points[12].debtE4.raw == 0)
    #expect(run.points[1].freeE4.raw == 100_000 * 10_000 + (30_000 - 10_000) * 10_000)
    #expect(run.interestE4.raw == 0)
  }

  @Test func theInterestOfALoanIsSummed() {
    let loan = ScenarioChange(
      kind: .loan, amountE4: 100_000 * 10_000, months: 12, rateBp: 1200, payment: .differentiated)
    let run = ScenarioEngine.run(ScenarioSpec(changes: [loan], horizonMonths: 12), from: base())
    #expect(run.interestE4.raw > 0)
    #expect(run.points[12].debtE4.raw == 0)
  }

  @Test func lostIncomeStopsTheSurplusForItsMonths() {
    let spec = ScenarioSpec(
      changes: [ScenarioChange(kind: .incomeLoss, months: 2)], horizonMonths: 3)
    let run = ScenarioEngine.run(spec, from: base(free: 100_000))
    // Months 1 and 2 have no income: -70 000 each; month 3 earns +30 000 again.
    #expect(run.points[1].freeE4.raw == 30_000 * 10_000)
    #expect(run.points[2].freeE4.raw == -40_000 * 10_000)
    #expect(run.firstShortMonth == 2)
    #expect(run.lowestFreeE4.raw == -40_000 * 10_000)
  }

  @Test func aSavingMovesMoneyFromFreeToSaved() {
    let spec = ScenarioSpec(
      changes: [ScenarioChange(kind: .save, amountE4: 10_000 * 10_000, months: 3)],
      horizonMonths: 4)
    let run = ScenarioEngine.run(spec, from: base())
    #expect(run.points[4].savedE4.raw == 30_000 * 10_000)
    #expect(run.points[4].netE4.raw == run.points[4].freeE4.raw + 30_000 * 10_000)
  }

  @Test func theSameSpecGivesTheSameRun() {
    let spec = ScenarioSpec(changes: [ScenarioChange(kind: .purchase, amountE4: 1)])
    #expect(ScenarioEngine.run(spec, from: base()) == ScenarioEngine.run(spec, from: base()))
  }
}

@Suite struct ScenarioBaselineTests {
  @Test func anEmptySnapshotGivesAZeroBaseline() {
    let base = ScenarioBaseline(snapshot: .empty)
    #expect(base.freeMoneyE4 == .zero)
    #expect(base.incomeMonthlyE4 == .zero)
    #expect(base.spendingMonthlyE4 == .zero)
    #expect(base.debtE4 == .zero)
  }
}
