import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// A refund taken back from one part of one purchase, counted in the purchase.
@Suite("Refunds of a purchase")
struct RefundRulesTests {
  let categories = StartingCategories()

  /// A purchase of 100 dollars at 90: a jacket of 60 and a scarf of 40.
  func purchase(rate: Decimal = 90, deleted: Bool = false) -> TransactionEntry {
    let when = moment("2026-03-02")
    let transaction = Transaction(
      id: id(1), kind: .expense, occurredAt: when, currency: .usd, amountE4: money(100),
      rate: rate, rateDate: day("2026-03-02"), rateSource: .cbr, amountRubE4: money(9000),
      note: "clothes", placeId: id(51), paymentMethodId: id(60), createdAt: when,
      updatedAt: when, deletedAt: deleted ? when : nil)
    return TransactionEntry(
      transaction: transaction,
      parts: [
        TransactionPart(
          id: id(11), transactionId: id(1), categoryId: categories.groceries, quality: .neutral,
          amountE4: money(60), amountRubE4: money(5400), forWhom: .partner, eventId: id(70)),
        TransactionPart(
          id: id(12), transactionId: id(1), categoryId: categories.groceries,
          amountE4: money(40), amountRubE4: money(3600)),
      ])
  }

  /// A refund of `amount` dollars of the jacket, on `iso`, storing `rubles`.
  func refund(
    _ number: Int, of partId: UUID = id(11), amount: Int, rubles: Int, on iso: String,
    deleted: Bool = false
  ) -> TransactionEntry {
    let when = moment(iso)
    return TransactionEntry(
      transaction: Transaction(
        id: id(number), kind: .refund, occurredAt: when, currency: .usd,
        amountE4: money(amount), amountRubE4: money(rubles), createdAt: when, updatedAt: when,
        deletedAt: deleted ? when : nil),
      parts: [
        TransactionPart(
          id: id(number * 10), transactionId: id(number), categoryId: categories.groceries,
          amountE4: money(amount), amountRubE4: money(rubles), refundOfPartId: partId)
      ])
  }

  // MARK: Refunds following their purchase

  /// A single purchase of 100 $ at 90 (9,000 ₽) with a refund of 90 $ (8,100 ₽): the owner
  /// types 50 — the purchase 5,000 ₽, the refund 4,500 ₽ at the purchase's manual rate; the last
  /// 10 $ refunded later complete the part with 500 ₽. At 200: 20,000 ₽, 18,000 ₽ and 2,000 ₽.
  @Test func refundsFollowAPurchaseRepricedByHand() throws {
    let when = moment("2026-03-02")
    let bought = TransactionEntry(
      transaction: Transaction(
        id: id(1), kind: .expense, occurredAt: when, currency: .usd, amountE4: money(100),
        rate: 90, rateDate: day("2026-03-02"), rateSource: .cbr, amountRubE4: money(9000)),
      parts: [
        TransactionPart(
          id: id(11), transactionId: id(1), amountE4: money(100), amountRubE4: money(9000))
      ])
    let first = refund(2, amount: 90, rubles: 8100, on: "2026-03-10")
    for (rate, refunded, last) in [(Decimal(50), 4500, 500), (Decimal(200), 18_000, 2000)] {
      let repriced = try PurchaseRate.repriced(bought, rate: rate, day: day("2026-03-02"))
      let followed = RefundRules.following(purchase: repriced, refunds: [first])
      #expect(followed.count == 1)
      #expect(followed.first?.transaction.amountRubE4 == money(refunded))
      #expect(followed.first?.parts.first?.amountRubE4 == money(refunded))
      #expect(followed.first?.transaction.rate == rate)
      #expect(followed.first?.transaction.rateSource == .manual)
      #expect(followed.first?.transaction.accountAmountE4 == first.transaction.accountAmountE4)
      let rest = RefundRules.rubles(
        refundAmount: money(10), part: repriced.parts[0],
        refundedBefore: (money(90), money(refunded)))
      #expect(rest == money(last))
    }
    // Nothing changed, nothing comes back.
    let same = RefundRules.following(
      purchase: bought, refunds: RefundRules.following(purchase: bought, refunds: [first]))
    #expect(same.isEmpty)
  }

