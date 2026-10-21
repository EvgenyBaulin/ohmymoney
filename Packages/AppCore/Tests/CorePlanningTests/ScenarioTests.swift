import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("What-if scenarios: the spec, the name and the calculators")
struct ScenarioTests {
  func rub(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }

  // MARK: - Spec and name

  @Test func theCanonicalTextDoesNotDependOnTheOrderAndReadsBack() {
    let spec = ScenarioSpec(
      changes: [
        ScenarioChange(
          kind: .loan, amountE4: 12_000_000_000, months: 60, rateBp: 1_250, payment: .annuity),
        ScenarioChange(kind: .save, amountE4: 150_000_000),
      ], horizonMonths: 120, incomeMonthlyE4: 800_000_000, inflationBp: 800,
      includeIncomeTax: true)
    let text = spec.json()
    #expect(text == spec.json())
    #expect(text.hasPrefix(#"{"changes":[{"amountE4":12000000000"#))
    #expect(ScenarioSpec(json: text) == spec)
    #expect(ScenarioSpec(json: "not json") == nil)
  }

  @Test func theHorizonIsAYearByDefaultAndNeverPastThirtyYears() {
    #expect(ScenarioSpec().horizonMonths == 12)
    #expect(ScenarioSpec(horizonMonths: 10_000).horizonMonths == 360)
    #expect(ScenarioSpec(horizonMonths: 0).horizonMonths == 1)
    #expect(ScenarioSpec(inflationBp: -5).inflationBp == 0)
  }

  @Test func theNameComesFromWhatTheScenarioHolds() {
    let loan = ScenarioSpec(
      changes: [ScenarioChange(kind: .loan, amountE4: 12_000_000_000, months: 60)])
    #expect(ScenarioName.make(loan, russian: true) == "Кредит 1,2 млн на 5 лет")
    #expect(ScenarioName.make(loan, russian: false) == "Loan 1.2M for 5 years")
    let save = ScenarioSpec(changes: [ScenarioChange(kind: .save, amountE4: 150_000_000)])
    #expect(ScenarioName.make(save, russian: true) == "Копить 15 тыс. в месяц")
    let loss = ScenarioSpec(changes: [ScenarioChange(kind: .incomeLoss, months: 6)])
    #expect(ScenarioName.make(loss, russian: true) == "Потеря дохода на 6 мес.")
    let two = ScenarioSpec(changes: loan.changes + save.changes)
    #expect(ScenarioName.make(two, russian: true) == "Кредит 1,2 млн на 5 лет и ещё 1")
    #expect(ScenarioName.make(ScenarioSpec(), russian: true) == "Сценарий")
    #expect(ScenarioName.duration(24, russian: true) == "2 года")
    #expect(ScenarioName.duration(12, russian: true) == "1 год")
    #expect(ScenarioName.duration(132, russian: true) == "11 лет")
  }

  // MARK: - The long horizon

  @Test func withoutARateTheMoneyIsWhatWasPut() {
    let result = SavingsPlan.outcome(monthlyE4: rub(10_000), months: 24)
    #expect(result.finalE4 == rub(240_000))
    #expect(result.depositedE4 == rub(240_000))
    #expect(result.todaysMoneyE4 == result.finalE4)
  }

  @Test func aRateAddsInterestAndInflationTakesItBack() {
    let plain = SavingsPlan.outcome(monthlyE4: rub(10_000), months: 60, rateBp: 1_200)
    #expect(plain.finalE4 > plain.depositedE4)
    let eaten = SavingsPlan.outcome(
      monthlyE4: rub(10_000), months: 60, rateBp: 1_200, inflationBp: 1_200)
    #expect(eaten.finalE4 == plain.finalE4)
    #expect(eaten.todaysMoneyE4 < eaten.finalE4)
    let taxed = SavingsPlan.outcome(
      monthlyE4: rub(10_000), months: 60, rateBp: 1_200, taxBp: 1_300)
    #expect(taxed.finalE4 < plain.finalE4)
    #expect(taxed.finalE4 > plain.depositedE4)
  }

