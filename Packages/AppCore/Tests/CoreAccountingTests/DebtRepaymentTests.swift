import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// Money a person gives back on a debt owed to me: the balance first, the debt closes once it is
/// covered, and what is over is income in «Доплаты».
@Suite("Repaying a debt owed to me")
struct DebtRepaymentTests {
  let masha = id(40)
  let card = id(1)

  func debt(currency: CurrencyCode = .rub) -> Debt {
    Debt(
      id: id(200), direction: .owedToMe, type: .personal, name: "Masha", personId: masha,
      currency: currency, paymentsAreExpenses: false)
  }

  func back(
    _ amount: String, currency: CurrencyCode = .rub, rubles: String? = nil,
    leg: (CurrencyCode, String)? = nil
  ) -> Transaction {
    Transaction(
      id: id(9), kind: .reimbursement, occurredAt: moment("2026-09-20"), currency: currency,
      amountE4: money(amount), amountRubE4: money(rubles ?? amount), paymentMethodId: card,
      accountCurrency: leg?.0, accountAmountE4: leg.map { money($0.1) }, debtId: id(200))
  }

  /// Маша owes 1,000 ₽ and gives 1,700 ₽ back: −1,000 ₽ on the debt, closed, and 700 ₽ of
  /// income on the card the money came to.
  @Test func moneyBackOverTheDebtClosesItAndTheRestIsSurcharges() throws {
    let outcome = try DebtRules.repayment(
      on: debt(), by: back("1700"), balance: money(1000), date: day("2026-09-20"))
    #expect(outcome.applied == money(1000))
    #expect(outcome.line?.amountE4 == money(-1000))
    #expect(outcome.line?.kind == .payment)
    #expect(outcome.line?.transactionId == id(9))
    #expect(outcome.closes)
    #expect(outcome.surplus?.amountE4 == money(700))
    #expect(outcome.surplus?.amountRubE4 == money(700))
    #expect(outcome.surplus?.currency == .rub)
    #expect(outcome.surplus?.accountId == card)
  }

  @Test func aRepaymentWithinTheDebtWritesNoSurplus() throws {
    let outcome = try DebtRules.repayment(
      on: debt(), by: back("600"), balance: money(1000), date: nil)
    #expect(outcome.line?.amountE4 == money(-600))
    #expect(!outcome.closes)
    #expect(outcome.surplus == nil)
  }

  /// Exactly what is owed closes the debt — unless the Debts form was told not to.
  @Test func anExactRepaymentClosesADebtOwedToMe() throws {
    let exact = try DebtRules.repayment(
      on: debt(), by: back("1000"), balance: money(1000), date: nil)
    #expect(exact.line?.amountE4 == money(-1000))
    #expect(exact.closes)
    #expect(exact.surplus == nil)
    let kept = try DebtRules.repayment(
      on: debt(), by: back("1000"), balance: money(1000), date: nil, closeWhenPaidOff: false)
    #expect(!kept.closes)
    // Above the balance the switch does not count: the debt is paid off.
    let over = try DebtRules.repayment(
      on: debt(), by: back("1001"), balance: money(1000), date: nil, closeWhenPaidOff: false)
    #expect(over.closes)
  }

  /// Маша owes 100 $ (lent at 90), gives 10,000 ₽ back to the ruble card: at 90 that is
  /// 111.1111 $; the debt takes 100 $ = 9,000 ₽, and 1,000 ₽ are income.
  @Test func aForeignDebtRepaidInRublesCountsAtTheCostRate() throws {
    let converted = try #require(
      DebtRules.convert(money(10_000), moneyRubPerUnit: 1, debtRubPerUnit: 90))
    #expect(converted == money("111.1111"))
    let operation = back(
      "111.1111", currency: .usd, rubles: "10000", leg: (.rub, "10000"))
    let outcome = try DebtRules.repayment(
      on: debt(currency: .usd), by: operation, balance: money(100), date: nil, rubPerUnit: 90)
    #expect(outcome.line?.amountE4 == money(-100))
    #expect(outcome.closes)
    #expect(outcome.surplus?.currency == .rub)
    #expect(outcome.surplus?.amountE4 == money(1000))
    #expect(outcome.surplus?.amountRubE4 == money(1000))
  }

  /// The same repayment as the line writes it — no rate handed over — values the debt's part at
  /// the operation's own rate as it is written, to four decimals: 1,000 ₽ over, not 999.9991 ₽.
  @Test func aConvertedRepaymentWithoutItsRateStillLeavesWholeRubles() throws {
    let operation = back(
      "111.1111", currency: .usd, rubles: "10000", leg: (.rub, "10000"))
    let outcome = try DebtRules.repayment(
      on: debt(currency: .usd), by: operation, balance: money(100), date: nil)
    #expect(outcome.surplus?.amountE4 == money(1000))
  }

  /// Dollars that reached a dollar account: the surplus is the dollars over, at their rubles.
  @Test func dollarsOverADollarDebtAreASurplusInDollars() throws {
    let operation = back("120", currency: .usd, rubles: "10800")
    let outcome = try DebtRules.repayment(
      on: debt(currency: .usd), by: operation, balance: money(100), date: nil)
    #expect(outcome.surplus?.currency == .usd)
    #expect(outcome.surplus?.amountE4 == money(20))
    #expect(outcome.surplus?.amountRubE4 == money(1800))
  }

  /// 9,000 ₽ lent as 100 $ through the journal, 1,850 ₽ more as 20 $ by an operation.
  @Test func theCostRateIsTheRublesLentOverTheAmount() {
    let lentByOperation = Transaction(
      id: id(30), kind: .expense, occurredAt: moment("2026-08-01"), currency: .usd,
      amountE4: money(20), amountRubE4: money(1850), paymentMethodId: card, debtId: id(200))
    var cash = DebtRules.makeEntry(
      id: id(31), debtId: id(200), kind: .borrowed, amountE4: money(100))
    cash.accountCurrency = .rub
    cash.accountAmountE4 = money(9000)
    let viaOperation = DebtRules.makeEntry(
      id: id(32), debtId: id(200), kind: .borrowed, amountE4: money(20), transactionId: id(30))
    let rate = DebtRules.costRate(
      of: debt(currency: .usd), journal: [cash, viaOperation],
      operations: [id(30): lentByOperation])
    #expect(rate == Decimal(string: "90.4167"))
    #expect(DebtRules.costRate(of: debt(), journal: [cash], operations: [:]) == nil)
    #expect(DebtRules.costRate(of: debt(currency: .usd), journal: [], operations: [:]) == nil)
  }

  @Test func aZeroBalanceMakesAllOfItSurplus() throws {
    let outcome = try DebtRules.repayment(
      on: debt(), by: back("500"), balance: .zero, date: nil)
    #expect(outcome.line == nil)
    #expect(outcome.applied == .zero)
    #expect(outcome.closes)
    #expect(outcome.surplus?.amountE4 == money(500))
  }

  @Test func moneyThatGrowsTheDebtOrIsInAnotherCurrencyIsNoRepayment() {
    var lent = back("500")
    lent.kind = .expense
    #expect(throws: DebtRules.RepaymentError.notARepayment) {
      try DebtRules.repayment(on: debt(), by: lent, balance: money(1000), date: nil)
    }
    #expect(throws: DebtRules.RepaymentError.otherCurrency) {
      try DebtRules.repayment(
        on: debt(currency: .usd), by: back("500"), balance: money(1000), date: nil)
    }
  }
}
