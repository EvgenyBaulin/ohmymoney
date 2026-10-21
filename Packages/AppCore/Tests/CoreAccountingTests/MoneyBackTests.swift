import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// Money back spread over what a person owes, oldest first, a part covered partly staying open.
@Suite("Money back")
struct MoneyBackTests {
  let categories = StartingCategories()
  let anya = id(40)

  /// A part of `rubles` paid for Anya on `iso`, in `currency` for `amount` when given.
  func owed(
    _ number: Int, rubles: Int, on iso: String, currency: CurrencyCode = .rub,
    amount: Int? = nil, returned: Int = 0, provisional: Bool = false
  ) -> OwedPart {
    OwedPart(
      partId: id(number), transactionId: id(number + 1000), occurredAt: moment(iso),
      debtorPersonId: anya, categoryId: categories.groceries, forWhom: .friends,
      amountE4: money(amount ?? rubles), amountRubE4: money(rubles), currency: currency,
      rateProvisional: provisional, returnedRubE4: money(returned), accountId: id(1))
  }

  func plan(
    _ received: Int, currency: CurrencyCode = .rub, rubles: Int? = nil,
    provisional: Bool = false, from person: UUID? = nil, owed: [OwedPart], debts: [Debt] = []
  ) -> MoneyBackPlan {
    MoneyBack.plan(
      received: money(received), currency: currency, receivedRub: money(rubles ?? received),
      rateProvisional: provisional, person: person ?? anya, owed: owed, openDebts: debts)
  }

  // MARK: Partial money back

  /// 1 700 ₽ against parts of 1 000 and 1 500: the first closes, the second keeps waiting with
  /// 800, and nothing falls short.
  @Test func thePartCoveredPartlyStaysOpenWithWhatIsLeft() {
    let result = plan(
      1700,
      owed: [owed(2, rubles: 1500, on: "2026-03-05"), owed(1, rubles: 1000, on: "2026-03-01")])
    #expect(result.refusal == nil)
    #expect(result.allocations.map(\.partId) == [id(1), id(2)])
    #expect(result.allocations.map(\.amountE4) == [money(1000), money(700)])
    #expect(result.closes == [id(1)])
    #expect(result.stillOwed == [OwedRemainder(partId: id(2), remainingRubE4: money(800))])
    #expect(result.surplus == .zero)

    let outcome = MoneyBack.outcome(result, reimbursementTxId: id(9), accountId: id(1))
    #expect(outcome.shortfalls.isEmpty)
    #expect(outcome.closedPartIds == [id(1)])
    #expect(outcome.links.map(\.amountE4) == [money(1000), money(700)])
    #expect(outcome.surplus == nil)
  }

  @Test func whatCameBackEarlierIsNotOwedAgain() {
    let result = plan(800, owed: [owed(2, rubles: 1500, on: "2026-03-05", returned: 700)])
    #expect(result.allocations.map(\.amountE4) == [money(800)])
    #expect(result.closes == [id(2)])
    #expect(result.stillOwed.isEmpty)
  }

  @Test func moneyOverEverythingOwedIsIncomeOnTheAccountItCameOnto() {
    let result = plan(2000, owed: [owed(1, rubles: 1500, on: "2026-03-01")])
    #expect(result.surplus == money(500))
    #expect(result.surplusRub == money(500))
    let outcome = MoneyBack.outcome(result, reimbursementTxId: id(9), accountId: id(3))
    #expect(outcome.surplus?.amountE4 == money(500))
    #expect(outcome.surplus?.currency == .rub)
    #expect(outcome.surplus?.accountId == id(3))
  }

  // MARK: Currencies

  /// 50 dollars back for a part of 50 dollars close it exactly, whatever the rate did: its
  /// link is all of its rubles, nothing is over and nothing is short.
  @Test func theSameCurrencyClosesExactlyAtAnotherRate() {
    let part = owed(1, rubles: 4750, on: "2026-03-01", currency: .usd, amount: 50)
    let result = plan(50, currency: .usd, rubles: 4600, owed: [part])
    #expect(result.closes == [id(1)])
    #expect(result.allocations.map(\.amountE4) == [money(4750)])
    #expect(result.surplus == .zero)
    #expect(result.surplusRub == .zero)
  }

  @Test func partOfADollarPartComesBackInDollars() {
    let part = owed(1, rubles: 9000, on: "2026-03-01", currency: .usd, amount: 100)
    let result = plan(40, currency: .usd, rubles: 3800, owed: [part])
    #expect(result.allocations.map(\.amountE4) == [money(3600)])
    #expect(result.closes.isEmpty)
    #expect(result.stillOwed == [OwedRemainder(partId: id(1), remainingRubE4: money(5400))])
  }

