import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// A book with cards, against a real database: «Сбер» (the main account) with its card «Сбер»,
/// «Т-Банк» with «Black» and «Virtual» («виртуалка»), «Kaspi» in tenge with its card, and
/// «Наличные» with none; «Кафе и рестораны» › «Кофейни», «Здоровье» › «Аптеки», «Одежда».
/// Black has the rules of the owner's example: «Кафе и рестораны» 5 % always and 10 % in the
/// month of today, «Кофейни» 3 % always, everything else 1 %.
@MainActor
final class CardEntryBook {
  let environment: AppEnvironment
  let store: TransactionsStore
  private let directory: URL
  private let dataDirectoryBefore: String?

  let sber = PaymentMethod(name: "Сбер", kind: .card, currency: .rub, isDefault: true)
  let tBank = PaymentMethod(name: "Т-Банк", kind: .card, currency: .rub)
  let kaspi = PaymentMethod(name: "Kaspi", kind: .card, currency: CurrencyCode("KZT"))
  let cash = PaymentMethod(name: "Наличные", kind: .cash, currency: .rub)
  let sberCard: PaymentCard
  let black: PaymentCard
  let virtual: PaymentCard
  let kaspiCard: PaymentCard
  let cafe = CoreKit.Category(kind: .expense, name: "Кафе и рестораны", quality: .neutral)
  let coffeeShops: CoreKit.Category
  let health = CoreKit.Category(kind: .expense, name: "Здоровье", quality: .good)
  let pharmacies: CoreKit.Category
  let clothes = CoreKit.Category(kind: .expense, name: "Одежда", quality: .neutral)

  init() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-entry-cards-\(UUID().uuidString)", isDirectory: true)
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
    sberCard = PaymentCard(accountId: sber.id, name: "Сбер")
    black = PaymentCard(accountId: tBank.id, name: "Black")
    virtual = PaymentCard(accountId: tBank.id, name: "Virtual", aliases: ["виртуалка"])
    kaspiCard = PaymentCard(accountId: kaspi.id, name: "Kaspi")
    coffeeShops = CoreKit.Category(parentId: cafe.id, kind: .expense, name: "Кофейни")
    pharmacies = CoreKit.Category(parentId: health.id, kind: .expense, name: "Аптеки")

    let references = try XCTUnwrap(environment.references)
    for account in [sber, tBank, kaspi, cash] { try references.save(account) }
    for category in [cafe, coffeeShops, health, pharmacies, clothes] {
      try references.save(category)
    }
    let month = environment.today.monthKey
    _ = try XCTUnwrap(environment.planning).apply(
      PlanningChange(
        upsert: PlanningRows(
          cards: [sberCard, black, virtual, kaspiCard],
          cashbackRules: [
            rule(on: black, cafe.id, 50_000),
            rule(on: black, coffeeShops.id, 30_000),
            rule(on: black, cafe.id, 100_000, in: month),
            rule(on: black, nil, 10_000),
          ])))
    environment.refreshVocabulary()
  }

  func close() async {
    await environment.close()
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    try? FileManager.default.removeItem(at: directory)
  }

  func rule(
    on card: PaymentCard, _ categoryId: UUID?, _ percentE4: Int64, in month: MonthKey? = nil
  ) -> CashbackRule {
    CashbackRule(
      accountId: card.accountId, cardId: card.id, categoryId: categoryId, month: month,
      percent: CashbackPercent(e4: percentE4)!)
  }

  var today: DateOnly { environment.today }

  /// The panel of the entry line, as the app makes it.
  func model() -> EntryDraftModel {
    let model = EntryDraftModel(environment: environment)
    model.reload()
    return model
  }

  /// A line typed and Enter pressed: what the line says goes into the draft.
  func enter(_ line: String, into model: EntryDraftModel) throws {
    let parsed = CoreLineInterpreter(
      vocabulary: environment.vocabulary, calendar: environment.calendar
    ).interpret(line, today: today, kind: model.draft.kind)
    model.apply(parsed, amount: try AmountE4(decimal: try XCTUnwrap(parsed.amount)), today: today)
  }

  /// The save of the line, once nothing is left to ask.
  @discardableResult
  func save(_ model: EntryDraftModel) throws -> TransactionEntry {
    let written = try XCTUnwrap(
      try EntrySave.write(model, environment: environment, store: store), "the write landed")
    return written.entry
  }

  func stored(_ id: UUID) throws -> TransactionEntry? {
    try XCTUnwrap(environment.transactions).entry(id: id)
  }

  func entries() throws -> [TransactionEntry] {
    try XCTUnwrap(environment.transactions).entries(from: .distantPast, to: .distantFuture)
  }

  /// An operation written as history before the line.
  @discardableResult
  func history(
    _ note: String, _ amount: Int64, on account: PaymentMethod, card: PaymentCard?,
    at place: Place? = nil, category: UUID? = nil, currency: CurrencyCode = .rub
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(
      currency: currency, amount: AmountE4(whole: amount), note: note, placeId: place?.id,
      paymentMethodId: account.id,
      parts: [PartDraft(categoryId: category, amount: AmountE4(whole: amount))],
      cardId: card?.id)
    draft.occurredAt = environment.calendar.startOfDay(today.adding(days: -3))
      .addingTimeInterval(12 * 3600)
    if currency != .rub {
      draft.rate = 1
      draft.rateDate = today.adding(days: -3)
      draft.rateSource = .manual
    }
    let entry = try draft.materialize()
    try XCTUnwrap(environment.transactions).save(entry)
    return entry
  }
}

