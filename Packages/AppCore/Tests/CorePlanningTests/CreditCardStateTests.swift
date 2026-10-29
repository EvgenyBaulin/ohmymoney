import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// A credit card is a plain card with a reminder while its grace period runs, and a debt once
/// a statement was missed; the limit is warned about before it is passed and after.
@Suite("Credit cards: grace or debt, and the limit")
struct CreditCardStateTests {
  typealias Fx = CreditCardTests

  private func rub(_ text: String) -> AmountE4 {
    (try? AmountE4(decimal: Decimal(string: text)!)) ?? .zero
  }
  private func day(_ iso: String) -> DateOnly { DateOnly(iso: iso)! }

  private func state(_ books: CreditCardTests.Books) -> CreditCardState {
    CreditCardStates.state(now: books.now, statements: books.statements)
  }

  @Test func aCardWithNothingOwedIsClear() {
    let books = Fx.books([], today: "2026-11-10")
    #expect(state(books).phase == .clear)
    #expect(!state(books).isDebt)
  }

  @Test func aWaitingStatementIsStillACardNotADebt() {
    let books = Fx.books(Fx.twoPurchases, today: "2026-11-10")
    let result = state(books)
    #expect(result.phase == .grace)
    #expect(result.debtE4 == rub("30000"))
    #expect(result.missedDue == nil)
  }

  @Test func aMissedStatementTurnsTheWholeCardIntoADebt() {
    let books = Fx.books(
      Fx.twoPurchases,
      transfers: [Fx.transfer(30, "900", on: "2026-11-25", from: Fx.mainId, to: Fx.cardId)],
      today: "2026-12-10")
    let result = state(books)
    let missedNow = books.now
    #expect(result.phase == .debt)
    #expect(result.isDebt)
    #expect(result.debtE4 == rub("29100"))
    #expect(result.missedDue == day("2026-11-30"))
    #expect(result.estimate == missedNow.estimate)
  }

  @Test func payingTheWholeDebtMakesItACardAgain() {
    let books = Fx.books(
      Fx.twoPurchases,
      transfers: [Fx.transfer(30, "30000", on: "2026-12-08", from: Fx.mainId, to: Fx.cardId)],
      today: "2026-12-10")
    #expect(state(books).debtE4 == .zero)
    #expect(state(books).phase == .clear)
  }

  // MARK: The limit

  @Test func overshootSaysByHowMuchTheLimitIsPassed() {
    let now = CreditCardNow(
      availableE4: rub("5000"), limitE4: rub("150000"), debtE4: rub("145000"))
    #expect(CreditCardStates.overshoot(now: now, spendE4: rub("5000")) == .zero)
    #expect(CreditCardStates.overshoot(now: now, spendE4: rub("7500")) == rub("2500"))
    #expect(CreditCardStates.overshoot(now: now, spendE4: .zero) == .zero)
  }

  @Test func overshootCountsWhatIsAlreadyOver() {
    let now = CreditCardNow(
      availableE4: rub("-1000"), limitE4: rub("150000"), debtE4: rub("151000"))
    #expect(CreditCardStates.overLimit(now) == rub("1000"))
    #expect(CreditCardStates.overshoot(now: now, spendE4: rub("500")) == rub("1500"))
  }

  @Test func aCardWithoutALimitIsNeverOver() {
    let now = CreditCardNow(availableE4: rub("-1000"), limitE4: .zero, debtE4: rub("1000"))
    #expect(CreditCardStates.overLimit(now) == .zero)
    #expect(CreditCardStates.overshoot(now: now, spendE4: rub("500")) == .zero)
  }

  @Test func theRealCardPassesItsLimit() {
    let books = Fx.books([Fx.purchase(10, "160000", on: "2026-10-10")], today: "2026-10-12")
    #expect(books.now.limitE4 == rub("150000"))
    #expect(state(books).overLimitE4 == rub("10000"))
  }

  @Test func overTheLimitIsAReminderThatCannotBePutAway() {
    let card = CreditCardNow(
      availableE4: rub("-1000"), limitE4: rub("150000"), debtE4: rub("151000"))
    let id = UUID()
    let reminder = DebtReminder.cardOverLimit(accountId: id, overE4: rub("1000"))
    let list = DebtReminders.list(
      debts: [], costs: [], cards: [id: card], today: day("2026-11-10"),
      dismissed: [reminder.id], creditHistoryEnabled: false, creditHistoryDone: nil)
    #expect(list == [reminder])
    let within = CreditCardNow(availableE4: rub("10"), limitE4: rub("150000"))
    #expect(
      DebtReminders.list(
        debts: [], costs: [], cards: [id: within], today: day("2026-11-10"),
        dismissed: [], creditHistoryEnabled: false, creditHistoryDone: nil
      ).isEmpty)
  }

  // MARK: Debts

  @Test func debtsListOnlyTheCardsInDebtOnceWhateverTheDebtsSay() {
    let missed = Fx.books(
      Fx.twoPurchases,
      transfers: [Fx.transfer(30, "900", on: "2026-11-25", from: Fx.mainId, to: Fx.cardId)],
      today: "2026-12-10")
    let accounts = AccountsSnapshot.build(
      balances: missed.balances, accounts: Fx.accounts, groups: [], rubPerUnit: [.rub: 1],
      locale: Locale(identifier: "ru"))
    let states = [Fx.cardId: state(missed)]
    let lines = CreditCardDebts.lines(states: states, accounts: accounts)
    #expect(lines.count == 1)
    #expect(lines.first?.name == "Т-Банк")
    #expect(lines.first?.debtE4 == rub("29100"))
    #expect(lines.first?.debtRub == rub("29100"))
    #expect(lines.first?.estimateE4 == missed.now.estimate?.shownE4)
    #expect(lines.first?.missedDue == day("2026-11-30"))
    // A debt of the same name that the owner made by hand stands for the card already.
    let manual = Debt(id: UUID(), direction: .iOwe, type: .creditCard, name: "т-банк")
    #expect(CreditCardDebts.lines(states: states, accounts: accounts, debts: [manual]).isEmpty)
    // A card in its grace period is not a debt.
    let waiting = Fx.books(Fx.twoPurchases, today: "2026-11-10")
    #expect(CreditCardDebts.lines(states: [Fx.cardId: state(waiting)], accounts: accounts).isEmpty)
  }
}