  /// Dollars back for a ruble part: the part needs its rubles at the money back's rate.
  @Test func dollarsBackForARublePartCountAtTheirOwnRate() {
    let part = owed(1, rubles: 1000, on: "2026-03-01")
    let result = plan(20, currency: .usd, rubles: 2000, owed: [part])
    #expect(result.allocations.map(\.amountE4) == [money(1000)])
    #expect(result.closes == [id(1)])
    #expect(result.surplus == money(10))
    #expect(result.surplusRub == money(1000))
  }

  // MARK: The tolerance

  @Test func theToleranceIsOnlyForForeignMoney() {
    #expect(MoneyBack.tolerance(partRub: money(4750), foreignInvolved: false) == .zero)
    #expect(MoneyBack.tolerance(partRub: money(4750), foreignInvolved: true) == money("47.5"))
    #expect(MoneyBack.tolerance(partRub: money(50), foreignInvolved: true) == money(1))
    #expect(MoneyBack.tolerance(partRub: money(100_000), foreignInvolved: true) == money(50))
  }

  /// A dollar part nearly covered by rubles closes: what is left is the drift of the rate.
  @Test func aRemainderWithinTheToleranceClosesThePart() {
    let part = owed(1, rubles: 4750, on: "2026-03-01", currency: .usd, amount: 50)
    let result = plan(4720, owed: [part])
    #expect(result.closes == [id(1)])
    #expect(result.allocations.map(\.amountE4) == [money(4720)])
    #expect(result.stillOwed.isEmpty)
  }

  @Test func inRublesAlonePartOfAPartIsNeverClosedByTolerance() {
    let result = plan(1499, owed: [owed(1, rubles: 1500, on: "2026-03-01")])
    #expect(result.closes.isEmpty)
    #expect(result.stillOwed == [OwedRemainder(partId: id(1), remainingRubE4: money(1))])
  }

