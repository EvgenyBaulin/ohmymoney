import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

// Synthetic data only; no windows.
@MainActor
final class CardOwnBalanceModelTests: XCTestCase {
  func testSwitchStartsOffAndTheDefaultLeavesThePastOnTheSharedAccount() throws {
    let account = PaymentMethod(name: "Shared", bankId: UUID())
    let card = PaymentCard(accountId: account.id, name: "Separate")
    var draft = CardOwnBalanceDraft(today: Date(timeIntervalSince1970: 1_700_000_000))
    XCTAssertFalse(CardOwnBalance.isOn(for: card, accounts: [account]))
    XCTAssertEqual(draft.past, .none)
    let plan = try XCTUnwrap(
      draft.attempt(
        separating: card, cards: [card], accounts: [account], calendar: .utc))
    XCTAssertEqual(plan.past, .none)
    XCTAssertTrue(CardOwnBalance.isOn(for: plan.card, accounts: [account, plan.account]))
    XCTAssertEqual(plan.accountsToReconcile, [account.id, card.id])
    XCTAssertNil(plan.account.credit)
    draft.past = .fromDate
    XCTAssertEqual(
      draft.pastOperations(calendar: .utc), .onAndAfter(CalendarContext.utc.day(of: draft.fromDate))
    )
    draft.past = .all
    XCTAssertEqual(draft.pastOperations(calendar: .utc), .all)
  }

  func testConflictingNameAsksForAnotherAndDoesNotWriteAnything() throws {
    let account = PaymentMethod(name: "Shared", bankId: UUID())
    let card = PaymentCard(accountId: account.id, name: "Shared")
    var draft = CardOwnBalanceDraft(today: Date(timeIntervalSince1970: 1_700_000_000))
    XCTAssertNil(
      draft.attempt(separating: card, cards: [card], accounts: [account], calendar: .utc))
    XCTAssertEqual(draft.refusal, .conversion(.name(.nameTaken)))
    XCTAssertTrue(draft.asksForName)
    draft.name = "Separate"
    XCTAssertEqual(
      draft.attempt(
        separating: card, cards: [card], accounts: [account], calendar: .utc)?.account.name,
      "Separate")
    XCTAssertNil(draft.refusal)
  }

  func testSwitchOffOffersOnlyOtherOwnDebitAccountsOfTheSameBank() throws {
    let bank = UUID()
    let shared = PaymentMethod(name: "Shared", bankId: bank)
    let card = PaymentCard(accountId: shared.id, name: "Separate")
    let plan = try CardOwnBalance.plan(separating: card.id, cards: [card], accounts: [shared]).get()
    var archived = PaymentMethod(name: "Archived", bankId: bank)
    archived.archived = true
    let credit = PaymentMethod(
      name: "Credit", bankId: bank, credit: CreditCardTerms(limitE4: AmountE4(whole: 100)))
    let elsewhere = PaymentMethod(name: "Other bank", bankId: UUID())
    let targets = CardOwnBalance.sharingTargets(
      for: plan.card, accounts: [shared, plan.account, archived, credit, elsewhere])
    XCTAssertEqual(targets.map(\.id), [shared.id])
    XCTAssertTrue(CardOwnBalance.sharingTargets(for: card, accounts: [shared]).isEmpty)
  }

  func testNewWordsExistInRussianAndEnglish() {
    for choice in [AppLanguage.Choice.english, .russian] {
      let environment = AppEnvironment()
      environment.language.choice = choice
      for key in [
        "card.ownBalance.title", "card.ownBalance.message", "card.ownBalance.confirm",
        "card.ownBalance.unavailable", "card.ownBalance.noTarget", "card.ownBalance.hint",
      ] {
        let words = environment.language(key, table: AccountText.table)
        XCTAssertNotEqual(words, key)
        XCTAssertFalse(words.isEmpty)
      }
      XCTAssertEqual(
        environment.language("panel.ownBalance", table: "SettingsAccounts"),
        choice == .english ? "Own balance" : "Свой счёт и остаток")
    }
  }
}