/// A card in the entry line and in the ↓ panel: the line reads a card and puts it on its
/// account; the account picker lists every account followed by its live cards; a card brings its
/// account and another account drops it; the place brings the card that paid there last, without
/// making its account the owner's choice; a refund taken back from a purchase takes its card.
@MainActor
final class EntryCardTests: XCTestCase {
  private var book: CardEntryBook!

  override func setUp() async throws {
    book = try await CardEntryBook()
  }

  override func tearDown() async throws {
    await book?.close()
    book = nil
  }

  /// «кофе 300 black»: the card and its account, and the saved operation names the card.
  func testALineCardSetsCardAndAccount() throws {
    let model = book.model()
    try book.enter("кофе 300 black", into: model)
    XCTAssertEqual(model.draft.paymentMethodId, book.tBank.id)
    XCTAssertEqual(model.draft.cardId, book.black.id)
    XCTAssertEqual(model.accountOrCardSelection, book.black.id, "the picker shows the card")
    let saved = try book.save(model)
    XCTAssertEqual(try book.stored(saved.id)?.transaction.cardId, book.black.id)
    XCTAssertEqual(try book.stored(saved.id)?.transaction.paymentMethodId, book.tBank.id)

    // An alias; and the account alone names no card.
    let next = book.model()
    try book.enter("кофе 300 виртуалка", into: next)
    XCTAssertEqual(next.draft.cardId, book.virtual.id)
    let account = book.model()
    try book.enter("кофе 300 т-банк", into: account)
    XCTAssertEqual(account.draft.paymentMethodId, book.tBank.id)
    XCTAssertNil(account.draft.cardId)
  }

  /// The picker lists every account followed by its live cards when it has two or more,
  /// «Т-Банк › Black»; an account with one card is the account alone, and a card picked brings
  /// its account; an archived card is not offered to a new operation.
  func testPickingACardPicksItsAccount() throws {
    let model = book.model()
    let names = model.accountCardChoices(locale: Locale(identifier: "ru_RU")).map(\.name)
    XCTAssertEqual(names.first, "Сбер", "the main account first")
    XCTAssertEqual(names.count, 6)
    // Every account is followed by its own cards, and by nothing else's.
    for (account, cards) in [
      ("Сбер", []), ("Т-Банк", ["Т-Банк › Black", "Т-Банк › Virtual"]), ("Kaspi", []),
      ("Наличные", []),
    ] as [(String, [String])] {
      let at = try XCTUnwrap(names.firstIndex(of: account), account)
      XCTAssertEqual(Array(names.dropFirst(at + 1).prefix(cards.count)), cards, account)
      let next = at + 1 + cards.count
      if next < names.count { XCTAssertFalse(names[next].contains(" › "), account) }
    }

    model.setAccountOrCard(book.virtual.id)
    XCTAssertEqual(model.draft.paymentMethodId, book.tBank.id)
    XCTAssertEqual(model.draft.cardId, book.virtual.id)
    XCTAssertEqual(model.chosenAccount?.id, book.tBank.id, "a card picked is the owner's choice")

    var archived = book.virtual
    archived.archived = true
    _ = try XCTUnwrap(book.environment.planning).apply(
      PlanningChange(upsert: PlanningRows(cards: [archived])))
    let fresh = book.model()
    XCTAssertFalse(
      fresh.accountCardChoices(locale: Locale(identifier: "ru_RU")).contains {
        $0.id == book.virtual.id
      }, "an archived card is offered to nothing new")
  }

