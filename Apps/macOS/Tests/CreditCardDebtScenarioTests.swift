import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// A credit card is never opened, or left, without a card; one whose statement was missed is a
/// line of Debts in both languages; spending past its limit is warned about before it is
/// written, and the card over its limit has a red line of «Стоит посмотреть» that cannot be put
/// away.
@MainActor
final class CreditCardDebtScenarioTests: AccountsScenarioDatabaseCase {
  private let terms = CreditCardTerms(
    limitE4: AmountE4(whole: 150_000), grace: .statement(day: 5, payDays: 25))

  private func creditAccount(_ name: String) -> PaymentMethod {
    PaymentMethod(name: name, kind: .card, currency: .rub, credit: terms)
  }

  // MARK: Never without a card

  func testACreditCardIsOpenedWithItsFirstCardNamedAsTyped() async throws {
    try await make(PaymentMethod(name: "Главный", isDefault: true))
    let books = try await freshBooks()
    let account = creditAccount("Т-Банк")
    XCTAssertEqual(
      accounts.save(account, previous: nil, books: books, firstCardNamed: " Платинум "), .done)
    let made = cardActions.cards.filter { $0.accountId == account.id }
    XCTAssertEqual(made.map(\.name), ["Платинум"])
  }

  func testWithoutATypedNameTheCardIsNamedLikeTheAccount() async throws {
    try await make(PaymentMethod(name: "Главный", isDefault: true))
    let books = try await freshBooks()
    let account = creditAccount("Альфа")
    XCTAssertEqual(accounts.save(account, previous: nil, books: books), .done)
    XCTAssertEqual(cardActions.cards.filter { $0.accountId == account.id }.map(\.name), ["Альфа"])
  }

  func testACardNameAnotherAccountHasIsRefusedAndNothingIsWritten() async throws {
    try await make(PaymentMethod(name: "Главный", isDefault: true))
    let books = try await freshBooks()
    let account = creditAccount("Кредитка")
    XCTAssertEqual(
      accounts.save(account, previous: nil, books: books, firstCardNamed: "главный"),
      .refused(.creditCardNeedsCard))
    XCTAssertNil(accounts.all.first { $0.id == account.id })
  }

  func testAnAccountThatBecomesACreditCardGetsACardWhenItHasNone() async throws {
    try await make(PaymentMethod(name: "Главный", isDefault: true))
    let cash = try await make(PaymentMethod(name: "Наличные", kind: .cash))
    XCTAssertTrue(cardActions.cards.filter { $0.accountId == cash.id }.isEmpty)
    var changed = cash
    changed.credit = terms
    let books = try await freshBooks()
    XCTAssertEqual(
      accounts.save(changed, previous: cash, books: books, firstCardNamed: "Рассрочка"), .done)
    XCTAssertEqual(
      cardActions.cards.filter { $0.accountId == cash.id }.map(\.name), ["Рассрочка"])
  }

  func testTheOnlyCardOfACreditCardCannotBeArchivedOrDeleted() async throws {
    try await make(PaymentMethod(name: "Главный", isDefault: true))
    let books = try await freshBooks()
    let account = creditAccount("Т-Банк")
    XCTAssertEqual(accounts.save(account, previous: nil, books: books), .done)
    let only = try XCTUnwrap(cardActions.cards.first { $0.accountId == account.id })
    XCTAssertEqual(cardActions.archive(only.id), .refused(.lastCardOfCreditCard))
    XCTAssertEqual(cardActions.delete(only.id), .refused(.lastCardOfCreditCard))
    // With a second card the first may go.
    XCTAssertEqual(
      cardActions.save(PaymentCard(accountId: account.id, name: "Вторая"), previous: nil), .done)
    XCTAssertEqual(cardActions.archive(only.id), .done)
  }

  // MARK: Words