  /// Two refunds of one part share it oldest first; a deleted one is left out.
  @Test func refundsFollowOldestFirstAndSkipDeletedOnes() {
    let refunds = [
      refund(2, amount: 30, rubles: 2000, on: "2026-03-10"),
      refund(3, amount: 30, rubles: 2000, on: "2026-03-12", deleted: true),
      refund(4, amount: 30, rubles: 2000, on: "2026-03-15"),
    ]
    let followed = RefundRules.following(purchase: purchase(), refunds: refunds)
    #expect(followed.map(\.id) == [id(2), id(4)])
    #expect(followed.map(\.transaction.amountRubE4) == [money(2700), money(2700)])
    #expect(followed.allSatisfy { $0.transaction.rate == 90 })
  }

  // MARK: The index

  @Test func aFullRefundTakesThePartToZeroWhateverItsOwnRublesSay() {
    let index = RefundIndex(
      entries: [purchase(), refund(2, amount: 60, rubles: 5000, on: "2026-03-20")], debts: [:])
    #expect(index.isLinked(refundPart: id(20)))
    #expect(index.purchasePart(ofRefundPart: id(20)) == id(11))
    #expect(index.refunded(part: id(11)) == money(60))
    #expect(index.refundedRub(part: id(11)) == money(5400))
    #expect(index.movedContribution(part: id(11)) == money(-5400))
    #expect(index.refunds(ofPart: id(11)) == [id(2)])
    #expect(index.refundedRub(part: id(12)) == .zero)
  }

  /// The rubles follow the part: after the rate of the purchase is edited, a full refund still
  /// takes the whole part.
  @Test func aFullRefundStillZeroesThePartAfterTheRateOfThePurchaseIsEdited() {
    var edited = purchase(rate: 95)
    edited.parts[0].amountRubE4 = money(5700)
    let index = RefundIndex(
      entries: [edited, refund(2, amount: 60, rubles: 5400, on: "2026-03-20")], debts: [:])
    #expect(index.refundedRub(part: id(11)) == money(5700))
  }

  @Test func aPartialRefundTakesItsShareOfTheRubles() {
    let index = RefundIndex(
      entries: [
        purchase(), refund(2, amount: 20, rubles: 1800, on: "2026-03-10"),
        refund(3, amount: 10, rubles: 900, on: "2026-03-12"),
      ], debts: [:])
    #expect(index.refunded(part: id(11)) == money(30))
    #expect(index.refundedRub(part: id(11)) == money(2700))
    #expect(index.refundedStoredRub(part: id(11)) == money(2700))
    #expect(index.refunds(ofPart: id(11)) == [id(2), id(3)])
  }

  @Test func aRefundOfAGoneOrUnknownPurchaseIsARefundOfItsOwn() {
    let gone = RefundIndex(
      entries: [purchase(deleted: true), refund(2, amount: 20, rubles: 1800, on: "2026-03-10")],
      debts: [:])
    #expect(!gone.isLinked(refundPart: id(20)))
    let deletedRefund = RefundIndex(
      entries: [purchase(), refund(2, amount: 20, rubles: 1800, on: "2026-03-10", deleted: true)],
      debts: [:])
    #expect(deletedRefund.refunded(part: id(11)) == .zero)
  }

  /// A purchase that is no spending of mine — a payment on a debt that is no expense — has
  /// nothing a refund could take off it.
  @Test func nothingIsTakenOffWhatWasNeverMySpending() {
    var payment = purchase()
    payment.transaction.debtId = id(201)
    let index = RefundIndex(
      entries: [payment, refund(2, amount: 60, rubles: 5400, on: "2026-03-20")],
      debts: [id(201): purchaseDebt()])
    #expect(index.refundedRub(part: id(11)) == money(5400))
    #expect(index.movedContribution(part: id(11)) == .zero)
  }

