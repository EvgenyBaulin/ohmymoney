import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

@Suite("The cashback mode of an account: none, constant rules, a choice every month")
struct CashbackAccountModeTests {
  private func percent() -> CashbackPercent { CashbackPercent(e4: 10_000)! }

  @Test func withoutRulesOrChoiceTheAccountEarnsNoneAndShowsNoBlock() {
    let account = PaymentMethod(name: "Cash")
    let mode = CashbackAccountMode.of(account, cards: [], rules: [])
    #expect(mode == .none)
    #expect(!mode.showsBlock && !mode.remindsMonthlyChoice)
  }

  @Test func rulesOfTheAccountOrOfItsCardsMakeItConstantWithoutReminders() {
    let account = PaymentMethod(name: "Black")
    let card = PaymentCard(accountId: account.id, name: "Black")
    let own = CashbackRule(accountId: account.id, percent: percent())
    let viaCard = CashbackRule(accountId: account.id, cardId: card.id, percent: percent())
    for rules in [[own], [viaCard]] {
      let mode = CashbackAccountMode.of(account, cards: [card], rules: rules)
      #expect(mode == .constant)
      #expect(mode.showsBlock && !mode.remindsMonthlyChoice)
    }
  }

  @Test func aRuleOfAnotherAccountChangesNothing() {
    let account = PaymentMethod(name: "Black")
    let other = CashbackRule(accountId: UUID(), percent: percent())
    #expect(CashbackAccountMode.of(account, cards: [], rules: [other]) == .none)
  }

  @Test func aChoiceDayMakesItMonthlyWithTheBlockAndTheReminder() {
    var account = PaymentMethod(name: "Gold")
    account.cashbackChoiceDay = 25
    let mode = CashbackAccountMode.of(account, cards: [], rules: [])
    #expect(mode == .monthly)
    #expect(mode.showsBlock && mode.remindsMonthlyChoice)
  }
}
