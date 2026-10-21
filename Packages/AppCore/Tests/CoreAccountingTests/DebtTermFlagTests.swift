import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// «В этом месяце больше платежей не будет»: a payment of a debt may say that no more money goes
/// to this month's due, so the due closes although the payment is smaller than the monthly one.
/// The line of the journal carries it (`closesTerm`), the payment rules hand it on, and a line
/// that does not say anything does not close a due it did not pay.
@Suite("A payment that closes its term")
struct DebtTermFlagTests {
  @Test func aLineDoesNotCloseItsTermUnlessSaid() {
    let line = DebtRules.makeEntry(debtId: id(200), kind: .payment, amountE4: money(4000))
    #expect(line.closesTerm == false)
    let closing = DebtRules.makeEntry(
      debtId: id(200), kind: .payment, amountE4: money(4000), closesTerm: true)
    #expect(closing.closesTerm)
    #expect(closing.amountE4 == money(-4000), "the sign is the kind's, as ever")
  }

  @Test func aPaymentHandsTheFlagToItsLine() throws {
    let debt = existingDebt(subcategory: id(7))
    let plain = try DebtRules.payment(on: debt, amountE4: money(4000), transactionId: id(1))
    #expect(plain.entry.closesTerm == false)
    let closing = try DebtRules.payment(
      on: debt, amountE4: money(4000), transactionId: id(1), closesTerm: true)
    #expect(closing.entry.closesTerm)
    #expect(closing.entry.kind == .payment)
    #expect(closing.isExpense, "the flag changes nothing about what the payment is")
  }

  /// Only money paid toward a due can say the due is closed: a line of any other kind never
  /// carries the flag, whatever was asked.
  @Test func onlyAPaymentCanCloseATerm() {
    for kind in DebtEntryKind.allCases where kind != .payment {
      let line = DebtRules.makeEntry(
        debtId: id(200), kind: kind, amountE4: money(1000), closesTerm: true)
      #expect(line.closesTerm == false, "\(kind)")
    }
  }

  /// «Уже списано до сверки» pays the rest of the due, not the whole monthly payment again, and
  /// the line says the due is closed.
  @Test func aDueTakenBeforeACountPaysWhatWasLeftOfIt() throws {
    var debt = existingDebt(subcategory: id(7))
    debt.monthlyPaymentE4 = money(8000)
    let whole = try #require(
      DebtRules.settledByCount(debt: debt, due: day("2026-09-05"), balance: money(50000)))
    #expect(whole.amountE4 == money(-8000))
    let rest = try #require(
      DebtRules.settledByCount(
        debt: debt, due: day("2026-09-05"), balance: money(50000), owed: money(4000)))
    #expect(rest.amountE4 == money(-4000))
    #expect(rest.closesTerm, "what is left of the due is paid, so the due is closed")
    #expect(whole.closesTerm)
    // Never more than is left on the debt, never more than the monthly payment.
    let small = try #require(
      DebtRules.settledByCount(
        debt: debt, due: day("2026-09-05"), balance: money(1500), owed: money(4000)))
    #expect(small.amountE4 == money(-1500))
    let big = try #require(
      DebtRules.settledByCount(
        debt: debt, due: day("2026-09-05"), balance: money(50000), owed: money(20000)))
    #expect(big.amountE4 == money(-8000))
  }
}
