import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("Can save this month and the savings rate")
struct CanSaveTests: SavingsFixtures {
  let today = DateOnly(year: 2026, month: 9, day: 19)

  func income(_ value: String?, lowData: Bool = false) -> MonthIncomeEstimate {
    MonthIncomeEstimate(
      month: today.monthKey, received: rub("60000"), expectedRemaining: rub("40000"),
      median3: nil, monthsInMedian: 0, value: value.map(rub),
      source: value == nil ? .receivedOnly : .expectations, lowData: lowData)
  }

  func remainder(
    p10: String, middle: String, p90: String, lowData: Bool = false
  )
    -> MonthForecast.Remainder
  {
    MonthForecast.Remainder(
      p10: rub(p10), middle: rub(middle), p90: rub(p90), lowData: lowData, computedFor: today,
      daysLeft: 11, windowDays: 90)
  }

  /// The «can save» formula: income 100 000 (60 000 received + 40 000 expected) − planned
  /// 15 000 (a subscription 5 000 and a loan 10 000 still due) − variable spending at P50,
  /// which is 30 000 spent + 20 000 to come. P50 = 35 000; with the rest of the month at its
  /// P90 of 31 000 — 24 000, at its P10 of 12 000 — 43 000. 10 000 saved already, so
  /// 25 000 more can go.
  @Test func matchesTheFormula() {
    let result = CanSave(
      CanSaveInputs(
        income: income("100000"), spentWithoutGoals: rub("30000"), plannedStillDue: rub("15000"),
        remainder: remainder(p10: "12000", middle: "20000", p90: "31000"),
        alreadySaved: rub("10000")))
    #expect(result.status == .ready)
    #expect(result.p50 == rub("35000"))
    #expect(result.low == rub("24000"))
    #expect(result.high == rub("43000"))
    #expect(result.alreadySaved == rub("10000"))
    #expect(result.canSaveMore == rub("25000"))
    #expect(!result.lowData)
    #expect(
      result.lines.map(\.key) == [
        "advice.canSave.income", "advice.canSave.spent", "advice.canSave.planned",
        "advice.canSave.variable",
      ])
    #expect(result.lines.map(\.amount) == ["100000", "30000", "15000", "20000"].map(rub))
    #expect(AmountE4.sum(result.lines.map(\.signedAmount)) == result.p50)
  }

  /// No income estimate — no advice, only the reason.
  @Test func withoutIncomeThereIsNotEnoughData() {
    let result = CanSave(
      CanSaveInputs(
        income: income(nil, lowData: true), spentWithoutGoals: rub("30000"),
        plannedStillDue: .zero, remainder: remainder(p10: "1", middle: "2", p90: "3"),
        alreadySaved: rub("500")))
    #expect(result.status == .notEnoughData(reasonKey: "advice.reason.noIncome"))
    #expect(result.p50 == nil)
    #expect(result.low == nil)
    #expect(result.high == nil)
    #expect(result.canSaveMore == nil)
    #expect(result.lines.isEmpty)
    #expect(result.alreadySaved == rub("500"))
    #expect(result.lowData)
  }

  /// Spending more than the month brings: P50 = 100 000 − 90 000 − 15 000 − 20 000 =
  /// −25 000, nothing more can be saved. A skewed history with P10 above the middle keeps
  /// the range around P50: high = max(−5 000 − 25 000, −25 000) = −25 000; low = −5 000 −
  /// 40 000 = −45 000.
  @Test func anOverspentMonthCanSaveNothingMore() {
    let result = CanSave(
      CanSaveInputs(
        income: income("100000"), spentWithoutGoals: rub("90000"), plannedStillDue: rub("15000"),
        remainder: remainder(p10: "25000", middle: "20000", p90: "40000", lowData: true),
        alreadySaved: rub("3000")))
    #expect(result.p50 == rub("-25000"))
    #expect(result.canSaveMore == .zero)
    #expect(result.high == rub("-25000"))
    #expect(result.low == rub("-45000"))
    #expect(result.lowData)
  }

  /// From the ledger: groceries 3 000 on the 5th (the 1 000 on the 25th has not happened,
  /// August's 500 is last month), a contribution of 10 000 and a withdrawal of 2 000 — spent
  /// without goals 3 000, already saved 8 000.
  @Test func theLedgerFiguresLeaveGoalsOutOfSpending() {
    var book = SavingsBook()
    book.expense("2026-08-30", "500")
    book.expense("2026-09-05", "3000")
    book.contribute("2026-09-06", "10000", goal: uid(500))
    book.withdraw("2026-09-10", "2000", goal: uid(500))
    book.expense("2026-09-25", "1000")
    let inputs = CanSaveInputs(
      ledger: book.ledger, today: today, income: income("100000"), plannedStillDue: .zero,
      remainder: remainder(p10: "0", middle: "0", p90: "0"))
    #expect(inputs.spentWithoutGoals == rub("3000"))
    #expect(inputs.alreadySaved == rub("8000"))
  }

  // MARK: - Savings rate

  /// September: 100 000 of income (40 000 of it arriving on 3 October, marked «for
  /// September»), 10 000 − 2 000 into goals: 8 000 ÷ 100 000 = 800 bp, below a 10 % target
  /// and above a 5 % one. October has no income yet: no rate.
  @Test func savingsRateIsGoalsOverIncome() {
    var book = SavingsBook()
    book.income("2026-09-05", "60000")
    book.income("2026-10-03", "40000", for: "2026-09")
    book.contribute("2026-09-06", "10000", goal: uid(500))
    book.withdraw("2026-09-10", "2000", goal: nil, category: book.goalsRoot)
    book.expense("2026-09-07", "5000")
    let ledger = book.ledger
    let september = MonthKey(year: 2026, month: 9)

    let rate = SavingsRate.month(ledger: ledger, month: september, targetBp: 1_000)
    #expect(rate.goalsNet == rub("8000"))
    #expect(rate.income == rub("100000"))
    #expect(rate.rateBp == 800)
    #expect(rate.status == .belowTarget)
    #expect(SavingsRate.month(ledger: ledger, month: september, targetBp: 500).status == .onTarget)

    let october = SavingsRate.month(ledger: ledger, month: september.next, targetBp: 1_000)
    #expect(october.rateBp == nil)
    #expect(october.status == .notEnoughData)
  }
}
