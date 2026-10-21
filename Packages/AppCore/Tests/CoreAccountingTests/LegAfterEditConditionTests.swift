import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// «Списано со счёта» follows a new rate only when the rate is really new, of the same currency,
/// and the operation's own: a refund taken back from a purchase carries the purchase's rate, the
/// same rate typed again is no change, and a rate cleared is no rate.
@Suite("When a rate moves the charge, and when it does not")
struct LegAfterEditConditionTests {
  let rates = DayRates(series: [
    CurrencyCode.usd: [DayRate(day: DateOnly(year: 2026, month: 3, day: 1), perUnit: 90)],
    CurrencyCode.eur: [DayRate(day: DateOnly(year: 2026, month: 3, day: 1), perUnit: 100)],
  ])
  let card = PaymentMethod(id: id(1), name: "Card", currency: .rub, isDefault: true)

  /// 50 dollars (or `amount`) at `rate` on the ruble card, charged `leg` rubles; a refund taken
  /// back from purchase part 700 when `refund` is set.
  func dollars(
    rate: Decimal = 90, source: RateSource = .cbr, leg: AmountE4, refund: Bool = false,
    amount: AmountE4 = money(50)
  ) -> TransactionEntry {
    let rub = (try? AmountE4(decimal: amount.decimal * rate)) ?? .zero
    return TransactionEntry(
      transaction: Transaction(
        id: id(9), kind: refund ? .refund : .expense, occurredAt: moment("2026-03-02"),
        currency: .usd, amountE4: amount, rate: rate, rateSource: source, amountRubE4: rub,
        paymentMethodId: id(1), accountCurrency: .rub, accountAmountE4: leg),
      parts: [
        TransactionPart(
          transactionId: id(9), amountE4: amount, amountRubE4: rub,
          refundOfPartId: refund ? id(700) : nil)
      ])
  }

  func edit(_ before: TransactionEntry, _ change: (inout TransactionDraft) -> Void) -> LegEdit {
    var after = TransactionDraft(entry: before)
    change(&after)
    return AccountRules.legAfterEdit(
      before: before, after: after, account: card, rates: rates, calendar: .utc)
  }

  /// A refund of 50 dollars taken back from a purchase at 90, which the bank credited as 4 700 ₽
  /// on the day it came. A draft with another rate — 92 — does not move that figure: the refund's
  /// rate is the purchase's, and what its account received never follows it.
  @Test func aLinkedRefundsChargeIgnoresARateOnTheDraft() {
    let before = dollars(leg: money(4700), refund: true)
    let result = edit(before) {
      $0.rate = 92
      $0.rateSource = .manual
    }
    #expect(result == LegEdit(outcome: .kept, currency: .rub, amount: money(4700)))
  }

  /// 50 dollars at 90, 4 500 ₽ charged. The owner types the same rate, 90, by hand: nothing moved,
  /// the charge stays as it was and nothing asks to check it.
  @Test func theSameRateTypedByHandChangesNothing() {
    let before = dollars(leg: money(4500))
    let result = edit(before) {
      $0.rate = 90
      $0.rateSource = .manual
      $0.rateProvisional = false
    }
    #expect(result == LegEdit(outcome: .kept, currency: .rub, amount: money(4500)))
  }

  /// 4 620 ₽ typed from the statement for 50 dollars (a rate of 92.4 by hand). The rate field is
  /// cleared and the bank has no dollar rate at all: no rate is no new rate, and the figure from
  /// the statement stays as it was.
  @Test func aRateClearedWithNoBankRateKeepsTheTypedRubles() {
    let before = dollars(rate: Decimal(924) / 10, source: .manual, leg: money(4620))
    let result = AccountRules.legAfterEdit(
      before: before,
      after: {
        var draft = TransactionDraft(entry: before)
        draft.rate = nil
        draft.rateSource = nil
        return draft
      }(), account: card, rates: .empty, calendar: .utc)
    #expect(result == LegEdit(outcome: .kept, currency: .rub, amount: money(4620)))
  }

  /// The currency is corrected from dollars to euros together with a rate of 100. A figure typed
  /// from the statement, 4 620 ₽, stays and the editor asks to check it; the prefill of an
  /// untouched one, 4 500 ₽, follows: 50 euros at 100 — 5 000 ₽.
  @Test func aNewCurrencyWithItsRateRefillsOnlyAnUntouchedCharge() {
    let typed = dollars(rate: Decimal(924) / 10, source: .manual, leg: money(4620))
    let euros: (inout TransactionDraft) -> Void = {
      $0.currency = .eur
      $0.rate = 100
      $0.rateSource = .manual
    }
    #expect(
      edit(typed, euros) == LegEdit(outcome: .keptTyped, currency: .rub, amount: money(4620)))
    let untouched = dollars(leg: money(4500))
    #expect(
      edit(untouched, euros) == LegEdit(outcome: .prefilled, currency: .rub, amount: money(5000)))
  }

  /// The euros without a rate typed take the bank's rate of the day for an untouched charge.
  @Test func aNewCurrencyWithoutARateTakesTheBanksRate() {
    let untouched = dollars(leg: money(4500))
    let result = edit(untouched) {
      $0.currency = .eur
      $0.rate = nil
      $0.rateSource = nil
    }
    #expect(result == LegEdit(outcome: .prefilled, currency: .rub, amount: money(5000)))
  }

  /// A linked refund whose amount is cut to 20 dollars: its charge was untouched — the prefill of
  /// its own day, 50 × 90 = 4 500 ₽ — and is worked out again at the rates of that day, 1 800 ₽,
  /// never at the purchase's rate the refund carries (here 80).
  @Test func aLinkedRefundCutToLessIsRefilledAtItsOwnDaysRate() {
    let before = dollars(rate: 80, leg: money(4500), refund: true)
    let result = edit(before) {
      $0.amount = money(20)
      $0.parts[0].amount = money(20)
    }
    #expect(result == LegEdit(outcome: .prefilled, currency: .rub, amount: money(1800)))
  }
}
