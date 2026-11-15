import CoreAccounting
import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation
import Testing

@Suite("Recorded capital events")
struct CapitalEventsTests {
  typealias Fx = CapitalFx

  @Test func purchaseSaleAndPayoffKeepTheirDatesAndAmounts() {
    let account = PaymentMethod(id: Fx.id(1), name: "Account")
    let (count, rows) = Fx.count(1, "2025-12-01", [(account.id, .rub, "900000")])
    let sale = Fx.operation(1, "2026-10-02", "2100000", kind: .income, method: account.id)
    let item = OwnedItem(
      id: Fx.id(2), name: "Car", boughtOn: Fx.day("2025-12-15"),
      priceE4: Fx.rub("2400000"), soldOn: Fx.day("2026-10-02"),
      saleTransactionId: sale.id)
    let debt = Debt(
      id: Fx.id(3), direction: .iOwe, type: .loan, name: "Car loan", closed: true)
    let journal = [
      DebtEntry(
        id: Fx.id(4), debtId: debt.id, date: Fx.day("2025-12-10"),
        amountE4: Fx.rub("1500000"), kind: .borrowed,
        paymentMethodId: account.id, occurredAt: Fx.noon("2025-12-10")),
      DebtEntry(
        id: Fx.id(5), debtId: debt.id, date: Fx.day("2026-10-03"),
        amountE4: -Fx.rub("1500000"), kind: .payment),
    ]
    var dataset = Dataset(
      entries: [sale], paymentMethods: [account], debts: [debt],
      planning: PlanningBook(
        reconciliations: [count], debtEntries: journal, reconciledBalances: rows),
      ownedItems: [item])
    dataset.thingValuations = [
      ThingValuation(
        owner: .ownedItem, ownerId: item.id, day: Fx.day("2025-12-15"),
        amountE4: Fx.rub("2400000"), currency: .rub)
    ]
    let capital = Fx.capital(dataset, today: Fx.day("2026-10-11"), months: nil)
    #expect(capital.events.map(\.kind) == [.loanOpened, .purchase, .sale, .loanClosed])
    #expect(
      capital.events.map(\.day) == [
        Fx.day("2025-12-10"), Fx.day("2025-12-15"),
        Fx.day("2026-10-02"), Fx.day("2026-10-03"),
      ])
    #expect(
      capital.events.map(\.amountE4) == [
        Fx.rub("1500000"), Fx.rub("2400000"), Fx.rub("2100000"), Fx.rub("1500000"),
      ])
    #expect(capital.events.first?.name == "Car loan")
  }

  @Test func anExistingBalanceIsNotALoanOriginationAndAnAdjustmentIsNotAPayoff() {
    let debt = Debt(direction: .iOwe, type: .loan, name: "Existing", closed: true)
    let lines = [
      DebtEntry(
        debtId: debt.id, date: Fx.day("2026-10-01"),
        amountE4: Fx.rub("1290000"), kind: .borrowed),
      DebtEntry(
        debtId: debt.id, date: Fx.day("2026-10-02"),
        amountE4: -Fx.rub("1290000"), kind: .adjustment),
    ]
    let dataset = Dataset(debts: [debt], planning: PlanningBook(debtEntries: lines))
    #expect(Fx.capital(dataset, today: Fx.day("2026-10-11")).events.isEmpty)
  }

  @Test func chartGroupsSameDayEventsAndKeepsExactDaysWithoutFloatingPointMoney() {
    let day = Fx.day("2026-09-15")
    let events = [
      CapitalEvent(
        id: "purchase", kind: .purchase, day: day, name: "Car",
        amountE4: Fx.rub("2400000"), currency: .rub),
      CapitalEvent(
        id: "loan", kind: .loanOpened, day: day, name: "Loan",
        amountE4: Fx.rub("1500000"), currency: .rub),
    ]
    let points = [
      CapitalPoint(day: Fx.day("2026-08-31"), isNow: false, accountsRub: Fx.rub("100")),
      CapitalPoint(day: Fx.day("2026-09-30"), isNow: false, accountsRub: Fx.rub("160")),
    ]
    let model = NetWorthChartModel(points, events: events)
    #expect(model.events.count == 1)
    #expect(model.events.first?.events == events)
    #expect(model.events.first?.net == 130)
    #expect(model.events.first?.position == NetWorthChartModel.position(of: day))
    #expect(model.events.first?.position != model.points.last?.position)
    #expect(NetWorthChartModel(points, events: events).points == NetWorthChartModel(points).points)
  }

  @Test func hiddenAccountsAndEventsOutsideTheDrawnDaysAreExcluded() {
    let hidden = Fx.id(9)
    let points = [
      CapitalPoint(day: Fx.day("2026-09-30"), isNow: false),
      CapitalPoint(day: Fx.day("2026-10-11"), isNow: true),
    ]
    let events = [
      CapitalEvent(
        id: "hidden", kind: .loanOpened, day: Fx.day("2026-10-01"), name: "Hidden",
        amountE4: Fx.rub("1"), currency: .rub, accountIds: [hidden]),
      CapitalEvent(
        id: "old", kind: .purchase, day: Fx.day("2025-12-15"), name: "Old",
        amountE4: Fx.rub("2400000"), currency: .rub),
      CapitalEvent(
        id: "future", kind: .sale, day: Fx.day("2026-10-12"), name: "Future",
        amountE4: Fx.rub("2100000"), currency: .rub),
    ]
    let chart = NetWorthChartModel(points, events: events, hiding: HiddenAccounts(ids: [hidden]))
    #expect(chart.events.isEmpty)
    #expect(chart.nearest(to: NetWorthChartModel.position(of: Fx.day("2026-10-10")))?.isNow == true)
    #expect(NetWorthChartModel([]).domain == 0...1)
  }

  @Test func anAdjustmentOnThePayoffDayDoesNotBecomeARepaidLoan() {
    let debt = Debt(direction: .iOwe, type: .loan, name: "Written off", closed: true)
    let lines = [
      DebtEntry(
        debtId: debt.id, date: Fx.day("2026-10-01"),
        amountE4: Fx.rub("100"), kind: .borrowed),
      DebtEntry(
        debtId: debt.id, date: Fx.day("2026-10-02"),
        amountE4: -Fx.rub("1"), kind: .payment),
      DebtEntry(
        debtId: debt.id, date: Fx.day("2026-10-02"),
        amountE4: -Fx.rub("99"), kind: .adjustment),
    ]
    let dataset = Dataset(debts: [debt], planning: PlanningBook(debtEntries: lines))
    #expect(Fx.capital(dataset, today: Fx.day("2026-10-11")).events.isEmpty)
  }
}