  func testTheWordsOfADebtCardAndOfTheRedLineInBothLanguages() {
    let id = UUID()
    let line = CreditCardDebtLine(
      accountId: id, name: "Т-Банк", bankId: nil, currency: .rub,
      debtE4: AmountE4(whole: 29_100), debtRub: AmountE4(whole: 29_100),
      missedDue: DateOnly(year: 2026, month: 11, day: 30),
      estimateE4: AmountE4(whole: 1_205), overLimitE4: AmountE4(whole: 1_000))
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = AppEnvironment()
      environment.language.choice = choice
      for key in CreditCardDebtText.keys {
        XCTAssertNotEqual(environment.language(key, table: "Debts"), key, "\(choice) \(key)")
      }
      let text = CreditCardDebtText(line, environment)
      XCTAssertTrue(text.title.contains("Т-Банк"), text.title)
      XCTAssertTrue(text.debt.contains("29"), text.debt)
      XCTAssertTrue(text.missed.contains("30"), text.missed)
      XCTAssertTrue(try XCTUnwrap(text.estimate).contains("≈"), "interest is never money")
      XCTAssertTrue(try XCTUnwrap(text.overLimit).contains("1"), "\(choice)")
      var within = line
      within.overLimitE4 = .zero
      within.estimateE4 = nil
      within.missedDue = nil
      let plain = CreditCardDebtText(within, environment)
      XCTAssertNil(plain.estimate)
      XCTAssertNil(plain.overLimit)
      XCTAssertFalse(plain.missed.isEmpty)

      let note = WorthALookNote.debt(
        .cardOverLimit(accountId: id, overE4: AmountE4(whole: 1_000)))
      let said = WorthALookNoteText.text(
        note, debts: [:], accounts: [id: "Т-Банк"], currencies: [id: .rub], environment)
      XCTAssertTrue(said.contains("Т-Банк") && said.contains("1"), said)
    }
    let note = WorthALookNote.debt(.cardOverLimit(accountId: id, overE4: AmountE4(whole: 1_000)))
    XCTAssertEqual(WorthALookNoteText.symbol(note), "exclamationmark.octagon")
    XCTAssertTrue(WorthALookNoteText.isAlarm(note))
    XCTAssertEqual(WorthALookNoteText.actions(note), [.openAccount], "no «Готово»: it stays")
  }

  // MARK: The warning before the line is written

  private func model(on account: PaymentMethod) throws -> EntryDraftModel {
    let references = try XCTUnwrap(environment.references)
    let transactions = try XCTUnwrap(environment.transactions)
    let model = EntryDraftModel(references: references, transactions: transactions, calendar: .utc)
    model.reload()
    model.applyDefaults(today: today)
    model.draft.kind = .expense
    model.draft.paymentMethodId = account.id
    model.draft.currency = .rub
    return model
  }

  func testSpendingPastTheLimitIsWarnedAboutOnceAndCanBeRecordedAnyway() async throws {
    try await make(PaymentMethod(name: "Главный", isDefault: true))
    let books = try await freshBooks()
    let account = creditAccount("Т-Банк")
    XCTAssertEqual(accounts.save(account, previous: nil, books: books), .done)
    let model = try model(on: account)
    let cards = [
      account.id: CreditCardNow(
        availableE4: AmountE4(whole: 5_000), limitE4: AmountE4(whole: 150_000),
        debtE4: AmountE4(whole: 145_000))
    ]
    model.draft.amount = AmountE4(whole: 5_000)
    XCTAssertNil(model.creditLimitWarning(cards: cards), "up to the limit is fine")
    model.draft.amount = AmountE4(whole: 7_500)
    let warning = try XCTUnwrap(model.creditLimitWarning(cards: cards))
    XCTAssertEqual(warning.over, AmountE4(whole: 2_500))
    XCTAssertEqual(warning.account, "Т-Банк")
    model.overLimitAnswered = true
    XCTAssertNil(model.creditLimitWarning(cards: cards), "asked once")
  }

  func testNoWarningForAnIncomeAnotherCurrencyOrAPlainAccount() async throws {
    let main = try await make(PaymentMethod(name: "Главный", isDefault: true))
    let books = try await freshBooks()
    let account = creditAccount("Т-Банк")
    XCTAssertEqual(accounts.save(account, previous: nil, books: books), .done)
    let over = CreditCardNow(
      availableE4: AmountE4(whole: 100), limitE4: AmountE4(whole: 150_000),
      debtE4: AmountE4(whole: 149_900))
    let cards = [account.id: over, main.id: over]
    let creditModel = try model(on: account)
    creditModel.draft.amount = AmountE4(whole: 500)
    XCTAssertNotNil(creditModel.creditLimitWarning(cards: cards))
    creditModel.draft.kind = .income
    XCTAssertNil(creditModel.creditLimitWarning(cards: cards))
    creditModel.draft.kind = .expense
    creditModel.draft.currency = .usd
    XCTAssertNil(creditModel.creditLimitWarning(cards: cards), "another currency than the card's")
    let plain = try model(on: main)
    plain.draft.amount = AmountE4(whole: 500)
    XCTAssertNil(plain.creditLimitWarning(cards: cards), "a plain account has no limit")
  }
}