  /// Money over the parts is income however little it is: 4,780 ₽ back for a dollar part of
  /// 4,750 ₽ leave 30 ₽ of income (the tolerance is only for what is left of a part).
  @Test func everySurplusIsIncome() {
    let part = owed(1, rubles: 4750, on: "2026-03-01", currency: .usd, amount: 50)
    let result = plan(4780, owed: [part])
    #expect(result.closes == [id(1)])
    #expect(result.surplus == money(30))
    #expect(result.surplusRub == money(30))
    #expect(
      MoneyBack.outcome(result, reimbursementTxId: id(9), accountId: nil).surplus?.amountE4
        == money(30))
    // 56 $ back at 90 for a part of 55.56 $ that cost 5,000 ₽: 0.44 $ = 39.60 ₽ of income.
    var dollars = owed(2, rubles: 5000, on: "2026-03-01", currency: .usd, amount: 55)
    dollars.amountE4 = money("55.56")
    let fromDollars = plan(56, currency: .usd, rubles: 5040, owed: [dollars])
    #expect(fromDollars.surplus == money("0.44"))
    #expect(fromDollars.surplusRub == money("39.6"))
  }

  /// What is over by less than a kopeck is the rounding of the shares, not income.
  @Test func aSubKopeckCrumbIsNoIncome() {
    let part = owed(1, rubles: 1000, on: "2026-03-01")
    let crumb = MoneyBack.plan(
      received: money("1000.0099"), currency: .rub, receivedRub: money("1000.0099"),
      rateProvisional: false, person: anya, owed: [part], openDebts: [])
    #expect(crumb.closes == [id(1)])
    #expect(crumb.surplus == .zero)
    #expect(crumb.surplusRub == .zero)
    let kopeck = MoneyBack.plan(
      received: money("1000.01"), currency: .rub, receivedRub: money("1000.01"),
      rateProvisional: false, person: anya, owed: [part], openDebts: [])
    #expect(kopeck.surplus == money("0.01"))
  }

  /// The owner's case: a subscription of 20 $ paid from the ruble card at 90 (1,800 ₽), and a
  /// friend sends 2,000 ₽: the part closes and 200 ₽ are income.
  @Test func theOwnersSubscriptionExample() {
    let part = owed(1, rubles: 1800, on: "2026-09-01", currency: .usd, amount: 20)
    let result = plan(2000, owed: [part])
    #expect(result.closes == [id(1)])
    #expect(result.allocations.map(\.amountE4) == [money(1800)])
    #expect(result.surplus == money(200))
    #expect(result.surplusRub == money(200))
  }

  // MARK: Refusals

  @Test func theMoneyBacksOwnProvisionalRateIsRefused() {
    let part = owed(1, rubles: 1000, on: "2026-03-01")
    #expect(
      plan(10, currency: .usd, rubles: 950, provisional: true, owed: [part]).refusal
        == .provisionalRate)
  }

  @Test func partsOnAProvisionalRateAreSkippedAndSaidSo() {
    let waiting = owed(1, rubles: 1000, on: "2026-03-01", provisional: true)
    let ready = owed(2, rubles: 500, on: "2026-03-02")
    let result = plan(500, owed: [waiting, ready])
    #expect(result.skippedProvisional == [id(1)])
    #expect(result.closes == [id(2)])
    #expect(result.stillOwed.map(\.partId) == [id(1)])
    #expect(plan(500, owed: [waiting]).refusal == .onlyProvisional)
  }

  /// The person owes 1 000 ₽ and 50 $ on a rate still provisional, and gives 5 500 ₽ back. The
  /// money over the 1 000 is not income while the dollars are still owed: it would be counted
  /// twice — once as income now, once more when the dollar part is closed or written off.
  @Test func noSurplusWhilePartsOnAProvisionalRateAreStillOwed() {
    let rubles = owed(1, rubles: 1000, on: "2026-03-01")
    let dollars = owed(
      2, rubles: 4500, on: "2026-03-02", currency: .usd, amount: 50, provisional: true)
    let result = plan(5500, owed: [rubles, dollars])
    #expect(result.refusal == .provisionalPartsOwed)
    #expect(result.skippedProvisional == [id(2)])
    #expect(result.allocations.isEmpty)
    #expect(result.surplus == .zero)
    #expect(MoneyBack.outcome(result, reimbursementTxId: id(9), accountId: nil).surplus == nil)
    // No more than the parts that can be closed: nothing is over, and the plan stands.
    let exact = plan(1000, owed: [rubles, dollars])
    #expect(exact.refusal == nil)
    #expect(exact.closes == [id(1)])
    #expect(exact.skippedProvisional == [id(2)])
  }

  @Test func somebodyWhoOwesNothingIsOfferedIncomeOrARepaymentOfTheirDebt() {
    #expect(plan(500, owed: []).refusal == .owesNothing)
    let debt = Debt(
      id: id(200), direction: .owedToMe, type: .personal, name: "Loan to Anya", personId: anya)
    #expect(plan(500, owed: [], debts: [debt]).refusal == .owesOnDebt(id(200)))
    var closed = debt
    closed.closed = true
    #expect(plan(500, owed: [], debts: [closed]).refusal == .owesNothing)
  }

  /// A debt owed to me is offered only while something is left on it: money from somebody whose
  /// debt is at zero is income. A debt the caller has no balance for counts as owing.
  @Test func owesOnDebtOnlyWhileTheDebtHasABalance() {
    let debt = Debt(
      id: id(200), direction: .owedToMe, type: .personal, name: "Loan to Anya", personId: anya)
    func refusal(_ balances: [UUID: AmountE4]) -> MoneyBackRefusal? {
      MoneyBack.plan(
        received: money(500), currency: .rub, receivedRub: money(500), rateProvisional: false,
        person: anya, owed: [], openDebts: [debt], debtBalances: balances
      ).refusal
    }
    #expect(refusal([id(200): money(300)]) == .owesOnDebt(id(200)))
    #expect(refusal([id(200): .zero]) == .owesNothing)
    #expect(refusal([id(200): money(-10)]) == .owesNothing)
    #expect(refusal([:]) == .owesOnDebt(id(200)))
  }

  /// Only the debts of the person who gave the money back are offered: another person's debt
  /// — first by name — is not.
  @Test func onlyThePersonsOwnDebtIsOffered() {
    let boris = id(41)
    let borisDebt = Debt(
      id: id(201), direction: .owedToMe, type: .personal, name: "A loan to Boris",
      personId: boris)
    let anyaDebt = Debt(
      id: id(202), direction: .owedToMe, type: .personal, name: "Loan to Anya", personId: anya)
    #expect(plan(500, owed: [], debts: [borisDebt, anyaDebt]).refusal == .owesOnDebt(id(202)))
    #expect(
      plan(500, from: boris, owed: [], debts: [borisDebt, anyaDebt]).refusal
        == .owesOnDebt(id(201)))
    #expect(
      plan(500, from: id(42), owed: [], debts: [borisDebt, anyaDebt]).refusal
        == .owesNothing)
  }

  // MARK: «Списать остаток»

  @Test func whatIsLeftIsWrittenOffFromThePurchasesAccount() throws {
    let part = owed(1, rubles: 1500, on: "2026-03-01", returned: 700)
    let entry = MoneyBack.remainderWriteOff(
      part: part, occurredAt: moment("2026-03-10"), operationId: id(77), tree: categories.tree,
      now: moment("2026-03-10"))
    #expect(entry.id == id(77))
    #expect(entry.transaction.kind == .expense)
    #expect(entry.transaction.amountE4 == money(800))
    #expect(entry.transaction.amountRubE4 == money(800))
    #expect(entry.transaction.paymentMethodId == id(1))
    #expect(entry.parts.first?.categoryId == categories.groceries)
    #expect(entry.parts.first?.forPersonId == anya)
    let link = try #require(OperationLink(externalId: entry.transaction.externalId))
    #expect(
      link
        == .remainderWriteOff(
          part: id(1).uuidString.lowercased(), operation: id(77).uuidString.lowercased()))
    #expect(link.isBookkeeping)
  }
}

