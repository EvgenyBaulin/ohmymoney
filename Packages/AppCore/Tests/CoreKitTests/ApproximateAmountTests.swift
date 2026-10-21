import Foundation
import Testing

@testable import CoreKit

@Suite("Серое «≈» рядом с суммой в другой валюте")
struct ApproximateAmountTests {
  private let day = DateOnly(year: 2026, month: 10, day: 7)

  private func dollars(
    rate: Decimal? = 90, source: RateSource? = .cbr, rateDate: DateOnly? = nil,
    provisional: Bool = false
  ) -> Transaction {
    var transaction = Transaction(
      kind: .expense, occurredAt: Date(), currency: .usd, amountE4: AmountE4(whole: 10),
      amountRubE4: rate.map { AmountE4(whole: Int64(truncating: (10 * $0) as NSNumber)) } ?? .zero)
    transaction.rate = rate
    transaction.rateSource = source
    transaction.rateDate = rateDate ?? day
    transaction.rateProvisional = provisional
    return transaction
  }

  @Test func theBanksRateOfTheDayIsApproximate() {
    #expect(
      ApproximateAmount.of(dollars(), day: day, defaultCurrency: .rub)
        == .approximate(AmountE4(whole: 900), .rub, rateDay: nil))
  }

  @Test func anEarlierOrProvisionalRateSaysItsDay() {
    let earlier = DateOnly(year: 2026, month: 10, day: 5)
    #expect(
      ApproximateAmount.of(dollars(rateDate: earlier), day: day, defaultCurrency: .rub)
        == .approximate(AmountE4(whole: 900), .rub, rateDay: earlier))
    #expect(
      ApproximateAmount.of(dollars(provisional: true), day: day, defaultCurrency: .rub)
        == .approximate(AmountE4(whole: 900), .rub, rateDay: day))
  }

  /// The rate typed, or the account charged in rubles: «≈» gives way to the exact amount.
  @Test func aTypedRateOrAChargeIsExact() {
    #expect(
      ApproximateAmount.of(dollars(source: .manual), day: day, defaultCurrency: .rub)
        == .exact(AmountE4(whole: 900), .rub))
    var charged = dollars()
    charged.accountCurrency = .rub
    charged.accountAmountE4 = AmountE4(whole: 912)
    #expect(
      ApproximateAmount.of(charged, day: day, defaultCurrency: .rub)
        == .exact(AmountE4(whole: 912), .rub))
  }

  @Test func theDefaultCurrencyOrNoRateShowsNothing() {
    var rubles = dollars()
    rubles.currency = .rub
    #expect(ApproximateAmount.of(rubles, day: day, defaultCurrency: .rub) == nil)
    #expect(ApproximateAmount.of(dollars(rate: nil), day: day, defaultCurrency: .rub) == nil)
  }

  @Test func anotherDefaultCurrencyIsConverted() {
    #expect(
      ApproximateAmount.of(
        dollars(), day: day, defaultCurrency: .eur, rubPerUnitOfDefault: 100)
        == .approximate(AmountE4(whole: 9), .eur, rateDay: nil))
  }

  /// Showing it changes nothing in the operation.
  @Test func itIsDisplayOnly() {
    let transaction = dollars()
    let copy = transaction
    _ = ApproximateAmount.of(transaction, day: day, defaultCurrency: .rub)
    #expect(transaction == copy)
  }
}
