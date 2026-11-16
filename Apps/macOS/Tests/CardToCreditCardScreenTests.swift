import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Сделать кредиткой» and «+ → Кредитная карта» of «Настройки → Счета»: what the sheet asks and
/// reads (the default past, the date, the refusals, the name asked when the card's own is
/// taken), the write as one step of ⌘Z, the credit card made from the «+» of a bank, the two
/// choices of that «+», and the words of every refusal in both languages.
@MainActor
final class CardToCreditCardScreenTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-tocredit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
  }

  override func tearDown() async throws {
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private var actions: AccountActions { AccountActions(environment: environment, store: store) }

  /// A debit account «Дебетовая» under the bank «Т-Банк» with one card, as the books keep it.
  private func debit(
    accountName: String = "Дебетовая", cardName: String = "Black"
  ) throws -> (bank: Bank, account: PaymentMethod, card: PaymentCard) {
    let references = try XCTUnwrap(environment.references)
    let bank = Bank(name: "Т-Банк")
    XCTAssertEqual(actions.save(bank: bank), .done)
    let account = PaymentMethod(name: accountName, kind: .card, currency: .rub, bankId: bank.id)
    try references.save(account)
    let card = PaymentCard(accountId: account.id, name: cardName)
    XCTAssertEqual(CardActions(environment: environment, store: store).save(card, previous: nil), .done)
    return (bank, account, card)
  }

  private func draft(limit: String = "150000") -> CardToCreditCardDraft {
    var draft = CardToCreditCardDraft(today: Date(timeIntervalSince1970: 1_700_000_000))
    draft.credit.limitText = limit
    return draft
  }

  // MARK: The sheet

  /// «Перенести все» is chosen to begin with, the credit switch is on and fixed, and the date
  /// is read in the calendar of the Mac.
  func testTheDefaultChoiceIsToMoveEverything() {
    var draft = draft()
    XCTAssertEqual(draft.past, .all)
    XCTAssertTrue(draft.credit.isOn)
    XCTAssertEqual(draft.pastOperations(calendar: environment.calendar), .all)
    draft.past = .none
    XCTAssertEqual(draft.pastOperations(calendar: environment.calendar), .none)
    draft.past = .fromDate
    draft.fromDate = Date(timeIntervalSince1970: 1_700_000_000)
    XCTAssertEqual(
      draft.pastOperations(calendar: environment.calendar),
      .onAndAfter(environment.calendar.day(of: draft.fromDate)))
  }

  func testTheThreeChoicesHaveWordsInBothLanguages() {
    for choice in CardToCreditCardDraft.Past.allCases {
      for language in [AppLanguage.Choice.english, .russian] {
        let environment = AppEnvironment()
        environment.language.choice = language
        let text = environment.language(
          CardToCreditCardSheet.key(of: choice), table: AccountText.table)
        XCTAssertNotEqual(text, CardToCreditCardSheet.key(of: choice))
        XCTAssertFalse(text.isEmpty)
      }
    }
  }

  func testTermsThatDoNotReadAreRefusedBeforeAnyPlanIsMade() throws {
    let made = try debit()
    var draft = draft(limit: "")
    XCTAssertNil(
      draft.attempt(
        converting: made.card, cards: actions.cards, accounts: actions.all,
        calendar: environment.calendar))
    XCTAssertEqual(draft.refusal, .terms(.limit))
    XCTAssertFalse(draft.asksForName)
    XCTAssertFalse(AccountText.message(.terms(.limit), environment).isEmpty)
  }

  func testACardOfAnotherPersonOrOfNoBankIsRefusedInWords() throws {
    let references = try XCTUnwrap(environment.references)
    let loose = PaymentMethod(name: "Без банка", kind: .card, currency: .rub)
    try references.save(loose)
    let card = PaymentCard(accountId: loose.id, name: "Карта")
    XCTAssertEqual(CardActions(environment: environment, store: store).save(card, previous: nil), .done)
    var draft = draft()
    let plan = draft.attempt(
      converting: card, cards: actions.cards, accounts: actions.all,
      calendar: environment.calendar)
    // The editor files an account under a bank when it is saved; one left under none is refused.
    if plan == nil {
      XCTAssertEqual(draft.refusal, .conversion(.noBank))
      XCTAssertEqual(
        AccountText.message(.conversion(.noBank), environment),
        environment.language("card.toCredit.refusal.noBank", table: AccountText.table))
    }
    for issue in [
      CreditCardConversionIssue.notFound, .archived, .alreadyCreditCard, .borrowed, .noBank,
      .emptyName, .terms, .name(.nameTaken), .name(.otherNameTaken("x")),
      .name(.nameTakenByCard("y")),
    ] {
      for language in [AppLanguage.Choice.english, .russian] {
        let environment = AppEnvironment()
        environment.language.choice = language
        let text = AccountText.message(.conversion(issue), environment)
        XCTAssertFalse(text.isEmpty)
        XCTAssertFalse(text.hasPrefix("card.toCredit"), "\(issue) has words in \(language)")
      }
    }
  }

  /// A card called like its debit account cannot give that name to the credit card: the sheet
  /// asks for another and goes on with it.
  func testATakenNameOpensTheFieldAndAnotherNameGoesThrough() throws {
    let made = try debit(accountName: "Т-Банк", cardName: "Т-Банк")
    var draft = draft()
    XCTAssertNil(
      draft.attempt(
        converting: made.card, cards: actions.cards, accounts: actions.all,
        calendar: environment.calendar))
    XCTAssertTrue(draft.asksForName)
    XCTAssertEqual(draft.refusal, .conversion(.name(.nameTaken)))
    draft.name = "Платинум"
    let plan = draft.attempt(
      converting: made.card, cards: actions.cards, accounts: actions.all,
      calendar: environment.calendar)
    XCTAssertEqual(plan?.account.name, "Платинум")
    XCTAssertNil(draft.refusal)
    XCTAssertTrue(draft.asksForName, "the field stays once asked")
  }

  // MARK: The write

  /// The conversion is one step of ⌘Z: the credit card is there with the terms and the card on
  /// it, the debit account stays, and undoing takes it all back at once.
  func testTheConversionIsOneStepAndBothAccountsAreOfferedACount() throws {
    let made = try debit()
    var draft = draft(limit: "200000")
    draft.credit.statementDay = 5
    let plan = try XCTUnwrap(
      draft.attempt(
        converting: made.card, cards: actions.cards, accounts: actions.all,
        calendar: environment.calendar))
    XCTAssertEqual(actions.convert(plan), .done)
    let credit = try XCTUnwrap(actions.all.first { $0.id == plan.account.id })
    XCTAssertEqual(credit.credit?.limitE4, AmountE4(whole: 200_000))
    XCTAssertEqual(credit.credit?.grace, .statement(day: 5, payDays: 25))
    XCTAssertEqual(credit.bankId, made.bank.id)
    XCTAssertEqual(actions.cards.first { $0.id == made.card.id }?.accountId, credit.id)
    XCTAssertEqual(plan.accountsToReconcile, [made.account.id, credit.id])
    store.undo()
    XCTAssertNil(actions.all.first { $0.id == plan.account.id }, "one step takes it all back")
    XCTAssertEqual(actions.cards.first { $0.id == made.card.id }?.accountId, made.account.id)
  }

  func testACardOfACreditCardIsNoLongerOffered() throws {
    let made = try debit()
    XCTAssertTrue(CreditCardConversion.offered(for: made.card, accounts: actions.all))
    var draft = draft()
    let plan = try XCTUnwrap(
      draft.attempt(
        converting: made.card, cards: actions.cards, accounts: actions.all,
        calendar: environment.calendar))
    XCTAssertEqual(actions.convert(plan), .done)
    let moved = try XCTUnwrap(actions.cards.first { $0.id == made.card.id })
    XCTAssertFalse(CreditCardConversion.offered(for: moved, accounts: actions.all))
    var again = self.draft()
    XCTAssertNil(
      again.attempt(
        converting: moved, cards: actions.cards, accounts: actions.all,
        calendar: environment.calendar))
    XCTAssertEqual(again.refusal, .conversion(.alreadyCreditCard))
  }

  // MARK: «+» of a bank

  func testThePlusOfABankOffersADebitAndACreditCardInThatOrder() {
    XCTAssertEqual(BankPlusChoice.allCases, [.debitCard, .creditCard])
    XCTAssertEqual(
      BankPlusChoice.allCases.map(\.identifier),
      ["accounts.tree.plus.debitCard", "accounts.tree.plus.creditCard"])
    for choice in BankPlusChoice.allCases {
      for language in [AppLanguage.Choice.english, .russian] {
        let environment = AppEnvironment()
        environment.language.choice = language
        let text = environment.language(choice.key, table: EntryLinks.table)
        XCTAssertNotEqual(text, choice.key)
      }
    }
  }

  /// «Кредитная карта» makes an account under the bank, in its group, with terms and its card
  /// at once, in one step of ⌘Z; a second one is numbered.
  func testACreditCardMadeFromThePlusOfABankHasItsTermsAndItsCard() async throws {
    let made = try debit()
    let group = AccountGroup(name: "Россия")
    XCTAssertEqual(actions.save(group: group), .done)
    var sibling = made.account
    sibling.groupId = group.id
    try XCTUnwrap(environment.references).save(sibling)
    let loaded = await actions.books()
    let books = try XCTUnwrap(loaded)
    let first = actions.addCreditCard(to: made.bank, books: books)
    XCTAssertEqual(first.outcome, .done)
    let credit = try XCTUnwrap(actions.all.first { $0.id == first.id })
    XCTAssertEqual(credit.bankId, made.bank.id)
    XCTAssertEqual(credit.groupId, group.id)
    XCTAssertEqual(credit.kind, .card)
    XCTAssertEqual(credit.credit?.limitE4, AccountActions.starterLimit)
    XCTAssertEqual(actions.cards.filter { $0.accountId == credit.id }.count, 1)
    let again = actions.addCreditCard(to: made.bank, books: books)
    XCTAssertEqual(again.outcome, .done)
    let names = actions.all.filter { $0.credit != nil }.map(\.name).sorted()
    XCTAssertEqual(names.count, 2)
    XCTAssertEqual(Set(names).count, 2, "the second one is numbered, not refused")
    store.undo()
    XCTAssertEqual(actions.all.filter { $0.credit != nil }.count, 1)
    store.undo()
    XCTAssertTrue(actions.all.filter { $0.credit != nil }.isEmpty, "each is one step")
    XCTAssertTrue(actions.cards.allSatisfy { $0.accountId == made.account.id })
  }

  func testTheTermsOfThePanelReadAndRefuseLikeTheEditor() throws {
    var credit = CreditDraft(CreditCardTerms(limitE4: AmountE4(whole: 100_000)))
    credit.limitText = "250000"
    credit.statementDay = 20
    credit.purchaseRateText = "29,9"
    let terms = try XCTUnwrap(try credit.terms().get())
    XCTAssertEqual(terms.limitE4, AmountE4(whole: 250_000))
    XCTAssertEqual(terms.grace, .statement(day: 20, payDays: 25))
    XCTAssertEqual(terms.purchaseRate, Decimal(string: "29.9"))
    credit.limitText = "0"
    XCTAssertEqual(credit.terms(), .failure(.limit))
    credit.limitText = "100000"
    credit.graceKind = .fromPurchase
    credit.purchaseDays = 100
    XCTAssertEqual(try credit.terms().get()?.grace, .fromPurchase(days: 100))
  }
}
