import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("Dividends and coupons are expected incomes that know their holding")
struct PayoutTests {
  let today = DateOnly(year: 2026, month: 10, day: 28)

  func asset(_ name: String, _ kind: AssetKind, disposed: DateOnly? = nil) -> Asset {
    Asset(name: name, kind: kind, disposedOn: disposed)
  }

  @Test func onlyLiveInvestmentsCanPay() {
    let shares = asset("Акции", .investment)
    let bonds = asset("Облигации", .investment)
    let sold = asset("Старый", .investment, disposed: DateOnly(year: 2026, month: 1, day: 1))
    let flat = asset("Квартира", .realty)
    let list = PayoutRules.holdings([flat, sold, shares, bonds], today: today)
    #expect(list.map(\.name) == ["Акции", "Облигации"])
    // The holding an old payout names stays on the list while that payout is edited.
    let kept = PayoutRules.holdings([flat, sold, shares], keeping: sold.id, today: today)
    #expect(kept.contains { $0.id == sold.id })
  }

  @Test func aHoldingNeedsAPayoutKindAndAnInvestment() {
    let shares = asset("Акции", .investment)
    let flat = asset("Квартира", .realty)
    var income = ExpectedIncome(
      name: "x", totalE4: AmountE4(whole: 100), payoutKind: .dividend, assetId: shares.id)
    #expect(PayoutRules.normalized(income, assets: [shares]).assetId == shares.id)
    income.assetId = flat.id
    #expect(PayoutRules.normalized(income, assets: [flat, shares]).assetId == nil)
    income.assetId = shares.id
    income.payoutKind = nil
    #expect(PayoutRules.normalized(income, assets: [shares]).assetId == nil)
    income.assetId = UUID()
    income.payoutKind = .coupon
    #expect(PayoutRules.normalized(income, assets: [shares]).assetId == nil)
  }

  @Test func theDraftStartsInTheHoldingsCurrency() {
    var bonds = asset("ОФЗ", .investment)
    bonds.currency = .usd
    let draft = PayoutRules.draft(for: bonds, kind: .coupon, today: today)
    #expect(draft.payoutKind == .coupon)
    #expect(draft.assetId == bonds.id)
    #expect(draft.currency == .usd)
    #expect(draft.dueDate == today)
    #expect(draft.kind == .oneOff)
  }

  @Test func theCalendarCarriesTheKindOfAPayout() {
    let shares = asset("Акции", .investment)
    let coupon = ExpectedIncome(
      name: "Купон", kind: .recurring, totalE4: AmountE4(whole: 3_000),
      dueDate: DateOnly(year: 2026, month: 11, day: 10), freq: .monthly, day: 10,
      payoutKind: .coupon, assetId: shares.id)
    let plain = ExpectedIncome(
      name: "Проект", totalE4: AmountE4(whole: 50_000),
      dueDate: DateOnly(year: 2026, month: 11, day: 12))
    let book = PlanningBook(expected: [coupon, plain])
    let ledger = Ledger(dataset: Dataset(planning: book), calendar: .utc)
    let plans = CalendarPlans.collect(
      ledger: ledger, book: book, today: today, through: DateOnly(year: 2026, month: 11, day: 30))
    #expect(plans.first { $0.name == "Купон" }?.payoutKind == .coupon)
    #expect(plans.first { $0.name == "Проект" }?.payoutKind == nil)
  }
}
