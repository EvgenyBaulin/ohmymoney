import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// The rules belong to the account and its cards follow them: a card keeps only the rules in
/// which it differs, and wins where it has a rule for the same month and category.
@Suite("A card follows the cashback rules of its account")
struct CashbackInheritanceTests {
  let fixture = CashbackFixture()

  func rule(_ holder: CashbackHolder, _ category: UUID?, _ month: MonthKey) -> UUID? {
    fixture.book.rule(for: holder, categoryId: category, month: month)?.id
  }

  /// A card with no rule of its own is priced by the account's rules, step by step: the month's
  /// «Supermarkets» (3 %), «Cafes» always (5 %), «everything else» (1 %).
  @Test func aCardWithoutRulesFollowsItsAccount() {
    #expect(rule(.card(fixture.alfaCard), fixture.cafes, fixture.september) == id(341))
    #expect(rule(.card(fixture.alfaCard), fixture.coffee, fixture.september) == id(341))
    #expect(rule(.card(fixture.alfaCard), fixture.supermarkets, fixture.september) == id(342))
    #expect(rule(.card(fixture.alfaCard), fixture.cinema, fixture.september) == id(343))
    // The account itself is priced by the same rules.
    #expect(rule(.account(fixture.alfa), fixture.cafes, fixture.october) == id(341))
  }

  /// The card's own rule wins where both have a rule for the same month and category.
  @Test func aCardsOwnRuleBeatsTheAccountsOfTheSameKey() {
    #expect(rule(.card(fixture.alfaVirtual), fixture.cafes, fixture.september) == id(344))
    #expect(rule(.card(fixture.alfaVirtual), fixture.coffee, fixture.october) == id(344))
  }

  /// A rule of one key does not hide the account's rules of the others.
  @Test func aCardsRuleDoesNotHideTheAccountsOthers() {
    #expect(rule(.card(fixture.alfaVirtual), fixture.supermarkets, fixture.september) == id(342))
    #expect(rule(.card(fixture.alfaVirtual), fixture.cinema, fixture.october) == id(343))
  }

  /// The order of the steps holds across the two: the account's rule of a category beats the
  /// card's «everything else», as a named rule beats «everything else» everywhere.
  @Test func aNamedAccountRuleBeatsTheCardsEverythingElse() {
    let only = [
      CashbackRule(
        id: id(1), accountId: fixture.alfa, categoryId: fixture.cafes,
        percent: CashbackPercent(e4: 50_000)!),
      CashbackRule(
        id: id(2), accountId: fixture.alfa, cardId: fixture.alfaCard,
        percent: CashbackPercent(e4: 10_000)!),
    ]
    let book = CashbackRuleBook(rules: only, tree: fixture.tree, cards: fixture.cards)
    #expect(
      book.rule(for: .card(fixture.alfaCard), categoryId: fixture.coffee, month: fixture.september)?
        .id == id(1))
    #expect(
      book.rule(for: .card(fixture.alfaCard), categoryId: fixture.cinema, month: fixture.september)?
        .id == id(2))
  }

  /// A card the book does not know has no account above it: only its own rules.
  @Test func aCardOfNoKnownAccountHasOnlyItsOwn() {
    let book = CashbackRuleBook(rules: fixture.rules, tree: fixture.tree)
    #expect(
      book.rule(for: .card(fixture.alfaCard), categoryId: fixture.cafes, month: fixture.september)
        == nil)
    #expect(
      book.rule(
        for: .card(fixture.alfaVirtual), categoryId: fixture.cafes, month: fixture.september)?
        .id == id(344))
  }

  @Test func theEffectiveRulesOfACardAreItsOwnAndTheAccountsOthers() {
    // Own first; the account's «Cafes always» is covered by the card's, the others stay.
    #expect(
      fixture.book.effectiveRules(of: .card(fixture.alfaVirtual)).map(\.id) == [
        id(344), id(342), id(343),
      ])
    #expect(
      fixture.book.effectiveRules(of: .card(fixture.alfaCard)).map(\.id) == [
        id(341), id(342), id(343),
      ])
    #expect(
      fixture.book.effectiveRules(of: .account(fixture.alfa)).map(\.id) == [
        id(341), id(342), id(343),
      ])
    // «Own» stays only what the holder itself keeps.
    #expect(fixture.book.rules(of: .card(fixture.alfaVirtual)).map(\.id) == [id(344)])
  }

  /// The account a holder follows, and how that account rounds.
  @Test func theBookKnowsTheAccountsAboveTheCardsAndHowTheyRound() {
    #expect(fixture.book.account(of: .card(fixture.alfaVirtual)) == fixture.alfa)
    #expect(fixture.book.account(of: .account(fixture.cash)) == fixture.cash)
    #expect(fixture.book.rounding(for: .card(fixture.alfaCard)) == .standard)
    #expect(
      fixture.book.rounding(for: .card(fixture.black)) == CashbackRounding(precision: .cents))
    #expect(fixture.book.rounding(for: nil) == .standard)
  }

  /// The case that started it: 60 purchases of September on Sber, none naming a card. A second
  /// card added in October changes nothing about them — the rule is the account's.
  @Test func aSecondCardDoesNotZeroThePast() throws {
    let bread = fixture.operation(
      on: "09-12", parts: [(fixture.home, money(1000))], account: fixture.sber)
    let before = try #require(fixture.expected(bread))
    #expect(before.money.amount == money(5))

    let another = PaymentCard(id: id(22), accountId: fixture.sber, name: "Sber Mir")
    let withTwoCards = CashbackRuleBook(
      rules: fixture.rules, tree: fixture.tree, cards: fixture.cards + [another],
      accounts: fixture.accounts)
    let after = try #require(fixture.expected(bread, book: withTwoCards))
    #expect(after.money.amount == before.money.amount)
    #expect(after.holder == .account(fixture.sber))

    // Putting the first card in the archive changes nothing either.
    var archived = fixture.cards
    archived[2].archived = true
    let withoutCard = CashbackRuleBook(
      rules: fixture.rules, tree: fixture.tree, cards: archived, accounts: fixture.accounts)
    #expect(try #require(fixture.expected(bread, book: withoutCard)).money.amount == money(5))
  }
}