  /// Another account drops the card; the account of the card itself, picked in the menu, names
  /// no card; the same account set again keeps it.
  func testPickingAnotherAccountDropsTheCard() throws {
    let model = book.model()
    model.setAccountOrCard(book.black.id)
    model.setPaymentMethod(book.tBank.id)
    XCTAssertEqual(model.draft.cardId, book.black.id, "the card is of that account")
    model.setAccountOrCard(book.cash.id)
    XCTAssertEqual(model.draft.paymentMethodId, book.cash.id)
    XCTAssertNil(model.draft.cardId)

    model.setAccountOrCard(book.black.id)
    model.setAccountOrCard(book.tBank.id)
    XCTAssertEqual(model.draft.paymentMethodId, book.tBank.id)
    XCTAssertNil(model.draft.cardId, "the account picked in the menu is the account alone")

    // A line naming another account drops the card the panel chose.
    model.setAccountOrCard(book.black.id)
    try book.enter("хлеб 60 наличные", into: model)
    XCTAssertEqual(model.draft.paymentMethodId, book.cash.id)
    XCTAssertNil(model.draft.cardId)
  }

  /// The place brings the account it was paid from last, and the card that paid there — while
  /// the card is live and of that account.
  func testAPlaceDefaultBringsTheCard() throws {
    let place = Place(name: "Магнит")
    try XCTUnwrap(book.environment.references).save(place)
    book.environment.refreshVocabulary()
    try book.history("продукты", 700, on: book.tBank, card: book.virtual, at: place)

    let model = book.model()
    try book.enter("продукты 500 в Магните", into: model)
    XCTAssertEqual(model.draft.placeId, place.id)
    XCTAssertEqual(model.draft.paymentMethodId, book.tBank.id)
    XCTAssertEqual(model.draft.cardId, book.virtual.id)
    let saved = try book.save(model)
    XCTAssertEqual(try book.stored(saved.id)?.transaction.cardId, book.virtual.id)

    // A card archived since is not brought: the purchase is made with the one live card left
    // on the account, its default card.
    var archived = book.virtual
    archived.archived = true
    _ = try XCTUnwrap(book.environment.planning).apply(
      PlanningChange(upsert: PlanningRows(cards: [archived])))
    let next = book.model()
    try book.enter("продукты 400 в Магните", into: next)
    XCTAssertEqual(next.draft.paymentMethodId, book.tBank.id)
    XCTAssertEqual(next.draft.cardId, book.black.id)
  }

  /// A refund picked from a purchase takes the purchase's card while it is live and of the
  /// account the refund comes onto.
  func testARefundTakesThePurchasesCard() throws {
    let purchase = try book.history(
      "куртка", 10_000, on: book.tBank, card: book.black, category: book.clothes.id)
    let part = try XCTUnwrap(purchase.parts.first)
    let candidate = RefundCandidate(
      purchase: purchase, part: part, remaining: part.amountE4, refunded: .zero)

    let model = book.model()
    model.draft.kind = .refund
    try book.enter("возврат 4000 куртка", into: model)
    model.chooseRefund(of: candidate, amount: AmountE4(whole: 4_000))
    XCTAssertEqual(model.draft.paymentMethodId, book.tBank.id)
    XCTAssertEqual(model.draft.cardId, book.black.id)

    // Onto an account the owner chose, the card of another account stays behind.
    let onCash = book.model()
    onCash.draft.kind = .refund
    try book.enter("возврат 4000 куртка наличные", into: onCash)
    onCash.chooseRefund(of: candidate, amount: AmountE4(whole: 4_000))
    XCTAssertEqual(onCash.draft.paymentMethodId, book.cash.id)
    XCTAssertNil(onCash.draft.cardId)
  }

