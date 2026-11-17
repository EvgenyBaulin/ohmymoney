import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("Planning recommendations")
struct RecommendationRegressionTests {
  private let today = DateOnly(year: 2026, month: 11, day: 17)

  @Test func negativeFreeMoneyIsPartOfThePurchaseShortfall() {
    let result = AffordCheck.check(
      .init(
        amountE4: AmountE4(whole: 500), freeE4: AmountE4(whole: -3_000), today: today))
    #expect(result.shortfallE4 == AmountE4(whole: 3_500))
    #expect(result.verdict == .notEnough)
  }

  @Test func waitingMustCoverTheDeficitAndThePurchase() {
    let result = AffordCheck.check(
      .init(
        amountE4: AmountE4(whole: 500), freeE4: AmountE4(whole: -3_000),
        monthlySurplusE4: AmountE4(whole: 1_000), today: today))
    #expect(result.waitUntil == today.monthKey.adding(months: 4))
    #expect(result.shortfallE4 == AmountE4(whole: 3_500))
  }

  @Test func aNonpositiveSurplusPromisesNoRecoveryDate() {
    for surplus in [Int64(0), -1_000] {
      let result = AffordCheck.check(
        .init(
          amountE4: AmountE4(whole: 500), freeE4: AmountE4(whole: -3_000),
          monthlySurplusE4: AmountE4(whole: surplus), today: today))
      #expect(result.verdict == .notEnough)
      #expect(result.waitUntil == nil)
      #expect(result.shortfallE4 == AmountE4(whole: 3_500))
    }
  }

