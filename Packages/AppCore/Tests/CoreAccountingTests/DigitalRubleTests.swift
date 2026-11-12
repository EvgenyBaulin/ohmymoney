import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// The digital ruble is a flag on an account: rubles only, no interest, no cashback.
@Suite("A wallet of the digital ruble earns nothing")
struct DigitalRubleTests {
  let terms = DepositTerms(rate: 16, period: .monthly)

  @Test func anOrdinaryAccountHasNoIssuesWhateverItEarns() {
    let account = PaymentMethod(
      name: "Savings", currency: .usd, interest: terms, cashbackMonthlyCapE4: AmountE4(whole: 5))
    #expect(DigitalRuble.issues(for: account).isEmpty)
    #expect(DigitalRuble.allowsInterestAndCashback(account))
  }

  @Test func aMarkedAccountNamesWhatItMayNotHave() {
    let account = PaymentMethod(
      name: "Wallet", currency: .usd, otherCurrencies: [.eur], interest: terms,
      cashbackMonthlyCapE4: AmountE4(whole: 5), digitalRuble: true)
    #expect(
      Set(DigitalRuble.issues(for: account)) == [.hasInterest, .hasCashback, .notRubles])
    #expect(!DigitalRuble.allowsInterestAndCashback(account))
    let clean = PaymentMethod(name: "Wallet", currency: .rub, digitalRuble: true)
    #expect(DigitalRuble.issues(for: clean).isEmpty)
    let unsaid = PaymentMethod(name: "Wallet", currency: nil, digitalRuble: true)
    #expect(DigitalRuble.issues(for: unsaid).isEmpty)
  }

  @Test func makingAWalletStripsInterestCashbackAndOtherCurrencies() {
    let other = UUID()
    let account = PaymentMethod(
      name: "Card", currency: .usd, otherCurrencies: [.eur], cashbackPointsAccountId: other,
      interest: terms, cushion: true, cashbackMonthlyCapE4: AmountE4(whole: 5),
      cashbackChoiceDay: 3)
    let wallet = DigitalRuble.made(from: account)
    #expect(wallet.digitalRuble && wallet.currency == .rub && wallet.otherCurrencies.isEmpty)
    #expect(wallet.interest == nil && wallet.cashbackPointsAccountId == nil)
    #expect(wallet.cashbackMonthlyCapE4 == nil && wallet.cashbackChoiceDay == nil)
    #expect(DigitalRuble.issues(for: wallet).isEmpty)
    // The rest of the account stays as it was.
    #expect(wallet.id == account.id && wallet.name == "Card" && wallet.cushion)
  }
}