  /// «возврат 4000 куртка black»: the card the line names takes the money back, not the one that
  /// paid — and not none when the purchase named no card.
  func testARefundKeepsTheCardTheLineNamed() throws {
    for paidWith in [book.virtual, nil] {
      let purchase = try book.history(
        "куртка", 10_000, on: book.tBank, card: paidWith, category: book.clothes.id)
      let part = try XCTUnwrap(purchase.parts.first)
      let candidate = RefundCandidate(
        purchase: purchase, part: part, remaining: part.amountE4, refunded: .zero)

      let model = book.model()
      model.draft.kind = .refund
      try book.enter("возврат 4000 куртка black", into: model)
      model.chooseRefund(of: candidate, amount: AmountE4(whole: 4_000))
      let label = paidWith?.name ?? "no card"
      XCTAssertEqual(model.draft.paymentMethodId, book.tBank.id, label)
      XCTAssertEqual(model.draft.cardId, book.black.id, label)
    }
  }

  /// Money back names no card: the picker offers the accounts alone, and a card picked all the
  /// same brings its account without the card.
  func testMoneyBackOffersNoCard() throws {
    let model = book.model()
    try book.enter("возврат денег 500", into: model)
    XCTAssertEqual(model.draft.kind, .reimbursement)
    let choices = model.accountCardChoices(locale: Locale(identifier: "ru_RU"))
    XCTAssertFalse(choices.isEmpty)
    XCTAssertFalse(choices.contains(where: \.isCard), "no card is offered")

    model.setAccountOrCard(book.black.id)
    XCTAssertEqual(model.draft.paymentMethodId, book.tBank.id)
    XCTAssertNil(model.draft.cardId)
    XCTAssertEqual(model.accountOrCardSelection, book.tBank.id)

    // A card the draft kept from before its kind changed is not shown as picked either.
    let before = book.model()
    before.setAccountOrCard(book.black.id)
    before.draft.kind = .reimbursement
    XCTAssertEqual(before.accountOrCardSelection, book.tBank.id)
    XCTAssertFalse(
      before.accountCardChoices(locale: Locale(identifier: "ru_RU")).contains(where: \.isCard))
  }

  /// A purchase on «Т-Банк · Black» becomes money back in the panel; the confirmation moves it
  /// onto «Сбер» and it is recorded as income: the card of «Т-Банк» stays behind, and the income
  /// is written.
  func testMoneyBackRecordedAsIncomeOnAnotherAccountIsSaved() throws {
    let model = book.model()
    try book.enter("кофе 1500 black", into: model)
    XCTAssertEqual(model.draft.cardId, book.black.id)
    model.draft.kind = .reimbursement
    var sheet = model.draftForSaving
    sheet.paymentMethodId = book.sber.id

    model.recordMoneyBackInstead(.income, from: sheet, fromNote: { $0 }, today: book.today)
    XCTAssertEqual(model.draft.kind, .income)
    XCTAssertEqual(model.draft.paymentMethodId, book.sber.id)
    XCTAssertNil(model.draft.cardId)
    let saved = try book.save(model)
    let stored = try XCTUnwrap(try book.stored(saved.id))
    XCTAssertEqual(stored.transaction.kind, .income)
    XCTAssertEqual(stored.transaction.paymentMethodId, book.sber.id)
    XCTAssertNil(stored.transaction.cardId)
  }

  /// «продукты 5000 в Магнуме»: the place was paid from Kaspi, in tenge, with its card. The line
  /// takes the account and the card from the place, and the amount stays 5,000 ₽ — what paid is
  /// not a currency the owner chose.
  func testAPlaceDefaultCardDoesNotSetTheCurrency() throws {
    let place = Place(name: "Магнум")
    try XCTUnwrap(book.environment.references).save(place)
    book.environment.refreshVocabulary()
    try book.history(
      "продукты", 20_000, on: book.kaspi, card: book.kaspiCard, at: place,
      currency: CurrencyCode("KZT"))

    let model = book.model()
    try book.enter("продукты 5000 в Магнуме", into: model)
    XCTAssertEqual(model.draft.paymentMethodId, book.kaspi.id)
    XCTAssertEqual(model.draft.cardId, book.kaspiCard.id)
    XCTAssertEqual(model.draft.currency, .rub)
    XCTAssertEqual(model.draft.amount, AmountE4(whole: 5_000))
    XCTAssertNil(model.chosenAccount, "the place's account is no choice of the owner's")
    XCTAssertTrue(model.needsCharge, "the tenge account is asked what it was charged")
  }
}
