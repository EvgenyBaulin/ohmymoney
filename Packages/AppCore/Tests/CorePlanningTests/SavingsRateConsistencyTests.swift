import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("One savings rate for the overview and planning")
struct SavingsRateConsistencyTests: SavingsFixtures {
  private let today = DateOnly(year: 2026, month: 9, day: 19)
  private let main = PaymentMethod(name: "Main")
  private let cushion = PaymentMethod(name: "Cushion", cushion: true)
  private let deposit = PaymentMethod(
    name: "Deposit", interest: DepositTerms(rate: 10, period: .monthly))

  private func transfer(
    _ day: String, _ amount: String, from: PaymentMethod, to: PaymentMethod,
    currency: CurrencyCode = .rub
  ) -> Transfer {
    Transfer(
      occurredAt: noon(day), fromAccountId: from.id, fromCurrency: currency,
      fromAmountE4: rub(amount), toAccountId: to.id, toCurrency: currency,
      toAmountE4: rub(amount))
  }

  private func ledger(_ book: SavingsBook, transfers: [Transfer]) -> Ledger {
    Ledger(
      dataset: Dataset(
        entries: book.entries, categories: book.categories,
        paymentMethods: [main, cushion, deposit], transfers: transfers), calendar: .utc)
  }

  @Test func goalsCushionAndDepositsGiveTheSameRateEverywhere() {
    var book = SavingsBook()
    book.income("2026-09-05", "60000")
    book.income("2026-10-03", "40000", for: "2026-09")
    book.contribute("2026-09-06", "10000", goal: uid(500))
    book.withdraw("2026-09-10", "2000", goal: uid(500))
    let ledger = ledger(
      book,
      transfers: [
        transfer("2026-09-07", "20000", from: main, to: cushion),
        transfer("2026-09-08", "5000", from: cushion, to: main),
        transfer("2026-09-09", "30000", from: main, to: deposit),
        transfer("2026-09-10", "5000", from: deposit, to: main),
        transfer("2026-09-11", "7000", from: cushion, to: deposit),
        transfer("2026-09-12", "9000", from: main, to: main),
        transfer("2026-08-31", "1000", from: main, to: cushion),
        transfer("2026-10-01", "1000", from: deposit, to: main),
      ])
    let rate = SavingsRate.month(ledger: ledger, month: today.monthKey, targetBp: 4_000)
    let tile = OverviewFigures(ledger: ledger, today: today).savings
    let advice = AdviceRules.savingsRate(thisMonth: rate, lastMonth: rate)
    #expect(rate.rateBp == 4_800)
    #expect(rate.status == .onTarget)
    #expect(tile.goals == rub("8000"))
    #expect(tile.accounts == rub("40000"))
    #expect(tile.saved == rub("48000"))
    #expect(tile.income == rate.income)
    #expect(tile.basisPoints == rate.rateBp)
    #expect(advice.terms.first?.value == .money(tile.saved))
    #expect(advice.result?.value == .basisPoints(4_800))

    let inputs = CanSaveInputs(
      ledger: ledger, today: today,
      income: IncomeEstimate.month(ledger: ledger, statuses: [], today: today),
      plannedStillDue: .zero,
      remainder: MonthForecast.Remainder(
        p10: .zero, middle: .zero, p90: .zero, lowData: false, computedFor: today,
        daysLeft: 11, windowDays: 90))
    #expect(inputs.alreadySaved == tile.saved)
    let planning = PlanningSnapshot.build(
      ledger: ledger, today: today, now: noon("2026-09-19"), rubPerUnit: [:])
    let report = AdviceBook.build(
      planning: planning, ledger: ledger, remainder: inputs.remainder, today: today)
    #expect(report.canSave.alreadySaved == tile.saved)
    #expect(report.savingsRate.rateBp == tile.basisPoints)
    #expect(
      report.items.first { $0.kind == .savingsRate }?.result?.value == .basisPoints(4_800))
  }

  @Test func aLinkedGoalWithdrawalBelongsToTheMonthItHappens() {
    var book = SavingsBook()
    book.income("2026-08-05", "100000")
    book.income("2026-09-05", "100000")
    book.contribute("2026-08-06", "10000", goal: uid(500))
    let purchasePart = book.entries[2].parts[0].id
    book.withdraw("2026-09-10", "2000", goal: uid(500))
    book.entries[3].parts[0].refundOfPartId = purchasePart
    let ledger = book.ledger
    let september = OverviewFigures(ledger: ledger, today: today).savings
    let august = OverviewFigures(ledger: ledger, today: today.monthKey.previous.lastDay).savings
    #expect(september.saved == rub("-2000"))
    #expect(september.basisPoints == -200)
    #expect(august.saved == rub("10000"))
    #expect(august.basisPoints == 1_000)
    #expect(
      september.basisPoints
        == SavingsRate.month(ledger: ledger, month: today.monthKey, targetBp: 1_000).rateBp)
  }

  @Test func theWholeAttributedMonthIsUsedByBothCallers() {
    var book = SavingsBook()
    book.income("2026-09-05", "60000")
    book.income("2026-10-03", "40000", for: "2026-09")
    book.contribute("2026-09-25", "10000", goal: uid(500))
    let rate = SavingsRate.month(ledger: book.ledger, month: today.monthKey, targetBp: 1_000)
    let tile = OverviewFigures(ledger: book.ledger, today: today).savings
    #expect(tile.basisPoints == 1_000)
    #expect(tile.basisPoints == rate.rateBp)
  }

  @Test func withdrawalsCanMakeTheRateNegativeAndNoIncomeLeavesItAbsent() {
    var book = SavingsBook()
    book.income("2026-09-05", "100000")
    let out = transfer("2026-09-10", "5000", from: cushion, to: main)
    let withIncome = ledger(book, transfers: [out])
    let rate = SavingsRate.month(ledger: withIncome, month: today.monthKey, targetBp: 1_000)
    #expect(rate.rateBp == -500)
    #expect(rate.status == .belowTarget)
    #expect(OverviewFigures(ledger: withIncome, today: today).savings.basisPoints == -500)
    let withoutIncome = ledger(SavingsBook(), transfers: [out])
    let absent = SavingsRate.month(ledger: withoutIncome, month: today.monthKey, targetBp: 1_000)
    #expect(absent.rateBp == nil)
    #expect(absent.status == .notEnoughData)
    #expect(OverviewFigures(ledger: withoutIncome, today: today).savings.basisPoints == nil)
  }

  @Test func foreignTransfersAreLeftOutEqually() {
    var book = SavingsBook()
    book.income("2026-09-05", "100000")
    let ledger = ledger(
      book,
      transfers: [
        transfer("2026-09-10", "100", from: main, to: deposit, currency: CurrencyCode("USD"))
      ])
    let tile = OverviewFigures(ledger: ledger, today: today).savings
    #expect(tile.leftOutForeign == 1)
    #expect(tile.saved == .zero)
    #expect(
      tile.basisPoints
        == SavingsRate.month(ledger: ledger, month: today.monthKey, targetBp: 1_000).rateBp)
  }
}
