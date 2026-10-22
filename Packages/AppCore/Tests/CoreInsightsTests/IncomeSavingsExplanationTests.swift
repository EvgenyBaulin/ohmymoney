import CoreKit
import CorePlanning
import Foundation
import Testing

@testable import CoreInsights

/// The breakdowns of «Норма сбережений» and «Финансовое здоровье»: each line is a figure the
/// section of Analytics shows, and the lines come to the number on the tile.
@Suite("The breakdowns of the income and savings tiles")
struct IncomeSavingsExplanationTests {
  private let september = MonthKey(year: 2026, month: 9)

  private func norm(
    income: Int64, spending: Int64, goals: Int64 = 0, partial: Bool = false
  ) -> SavingsNormMonth {
    let kept = AmountE4(whole: income - spending)
    return SavingsNormMonth(
      month: september, incomeRub: AmountE4(whole: income),
      spendingRub: AmountE4(whole: spending + goals),
      spendingWithoutGoalsRub: AmountE4(whole: spending), goalsNetRub: AmountE4(whole: goals),
      cushionDepositsRub: .zero, keptRub: kept,
      rateBp: income > 0 ? Int((income - spending) * 10_000 / income) : nil,
      rateWithGoalsAsSpendingBp: nil, isPartial: partial, earningsFallback: false,
      state: income > 0 ? .ready : .noIncome)
  }

  @Test func theNormComesFromTheIncomeLessTheSpending() {
    let explanation = TileExplanations.savingsNorm(norm(income: 100_000, spending: 85_000))
    #expect(explanation.state == .ready)
    let first = explanation.sections[0]
    #expect(first.addsUp == true)
    #expect(first.total?.value == .money(AmountE4(whole: 15_000), .rub))
    #expect(explanation.sections[1].rows.first?.value == .percent(1_500))
  }

  @Test func aMonthInTheRedKeepsItsMinus() {
    let explanation = TileExplanations.savingsNorm(norm(income: 100_000, spending: 115_000))
    #expect(explanation.sections[0].addsUp == true)
    #expect(explanation.sections[0].total?.value == .money(AmountE4(whole: -15_000), .rub))
    #expect(explanation.sections[1].rows.first?.value == .percent(-1_500))
  }

  @Test func theMoneyPutIntoGoalsIsSaidButNotSubtracted() {
    let explanation = TileExplanations.savingsNorm(
      norm(income: 100_000, spending: 70_000, goals: 10_000))
    #expect(explanation.sections[0].addsUp == true)
    #expect(explanation.sections[0].total?.value == .money(AmountE4(whole: 30_000), .rub))
    #expect(
      explanation.sections[1].rows.contains {
        $0.label.key == "why.norm.goals" && $0.value == .money(AmountE4(whole: 10_000), .rub)
      })
  }

  @Test func aPartialMonthSaysItIsNotOver() {
    let explanation = TileExplanations.savingsNorm(
      norm(income: 100_000, spending: 10_000, partial: true))
    #expect(explanation.notes.contains { $0.key == "why.norm.partial" })
  }

  @Test func withoutIncomeThereIsNothingToExplain() {
    let explanation = TileExplanations.savingsNorm(norm(income: 0, spending: 5_000))
    #expect(explanation.state == .empty(TilePhrase("why.norm.noIncome", table: "IncomeSavings")))
  }

  @Test func theHealthPointsAddUpToTheNumber() {
    let health = FinancialHealth.build(
      HealthInputs(
        cushionMonths: 3, cushionTargetMonths: 6, debtLoad: nil, savingsRateBp: 1_000,
        overdueCount: 1, stability: nil))
    let explanation = TileExplanations.financialHealth(health)
    #expect(explanation.state == .ready)
    let section = explanation.sections[0]
    let points = section.rows.compactMap { row -> Int? in
      if case .count(let count) = row.value { count } else { nil }
    }
    #expect(points.reduce(0, +) == health.total)
    #expect(section.total?.value == .count(health.total ?? -1))
    // The parts without data are named, not scored.
    #expect(explanation.sections.count == 2)
    #expect(explanation.sections[1].rows.count == health.notCounted.count)
  }

  @Test func withTooFewPartsTheHealthSaysSo() {
    let health = FinancialHealth.build(
      HealthInputs(
        cushionMonths: nil, debtLoad: nil, savingsRateBp: nil, overdueCount: 0, stability: nil))
    #expect(health.state == .notEnoughData)
    #expect(
      TileExplanations.financialHealth(health).state
        == .empty(TilePhrase("why.health.notEnough", table: "IncomeSavings")))
    #expect(TileExplanations.financialHealth(nil).state == .waiting)
  }

  @Test func theTilesOpenTheSectionOfAnalytics() {
    #expect(TileDestination.of(.savingsRate) == .analytics(.incomeSavings))
    #expect(TileDestination.of(.financialHealth) == .analytics(.incomeSavings))
    #expect(!OverviewTile.financialHealth.isShownUnnamed)
    #expect(OverviewCatalog.item(of: .financialHealth)?.number == 103)
  }
}
