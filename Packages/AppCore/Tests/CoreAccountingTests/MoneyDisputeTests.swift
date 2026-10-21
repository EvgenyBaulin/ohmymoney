import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// The cases the owner is asked about, with the very numbers of the question: an answer other
/// than the present behaviour changes one of these tests on purpose.
@Suite("The cases put to the owner, with their numbers")
struct MoneyDisputeTests {
  /// A part paid for Аня: 55.56 dollars, 5 000 ₽.
  var anya: OwedPart {
    OwedPart(
      partId: id(1), transactionId: id(11), occurredAt: moment("2026-03-01"),
      debtorPersonId: id(40), amountE4: money("55.56"), amountRubE4: money(5000), currency: .usd)
  }

  func dollarsBack(_ amount: String) -> MoneyBackPlan {
    let received = money(amount)
    return MoneyBack.plan(
      received: received, currency: .usd,
      receivedRub: MoneyDice.rounded(received.decimal * 90), rateProvisional: false,
      person: id(40), owed: [anya], openDebts: [])
  }

  /// Аня gives back 56 dollars at 90 — 5 040 ₽: the part closes, and the 0.44 dollars over
  /// (39.60 ₽) are income in «Доплаты» — every kopeck over the parts is (the owner's answer:
  /// 1.1 took up to 1 % of the part over as drift and wrote nothing).
  @Test func fiftySixDollarsCloseThePartAndTheRestIsIncome() {
    let plan = dollarsBack("56")
    #expect(plan.closes == [id(1)])
    #expect(plan.allocations == [ReimbursementAllocation(partId: id(1), amountE4: money(5000))])
    #expect(plan.surplus == money("0.44"))
    #expect(plan.surplusRub == money("39.6"))
  }

  /// 55.20 dollars (4 968 ₽): the link is 55.20 of 55.56 of the part's rubles — 4 967.6026 ₽ —,
  /// the 32.3974 ₽ left are within the drift, and the part closes with no shortfall.
  @Test func fiftyFiveTwentyCloseThePartWithNoShortfall() {
    let plan = dollarsBack("55.20")
    #expect(plan.closes == [id(1)])
    #expect(
      plan.allocations == [ReimbursementAllocation(partId: id(1), amountE4: money("4967.6026"))])
    #expect(plan.stillOwed.isEmpty)
    #expect(MoneyBack.outcome(plan, reimbursementTxId: id(9), accountId: id(7)).shortfalls.isEmpty)
  }

  /// 55 dollars: the link is 4 949.604 ₽ and 50.396 ₽ are left — just over the drift: the part
  /// stays open, waiting for them.
  @Test func fiftyFiveDollarsLeaveThePartWaiting() {
    let plan = dollarsBack("55")
    #expect(plan.closes.isEmpty)
    #expect(
      plan.allocations == [ReimbursementAllocation(partId: id(1), amountE4: money("4949.604"))])
    #expect(plan.stillOwed == [OwedRemainder(partId: id(1), remainingRubE4: money("50.396"))])
  }

  /// 50 dollars from the card at a rate of 92 typed by hand: 4 600 ₽ written, the rate manual.
  /// Later the amount is corrected to 60 dollars: after the save a typed rate and a typed charge
  /// look the same, so the 4 600 ₽ stay with «проверьте», and the rate becomes 4 600 ÷ 60.
  @Test func aTypedRateLooksLikeATypedChargeOnceSaved() throws {
    let before = TransactionEntry(
      transaction: Transaction(
        id: id(9), kind: .expense, occurredAt: moment("2026-03-02"), currency: .usd,
        amountE4: money(50), rate: 92, rateSource: .manual, amountRubE4: money(4600),
        paymentMethodId: id(1), accountCurrency: .rub, accountAmountE4: money(4600)),
      parts: [TransactionPart(transactionId: id(9), amountE4: money(50), amountRubE4: money(4600))])
    var after = TransactionDraft(entry: before)
    after.amount = money(60)
    after.parts[0].amount = money(60)
    let card = PaymentMethod(id: id(1), name: "Card", currency: .rub, isDefault: true)
    let edit = AccountRules.legAfterEdit(
      before: before, after: after, account: card, rates: .empty, calendar: .utc)
    #expect(edit == LegEdit(outcome: .keptTyped, currency: .rub, amount: money(4600)))
    after.accountCurrency = edit.currency
    after.accountAmount = edit.amount
    let saved = try after.materialize(id: id(9), now: moment("2026-03-03"))
    #expect(saved.transaction.amountRubE4 == money(4600))
    #expect(saved.transaction.rate.map { MoneyDice.rounded($0) } == money("76.6667"))
  }
}
