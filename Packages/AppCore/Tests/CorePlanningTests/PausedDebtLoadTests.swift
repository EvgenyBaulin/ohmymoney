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