  @Test func aSmallPurchaseDoesNotPauseWhenFreeMoneyIsNegative() {
    #expect(
      !PurchasePause.check(
        amountRubE4: AmountE4(whole: 80), freeRubE4: AmountE4(whole: -3_000),
        settings: PurchaseSettings(pauseEnabled: true)
      ).shouldAsk)
    #expect(
      !PurchasePause.check(
        amountRubE4: AmountE4(whole: 1_000), freeRubE4: .zero,
        settings: PurchaseSettings(pauseEnabled: true)
      ).shouldAsk)
    #expect(
      PurchasePause.check(
        amountRubE4: AmountE4(whole: 1_001), freeRubE4: .zero,
        settings: PurchaseSettings(pauseEnabled: true)
      ).shouldAsk)
  }

  @Test func suggestedLimitsUseSixMonthsAndHundreds() {
    #expect(LimitSuggestions.months(before: today).count == 6)
    #expect(LimitSuggestions.minimumMonthsSpent == 3)
    #expect(LimitSuggestions.roundedUp(AmountE4(whole: 31_750)) == AmountE4(whole: 31_800))
    #expect(LimitSuggestions.roundedUp(AmountE4(whole: 1_001)) == AmountE4(whole: 1_100))
  }

  @Test func theSheetAndAdviceOfferTheSameSixMonthMedian() throws {
    let category = CoreKit.Category(kind: .expense, name: "Synthetic groceries")
    let amounts: [Int64] = [31_000, 29_000, 34_000, 33_000, 30_000, 32_500]
    let months = LimitSuggestions.months(before: today)
    let entries = zip(months, amounts).map { month, amount in
      let transaction = Transaction(
        kind: .expense,
        occurredAt: CalendarContext.utc.noon(of: month.firstDay), amountE4: AmountE4(whole: amount))
      return TransactionEntry(
        transaction: transaction,
        parts: [
          TransactionPart(
            transactionId: transaction.id, categoryId: category.id,
            amountE4: transaction.amountE4)
        ])
    }
    let ledger = Ledger(dataset: Dataset(entries: entries, categories: [category]), calendar: .utc)
    let suggestion = try #require(
      LimitSuggestions.suggestions(
        ledger: ledger, budgets: [], today: today
      ).first)
    let advice = try #require(
      AdviceRules.limitSuggestions(
        AdviceContext(ledger: ledger, today: today), budgets: []
      ).first)
    #expect(suggestion.median == AmountE4(whole: 31_750))
    #expect(suggestion.usual == AmountE4(whole: 31_800))
    #expect(suggestion.tenPercentLess == AmountE4(whole: 28_600))
    #expect(advice.result?.value == .money(suggestion.usual))
  }

  @Test func aDailyGuideBelowHalfTheUsualSpendingIsTight() {
    #expect(
      FreeVerdict(
        free: AmountE4(whole: 500), days: 30,
        usualDaily: AmountE4(whole: 1_500)) == .tight)
    #expect(
      FreeVerdict(
        free: .zero, days: 30,
        usualDaily: AmountE4(whole: 1_500)) == .tight)
    #expect(
      FreeVerdict(
        free: AmountE4(whole: 22_500), days: 30,
        usualDaily: AmountE4(whole: 1_500)) == .enough)
    #expect(
      FreeVerdict(
        free: AmountE4(whole: -1), days: 30,
        usualDaily: AmountE4(whole: 1_500)) == .short)
    #expect(FreeVerdict(free: .zero, days: 30, usualDaily: nil) == .enough)
  }

  @Test func aPauseUsesTheLargerOfTheDailyNormAndAThousand() {
    let settings = PurchaseSettings(pauseEnabled: true)
    #expect(
      !PurchasePause.check(
        amountRubE4: AmountE4(whole: 1_500), freeRubE4: .zero,
        settings: settings, usualDailyRubE4: AmountE4(whole: 2_000)
      ).shouldAsk)
    #expect(
      PurchasePause.check(
        amountRubE4: AmountE4(whole: 2_001), freeRubE4: .zero,
        settings: settings, usualDailyRubE4: AmountE4(whole: 2_000)
      ).shouldAsk)
  }

  @Test func aScenarioStartsAfterPlannedPaymentsAndUsesUsualSpending() {
    var snapshot = PlanningSnapshot.empty
    snapshot.freeMoney.moneyNow = AmountE4(whole: 20_000)
    snapshot.freeMoney.main = AmountE4(whole: 20_000)
    snapshot.freeMoney.grey = AmountE4(whole: -3_000)
    snapshot.affordSpending = AffordSpending(medianRub: AmountE4(whole: 105_000), fullMonths: 3)
    let base = ScenarioBaseline(snapshot: snapshot)
    #expect(base.freeMoneyE4 == AmountE4(whole: -3_000))
    #expect(base.spendingMonthlyE4 == AmountE4(whole: 105_000))
  }

  @Test func anIncomeLossUsesNecessitiesRatherThanTheUsualLifestyle() {
    let base = ScenarioBaseline(
      today: today, freeMoneyE4: AmountE4(whole: 100_000),
      incomeMonthlyE4: AmountE4(whole: 120_000), spendingMonthlyE4: AmountE4(whole: 105_000),
      obligatoryMonthlyE4: AmountE4(whole: 60_000))
    let run = ScenarioEngine.run(
      ScenarioSpec(
        changes: [.init(kind: .incomeLoss, months: 1)], horizonMonths: 2), from: base)
    #expect(run.points[1].freeE4 == AmountE4(whole: 40_000))
    #expect(run.points[2].freeE4 == AmountE4(whole: 55_000))
  }

  @Test func aMonthOfHistoryCanStartInTheMiddleOfAMonth() {
    let first = DateOnly(year: 2026, month: 10, day: 17)
    let entries = DayRange(first, today.adding(days: -1)).days.map { day in
      let transaction = Transaction(
        kind: .expense,
        occurredAt: CalendarContext.utc.noon(of: day), amountE4: AmountE4(whole: 1_500))
      return TransactionEntry(
        transaction: transaction,
        parts: [
          TransactionPart(transactionId: transaction.id, amountE4: transaction.amountE4)
        ])
    }
    let ledger = Ledger(dataset: Dataset(entries: entries), calendar: .utc)
    #expect(UsualDailySpending(ledger: ledger, today: today).average == AmountE4(whole: 1_500))
    #expect(UsualDailySpending(ledger: ledger, today: today.adding(days: -1)).average == nil)
  }

  @Test func dailySpendingRoundsHalfAwayFromZeroToStoredUnits() {
    let first = DateOnly(year: 2026, month: 9, day: 1)
    let today = DateOnly(year: 2026, month: 10, day: 1)
    for (total, rounded) in [(Int64(15), Int64(1)), (45, 2)] {
      let transaction = Transaction(
        kind: .expense, occurredAt: CalendarContext.utc.noon(of: first),
        amountE4: AmountE4(raw: total))
      let entry = TransactionEntry(
        transaction: transaction,
        parts: [
          TransactionPart(transactionId: transaction.id, amountE4: transaction.amountE4)
        ])
      let ledger = Ledger(dataset: Dataset(entries: [entry]), calendar: .utc)
      let daily = UsualDailySpending(ledger: ledger, today: today)
      #expect(daily.average == AmountE4(raw: rounded))
      #expect(daily.median == AmountE4(raw: rounded))
    }
  }
}
