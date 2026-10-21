import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Where a new account gets its card, against a real database: an account of the kind card or
/// account the owner makes — in the editor, in «Add…» of the ↓ panel, in the setup sheet —
/// comes with a card named like it, in the same step of ⌘Z; cash gets none. An account may not
/// take the name of another account's live card, and the first card of an account takes the
/// account's own cashback rules.
@MainActor
final class AccountCardsTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-account-cards-\(UUID().uuidString)", isDirectory: true)
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
  private var cards: CardActions { CardActions(environment: environment, store: store) }

  private func books() async throws -> AccountBooks {
    let read = await actions.books()
    return try XCTUnwrap(read)
  }

  private func account(_ name: String) -> PaymentMethod? {
    actions.all.first { $0.name == name }
  }

  // MARK: The editor

  /// «Т-Банк» of the kind card comes with the card «Т-Банк»; one ⌘Z takes both away.
  func testANewCardAccountGetsItsCardInOneUndoStep() async throws {
    let books = try await books()
    XCTAssertEqual(
      actions.save(
        PaymentMethod(name: " Т-Банк ", kind: .card, currency: .rub), previous: nil, books: books),
      .done)
    let saved = try XCTUnwrap(account("Т-Банк"))
    XCTAssertEqual(cards.cards.map(\.name), ["Т-Банк"])
    XCTAssertEqual(cards.cards.first?.accountId, saved.id)
    XCTAssertTrue(
      environment.vocabulary.cards.contains { $0.accountId == saved.id },
      "the entry line does not know the new card")

    store.undo()
    XCTAssertNil(account("Т-Банк"), "the account stayed after ⌘Z")
    XCTAssertTrue(cards.cards.isEmpty, "the card stayed after ⌘Z: two steps")
  }

  /// A bank account is paid from with a card too; cash and «other» are not.
  func testANewBankAccountGetsACardAndCashGetsNone() async throws {
    let books = try await books()
    XCTAssertEqual(
      actions.save(
        PaymentMethod(name: "Сбер", kind: .account, currency: .rub), previous: nil, books: books),
      .done)
    XCTAssertEqual(
      actions.save(
        PaymentMethod(name: "Наличные", kind: .cash, currency: .rub), previous: nil, books: books),
      .done)
    XCTAssertEqual(
      actions.save(
        PaymentMethod(name: "Копилка", kind: .other, currency: .rub), previous: nil, books: books),
      .done)
    XCTAssertEqual(cards.cards.map(\.name), ["Сбер"])
  }

  /// An edit of an account makes no card: the card is for an account the owner opens.
  func testAnEditMakesNoCard() async throws {
    let references = try XCTUnwrap(environment.references)
    let cash = PaymentMethod(name: "Кошелёк", kind: .cash, currency: .rub)
    try references.save(cash)
    var edited = cash
    edited.kind = .card
    let books = try await books()
    XCTAssertEqual(actions.save(edited, previous: cash, books: books), .done)
    XCTAssertTrue(cards.cards.isEmpty, "an edit made a card")
  }

  /// «Black» is a live card of «Т-Банк»: an account may not be called so, nor carry it among
  /// its other names — the entry line would read the card. Once the card is archived the name
  /// is free.
  func testANameOfAnotherAccountsLiveCardIsTaken() async throws {
    let references = try XCTUnwrap(environment.references)
    let tBank = PaymentMethod(name: "Т-Банк", kind: .card, currency: .rub)
    try references.save(tBank)
    let black = PaymentCard(accountId: tBank.id, name: "Black")
    XCTAssertEqual(cards.save(black, previous: nil), .done)
    let books = try await books()

    let named = PaymentMethod(name: "black", kind: .card, currency: .rub)
    let refused = actions.save(named, previous: nil, books: books)
    XCTAssertEqual(refused, .refused(.nameTakenByCard("Black")))
    XCTAssertTrue(
      AccountText.message(.nameTakenByCard("Black"), environment).contains("Black"),
      "the refusal does not name the card")
    let aliased = PaymentMethod(
      name: "Альфа", kind: .card, currency: .rub, aliases: ["Black"])
    XCTAssertEqual(
      actions.save(aliased, previous: nil, books: books), .refused(.nameTakenByCard("Black")))
    XCTAssertNil(account("black"))

    XCTAssertEqual(cards.archive(black.id), .done)
    XCTAssertEqual(actions.save(named, previous: nil, books: books), .done)
  }

  // MARK: The other ways in

  /// «Add…» of the ↓ panel: a card account comes with its card in the same write; cash with
  /// none.
  func testAddFromPickerMakesTheCard() throws {
    let references = try XCTUnwrap(environment.references)
    let transactions = try XCTUnwrap(environment.transactions)
    let model = EntryDraftModel(references: references, transactions: transactions, calendar: .utc)
    model.reload()
    let today = DateOnly(year: 2026, month: 9, day: 18)
    model.applyDefaults(today: today)
    let context = NewRecordForm.Context(references: references)

    var card = NewRecordForm(kind: .paymentMethod, model: model, today: today)
    card.name = "Kaspi"
    XCTAssertTrue(card.save(into: model, today: today, context: context))
    var cash = NewRecordForm(kind: .paymentMethod, model: model, today: today)
    cash.name = "Наличные"
    cash.paymentKind = .cash
    XCTAssertTrue(cash.save(into: model, today: today, context: context))

    let kaspi = try XCTUnwrap(account("Kaspi"))
    XCTAssertEqual(cards.cards.map(\.name), ["Kaspi"])
    XCTAssertEqual(cards.cards.first?.accountId, kaspi.id)
  }

  /// «Add…» of the ↓ panel refuses the name of another account's live card, as the editor
  /// does: «black» would make an account the line reads instead of «Т-Банк · Black», and its
  /// own card «black» a second live card of one name. The card of an archived account holds its
  /// name too; an archived card frees it.
  func testAddFromPickerRefusesALiveCardsName() throws {
    let references = try XCTUnwrap(environment.references)
    let transactions = try XCTUnwrap(environment.transactions)
    let tBank = PaymentMethod(name: "Т-Банк", kind: .card, currency: .rub)
    try references.save(tBank)
    let black = PaymentCard(accountId: tBank.id, name: "Black")
    XCTAssertEqual(cards.save(black, previous: nil), .done)
    let alfa = PaymentMethod(name: "Альфа", kind: .card, currency: .rub)
    try references.save(alfa)
    XCTAssertEqual(cards.save(PaymentCard(accountId: alfa.id, name: "Gold"), previous: nil), .done)
    var archivedAlfa = alfa
    archivedAlfa.archived = true
    try references.save(archivedAlfa)

    let model = EntryDraftModel(references: references, transactions: transactions, calendar: .utc)
    let cardActions = cards
    model.readsCards = { (cardActions.cards, cardActions.rules) }
    model.reload()
    let today = DateOnly(year: 2026, month: 9, day: 18)
    model.applyDefaults(today: today)
    let context = NewRecordForm.Context(references: references)

    var form = NewRecordForm(kind: .paymentMethod, model: model, today: today)
    form.name = " black "
    XCTAssertEqual(form.refusalKey(in: model), "entry.add.nameTaken")
    XCTAssertFalse(form.save(into: model, today: today, context: context))
    XCTAssertEqual(
      form.commit(into: model, today: today, context: context), .key("entry.add.nameTaken"))

    var gold = NewRecordForm(kind: .paymentMethod, model: model, today: today)
    gold.name = "gold"
    XCTAssertEqual(
      gold.commit(into: model, today: today, context: context), .key("entry.add.nameTaken"),
      "a live card of an archived account lost its name")

    XCTAssertNil(account("black"))
    XCTAssertNil(account("gold"))
    XCTAssertEqual(cards.cards.filter { !$0.archived }.map(\.name).sorted(), ["Black", "Gold"])

    XCTAssertEqual(cards.archive(black.id), .done)
    model.reload()
    XCTAssertNil(form.refusalKey(in: model), "an archived card still holds its name")
    XCTAssertTrue(form.save(into: model, today: today, context: context))
    XCTAssertNotNil(account("black"))
  }

  /// The setup sheet: every new account of the kind card or account gets its card with
  /// «Готово»; a stored account keeps the cards it has, cash gets none.
  func testTheSetupSheetMakesCardsForNewAccounts() async throws {
    let references = try XCTUnwrap(environment.references)
    let stored = PaymentMethod(name: "Сбер", kind: .card, currency: .rub, isDefault: true)
    try references.save(stored)
    var model = AccountSetupModel(
      accounts: [stored], groups: [], defaultCurrency: .rub,
      enabled: CurrencyCode.defaultEnabled)
    model.setExpected([:])
    let tBank = try XCTUnwrap(model.addAccount(name: "Т-Банк", kind: .card))
    _ = try XCTUnwrap(model.addAccount(name: "Наличные", kind: .cash))
    _ = try XCTUnwrap(model.addAccount(name: "Вклад", kind: .account))

    let plan = try XCTUnwrap(model.plan(at: Date()))
    XCTAssertEqual(plan.cards.map(\.name).sorted(), ["Вклад", "Т-Банк"])
    XCTAssertEqual(plan.cards.first { $0.name == "Т-Банк" }?.accountId, tBank)
    XCTAssertEqual(
      try XCTUnwrap(model.plan(at: Date())).cards.map(\.id), plan.cards.map(\.id),
      "the plan changes each time it is asked for")

    XCTAssertEqual(
      AccountSetupWrites.finish(plan, environment: environment, store: store), .written)
    XCTAssertEqual(cards.cards.map(\.name).sorted(), ["Вклад", "Т-Банк"])
  }

  /// The setup sheet knows the cards: an account added or renamed there under the name of
  /// another account's live card is an issue that names the card, and «Готово» writes nothing
  /// — it would write the account and a second live card of that name. An account's own card
  /// is no clash; a card archived meanwhile frees the name once the sheet reads again.
  func testTheSetupSheetRefusesALiveCardsName() async throws {
    let references = try XCTUnwrap(environment.references)
    let tBank = PaymentMethod(name: "Т-Банк", kind: .card, currency: .rub, isDefault: true)
    try references.save(tBank)
    let sber = PaymentMethod(name: "Сбер", kind: .card, currency: .rub)
    try references.save(sber)
    let black = PaymentCard(accountId: tBank.id, name: "Black")
    XCTAssertEqual(cards.save(black, previous: nil), .done)
    XCTAssertEqual(
      cards.save(PaymentCard(accountId: tBank.id, name: "Т-Банк"), previous: nil), .done)

    var model = try XCTUnwrap(AccountSetupModel.load(from: environment))
    model.setExpected([:])
    XCTAssertEqual(model.issues, [], "an account's own card was taken for a clash")
    let added = try XCTUnwrap(model.addAccount(name: "black", kind: .card))
    let issue = AccountSetupModel.Issue.nameTakenByCard(added, card: "Black")
    XCTAssertEqual(model.issues, [issue])
    XCTAssertNil(model.plan(at: Date()))
    XCTAssertTrue(
      model.message(for: issue, language: environment.language).contains("Black"),
      "the words do not name the card")

    model.removeAccount(added)
    let sberIndex = try XCTUnwrap(model.accounts.firstIndex { $0.id == sber.id })
    model.accounts[sberIndex].name = " BLACK "
    XCTAssertEqual(model.issues, [.nameTakenByCard(sber.id, card: "Black")])
    XCTAssertNil(model.plan(at: Date()))

    XCTAssertEqual(cards.archive(black.id), .done)
    XCTAssertEqual(model.rebase(on: environment), false)
    XCTAssertEqual(model.issues, [])
    XCTAssertNotNil(model.plan(at: Date()))
  }

  // MARK: Rules

  /// «Наличные» keep a rule of their own, which every card follows: the first card changes
  /// nothing about it, and ⌘Z takes the card away alone.
  func testTheFirstCardLeavesTheAccountRulesWhereTheyAre() throws {
    let references = try XCTUnwrap(environment.references)
    let cash = PaymentMethod(name: "Наличные", kind: .cash, currency: .rub)
    try references.save(cash)
    let rule = CashbackRule(accountId: cash.id, percent: CashbackPercent(e4: 10_000)!)
    XCTAssertEqual(cards.saveRules(of: [.account(cash.id)], [rule]), .done)

    let first = PaymentCard(accountId: cash.id, name: "Карта к кошельку")
    XCTAssertEqual(cards.save(first, previous: nil), .done)
    XCTAssertEqual(cards.rules.map(\.cardId), [nil], "the account's rule is still the account's")
    XCTAssertEqual(cards.rules.map(\.id), [rule.id], "the same row")

    store.undo()
    XCTAssertEqual(cards.rules.map(\.id), [rule.id])
    XCTAssertTrue(cards.cards.isEmpty, "one step: the card alone")
  }
}
