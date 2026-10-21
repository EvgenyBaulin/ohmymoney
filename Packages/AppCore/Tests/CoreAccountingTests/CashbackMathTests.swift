import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// How much cashback an operation is expected to earn: the money that moved on the account, by
/// the rule of each part's category, rounded once to the kopeck; refunds make a purchase
/// cheaper; what the owner typed wins. Never income.
@Suite("Expected cashback of an operation")
struct CashbackMathTests {
  let fixture = CashbackFixture()
  var kzt: CurrencyCode { CurrencyCode("KZT") }

  func rub(_ text: String) -> Money { Money(amount: money(text), currency: .rub) }

  /// 12.09 «coffee 350 black», Coffee: the month's rule of Cafes, 10 % → 35.00.
  @Test func simplePurchase() throws {
    let coffee = fixture.operation(
      on: "09-12", parts: [(fixture.coffee, money(350))], account: fixture.tBank,
      card: fixture.black)
    let expected = try #require(fixture.expected(coffee))
    #expect(expected.money == rub("35"))
    #expect(expected.rubles == money(35))
    #expect(expected.holder == .card(fixture.black))
    #expect(expected.source == .rules([id(303)]))
  }

  /// 15.09 «Ашан 3,000» on Black: 2,000 supermarkets at the month's 3 % and 1,000 home at 1 %
  /// → 60 + 10 = 70.00, the exact sum rounded once.
  @Test func splitSumsExactlyThenRounds() throws {
    let split = fixture.operation(
      on: "09-15", parts: [(fixture.supermarkets, money(2000)), (fixture.home, money(1000))],
      account: fixture.tBank, card: fixture.black)
    let expected = try #require(fixture.expected(split))
    #expect(expected.money == rub("70"))
    #expect(expected.source == .rules([id(304), id(306)]))
  }

  /// 16.09 «Netflix 20 $» on Black with 1,850 ₽ charged: the base is 1,850 ₽ → 1 % = 18.50.
  @Test func rubleLegIsTheBase() throws {
    let netflix = fixture.operation(
      on: "09-16", currency: .usd, parts: [(fixture.subscriptions, money(20))],
      account: fixture.tBank, card: fixture.black, leg: rub("1850"))
    let expected = try #require(fixture.expected(netflix))
    #expect(expected.money == rub("18.5"))
    #expect(expected.rubles == money("18.5"))
  }

  /// 17.09 «taxi 5,000 ₸ kaspi», 900 ₽ at the operation's rate → 2 % = 100.00 ₸, 18.00 ₽.
  @Test func accountInTenge() throws {
    let taxi = fixture.operation(
      on: "09-17", currency: kzt, parts: [(fixture.cinema, money(5000))], account: fixture.kaspi,
      rubles: money(900))
    let expected = try #require(fixture.expected(taxi))
    #expect(expected.money == Money(amount: money(100), currency: kzt))
    #expect(expected.rubles == money(18))
    #expect(expected.holder == .account(fixture.kaspi))
  }

  /// 50 $ = 30 $ cafes + 20 $ home, 4,600 ₽ charged: 2,760 ₽ × 10 % + 1,840 ₽ × 1 % = 294.40.
  @Test func splitWithForeignLeg() throws {
    let dinner = fixture.operation(
      on: "09-18", currency: .usd, parts: [(fixture.cafes, money(30)), (fixture.home, money(20))],
      account: fixture.tBank, card: fixture.black, leg: rub("4600"))
    #expect(try #require(fixture.expected(dinner)).money == rub("294.4"))
  }

