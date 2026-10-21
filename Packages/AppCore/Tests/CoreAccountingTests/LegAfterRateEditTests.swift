import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// «Списано со счёта» of a saved operation when only its rate is edited.
///
/// A figure in rubles is the operation's rubles: the save works the rate out of it
/// (`TransactionDraft.materialize`). So a figure kept over a new rate throws the rate away — the
/// save puts back the rate the old figure implies — and the edit has no effect at all. A rate
/// typed after the figure is the owner's later word: the figure follows it.
@Suite("The charge after the rate of an operation is edited")
struct LegAfterRateEditTests {
  let kzt = CurrencyCode("KZT")
  let rates = DayRates(series: [
    CurrencyCode.usd: [DayRate(day: DateOnly(year: 2026, month: 3, day: 1), perUnit: 90)],
    CurrencyCode("KZT"): [
      DayRate(day: DateOnly(year: 2026, month: 3, day: 1), perUnit: Decimal(18) / 100)
    ],
  ])
  let card = PaymentMethod(id: id(1), name: "Card", currency: .rub, isDefault: true)
  var tenge: PaymentMethod { PaymentMethod(id: id(1), name: "Tenge", currency: kzt) }

  /// 50 dollars at `rate` on account 1, charged `leg`.
  func dinner(
    rate: Decimal = 90, source: RateSource = .cbr, leg: (CurrencyCode, AmountE4)?
  ) -> TransactionEntry {
    let rub = (try? AmountE4(decimal: money(50).decimal * rate)) ?? .zero
    return TransactionEntry(
      transaction: Transaction(
        id: id(9), kind: .expense, occurredAt: moment("2026-03-02"), currency: .usd,
        amountE4: money(50), rate: rate, rateSource: source, amountRubE4: rub,
        paymentMethodId: id(1), accountCurrency: leg?.0, accountAmountE4: leg?.1),
      parts: [TransactionPart(transactionId: id(9), amountE4: money(50), amountRubE4: rub)])
  }

  func withRate(_ entry: TransactionEntry, _ rate: Decimal) -> TransactionDraft {
    var draft = TransactionDraft(entry: entry)
    draft.rate = rate
    draft.rateSource = .manual
    draft.rateProvisional = false
    return draft
  }

  /// 50 dollars at 90 charged 4 500 ₽ from the card — the prefill. The owner types the rate from
  /// the statement, 92: the charge becomes 4 600, and the save keeps 92.
  @Test func anUntouchedRubleChargeFollowsANewRate() throws {
    let before = dinner(leg: (.rub, money(4500)))
    let after = withRate(before, 92)
    let edit = AccountRules.legAfterEdit(
      before: before, after: after, account: card, rates: rates, calendar: .utc)
    #expect(edit == LegEdit(outcome: .prefilled, currency: .rub, amount: money(4600)))

    var saved = after
    saved.accountCurrency = edit.currency
    saved.accountAmount = edit.amount
    let entry = try saved.materialize(id: id(9), now: moment("2026-03-02"))
    #expect(entry.transaction.rate == 92)
    #expect(entry.transaction.amountRubE4 == money(4600))
  }

  /// A figure in rubles typed from the statement, 4 620 — a rate of 92.4 by hand. A rate typed
  /// after it, 93, is the owner's later word: the figure is worked out from it, 4 650.
  @Test func aRateTypedAfterATypedRubleChargeIsTheLaterWord() {
    let before = dinner(rate: Decimal(924) / 10, source: .manual, leg: (.rub, money(4620)))
    let edit = AccountRules.legAfterEdit(
      before: before, after: withRate(before, 93), account: card, rates: rates, calendar: .utc)
    #expect(edit == LegEdit(outcome: .prefilled, currency: .rub, amount: money(4650)))
  }

  /// On a tenge account the untouched charge — 50 dollars at 90 through 0.18 ₽ a tenge: 25 000 —
  /// follows a new dollar rate, 92: 25 555.5556. One typed from the statement stays, and the
  /// editor asks to check it.
  @Test func anotherChargeFollowsWhenUntouchedAndStaysWhenTyped() {
    let prefilled = dinner(leg: (kzt, money(25_000)))
    #expect(
      AccountRules.legAfterEdit(
        before: prefilled, after: withRate(prefilled, 92), account: tenge, rates: rates,
        calendar: .utc)
        == LegEdit(outcome: .prefilled, currency: kzt, amount: money("25555.5556")))
    let typed = dinner(leg: (kzt, money(24_870)))
    #expect(
      AccountRules.legAfterEdit(
        before: typed, after: withRate(typed, 92), account: tenge, rates: rates, calendar: .utc)
        == LegEdit(outcome: .keptTyped, currency: kzt, amount: money(24_870)))
  }

  /// An edit that leaves the rate as it was — only the note changes here — keeps the charge as it
  /// was. The same rate typed again by hand is `LegAfterEditConditionTests`.
  @Test func theSameRateChangesNothing() {
    let before = dinner(leg: (.rub, money(4500)))
    var after = TransactionDraft(entry: before)
    after.note = "dinner"
    #expect(
      AccountRules.legAfterEdit(
        before: before, after: after, account: card, rates: rates, calendar: .utc)
        == LegEdit(outcome: .kept, currency: .rub, amount: money(4500)))
  }
}