  // MARK: The totals of a day and of a selection

  @Test func theTotalsCountTheRefundInThePurchase() {
    let entries = [purchase(), refund(2, amount: 20, rubles: 1900, on: "2026-03-10")]
    let index = RefundIndex(entries: entries, debts: [:])
    let purchaseDay = RowTotals(entries: [entries[0]], refunds: index)
    #expect(purchaseDay.myExpenses == money(9000 - 1800))
    let refundDay = RowTotals(entries: [entries[1]], refunds: index)
    #expect(refundDay.myExpenses == .zero)
    #expect(refundDay.isEmpty)
    // Without the index — an old caller — a refund counts on its own day, as it always did.
    #expect(RowTotals(entries: [entries[1]]).myExpenses == money(-1900))
  }

  // MARK: What can be refunded

  @Test func onlyAPurchaseOfMyOwnCanBeRefunded() {
    let tree = categories.tree
    let ordinary = purchase()
    #expect(RefundRules.isRefundable(part: ordinary.parts[0], in: ordinary, tree: tree))

    var forFriend = ordinary
    forFriend.parts[0].reimbursable = true
    #expect(!RefundRules.isRefundable(part: forFriend.parts[0], in: forFriend, tree: tree))

    var onCredit = ordinary
    onCredit.transaction.creditDebtId = id(201)
    #expect(!RefundRules.isRefundable(part: onCredit.parts[0], in: onCredit, tree: tree))

    var debtPayment = ordinary
    debtPayment.transaction.debtId = id(200)
    #expect(!RefundRules.isRefundable(part: debtPayment.parts[0], in: debtPayment, tree: tree))

    var goal = ordinary
    goal.parts[0].categoryId = categories.goalsTrip
    #expect(!RefundRules.isRefundable(part: goal.parts[0], in: goal, tree: tree))

    var books = ordinary
    books.transaction.externalId =
      "reimb:\(id(5).uuidString.lowercased()):shortfall:\(id(6).uuidString.lowercased())"
    #expect(!RefundRules.isRefundable(part: books.parts[0], in: books, tree: tree))

    let deleted = purchase(deleted: true)
    #expect(!RefundRules.isRefundable(part: deleted.parts[0], in: deleted, tree: tree))

    let income = entry(id(3), kind: .income, parts: [part(id(31), amount: money(10))])
    #expect(!RefundRules.isRefundable(part: income.parts[0], in: income, tree: tree))
  }

  // MARK: The refund itself

  @Test func theWholeRefundIsWhatIsLeftInThePurchasesCurrencyAtItsRate() throws {
    let original = purchase()
    let index = RefundIndex(
      entries: [original, refund(2, amount: 20, rubles: 1800, on: "2026-03-10")], debts: [:])
    let draft = try RefundRules.draft(
      refunding: original.parts[0], of: original, amount: nil, occurredAt: moment("2026-03-25"),
      accountId: nil, index: index, tree: categories.tree)
    #expect(draft.kind == .refund)
    #expect(draft.currency == .usd)
    #expect(draft.amount == money(40))
    #expect(draft.rate == 90)
    #expect(draft.rateSource == .cbr)
    #expect(draft.paymentMethodId == id(60))
    #expect(draft.placeId == id(51))
    #expect(draft.parts.count == 1)
    #expect(draft.parts[0].refundOfPartId == id(11))
    #expect(draft.parts[0].categoryId == categories.groceries)
    #expect(draft.parts[0].forWhom == .partner)
    #expect(draft.parts[0].eventId == id(70))

    let elsewhere = try RefundRules.draft(
      refunding: original.parts[0], of: original, amount: money(5),
      occurredAt: moment("2026-03-25"), accountId: id(61), index: index, tree: categories.tree)
    #expect(elsewhere.paymentMethodId == id(61))
    #expect(elsewhere.amount == money(5))
  }

