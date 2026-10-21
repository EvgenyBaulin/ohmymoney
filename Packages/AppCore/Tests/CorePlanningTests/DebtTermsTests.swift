import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// When a payment of a debt may say «в этом месяце больше платежей не будет»: only when it
/// leaves part of the due unpaid. A payment that covers the due has nothing to say, and neither
/// has a payment on a debt with no dues.
@Suite("When a payment may close its term")
struct DebtTermsTests {
  typealias Fx = CashFx

  static let loan = Debt(
    id: Fx.id(351), direction: .iOwe, type: .loan, name: "Loan",
    monthlyPaymentE4: Fx.money("8000"), paymentDay: 5)

  func dues(partial: String = "0", owes: Bool = true) -> DebtDueState {
    DebtDueState(
      debtId: Self.loan.id, firstDue: Fx.day("2026-09-05"), paidCount: 0, owes: owes,
      paymentDay: 5, partialE4: Fx.money(partial))
  }

  @Test func aPaymentSmallerThanTheDueMaySay() {
    #expect(DebtTerms.offersClosing(Self.loan, paying: Fx.money("4000"), dues: dues()))
    #expect(DebtTerms.offersClosing(Self.loan, paying: Fx.money("100"), dues: dues()))
  }

  /// The money paid toward the due counts with the payment: 4 000 paid and 4 000 more cover it.
  @Test func moneyAlreadyPaidCountsWithThePayment() {
    #expect(
      !DebtTerms.offersClosing(Self.loan, paying: Fx.money("4000"), dues: dues(partial: "4000")))
    #expect(
      DebtTerms.offersClosing(Self.loan, paying: Fx.money("3000"), dues: dues(partial: "4000")))
  }

  /// A payment that covers the due — a percent short of it too — has nothing to close.
  @Test func aPaymentThatCoversTheDueHasNothingToSay() {
    #expect(!DebtTerms.offersClosing(Self.loan, paying: Fx.money("8000"), dues: dues()))
    #expect(!DebtTerms.offersClosing(Self.loan, paying: Fx.money("7950"), dues: dues()))
    #expect(!DebtTerms.offersClosing(Self.loan, paying: Fx.money("20000"), dues: dues()))
  }

  @Test func onlyADebtWithDuesAsks() {
    #expect(!DebtTerms.offersClosing(Self.loan, paying: Fx.money("4000"), dues: dues(owes: false)))
    var owedToMe = Self.loan
    owedToMe.direction = .owedToMe
    #expect(!DebtTerms.offersClosing(owedToMe, paying: Fx.money("4000"), dues: dues()))
    var closed = Self.loan
    closed.closed = true
    #expect(!DebtTerms.offersClosing(closed, paying: Fx.money("4000"), dues: dues()))
    var noMonthly = Self.loan
    noMonthly.monthlyPaymentE4 = nil
    #expect(!DebtTerms.offersClosing(noMonthly, paying: Fx.money("4000"), dues: dues()))
    var noDay = Self.loan
    noDay.paymentDay = nil
    #expect(!DebtTerms.offersClosing(noDay, paying: Fx.money("4000"), dues: dues()))
    #expect(!DebtTerms.offersClosing(Self.loan, paying: .zero, dues: dues()))
  }

  /// Without the state of its dues — the data is not here yet — the monthly payment is the
  /// measure.
  @Test func withoutTheStateTheMonthlyPaymentIsTheMeasure() {
    #expect(DebtTerms.offersClosing(Self.loan, paying: Fx.money("4000"), dues: nil))
    #expect(!DebtTerms.offersClosing(Self.loan, paying: Fx.money("8000"), dues: nil))
  }

  /// A payment starts with what is left of the due, not with the whole payment again.
  @Test func aPaymentStartsWithWhatIsLeftOfTheDue() {
    #expect(DebtTerms.amountToPay(Self.loan, dues: dues()) == Fx.money("8000"))
    #expect(DebtTerms.amountToPay(Self.loan, dues: dues(partial: "3000")) == Fx.money("5000"))
    #expect(DebtTerms.amountToPay(Self.loan, dues: nil) == Fx.money("8000"))
    // Nothing owed any more: the monthly payment, as the form always started.
    #expect(
      DebtTerms.amountToPay(Self.loan, dues: dues(partial: "3000", owes: false)) == Fx.money("8000")
    )
    var loose = Self.loan
    loose.monthlyPaymentE4 = nil
    #expect(DebtTerms.amountToPay(loose, dues: dues()) == .zero)
  }

  // MARK: A loan written on its payment day

  /// A loan written on the day its payment falls due asks whether this month's payment is made:
  /// the owner enters what is left after it, or before it, and only they know.
  @Test func aLoanWrittenOnItsPaymentDayAsksAboutThisMonth() {
    let paymentDay = Fx.day("2026-09-05")
    #expect(DebtTerms.asksAboutThisMonth(Self.loan, balance: Fx.money("80000"), today: paymentDay))
    #expect(
      !DebtTerms.asksAboutThisMonth(
        Self.loan, balance: Fx.money("80000"), today: Fx.day("2026-09-06")),
      "any other day is plain")
    #expect(!DebtTerms.asksAboutThisMonth(Self.loan, balance: .zero, today: paymentDay))
    var owedToMe = Self.loan
    owedToMe.direction = .owedToMe
    #expect(!DebtTerms.asksAboutThisMonth(owedToMe, balance: Fx.money("80000"), today: paymentDay))
    var bought = Self.loan
    bought.origin = .purchase
    #expect(
      !DebtTerms.asksAboutThisMonth(bought, balance: Fx.money("80000"), today: paymentDay),
      "a purchase on credit pays from the next month already")
    var noMonthly = Self.loan
    noMonthly.monthlyPaymentE4 = nil
    #expect(!DebtTerms.asksAboutThisMonth(noMonthly, balance: Fx.money("80000"), today: paymentDay))
    var noDay = Self.loan
    noDay.paymentDay = nil
    #expect(!DebtTerms.asksAboutThisMonth(noDay, balance: Fx.money("80000"), today: paymentDay))
  }

  /// A payment day past the end of a month is its last day: a loan due «on the 31st» asks on 30
  /// September.
  @Test func theLastDayOfAShortMonthIsThePaymentDay() {
    var thirty = Self.loan
    thirty.paymentDay = 31
    #expect(
      DebtTerms.asksAboutThisMonth(thirty, balance: Fx.money("80000"), today: Fx.day("2026-09-30")))
    #expect(
      !DebtTerms.asksAboutThisMonth(thirty, balance: Fx.money("80000"), today: Fx.day("2026-09-29"))
    )
  }

  /// The answer «да» is a payment of nothing that closes its term, dated the day: the due of the
  /// day is paid, and the first one still owed is next month's.
  @Test func aMonthAnsweredPaidMakesNextMonthTheFirstDue() {
    var fx = Fx()
    fx.debts = [Self.loan]
    let today = Fx.day("2026-09-05")
    let opening = DebtEntry(
      debtId: Self.loan.id, date: today, amountE4: Fx.money("80000"), kind: .adjustment)
    func firstUnpaid(_ journal: [DebtEntry]) -> DateOnly? {
      var copy = fx
      copy.debtEntries = journal
      return DebtDues.states(
        debts: [Self.loan], ledger: copy.ledger, journal: journal, today: today
      )[Self.loan.id]?.firstUnpaid
    }
    #expect(firstUnpaid([opening]) == today, "taken on its payment day it owes that day")
    let paid = DebtRules.makeEntry(
      debtId: Self.loan.id, kind: .payment, amountE4: .zero, date: today, closesTerm: true)
    #expect(firstUnpaid([opening, paid]) == Fx.day("2026-10-05"))
    #expect(DebtRules.balance(entries: [opening, paid]) == Fx.money("80000"), "no money moves")
  }
}
