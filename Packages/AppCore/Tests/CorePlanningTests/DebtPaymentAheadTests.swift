import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// A payment of a debt written for a later day pays nothing before its day: the money now still
/// holds it, so until then the due is still owed — even when that payment will pay the debt off.
/// Counting it as paid at once took the debt out of the free sum while its money was still on
/// the account, and the free sum handed those 8 000 out a second time.
@Suite("A debt payment written ahead is still to be paid")
struct DebtPaymentAheadTests {
  typealias Fx = CashFx

  /// 8 000 left, 8 000 a month on the 25th; on the 19th the payment of the 25th is written
  /// ahead. Through the end of September the free sum still holds back 8 000, the due is not
  /// paid before its day, and on the 25th it is.
  @Test func aPaymentAheadThatPaysTheDebtOffStillHoldsItsDueBack() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-10", 14))
    let loan = Debt(
      id: Fx.id(301), direction: .iOwe, type: .loan, name: "Loan",
      monthlyPaymentE4: Fx.money("8000"), paymentDay: 25, paymentsAreExpenses: true)
    fx.debts = [loan]
    fx.debtEntries = [
      DebtEntry(
        id: Fx.id(310), debtId: loan.id, date: Fx.day("2026-09-01"),
        amountE4: Fx.money("8000"), kind: .borrowed)
    ]
    let payment = fx.add(.expense, "8000", at: Fx.at("2026-09-25", 9), debt: loan.id)
    fx.debtEntries.append(
      DebtEntry(
        id: Fx.id(311), debtId: loan.id, date: Fx.day("2026-09-25"),
        amountE4: Fx.money("-8000"), kind: .payment, transactionId: payment))

    #expect(fx.plan(until: "2026-09-30").debts == Fx.money("8000"))
    let line = fx.snapshot().debts.iOwe.first
    #expect(line?.nextPayment == Fx.day("2026-09-25"), "the due waits for the payment's day")
    let onTheDay = fx.snapshot(today: Fx.day("2026-09-25"), now: Fx.at("2026-09-25", 12))
    #expect(onTheDay.debts.iOwe.first?.nextPayment == nil, "paid off on its day")
  }
}
