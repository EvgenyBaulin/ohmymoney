import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("The configured free sum")
struct ConfiguredFreeMoneyTests {
  typealias Fx = CashFx

  private func fixture() -> Fx {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "41600")], at: Fx.at("2026-09-18", 12))
    fx.scheduled = [
      Fx.payment(1, "Internet", "2000", day: 25, next: "2026-09-25"),
      Fx.payment(2, "Rent", "10000", day: 5, next: "2026-10-05"),
      Fx.payment(3, "Later", "9000", day: 19, next: "2026-10-19"),
    ]
    return fx
  }

  @Test func thirtyDaysWithoutIncomeCrossesTheMonthBoundary() {
    let fx = fixture()
    let free = fx.snapshot().configuredFreeMoney(ledger: fx.ledger)
    #expect(free.days == 30)
    #expect(free.until == Fx.day("2026-10-18"))
    #expect(free.grey == Fx.money("29600"))
    #expect(free.dailyGuide == Fx.money("986.6667"))
  }

  @Test func incomeInsideThirtyDaysDoesNotAddMoneyOrShortenTheWindow() {
    var fx = fixture()
    fx.expected = [
      ExpectedIncome(name: "Salary", totalE4: Fx.money("100000"), dueDate: Fx.day("2026-09-25"))
    ]
    fx.add(.income, "100000", at: Fx.at("2026-09-25", 12), category: Fx.salary)
    let free = fx.snapshot().configuredFreeMoney(ledger: fx.ledger)
    #expect(free.days == 30)
    #expect(free.grey == Fx.money("29600"))
  }

  @Test func nearestIncomeIncludesPaymentsOnItsDay() {
    var fx = fixture()
    fx.settings.freeMoneyHorizon = .nearestIncome
    fx.expected = [
      ExpectedIncome(name: "Later", totalE4: Fx.money("200000"), dueDate: Fx.day("2026-10-05")),
      ExpectedIncome(name: "Salary", totalE4: Fx.money("100000"), dueDate: Fx.day("2026-09-25")),
    ]
    let free = fx.snapshot().configuredFreeMoney(ledger: fx.ledger)
    #expect(free.until == Fx.day("2026-09-25"))
    #expect(free.days == 7)
    #expect(free.grey == Fx.money("39600"))
  }

  @Test func nearestIncomeWithoutAnIncomeFallsBackToThirtyDays() {
    var fx = fixture()
    fx.settings.freeMoneyHorizon = .nearestIncome
    #expect(fx.snapshot().configuredFreeMoney(ledger: fx.ledger).days == 30)
  }

  @Test func receivedAndClosedIncomesDoNotEndTheWindow() {
    var fx = fixture()
    fx.settings.freeMoneyHorizon = .nearestIncome
    let received = ExpectedIncome(
      id: Fx.id(601), name: "Already received", totalE4: Fx.money("1000"),
      dueDate: Fx.day("2026-09-20"))
    let transaction = fx.add(.income, "1000", at: Fx.at("2026-09-18", 14), category: Fx.salary)
    fx.expectedLinks = [
      ExpectedIncomeLink(expectedIncomeId: received.id, transactionId: transaction)
    ]
    fx.expected = [
      received,
      ExpectedIncome(
        name: "Closed", totalE4: Fx.money("1000"), dueDate: Fx.day("2026-09-21"), closed: true),
      ExpectedIncome(name: "Salary", totalE4: Fx.money("100000"), dueDate: Fx.day("2026-09-25")),
    ]
    #expect(fx.snapshot().configuredFreeMoney(ledger: fx.ledger).until == Fx.day("2026-09-25"))
  }

  @Test func nearestIncomeWorksForOneMonthlySalaryAcrossTheYearBoundary() {
    var fx = fixture()
    fx.settings.freeMoneyHorizon = .nearestIncome
    fx.expected = [
      ExpectedIncome(
        name: "Salary", kind: .recurring, totalE4: Fx.money("100000"),
        dueDate: Fx.day("2026-01-05"), freq: .monthly, day: 5)
    ]
    let today = Fx.day("2026-12-31")
    let free = fx.snapshot(today: today, now: Fx.at("2026-12-31", 12))
      .configuredFreeMoney(ledger: fx.ledger)
    #expect(free.until == Fx.day("2027-01-05"))
    #expect(free.days == 6)
  }

  @Test func thirtyDaysIncludeTodayEvenOnTheLastDayOfAMonth() {
    let fx = fixture()
    let free = fx.snapshot(today: Fx.day("2028-02-29"), now: Fx.at("2028-02-29", 12))
      .configuredFreeMoney(ledger: fx.ledger)
    #expect(free.days == 30)
    #expect(free.until == Fx.day("2028-03-29"))
  }

  @Test func cushionIsSubtractedByDefaultAndCanBeIncluded() {
    let fx = fixture()
    var dataset = fx.ledger.dataset
    dataset.paymentMethods[0].cushion = true
    for excluded in [true, false] {
      dataset.capitalSettings = CapitalSettings(outOfFreeMoney: excluded)
      let ledger = Ledger(dataset: dataset, calendar: .utc)
      let snapshot = PlanningSnapshot.build(
        ledger: ledger, today: Fx.today, now: Fx.now, rubPerUnit: fx.rubPerUnit)
      let free = snapshot.configuredFreeMoney(ledger: ledger)
      #expect(free.cushion == (excluded ? Fx.money("41600") : .zero))
      #expect(free.grey == Fx.money(excluded ? "-12000" : "29600"))
    }
    #expect(CapitalSettings.standard.outOfFreeMoney)
    #expect(CapitalSettings(storedValues: [:]).outOfFreeMoney)
    #expect(!CapitalSettings(storedValues: [CapitalSettings.outOfFreeMoneyKey: "0"]).outOfFreeMoney)
  }

  @Test func dailyRublesUseDecimalAndNeverRoundToTens() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "41580")], at: Fx.at("2026-09-18", 12))
    let free = fx.snapshot().configuredFreeMoney(ledger: fx.ledger)
    #expect(free.dailyGuide == Fx.money("1386"))
    #expect(free.dailyRubles == 1386)
  }

  @Test(arguments: [("41594.9999", Int64(1386)), ("41595", Int64(1387))])
  func dailyRublesRoundOnlyAfterDecimalDivision(_ amount: String, _ rubles: Int64) {
    var fx = Fx()
    fx.count([(Fx.main, .rub, amount)], at: Fx.at("2026-09-18", 12))
    let free = fx.snapshot().configuredFreeMoney(ledger: fx.ledger)
    #expect(free.dailyRubles == rubles)
  }
}
