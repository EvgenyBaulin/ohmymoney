import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// A purchase in another currency at the rate it cost, and written again at a rate typed from
/// the statement.
@Suite("The rate of a purchase")
struct PurchaseRateTests {
  func purchase(
    _ amount: String, rubles: String, parts: [String]? = nil,
    leg: (CurrencyCode, String)? = nil
  ) -> TransactionEntry {
    let amounts = parts ?? [amount]
    let shares = money(rubles).allocated(
      proportionallyTo: amounts.map { money($0) }, outOf: money(amount))
    return TransactionEntry(
      transaction: Transaction(
        id: id(1), kind: .expense, occurredAt: moment("2026-09-01"), currency: .usd,
        amountE4: money(amount), rate: Decimal(92), rateDate: day("2026-09-01"),
        rateSource: .cbr, rateProvisional: true, amountRubE4: money(rubles),
        paymentMethodId: id(2), accountCurrency: leg?.0, accountAmountE4: leg.map { money($0.1) }),
      parts: zip(amounts, shares).enumerated().map { index, pair in
        TransactionPart(
          id: id(10 + index), transactionId: id(1), amountE4: money(pair.0),
          amountRubE4: pair.1)
      })
  }

  /// 20 $ charged 1,800 ₽ on the ruble card cost 90 a dollar; typed 88, it is 1,760 ₽ — the
  /// part, and what the card was charged — at a manual rate that is no longer provisional.
  @Test func repricingRewritesRublesPartsAndARubleLeg() throws {
    let entry = purchase("20", rubles: "1800", leg: (.rub, "1800"))
    #expect(PurchaseRate.costRate(of: entry.transaction) == 90)
    let repriced = try PurchaseRate.repriced(entry, rate: 88, day: day("2026-09-20"))
    #expect(repriced.transaction.amountRubE4 == money(1760))
    #expect(repriced.transaction.accountAmountE4 == money(1760))
    #expect(repriced.transaction.rate == 88)
    #expect(repriced.transaction.rateSource == .manual)
    #expect(!repriced.transaction.rateProvisional)
    #expect(repriced.transaction.rateDate == day("2026-09-20"))
    #expect(repriced.parts.map(\.amountRubE4) == [money(1760)])

    let split = purchase("10", rubles: "900", parts: ["3.33", "3.33", "3.34"])
    let three = try PurchaseRate.repriced(
      split, rate: Decimal(string: "88.8888") ?? 0, day: day("2026-09-20"))
    #expect(three.transaction.amountRubE4 == money("888.888"))
    #expect(AmountE4.sum(three.parts.map(\.amountRubE4)) == three.transaction.amountRubE4)
  }

  /// A charge in tenge on the account stays what the account was charged.
  @Test func aNonRubleLegStaysWhenRepriced() throws {
    let entry = purchase("20", rubles: "1800", leg: (CurrencyCode("KZT"), "10000"))
    let repriced = try PurchaseRate.repriced(entry, rate: 91, day: day("2026-09-20"))
    #expect(repriced.transaction.amountRubE4 == money(1820))
    #expect(repriced.transaction.accountCurrency == CurrencyCode("KZT"))
    #expect(repriced.transaction.accountAmountE4 == money(10000))
  }

  @Test func costRateIsRublesOverAmount() {
    #expect(PurchaseRate.costRate(of: purchase("3", rubles: "271").transaction) == Decimal(271) / 3)
    var rubles = purchase("20", rubles: "1800").transaction
    rubles.currency = .rub
    #expect(PurchaseRate.costRate(of: rubles) == nil)
  }

  /// The owed parts of the repriced purchase take its rubles; others stay.
  @Test func owedPartsFollowTheRepricedPurchase() throws {
    let entry = purchase("20", rubles: "1800")
    let repriced = try PurchaseRate.repriced(entry, rate: 88, day: day("2026-09-20"))
    let mine = OwedPart(
      partId: id(10), transactionId: id(1), occurredAt: moment("2026-09-01"), amountE4: money(20),
      amountRubE4: money(1800), currency: .usd, rateProvisional: true)
    let other = OwedPart(
      partId: id(30), transactionId: id(3), occurredAt: moment("2026-09-02"), amountE4: money(500))
    let after = PurchaseRate.repriced([mine, other], of: repriced)
    #expect(after[0].amountRubE4 == money(1760))
    #expect(!after[0].rateProvisional)
    #expect(after[1] == other)
  }
}