  /// 1,234.56 at 1 % is 12.3456 → 12.35; 50 at 0.01 % is 0.005 → 0.01: once, half away from
  /// zero.
  @Test func roundsOnceHalfAwayFromZero() throws {
    let pharmacy = fixture.operation(
      on: "09-14", parts: [(fixture.pharmacy, money("1234.56"))], account: fixture.tBank,
      card: fixture.black)
    #expect(try #require(fixture.expected(pharmacy)).money == rub("12.35"))
    let tiny = CashbackRuleBook(
      rules: [
        CashbackRule(
          accountId: fixture.tBank, cardId: fixture.black,
          percent: try #require(CashbackPercent(e4: 100)))
      ], tree: fixture.tree, cards: fixture.cards, accounts: fixture.accounts)
    let bread = fixture.operation(
      on: "09-14", parts: [(fixture.home, money(50))], account: fixture.tBank,
      card: fixture.black)
    #expect(try #require(fixture.expected(bread, book: tiny)).money == rub("0.01"))
  }

  /// A jacket of 10,000 at 1 %, 4,000 of it refunded later: 60.00, in the purchase's month.
  @Test func tiedRefundLowersThePurchase() throws {
    let jacket = fixture.operation(
      on: "09-20", parts: [(fixture.clothes, money(10000))], account: fixture.tBank,
      card: fixture.black)
    let expected = try #require(fixture.expected(jacket, refunded: [id(1000): money(4000)]))
    #expect(expected.money == rub("60"))
  }

  /// The owner typed 120 on the jacket; after the refund of 4,000 of 10,000 it is 72.00.
  @Test func overrideScaledByRefund() throws {
    let jacket = fixture.operation(
      on: "09-20", parts: [(fixture.clothes, money(10000))], account: fixture.tBank,
      card: fixture.black, cashback: rub("120"))
    let whole = try #require(fixture.expected(jacket))
    #expect(whole.money == rub("120") && whole.source == .override)
    let after = try #require(fixture.expected(jacket, refunded: [id(1000): money(4000)]))
    #expect(after.money == rub("72"))
  }

  /// A refund of 500 of no purchase takes back 1 % of it: −5.00.
  @Test func untiedRefundIsNegative() throws {
    let refund = fixture.operation(
      .refund, on: "09-22", parts: [(fixture.clothes, money(500))], account: fixture.tBank,
      card: fixture.black)
    let expected = try #require(fixture.expected(refund))
    #expect(expected.money == rub("-5"))
    #expect(expected.rubles == money(-5))
  }

  /// A refund taken back from a purchase earns nothing itself: its effect is in the purchase.
  @Test func tiedRefundItselfIsZero() {
    let refund = fixture.operation(
      .refund, on: "10-05", parts: [(fixture.clothes, money(4000))], account: fixture.tBank,
      card: fixture.black, refundOf: id(1000))
    #expect(fixture.expected(refund) == nil)
  }

  /// A contribution to a goal, a purchase on credit, the difference of a count, a transfer fee,
  /// income and money back earn nothing.
  @Test func goalCreditBookkeepingFeeIncomeMoneyBackEarnNothing() {
    func on(
      _ category: UUID, kind: TransactionKind = .expense, credit: UUID? = nil,
      externalId: String? = nil
    ) -> TransactionEntry {
      fixture.operation(
        kind, on: "09-10", parts: [(category, money(5000))], account: fixture.tBank,
        card: fixture.black, credit: credit, externalId: externalId)
    }
    #expect(fixture.expected(on(fixture.goalTrip)) == nil)
    #expect(fixture.expected(on(fixture.home, credit: id(500))) == nil)
    #expect(
      fixture.expected(on(fixture.home, externalId: "reconcile:\(id(600)):\(id(601))")) == nil)
    #expect(fixture.expected(on(fixture.home, externalId: "transfer:\(id(602)):fee")) == nil)
    #expect(fixture.expected(on(fixture.salary, kind: .income)) == nil)
    #expect(fixture.expected(on(fixture.home, kind: .reimbursement)) == nil)
    // A charge «Mark as paid» wrote is real spending: it earns.
    #expect(
      fixture.expected(on(fixture.home, externalId: "sched:\(id(603)):2026-09-10")) != nil)
  }

  /// A figure typed in money the account no longer moves says nothing: the rules price it.
  @Test func overrideInAnotherCurrencyIsIgnored() throws {
    let coffee = fixture.operation(
      on: "09-12", parts: [(fixture.coffee, money(350))], account: fixture.tBank,
      card: fixture.black, cashback: Money(amount: money(1), currency: .usd))
    let expected = try #require(fixture.expected(coffee))
    #expect(expected.money == rub("35") && expected.source == .rules([id(303)]))
  }

  /// A typed zero is the owner's zero, even with rules that would give more.
  @Test func overrideZeroMeansZero() throws {
    let coffee = fixture.operation(
      on: "09-12", parts: [(fixture.coffee, money(350))], account: fixture.tBank,
      card: fixture.black, cashback: rub("0"))
    let expected = try #require(fixture.expected(coffee))
    #expect(expected.money == rub("0") && expected.source == .override)
  }

  /// Cash has no rules, and an account with two cards and none named has none of its own.
  @Test func noRuleForAnyPartIsNil() {
    let cash = fixture.operation(
      on: "09-12", parts: [(fixture.coffee, money(200))], account: fixture.cash)
    #expect(fixture.expected(cash) == nil)
    let tBank = fixture.operation(
      on: "09-12", parts: [(fixture.coffee, money(300))], account: fixture.tBank)
    #expect(fixture.expected(tBank) == nil)
  }

  /// The ↓ panel prices a draft the same way, before anything is saved.
  @Test func aDraftIsPricedLikeTheSavedOperation() throws {
    let draft = TransactionDraft(
      occurredAt: fixture.at("09-12"), amount: money(350), paymentMethodId: fixture.tBank,
      parts: [PartDraft(categoryId: fixture.coffee, amount: money(350))], cardId: fixture.black)
    let expected = try #require(
      CashbackMath.expected(
        draft, holder: .card(fixture.black), book: fixture.book, tree: fixture.tree,
        calendar: .utc))
    #expect(expected.money == rub("35"))
  }

  /// A typed percent is a share of the money that moves on the account.
  @Test func aTypedPercentOfTheDraftsBase() throws {
    var draft = TransactionDraft(
      occurredAt: fixture.at("09-14"), amount: money(1000), paymentMethodId: fixture.tBank,
      parts: [PartDraft(categoryId: fixture.pharmacy, amount: money(1000))])
    let seven = try #require(CashbackPercent(e4: 70_000))
    let kopecks = CashbackRounding(precision: .cents)
    #expect(CashbackMath.amount(of: seven, on: draft, rounding: kopecks) == rub("70"))
    draft.currency = .usd
    draft.amount = money(20)
    draft.accountCurrency = .rub
    draft.accountAmount = money(1850)
    #expect(CashbackMath.amount(of: seven, on: draft, rounding: kopecks) == rub("129.5"))
    // An account that rounds to whole rubles, as a new one does, gets 130.
    #expect(CashbackMath.amount(of: seven, on: draft) == rub("130"))
  }
}
