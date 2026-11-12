import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// A debt whose pause covers today takes nothing from the month's load of payments.
@Suite("The debt load skips a paused debt")
struct PausedDebtLoadTests {
  let pause = DebtPause(
    from: DateOnly(year: 2027, month: 2, day: 1), to: DateOnly(year: 2027, month: 3, day: 31),
    kind: .holiday)

  func debt(_ name: String, pause: DebtPause? = nil) -> Debt {
    Debt(
      direction: .iOwe, type: .loan, name: name, monthlyPaymentE4: AmountE4(whole: 10_000),
      paymentDay: 10, pause: pause)
  }

  @Test func aPausedDebtAddsNothingInsideItsPauseAndItsPaymentOutside() {
    let paused = debt("Paused", pause: pause)
    let plain = debt("Plain")
    let inside = DebtLoad.monthlyPayments(
      of: [paused, plain], rubPerUnit: [:], today: DateOnly(year: 2027, month: 2, day: 15))
    #expect(inside.total == AmountE4(whole: 10_000))
    #expect(inside.withoutPayment.isEmpty)
    let outside = DebtLoad.monthlyPayments(
      of: [paused, plain], rubPerUnit: [:], today: DateOnly(year: 2027, month: 4, day: 1))
    #expect(outside.total == AmountE4(whole: 20_000))
    let unaware = DebtLoad.monthlyPayments(of: [paused, plain], rubPerUnit: [:])
    #expect(unaware.total == AmountE4(whole: 20_000))
  }
}

/// A paused debt asks nothing in the planned month and the plan of the free sum while the pause
/// lasts, and asks again in the first month after it — through the very figures those screens read.
@Suite("A paused debt is left out of the plan and comes back after the pause")
struct PausedDebtPlanTests {
  typealias Fx = CashFx

  /// A loan of 40,000 taken on 20 August, paid 8,000 on the 5th: five dues from 5 September.
  func book(pause: DebtPause?) -> CashFx {
    var fx = Fx()
    let loan = Debt(
      id: CashFx.id(306), direction: .iOwe, type: .loan, name: "Loan",
      monthlyPaymentE4: CashFx.money("8000"), paymentDay: 5, pause: pause)
    fx.debts = [loan]
    fx.debtEntries = [
      DebtEntry(
        debtId: loan.id, date: Fx.day("2026-08-20"), amountE4: Fx.money("40000"), kind: .borrowed)
    ]
    return fx
  }

  let october = DebtPause(
    from: DateOnly(iso: "2026-10-01")!, to: DateOnly(iso: "2026-11-30")!, kind: .holiday)

  @Test func theDuesInsideThePauseAreNotInThePlan() {
    let plain = book(pause: nil)
    let paused = book(pause: october)
    let without = plain.plan(until: "2026-11-30").debts
    let with = paused.plan(until: "2026-11-30").debts
    // October's and November's payments, 8,000 each, are gone.
    #expect(without - with == Fx.money("16000"))
    // December's comes back after the pause.
    #expect(
      paused.plan(until: "2026-12-31").debts - with == Fx.money("8000"))
  }

  @Test func theNextPaymentOfTheCardSkipsThePause() {
    let paused = book(pause: DebtPause(
      from: DateOnly(iso: "2026-09-01")!, to: DateOnly(iso: "2026-10-31")!))
    let line = paused.snapshot().debts.iOwe.first
    #expect(line?.nextPayment == Fx.day("2026-11-05"))
    #expect(book(pause: nil).snapshot().debts.iOwe.first?.nextPayment == Fx.day("2026-09-05"))
  }
}