  @Test func theMonthlyNeededMakesTheTargetAndRoundsUp() throws {
    let needed = try #require(SavingsPlan.monthlyNeeded(targetE4: rub(1_200_000), months: 120))
    #expect(needed == rub(10_000))
    let withRate = try #require(
      SavingsPlan.monthlyNeeded(targetE4: rub(1_200_000), months: 120, rateBp: 800))
    #expect(withRate < needed)
    let back = SavingsPlan.outcome(monthlyE4: withRate, months: 120, rateBp: 800)
    #expect(back.finalE4 >= rub(1_200_000))
    #expect(SavingsPlan.monthlyNeeded(targetE4: rub(1), months: 0) == nil)
    #expect(SavingsPlan.monthlyNeeded(targetE4: .zero, months: 12) == nil)
  }

  @Test func aZeroPaceNeverGetsThereAndSaysWhatWouldDo() {
    let never = SavingsPlan.pace(targetE4: rub(180_000), monthlyE4: .zero, wishMonths: 12)
    #expect(never == .never(suggestedMonthlyE4: rub(15_000), suggestedFor: 12))
    #expect(
      SavingsPlan.pace(targetE4: rub(180_000), monthlyE4: rub(15_000)) == .reaches(months: 12))
    #expect(
      SavingsPlan.pace(targetE4: rub(100_000), monthlyE4: rub(30_000)) == .reaches(months: 4))
    // A pace that never reaches it in thirty years: 1 ruble a month for a million.
    guard case .never = SavingsPlan.pace(targetE4: rub(1_000_000), monthlyE4: rub(1)) else {
      Issue.record("a ruble a month does not make a million")
      return
    }
  }

  // MARK: - Loss of income

  @Test func theTwoRowsSayHowLongTheCushionLasts() {
    let result = IncomeLoss.check(
      cushionE4: rub(300_000), obligatoryMonthlyE4: rub(50_000), usualMonthlyE4: rub(100_000),
      months: 6)
    #expect(result.tightenedBelt.monthsLasting == 6)
    #expect(result.tightenedBelt.enough)
    #expect(result.tightenedBelt.shortfallE4 == .zero)
    #expect(result.asUsual.monthsLasting == 3)
    #expect(!result.asUsual.enough)
    #expect(result.asUsual.shortfallE4 == rub(300_000))
  }

  @Test func theUsualRowNeverLivesCheaperThanTheObligatoryOne() {
    let result = IncomeLoss.check(
      cushionE4: rub(10_000), obligatoryMonthlyE4: rub(60_000), usualMonthlyE4: rub(40_000),
      months: 2)
    #expect(result.asUsual.monthlyE4 == rub(60_000))
    #expect(
      IncomeLoss.check(
        cushionE4: .zero, obligatoryMonthlyE4: .zero, usualMonthlyE4: .zero, months: 3
      ).tightenedBelt.monthsLasting == nil)
  }

  // MARK: - «Хватит ли?»

  let today = DateOnly(year: 2026, month: 10, day: 20)

  func input(
    amount: Int64, free: Int64, surplus: Int64 = 0, cushion: Int64 = 0, target: Int64 = 0,
    counts: Bool = false, goals: [AffordCheck.Goal] = [], income: DateOnly? = nil
  ) -> AffordCheck.Input {
    AffordCheck.Input(
      amountE4: rub(amount), freeE4: rub(free), monthlySurplusE4: rub(surplus),
      cushionE4: rub(cushion), cushionTargetE4: rub(target), freeCountsCushion: counts,
      goals: goals, today: today, nextIncomeDay: income)
  }

  @Test func yesWhenItIsFreeAndNothingIsTouched() {
    let result = AffordCheck.check(input(amount: 30_000, free: 100_000))
    #expect(result.verdict == .yes)
    #expect(result.shortfallE4 == .zero)
  }

  @Test func yesButAGoalMovesWhenThePurchaseEatsItsPlan() {
    let goals = [
      AffordCheck.Goal(name: "Отпуск", monthlyPlanE4: rub(20_000)),
      AffordCheck.Goal(name: "Машина", monthlyPlanE4: rub(30_000)),
    ]
    let result = AffordCheck.check(input(amount: 40_000, free: 100_000, goals: goals))
    // 100 000 free, 50 000 of it planned for the goals: 50 000 spare cover 40 000.
    #expect(result.verdict == .yes)
    let tight = AffordCheck.check(input(amount: 70_000, free: 100_000, goals: goals))
    #expect(tight.verdict == .yesGoalsShift)
    #expect(tight.goalShifts == [AffordCheck.GoalShift(name: "Машина", months: 1)])
    let both = AffordCheck.check(input(amount: 100_000, free: 100_000, goals: goals))
    #expect(both.goalShifts.map(\.name) == ["Отпуск", "Машина"], "in the owner's order")
  }

  @Test func yesButTheCushionFallsBelowItsTargetWhenTheFreeMoneyCountsIt() {
    let result = AffordCheck.check(
      input(amount: 60_000, free: 200_000, cushion: 150_000, target: 150_000, counts: true))
    // 200 000 free, 150 000 of it the cushion: 50 000 spare, 10 000 come from the cushion.
    #expect(result.verdict == .yesCushionBelowTarget)
    #expect(result.cushionAfterE4 == rub(140_000))
    let ok = AffordCheck.check(
      input(amount: 40_000, free: 200_000, cushion: 150_000, target: 150_000, counts: true))
    #expect(ok.verdict == .yes)
    let outside = AffordCheck.check(
      input(amount: 60_000, free: 200_000, cushion: 150_000, target: 150_000, counts: false))
    #expect(outside.verdict == .yes, "a free sum without the cushion never touches it")
  }

  @Test func notEnoughSaysHowMuchAndUntilWhen() {
    let day = DateOnly(year: 2026, month: 10, day: 25)
    let result = AffordCheck.check(input(amount: 100_000, free: 66_000, income: day))
    #expect(result.verdict == .notEnough)
    #expect(result.shortfallE4 == rub(34_000))
    #expect(result.shortUntil == day)
    #expect(result.waitUntil == nil)
  }

  @Test func yesIfWaitedWhenTheMonthsLeaveASurplus() {
    let result = AffordCheck.check(input(amount: 100_000, free: 40_000, surplus: 25_000))
    #expect(result.verdict == .yesIfWait)
    #expect(result.shortfallE4 == rub(60_000))
    #expect(result.waitUntil == MonthKey(year: 2026, month: 10).adding(months: 3))
  }

  @Test func theCheckNeverOffersALoan() {
    for verdict in [
      AffordCheck.Verdict.yes, .yesGoalsShift, .yesCushionBelowTarget, .notEnough, .yesIfWait,
    ] {
      #expect(!verdict.rawValue.lowercased().contains("loan"))
      #expect(!verdict.rawValue.lowercased().contains("credit"))
    }
  }
}