  @Test func noMoreThanIsLeftIsRefunded() {
    let original = purchase()
    let index = RefundIndex(
      entries: [original, refund(2, amount: 60, rubles: 5400, on: "2026-03-10")], debts: [:])
    #expect(throws: RefundError.exceedsRemaining) {
      try RefundRules.draft(
        refunding: original.parts[0], of: original, amount: nil,
        occurredAt: moment("2026-03-25"), accountId: nil, index: index, tree: categories.tree)
    }
    #expect(throws: RefundError.exceedsRemaining) {
      try RefundRules.draft(
        refunding: original.parts[1], of: original, amount: money(41),
        occurredAt: moment("2026-03-25"), accountId: nil, index: index, tree: categories.tree)
    }
    #expect(throws: RefundError.notPositive) {
      try RefundRules.draft(
        refunding: original.parts[1], of: original, amount: .zero,
        occurredAt: moment("2026-03-25"), accountId: nil, index: index, tree: categories.tree)
    }
    var forFriend = original
    forFriend.parts[1].reimbursable = true
    #expect(throws: RefundError.notRefundable) {
      try RefundRules.draft(
        refunding: forFriend.parts[1], of: forFriend, amount: nil,
        occurredAt: moment("2026-03-25"), accountId: nil, index: index, tree: categories.tree)
    }
    #expect(RefundRules.remaining(part: original.parts[1], index: index) == money(40))
    #expect(RefundRules.remaining(part: original.parts[0], index: index) == .zero)
  }

  /// The refund keeps the purchase's rate for its rubles, but an account that does not hold the
  /// currency is credited at the rates of the refund's own day, the way the bank converts it:
  /// 40 dollars back on the 20th, when the dollar is 95, are 3 800 rubles on a ruble card — not
  /// the 3 600 of the purchase's rate.
  @Test func whatTheAccountReceivesIsAtTheRatesOfTheRefundsDay() {
    let refundDay = day("2026-03-20")
    let rates = DayRates(series: [
      CurrencyCode.usd: [
        DayRate(day: day("2026-03-02"), perUnit: 90), DayRate(day: refundDay, perUnit: 95),
      ],
      CurrencyCode("KZT"): [DayRate(day: refundDay, perUnit: Decimal(19) / 100)],
    ])
    let card = PaymentMethod(id: id(60), name: "Card", currency: .rub)
    #expect(
      RefundRules.prefillLeg(
        amount: money(40), currency: .usd, day: refundDay, account: card, rates: rates)
        == money(3800))
    let tenge = PaymentMethod(id: id(61), name: "Tenge", currency: CurrencyCode("KZT"))
    #expect(
      RefundRules.prefillLeg(
        amount: money(40), currency: .usd, day: refundDay, account: tenge, rates: rates)
        == money(20000))
    let dollars = PaymentMethod(id: id(62), name: "Dollars", currency: .usd)
    #expect(
      RefundRules.prefillLeg(
        amount: money(40), currency: .usd, day: refundDay, account: dollars, rates: rates) == nil)
    #expect(
      RefundRules.prefillLeg(
        amount: money(40), currency: .usd, day: day("2026-03-25"), account: card, rates: .empty)
        == nil)
  }

  /// The refund completing the part stores what is left of its rubles, so the stored rubles of
  /// all its refunds add up to the part exactly; any other stores its share.
  @Test func theStoredRublesAddUpToThePart() {
    let jacket = purchase().parts[0]
    #expect(
      RefundRules.rubles(
        refundAmount: money(20), part: jacket, refundedBefore: (.zero, .zero)) == money(1800))
    #expect(
      RefundRules.rubles(
        refundAmount: money(40), part: jacket, refundedBefore: (money(20), money(1801)))
        == money(3599))
  }
}
