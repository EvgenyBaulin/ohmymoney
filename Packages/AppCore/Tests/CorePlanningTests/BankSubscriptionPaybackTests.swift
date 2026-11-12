import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// Whether a bank subscription pays back: its cost against the stated benefit and the share of the
/// bank's cashback it gives. Synthetic data.
@Suite("A bank subscription pays back or does not")
struct BankSubscriptionPaybackTests {
  let today = DateOnly(year: 2026, month: 11, day: 12)
  let bank = UUID(uuidString: "00000000-0000-0000-0000-0000000000b1")!
  let other = UUID(uuidString: "00000000-0000-0000-0000-0000000000b2")!

  func account(_ number: Int, bank: UUID?) -> PaymentMethod {
    PaymentMethod(
      id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!,
      name: "Account \(number)", bankId: bank)
  }

  func subscription(
    _ name: String, _ amount: Int64, on account: PaymentMethod?, freq: Frequency = .monthly,
    currency: CurrencyCode = .rub
  ) -> ScheduledPayment {
    ScheduledPayment(
      name: name, kind: .subscription, amountE4: AmountE4(whole: amount), currency: currency,
      paymentMethodId: account?.id, freq: freq, day: 20,
      month: freq == .yearly ? 12 : nil, nextDate: DateOnly(year: 2026, month: 11, day: 20))
  }

  func report(
    _ payments: [ScheduledPayment], terms: [SubscriptionTerms], accounts: [PaymentMethod],
    cashback: [UUID: AmountE4] = [:], rates: [CurrencyCode: Decimal] = [:]
  ) -> [BankSubscriptionPayback] {
    BankSubscriptionPaybacks.report(
      book: PlanningBook(scheduled: payments), subscriptions: SubscriptionBook(terms: terms),
      accounts: accounts, cashbackRub: cashback, today: today, rubPerUnit: rates)
  }

  @Test func theBenefitAndAShareOfTheCashbackAgainstTheCost() throws {
    let account = account(1, bank: bank)
    let pro = subscription("Pro", 300, on: account)
    let terms = SubscriptionTerms(
      paymentId: pro.id, bankBenefitE4: AmountE4(whole: 100), bankCashbackShare: 50)
    // 100 + half of 500 against 300: pays back by 50.
    let line = try #require(
      report([pro], terms: [terms], accounts: [account], cashback: [bank: AmountE4(whole: 500)])
        .first)
    #expect(line.costRub == AmountE4(whole: 300) && line.benefitRub == AmountE4(whole: 100))
    #expect(line.cashbackGainRub == AmountE4(whole: 250) && line.gainRub == AmountE4(whole: 350))
    #expect(line.netRub == AmountE4(whole: 50) && line.verdict == .paysBack)
    // With less cashback the same subscription costs more than it brings.
    let poor = try #require(
      report([pro], terms: [terms], accounts: [account], cashback: [bank: AmountE4(whole: 100)])
        .first)
    #expect(poor.netRub == AmountE4(whole: -150) && poor.verdict == .costsMore)
  }

  @Test func aYearlySubscriptionCostsAMonthOfItsPrice() throws {
    let account = account(1, bank: bank)
    let year = subscription("Year", 1_200, on: account, freq: .yearly)
    let terms = SubscriptionTerms(paymentId: year.id, bankBenefitE4: AmountE4(whole: 100))
    let line = try #require(report([year], terms: [terms], accounts: [account]).first)
    #expect(line.costRub == AmountE4(whole: 100) && line.verdict == .paysBack)
  }

  @Test func onlyABankSubscriptionOfAnAccountWithABankIsReported() {
    let banked = account(1, bank: bank)
    let free = account(2, bank: nil)
    let stated = subscription("A", 300, on: banked)
    let noTerms = subscription("B", 300, on: banked)
    let statedNoBank = subscription("C", 300, on: free)
    let blank = subscription("D", 300, on: banked)
    let noAccount = subscription("E", 300, on: nil)
    let terms = [
      SubscriptionTerms(paymentId: stated.id, bankBenefitE4: AmountE4(whole: 10)),
      SubscriptionTerms(paymentId: statedNoBank.id, bankBenefitE4: AmountE4(whole: 10)),
      SubscriptionTerms(paymentId: blank.id),
      SubscriptionTerms(paymentId: noAccount.id, bankBenefitE4: AmountE4(whole: 10)),
    ]
    let lines = report(
      [stated, noTerms, statedNoBank, blank, noAccount], terms: terms, accounts: [banked, free])
    #expect(lines.map(\.paymentId) == [stated.id])
    #expect(!BankSubscriptionPaybacks.isBankSubscription(nil))
    #expect(!BankSubscriptionPaybacks.isBankSubscription(SubscriptionTerms(paymentId: blank.id)))
  }

  @Test func theBestComesFirstAndAForeignPriceNeedsARate() throws {
    let account = account(1, bank: bank)
    let cheap = subscription("Cheap", 100, on: account)
    let dear = subscription("Dear", 900, on: account)
    let dollars = subscription("Dollars", 5, on: account, currency: .usd)
    let terms = [cheap, dear, dollars].map {
      SubscriptionTerms(paymentId: $0.id, bankBenefitE4: AmountE4(whole: 200))
    }
    let lines = report([dear, cheap, dollars], terms: terms, accounts: [account])
    #expect(lines.map(\.paymentId) == [cheap.id, dear.id])
    let priced = report(
      [dollars], terms: terms, accounts: [account], rates: [.usd: 100])
    #expect(priced.first?.costRub == AmountE4(whole: 500))
    #expect(priced.first?.benefitRub == AmountE4(whole: 20_000))
  }
}
