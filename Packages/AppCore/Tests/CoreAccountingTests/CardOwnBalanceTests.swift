import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

// Synthetic data only.
@Suite("A card with its own balance")
struct CardOwnBalanceTests {
  let fixture = CardToCreditCardTests()

  @Test func aSeparateDebitAccountKeepsTheBankGroupCurrenciesAndCard() throws {
    let plan = try CardOwnBalance.plan(
      separating: fixture.black.id, past: .none, cards: [fixture.black, fixture.plain],
      accounts: [fixture.debit, fixture.sber]
    ).get()
    #expect(plan.account.id == fixture.black.id)
    #expect(plan.account.credit == nil && !plan.account.isCreditCard)
    #expect(plan.account.bankId == fixture.bank && plan.account.groupId == fixture.group)
    #expect(plan.account.currencies == fixture.debit.currencies)
    #expect(plan.account.mainCardId == fixture.black.id)
    #expect(plan.card.accountId == plan.account.id)
    #expect(plan.card.aliases == fixture.black.aliases && plan.card.last4 == fixture.black.last4)
    #expect(plan.former.mainCardId == nil && plan.former.isDefault)
    #expect(plan.accountsToReconcile == [fixture.debit.id, plan.account.id])
    #expect(CardOwnBalance.isOn(for: plan.card, accounts: [plan.account, plan.former]))
  }

  @Test func existingMainCardsStillShareTheirAccountAndRepeatedSeparationIsRefused() throws {
    #expect(!CardOwnBalance.isOn(for: fixture.black, accounts: [fixture.debit]))
    let plan = try CardOwnBalance.plan(
      separating: fixture.black.id, cards: [fixture.black], accounts: [fixture.debit]
    ).get()
    #expect(!CardOwnBalance.offered(for: plan.card, accounts: [plan.account]))
    #expect(throws: CardOwnBalanceIssue.self) {
      try CardOwnBalance.plan(
        separating: plan.card.id, cards: [plan.card], accounts: [plan.account]
      ).get()
    }
    // Changing the main card or the names does not switch an independent balance off.
    var renamed = plan.account
    renamed.name = "Renamed"
    renamed.mainCardId = nil
    #expect(CardOwnBalance.isOn(for: plan.card, accounts: [renamed]))
  }

  @Test func anExistingAccountIdCannotBeOverwritten() {
    let occupied = PaymentMethod(id: fixture.black.id, name: "Occupied")
    #expect(
      CardOwnBalance.plan(
        separating: fixture.black.id, cards: [fixture.black],
        accounts: [fixture.debit, occupied]) == .failure(.accountIdInUse))
  }

  @Test func theChosenDayUsesTheExistingMovementRules() throws {
    let day = DateOnly(year: 2026, month: 3, day: 1)
    let plan = try CardOwnBalance.plan(
      separating: fixture.black.id, past: .onAndAfter(day), cards: [fixture.black],
      accounts: [fixture.debit]
    ).get()
    #expect(!plan.moves(fixture.operation(1, at: "2026-02-28T12:00:00Z"), calendar: .utc))
    #expect(plan.moves(fixture.operation(2, at: "2026-03-01T12:00:00Z"), calendar: .utc))
    #expect(
      !plan.moves(
        fixture.operation(3, at: "2026-03-02T12:00:00Z", card: nil), calendar: .utc))
  }

  @Test func aMergedAwayOwnAccountCanBeUsedAgain() throws {
    var archived = PaymentMethod(id: fixture.black.id, name: "Old own", bankId: fixture.bank)
    archived.archived = true
    #expect(CardOwnBalance.offered(for: fixture.black, accounts: [fixture.debit, archived]))
    let plan = try CardOwnBalance.plan(
      separating: fixture.black.id, cards: [fixture.black], accounts: [fixture.debit, archived]
    ).get()
    #expect(plan.account.id == archived.id && !plan.account.archived)
  }

  @Test func renamingAndAddingAnotherCardDoesNotDuplicatePickerIds() throws {
    let plan = try CardOwnBalance.plan(
      separating: fixture.black.id, cards: [fixture.black], accounts: [fixture.debit]
    ).get()
    var account = plan.account
    account.name = "Own account renamed"
    let extra = PaymentCard(accountId: account.id, name: "Extra")
    let entries = AccountLabels(accounts: [account], cards: [plan.card, extra], banks: [])
      .entries(offering: [account], withCards: true, locale: Locale(identifier: "en_US"))
    #expect(Set(entries.map(\.id)).count == entries.count)
  }
}
