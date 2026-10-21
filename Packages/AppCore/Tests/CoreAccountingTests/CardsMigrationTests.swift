import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// The update gives every live account of the kind «card» one card named like it, with an id
/// derived from the account's: the same on every run and every retry, never the account's own.
@Suite("The cards the update makes")
struct CardsMigrationTests {
  private func account(
    _ name: String, kind: PaymentMethodKind? = .card, archived: Bool = false, id: UUID = UUID()
  ) -> MigratingCardAccount {
    MigratingCardAccount(id: id, name: name, kind: kind, archived: archived)
  }

  @Test func theCardIdIsTheAccountIdXorCard() throws {
    let account = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
    #expect(
      CardsMigration.cardId(forAccount: account).uuidString
        == "72706375-4143-4157-2725-273136342731")
    #expect(CardsMigration.idMask == Array("cardcardcardcard".utf8))
  }

  @Test func theCardIdIsNeverItsAccountsAndComesBack() {
    var seen: Set<UUID> = []
    for _ in 0..<500 {
      let account = UUID()
      let card = CardsMigration.cardId(forAccount: account)
      #expect(card != account)
      #expect(CardsMigration.cardId(forAccount: card) == account)
      seen.insert(card)
    }
    #expect(seen.count == 500)
  }

  /// The table of the rule: a card for a live account of the kind «card» only.
  @Test func onlyLiveCardAccountsGetACard() {
    let tbank = account("Т-Банк")
    let oldVisa = account("Old Visa", archived: true)
    let cash = account("Наличные", kind: .cash)
    let deposit = account("Вклад", kind: .account)
    let other = account("Другое", kind: .other)
    let unknown = account("Неизвестный вид", kind: nil)
    let blank = account("  ")
    let sber = account(" Сбер ")

    let plan = CardsMigration.plan(
      accounts: [tbank, oldVisa, cash, deposit, other, unknown, blank, sber])

    #expect(
      plan.cards == [
        PaymentCard(
          id: CardsMigration.cardId(forAccount: tbank.id), accountId: tbank.id, name: "Т-Банк"),
        PaymentCard(
          id: CardsMigration.cardId(forAccount: sber.id), accountId: sber.id, name: "Сбер"),
      ])
    #expect(plan.skipped == 1)
  }

  @Test func aBlankNameIsSkippedAndCounted() {
    let plan = CardsMigration.plan(accounts: [
      account(""), account("   "), account("\t\n"), account(" \u{00A0} "),
      account("   ", archived: true), account("", kind: .cash),
    ])
    #expect(plan.cards.isEmpty)
    #expect(plan.skipped == 4)
  }

  @Test func theNameIsTrimmed() {
    let visa = account("\t Visa Gold \n")
    let plan = CardsMigration.plan(accounts: [visa])
    #expect(plan.cards.map(\.name) == ["Visa Gold"])
    #expect(plan.cards.first?.aliases == [])
    #expect(plan.cards.first?.sort == 0)
    #expect(plan.cards.first?.archived == false)
    #expect(plan.cards.first?.accountId == visa.id)
  }

  @Test func theCardsComeInTheOrderOfTheAccounts() {
    let accounts = (0..<12).map { account("Card \($0)") }
    let plan = CardsMigration.plan(accounts: accounts)
    #expect(plan.cards.map(\.accountId) == accounts.map(\.id))
    #expect(plan.skipped == 0)
  }

  /// One id read twice — a file edited by hand holding it in two cases — gets one card: two
  /// would take one id and stop the update.
  @Test func anAccountIdReadTwiceGetsOneCard() {
    let id = UUID()
    let plan = CardsMigration.plan(accounts: [
      account("Visa", id: id), account("Visa again", id: id),
    ])
    #expect(plan.cards.map(\.name) == ["Visa"])
    #expect(plan.skipped == 0)
  }

  @Test func noAccountsNoCards() {
    let plan = CardsMigration.plan(accounts: [])
    #expect(plan == CardsMigrationPlan(cards: [], skipped: 0))
  }
}
