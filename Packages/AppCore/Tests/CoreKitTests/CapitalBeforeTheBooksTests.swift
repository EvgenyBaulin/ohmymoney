import Foundation
import Testing

@testable import CoreKit

// Synthetic data only.

/// «Куплено: дата и цена» of an asset and «Оформлен: дата и сумма» of a loan: each half is kept as
/// typed, and the point the capital can start from is there only when both halves are said and
/// the sum holds.
@Suite("The capital before the books began")
struct CapitalBeforeTheBooksTests {
  private let day = DateOnly(year: 2019, month: 6, day: 14)

  @Test func aPurchaseNeedsTheDayAndThePrice() {
    var flat = Asset(name: "Flat", kind: .realty, currency: .eur)
    #expect(flat.purchase == nil)
    flat.purchasedOn = day
    #expect(flat.purchase == nil, "a day without a price")
    flat.purchasedOn = nil
    flat.purchasePriceE4 = AmountE4(whole: 120_000)
    #expect(flat.purchase == nil, "a price without a day")
    flat.purchasedOn = day
    #expect(
      flat.purchase == AssetPurchase(day: day, priceE4: AmountE4(whole: 120_000), currency: .eur))
  }

  @Test func aPurchaseIsInTheCurrencyOfTheAssetAndMayCostNothing() {
    var gift = Asset(
      name: "Gift", currency: .usd, purchasedOn: day, purchasePriceE4: .zero)
    #expect(gift.purchase?.priceE4 == .zero, "a thing given for nothing still has a day")
    #expect(gift.purchase?.currency == .usd)
    gift.currency = .rub
    #expect(gift.purchase?.currency == .rub, "the price follows the currency of the asset")
    gift.purchasePriceE4 = AmountE4(raw: -1)
    #expect(gift.purchase == nil, "a price below zero is no purchase")
  }

  @Test func anOpeningNeedsTheDayAndASumAboveZero() {
    var loan = Debt(direction: .iOwe, type: .loan, name: "Mortgage")
    #expect(loan.opening == nil)
    loan.openedOn = day
    #expect(loan.opening == nil, "a day without a sum")
    loan.originalAmountE4 = .zero
    #expect(loan.opening == nil, "nothing borrowed is no loan")
    loan.originalAmountE4 = AmountE4(raw: -10_000)
    #expect(loan.opening == nil)
    loan.originalAmountE4 = AmountE4(whole: 4_200_000)
    #expect(
      loan.opening
        == DebtOpening(day: day, amountE4: AmountE4(whole: 4_200_000), currency: .rub))
    loan.openedOn = nil
    #expect(loan.opening == nil, "a sum without a day")
  }

  @Test func theNewFieldsStartEmptyAndSurviveACopy() {
    let made = Debt(direction: .iOwe, type: .loan, name: "L")
    #expect(made.openedOn == nil && made.originalAmountE4 == nil)
    let asset = Asset(name: "A")
    #expect(asset.purchasedOn == nil && asset.purchasePriceE4 == nil)
    var loan = Debt(
      direction: .iOwe, type: .loan, name: "L", openedOn: day,
      originalAmountE4: AmountE4(whole: 1))
    loan.name = "Renamed"
    #expect(loan.openedOn == day)
    #expect(loan.originalAmountE4 == AmountE4(whole: 1))
  }
}
