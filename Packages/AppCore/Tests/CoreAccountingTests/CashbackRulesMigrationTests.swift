import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// The update to rules that belong to the account: what the cards held goes up to the account
/// where every card would repeat it, and nothing else is moved or invented.
@Suite("The update of the cashback rules to the account")
struct CashbackRulesMigrationTests {
  let account = id(1)
  let other = id(2)
  let cafes = id(50)
  let health = id(51)
  let loans = id(52)
  let mortgage = id(53)

  func card(_ number: Int, of account: UUID, archived: Bool = false) -> PaymentCard {
    PaymentCard(id: id(number), accountId: account, name: "Card \(number)", archived: archived)
  }

  func rule(
    _ number: Int, on holder: UUID?, of account: UUID? = nil, category: UUID? = nil,
    month: MonthKey? = nil, percent: Int64 = 50_000
  ) -> CashbackRule {
    CashbackRule(
      id: id(number), accountId: account ?? self.account, cardId: holder, categoryId: category,
      month: month, percent: CashbackPercent(e4: percent)!)
  }

  func plan(_ rules: [CashbackRule], _ cards: [PaymentCard]) -> CashbackRulesMigration.Plan {
    CashbackRulesMigration.plan(rules: rules, cards: cards, loanCategoryIds: [loans, mortgage])
  }

  /// The common case: one card holds the rules. They go up to the account as the same rows, and
  /// nothing is dropped.
  @Test func theRulesOfTheOnlyCardGoUp() {
    let result = plan(
      [rule(10, on: id(21), category: cafes), rule(11, on: id(21))], [card(21, of: account)])
    #expect(result.movedUp == [id(10), id(11)])
    #expect(result.dropped.isEmpty)
    #expect(!result.isEmpty)
  }

  /// Cards that hold the same rules — the same months, categories and percents, whatever the
  /// rows — are the account's rules once: the first card's rows go up, the copies go.
  @Test func cardsThatAgreeGiveOneCopy() {
    let result = plan(
      [
        rule(10, on: id(21), category: cafes), rule(11, on: id(21)),
        rule(20, on: id(22)), rule(21, on: id(22), category: cafes),
      ], [card(21, of: account), card(22, of: account)])
    #expect(result.movedUp == [id(10), id(11)])
    #expect(Set(result.dropped) == [id(20), id(21)])
  }

  /// Cards that differ keep their own rules: the account gets none, and nothing is lost.
  @Test func cardsThatDifferKeepTheirs() {
    let result = plan(
      [
        rule(10, on: id(21), category: cafes, percent: 50_000),
        rule(20, on: id(22), category: cafes, percent: 70_000),
      ], [card(21, of: account), card(22, of: account)])
    #expect(result.isEmpty)
    // A card with a rule the other lacks differs as well.
    let more = plan(
      [rule(10, on: id(21), category: cafes), rule(11, on: id(21)), rule(20, on: id(22))],
      [card(21, of: account), card(22, of: account)])
    #expect(more.isEmpty)
  }

  /// A card without rules stays without: it follows the account afterwards.
  @Test func aCardWithoutRulesDoesNotStopTheRest() {
    let result = plan(
      [rule(10, on: id(21), category: cafes)], [card(21, of: account), card(22, of: account)])
    #expect(result.movedUp == [id(10)] && result.dropped.isEmpty)
  }

  /// An account that has rules of its own is left as it is.
  @Test func anAccountWithRulesOfItsOwnIsLeftAlone() {
    let result = plan(
      [rule(10, on: nil, category: cafes), rule(11, on: id(21))], [card(21, of: account)])
    #expect(result.isEmpty)
  }

  /// A card in the archive keeps its rules for its past purchases; it takes no part.
  @Test func anArchivedCardIsLeftAlone() {
    let result = plan(
      [rule(10, on: id(21), category: cafes), rule(11, on: id(23), category: health)],
      [card(21, of: account), card(23, of: account, archived: true)])
    #expect(result.movedUp == [id(10)] && result.dropped.isEmpty)
    let onlyArchived = plan(
      [rule(11, on: id(23), category: health)], [card(23, of: account, archived: true)])
    #expect(onlyArchived.isEmpty)
  }

  /// Accounts are taken one by one.
  @Test func eachAccountIsItsOwnCase() {
    let result = plan(
      [
        rule(10, on: id(21), category: cafes),
        rule(30, on: id(31), of: other, category: cafes, percent: 20_000),
        rule(31, on: id(32), of: other, category: cafes, percent: 30_000),
      ],
      [card(21, of: account), card(31, of: other), card(32, of: other)])
    #expect(result.movedUp == [id(10)])
    #expect(result.dropped.isEmpty)
  }

  /// A payment on a debt earns nothing now, so a rule on «Кредиты» — or a subcategory of it —
  /// has nothing to say and goes; the others are judged without it.
  @Test func rulesOnLoansGo() {
    let result = plan(
      [
        rule(10, on: id(21), category: cafes), rule(11, on: id(21), category: loans, percent: 0),
        rule(12, on: id(21), category: mortgage, percent: 0),
        rule(20, on: id(22), category: cafes), rule(21, on: id(22), category: loans, percent: 0),
      ], [card(21, of: account), card(22, of: account)])
    // Without the loan rules the two cards hold the same: «Cafes».
    #expect(result.movedUp == [id(10)])
    #expect(Set(result.dropped) == [id(11), id(12), id(20), id(21)])
    #expect(result.droppedOnLoans == 3)
  }

  /// An account's own rule on a loan goes too.
  @Test func anAccountsRuleOnLoansGoes() {
    let result = plan([rule(10, on: nil, category: loans, percent: 0)], [])
    #expect(result.dropped == [id(10)] && result.movedUp.isEmpty && result.droppedOnLoans == 1)
  }

  @Test func nothingToDoIsEmpty() {
    #expect(plan([], [card(21, of: account)]).isEmpty)
    #expect(plan([rule(10, on: nil, category: cafes)], []).isEmpty)
  }
}
