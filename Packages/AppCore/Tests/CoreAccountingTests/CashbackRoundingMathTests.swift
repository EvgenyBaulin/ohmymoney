import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// The expectation follows the account: it is rounded once per operation, the way the bank of
/// the account rounds, and a debt payment earns nothing at all.
@Suite("The cashback expected, rounded as the account says")
struct CashbackRoundingMathTests {
  let fixture = CashbackFixture()

  /// A book over the fixture's rules in which `account` rounds as given.
  func book(_ account: UUID, _ rounding: CashbackRounding) -> CashbackRuleBook {
    var accounts = fixture.accounts
    let index = accounts.firstIndex { $0.id == account }!
    accounts[index].cashbackRounding = rounding
    return CashbackRuleBook(
      rules: fixture.rules, tree: fixture.tree, cards: fixture.cards, accounts: accounts)
  }

  /// 350 ₽ of coffee at 5 % is 17.50: a new account rounds to 18, whole rubles.
  @Test func aNewAccountRoundsToWholeUnits() throws {
    let coffee = fixture.operation(
      on: "09-12", parts: [(fixture.cafes, money(350))], account: fixture.alfa)
    let expectation = try #require(fixture.expected(coffee))
    #expect(expectation.money.amount == money(18))
    #expect(expectation.rubles == money(18))
  }

  @Test func downAndUp() throws {
    let coffee = fixture.operation(
      on: "09-12", parts: [(fixture.cafes, money(350))], account: fixture.alfa)
    let down = book(fixture.alfa, CashbackRounding(precision: .whole, direction: .down))
    #expect(try #require(fixture.expected(coffee, book: down)).money.amount == money(17))
    let up = book(fixture.alfa, CashbackRounding(precision: .whole, direction: .up))
    #expect(try #require(fixture.expected(coffee, book: up)).money.amount == money(18))
    let cheap = fixture.operation(
      on: "09-12", parts: [(fixture.cafes, money(21))], account: fixture.alfa)
    // 1.05: down 1, up 2, nearest 1.
    #expect(try #require(fixture.expected(cheap, book: down)).money.amount == money(1))
    #expect(try #require(fixture.expected(cheap, book: up)).money.amount == money(2))
    #expect(try #require(fixture.expected(cheap)).money.amount == money(1))
  }

  /// The kopeck is a setting of the account: 17.50 stays 17.50.
  @Test func aKopeckAccountKeepsTheKopecks() throws {
    let coffee = fixture.operation(
      on: "09-12", parts: [(fixture.cafes, money(350))], account: fixture.alfa)
    let cents = book(fixture.alfa, CashbackRounding(precision: .cents))
    #expect(try #require(fixture.expected(coffee, book: cents)).money.amount == money("17.5"))
  }

  /// The rounding is once per operation, on the sum of its parts — not once per part.
  @Test func aSplitIsRoundedOnce() throws {
    // Cafes 5 % of 110 = 5.50 and supermarkets 3 % of 110 = 3.30 in September: 8.80 → 9.
    let split = fixture.operation(
      on: "09-12", parts: [(fixture.cafes, money(110)), (fixture.supermarkets, money(110))],
      account: fixture.alfa)
    #expect(try #require(fixture.expected(split)).money.amount == money(9))
  }

  /// A refund of no purchase takes back what a purchase would have given, rounded the same way.
  @Test func aRefundIsRoundedLikeAPurchase() throws {
    let refund = fixture.operation(
      .refund, on: "09-12", parts: [(fixture.cafes, money(350))], account: fixture.alfa)
    #expect(try #require(fixture.expected(refund)).money.amount == money(-18))
    let down = book(fixture.alfa, CashbackRounding(precision: .whole, direction: .down))
    #expect(try #require(fixture.expected(refund, book: down)).money.amount == money(-17))
  }

  /// The figure the owner typed is theirs: it keeps its kopecks whatever the account rounds to.
  @Test func aTypedFigureIsNotRounded() throws {
    let typed = fixture.operation(
      on: "09-12", parts: [(fixture.cafes, money(350))], account: fixture.alfa,
      cashback: Money(amount: money("17.5"), currency: .rub))
    let expectation = try #require(fixture.expected(typed))
    #expect(expectation.money.amount == money("17.5"))
    #expect(expectation.source == .override)
  }

  /// A typed percent of the panel is turned into money the way the account's bank would.
  @Test func aTypedPercentFollowsTheRounding() throws {
    var draft = TransactionDraft(
      kind: .expense, occurredAt: fixture.at("09-12"), currency: .rub, amount: money("123.45"))
    draft.paymentMethodId = fixture.alfa
    let five = try #require(CashbackPercent(decimal: 5))
    // 5 % of 123.45 = 6.1725.
    #expect(try #require(CashbackMath.amount(of: five, on: draft)).amount == money(6))
    #expect(
      try #require(
        CashbackMath.amount(of: five, on: draft, rounding: CashbackRounding(precision: .cents))
      ).amount == money("6.17"))
    #expect(
      try #require(
        CashbackMath.amount(
          of: five, on: draft, rounding: CashbackRounding(precision: .whole, direction: .up))
      ).amount == money(7))
  }

  // MARK: Debts

  /// A payment on a debt earns no cashback, even where «everything else» would catch it.
  @Test func aDebtPaymentEarnsNothing() {
    let payment = fixture.operation(
      on: "09-25", parts: [(fixture.loans, money(15_000))], account: fixture.alfa)
    #expect(!CashbackMath.earns(payment, tree: fixture.tree))
    #expect(fixture.expected(payment) == nil)
    // On a card whose own rules even name «Loans — 0 %» the answer is the same.
    let onBlack = fixture.operation(
      on: "09-25", parts: [(fixture.loans, money(15_000))], account: fixture.tBank,
      card: fixture.black)
    #expect(fixture.expected(onBlack) == nil)
  }

  /// A receipt with a part that pays a debt earns on the other parts only.
  @Test func aSplitWithADebtPartEarnsOnTheRest() throws {
    // 600 of cafes at 5 % = 30; the 400 of the loan earn nothing.
    let split = fixture.operation(
      on: "09-12", parts: [(fixture.cafes, money(600)), (fixture.loans, money(400))],
      account: fixture.alfa)
    #expect(CashbackMath.earns(split, tree: fixture.tree))
    #expect(try #require(fixture.expected(split)).money.amount == money(30))
  }

  /// A purchase on credit and a contribution to a goal still earn nothing, as before.
  @Test func creditAndGoalsStillEarnNothing() {
    let onCredit = fixture.operation(
      on: "09-12", parts: [(fixture.cafes, money(350))], account: fixture.alfa, credit: id(700))
    #expect(fixture.expected(onCredit) == nil)
    let goal = fixture.operation(
      on: "09-12", parts: [(fixture.goalTrip, money(350))], account: fixture.alfa)
    #expect(fixture.expected(goal) == nil)
  }
}