/// «Вручную…»: ticking a part settles it, and whatever did not come back is counted short —
/// but only of what was still owed.
@Suite("Money back settled by hand")
struct ManualMoneyBackTests {
  let categories = StartingCategories()

  /// 700 came back for a part of 1 500 earlier. Settled by hand with nothing more, the part
  /// falls short by 800 — not by 1 500.
  @Test func noShortfallForMoneyThatAlreadyCameBack() throws {
    let purchase = entry(
      id(1), on: "2026-03-01",
      parts: [
        part(
          id(11), amount: money(1500), category: categories.groceries, reimbursable: true,
          debtor: id(40))
      ])
    let earlier = ReimbursementLink(reimbursementTxId: id(5), partId: id(11), amountE4: money(700))
    let owed = MyExpensesRule.owedToMe(entries: [purchase], links: [earlier])
    #expect(owed.map(\.remainingRubE4) == [money(800)])

    let outcome = try ReimbursementResolver.resolve(
      reimbursementTxId: id(9), amountE4: .zero, closing: owed.map(\.inRubles))
    #expect(outcome.shortfalls.map(\.amountE4) == [money(800)])
    #expect(outcome.closedPartIds == [id(11)])
  }

  @Test func aShareAboveWhatIsStillOwedIsRefused() {
    let purchase = entry(
      id(1), on: "2026-03-01",
      parts: [part(id(11), amount: money(1500), reimbursable: true, debtor: id(40))])
    let earlier = ReimbursementLink(reimbursementTxId: id(5), partId: id(11), amountE4: money(700))
    let owed = MyExpensesRule.owedToMe(entries: [purchase], links: [earlier]).map(\.inRubles)
    #expect(throws: ReimbursementError.allocationExceedsPart(id(11))) {
      try ReimbursementResolver.resolve(
        reimbursementTxId: id(9), amountE4: money(1000), closing: owed,
        allocation: [ReimbursementAllocation(partId: id(11), amountE4: money(900))])
    }
  }

  @Test func aShortfallIsSpendingFromThePurchasesAccount() throws {
    var purchase = entry(
      id(1), on: "2026-03-01",
      parts: [part(id(11), amount: money(1500), reimbursable: true, debtor: id(40))])
    purchase.transaction.paymentMethodId = id(3)
    let owed = MyExpensesRule.owedToMe(entries: [purchase]).map(\.inRubles)
    let outcome = try ReimbursementResolver.resolve(
      reimbursementTxId: id(9), amountE4: money(1000), closing: owed, accountId: id(4))
    #expect(outcome.shortfalls.first?.accountId == id(3))
    #expect(outcome.surplus == nil)
  }

  /// A link counts while its money back is live: a deleted one gives nothing back.
  @Test func aLinkOfDeletedMoneyBackGivesNothingBack() {
    let purchase = entry(
      id(1), on: "2026-03-01",
      parts: [part(id(11), amount: money(1500), reimbursable: true, debtor: id(40))])
    let gone = entry(
      id(5), kind: .reimbursement, on: "2026-03-02", deleted: true,
      parts: [part(id(51), amount: money(700))])
    let link = ReimbursementLink(reimbursementTxId: id(5), partId: id(11), amountE4: money(700))
    #expect(
      MyExpensesRule.owedToMe(entries: [purchase, gone], links: [link]).map(\.remainingRubE4)
        == [money(1500)])
    #expect(MyExpensesRule.totalOwedToMe(entries: [purchase], links: [link]) == money(800))
  }
}
