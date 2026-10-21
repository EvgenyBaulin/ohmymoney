import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// A database of its own in memory for each test, with the clock of the app standing still at
/// noon of Wednesday 16 September 2026, and the actions the account screens call. No test method
/// lives here: the scenario classes below inherit it.
@MainActor
class AccountsScenarioDatabaseCase: XCTestCase {
  var environment: AppEnvironment!
  var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  let today = DateOnly(year: 2026, month: 9, day: 16)
  var moment = Date()
  var noon: Date { environment.calendar.noon(of: today) }

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-lane-e-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    moment = environment.calendar.noon(of: today)
    environment.now = { [unowned self] in self.moment }
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
  }

  override func tearDown() async throws {
    if let environment { await environment.close() }
    environment = nil
    store = nil
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  var accounts: AccountActions { AccountActions(environment: environment, store: store) }
  var cardActions: CardActions { CardActions(environment: environment, store: store) }
  var transfers: TransferActions { TransferActions(environment: environment, store: store) }

  func freshBooks() async throws -> AccountBooks {
    let books = await accounts.books()
    return try XCTUnwrap(books)
  }

  /// A new account saved through the editor at 06:00 of the day, with «Остаток сейчас» for its
  /// currencies: counted then, so the moves of the day come after the count.
  @discardableResult
  func make(
    _ account: PaymentMethod, openings: [CurrencyCode: AmountE4] = [:], bank: String? = nil
  ) async throws -> PaymentMethod {
    moment = noon.addingTimeInterval(-6 * 3_600)
    defer { moment = noon }
    let books = try await freshBooks()
    XCTAssertEqual(
      accounts.save(account, previous: nil, openings: openings, books: books, newBankNamed: bank),
      .done, account.name)
    return try XCTUnwrap(accounts.all.first { $0.id == account.id })
  }

  func account(_ id: UUID) throws -> PaymentMethod {
    try XCTUnwrap(accounts.all.first { $0.id == id })
  }

  func balance(_ id: UUID, _ currency: CurrencyCode = .rub) async throws -> AmountE4? {
    let books = try await freshBooks()
    return books.balances.balance(BalanceKey(accountId: id, currency: currency), at: moment)
  }

  func rub(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }

  func liveEntries() throws -> [TransactionEntry] {
    try XCTUnwrap(environment.transactions).entries(from: .distantPast, to: .distantFuture)
      .filter { !$0.transaction.isDeleted }
  }

  @discardableResult
  func spend(
    _ whole: Int64, on accountId: UUID, card: UUID? = nil, at: Date? = nil
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(
      occurredAt: at ?? noon.addingTimeInterval(-3_600), amount: rub(whole), note: "coffee",
      paymentMethodId: accountId, cardId: card)
    draft.normalizeSinglePart()
    let entry = try draft.materialize()
    XCTAssertTrue(store.save(entry))
    return entry
  }

  func transferForm(
    from: PaymentMethod, _ fromCurrency: CurrencyCode = .rub, to: PaymentMethod,
    _ toCurrency: CurrencyCode = .rub, sent: Int64, received: Int64? = nil, fee: Int64 = 0
  ) -> TransferForm {
    var form = TransferForm(from: from, accounts: accounts.all, day: today)
    form.chooseFrom(from)
    form.fromCurrency = fromCurrency
    form.toAccountId = to.id
    form.toCurrency = toCurrency
    form.sent = rub(sent)
    form.received = rub(received ?? sent)
    form.fee = rub(fee)
    return form
  }

  @discardableResult
  func transfer(
    from: PaymentMethod, _ fromCurrency: CurrencyCode = .rub, to: PaymentMethod,
    _ toCurrency: CurrencyCode = .rub, sent: Int64, received: Int64? = nil, fee: Int64 = 0,
    at: Date? = nil
  ) async throws -> TransferOutcome {
    let form = transferForm(
      from: from, fromCurrency, to: to, toCurrency, sent: sent, received: received, fee: fee)
    let books = try await freshBooks()
    return transfers.save(form, occurredAt: at ?? noon.addingTimeInterval(-1_800), books: books)
  }

  func storedTransfers() async throws -> [Transfer] {
    try await freshBooks().dataset.transfers
  }
}

/// Accounts as the owner keeps them up over time: a new account goes under a bank, «Остаток
/// сейчас» is its first count (or «не знаю»), names are his own whatever case or «ё», the main
/// account is only ever passed on, an account goes to the archive and comes back, and each of
/// these is one step of ⌘Z.
final class AccountsScenarioAccountActionTests: AccountsScenarioDatabaseCase {
  func testANewAccountWithoutABankGetsABankOfItsNameAndUndoTakesBoth() async throws {
    let saved = try await make(PaymentMethod(name: "Альфа", isDefault: true))
    let bank = try XCTUnwrap(accounts.banks.first { $0.id == saved.bankId })
    XCTAssertEqual(bank.name, "Альфа")
    XCTAssertEqual(cardActions.cards.map(\.name), ["Альфа"], "a card account starts with a card")
    store.undo()
    XCTAssertTrue(accounts.all.isEmpty)
    XCTAssertTrue(accounts.banks.isEmpty)
    XCTAssertTrue(cardActions.cards.isEmpty)
  }

  func testANewAccountJoinsTheLiveBankNamedInAnotherCase() async throws {
    let first = try await make(PaymentMethod(name: "Т-Банк", isDefault: true))
    let second = try await make(PaymentMethod(name: "Накопительный"), bank: "т-банк")
    XCTAssertEqual(second.bankId, first.bankId)
    XCTAssertEqual(accounts.banks.count, 1)
  }

  func testCashStartsWithNoCard() async throws {
    try await make(PaymentMethod(name: "Наличные", kind: .cash, isDefault: true))
    XCTAssertTrue(cardActions.cards.isEmpty)
  }

  func testTheOpeningBalanceIsTheMoneyNowAndNoOperation() async throws {
    let saved = try await make(
      PaymentMethod(name: "Сбер", isDefault: true), openings: [.rub: rub(100_000)])
    let money = try await balance(saved.id)
    XCTAssertEqual(money, rub(100_000))
    XCTAssertTrue(try liveEntries().isEmpty, "an opening is no income")
    store.undo()
    XCTAssertTrue(accounts.all.isEmpty)
    let book = try XCTUnwrap(environment.planning).book()
    XCTAssertTrue(book.reconciledBalances.isEmpty, "⌘Z takes the count with the account")
  }

  func testAZeroOpeningIsZeroAndAnEmptyOneIsUnknown() async throws {
    let zero = try await make(PaymentMethod(name: "Ноль", isDefault: true), openings: [.rub: .zero])
    let blank = try await make(PaymentMethod(name: "Пусто"))
    let zeroMoney = try await balance(zero.id)
    let blankMoney = try await balance(blank.id)
    XCTAssertEqual(zeroMoney, .zero)
    XCTAssertNil(blankMoney, "«не знаю» is no count")
  }

  func testACreditCardOpensBelowZero() async throws {
    let card = try await make(
      PaymentMethod(name: "Кредитка", isDefault: true), openings: [.rub: rub(-15_000)])
    let money = try await balance(card.id)
    XCTAssertEqual(money, rub(-15_000))
  }

  func testAnOpeningInEachCurrencyOfTheAccount() async throws {
    let saved = try await make(
      PaymentMethod(name: "Мульти", currency: .rub, isDefault: true, otherCurrencies: [.usd]),
      openings: [.rub: rub(1_000), .usd: rub(50)])
    let rubles = try await balance(saved.id, .rub)
    let dollars = try await balance(saved.id, .usd)
    XCTAssertEqual(rubles, rub(1_000))
    XCTAssertEqual(dollars, rub(50))
  }

  func testAnOpeningForACurrencyTheAccountDoesNotHoldIsIgnored() async throws {
    let saved = try await make(
      PaymentMethod(name: "Рубли", currency: .rub, isDefault: true), openings: [.usd: rub(50)])
    let dollars = try await balance(saved.id, .usd)
    XCTAssertNil(dollars)
    XCTAssertTrue(try XCTUnwrap(environment.planning).book().reconciledBalances.isEmpty)
  }

  func testANameWithYoIsTheSameName() async throws {
    try await make(PaymentMethod(name: "Ёлка", isDefault: true))
    let books = try await freshBooks()
    XCTAssertEqual(
      accounts.save(PaymentMethod(name: " ЕЛКА "), previous: nil, books: books),
      .refused(.nameTaken))
  }

  func testAnEmptyNameIsRefused() async throws {
    let books = try await freshBooks()
    XCTAssertEqual(
      accounts.save(PaymentMethod(name: "   "), previous: nil, books: books),
      .refused(.emptyName))
  }

  func testTheNameOfAnArchivedAccountOffersItBack() async throws {
    try await make(PaymentMethod(name: "Главный", isDefault: true))
    let old = try await make(PaymentMethod(name: "Старый"))
    let books = try await freshBooks()
    XCTAssertEqual(accounts.archive(old.id, books: books), .done)
    let again = try await freshBooks()
    XCTAssertEqual(
      accounts.save(PaymentMethod(name: "старый"), previous: nil, books: again),
      .refused(.inArchive(old.id)))
  }

  func testAnotherNameTakenByAnotherAccountIsTold() async throws {
    try await make(PaymentMethod(name: "Сбер", aliases: ["Зарплатная"], isDefault: true))
    let books = try await freshBooks()
    XCTAssertEqual(
      accounts.save(
        PaymentMethod(name: "Альфа", aliases: ["зарплатная"]), previous: nil, books: books),
      .refused(.otherNameTaken("зарплатная")))
    XCTAssertEqual(
      accounts.save(PaymentMethod(name: "ЗАРПЛАТНАЯ"), previous: nil, books: books),
      .refused(.nameTaken), "a name another account answers to is taken")
  }

  func testANameALiveCardOfAnotherAccountAnswersToIsRefused() async throws {
    let sber = try await make(PaymentMethod(name: "Сбер", isDefault: true))
    XCTAssertEqual(
      cardActions.save(PaymentCard(accountId: sber.id, name: "Visa Gold"), previous: nil), .done)
    let books = try await freshBooks()
    XCTAssertEqual(
      accounts.save(PaymentMethod(name: "visa gold"), previous: nil, books: books),
      .refused(.nameTakenByCard("Visa Gold")))
  }

  func testTheNameAndAliasesAreTidiedOnSave() async throws {
    let saved = try await make(
      PaymentMethod(
        name: "  Сбер  ", aliases: ["  ", "сбер", " СберБанк ", "сбербанк"], isDefault: true))
    XCTAssertEqual(saved.name, "Сбер")
    XCTAssertEqual(saved.aliases, ["СберБанк"])
  }

  // MARK: The main account

  func testTheFirstAccountIsMainAndAnEditCannotSwitchItOff() async throws {
    let main = try await make(PaymentMethod(name: "Главный", isDefault: true))
    var edited = main
    edited.isDefault = false
    let books = try await freshBooks()
    XCTAssertEqual(accounts.save(edited, previous: main, books: books), .done)
    XCTAssertTrue(try account(main.id).isDefault)
  }

  func testMakingAnotherMainMovesTheFlagInOneStep() async throws {
    let one = try await make(PaymentMethod(name: "Первый", isDefault: true))
    let two = try await make(PaymentMethod(name: "Второй"))
    XCTAssertEqual(accounts.makeMain(two.id), .done)
    XCTAssertTrue(try account(two.id).isDefault)
    XCTAssertFalse(try account(one.id).isDefault)
    store.undo()
    XCTAssertTrue(try account(one.id).isDefault)
    XCTAssertFalse(try account(two.id).isDefault)
  }

  func testAnAccountOutOfTheSummaryCannotBeMain() async throws {
    try await make(PaymentMethod(name: "Главный", isDefault: true))
    let group = AccountGroup(name: "Заграница", inSummary: false)
    XCTAssertEqual(accounts.save(group: group), .done)
    let abroad = try await make(PaymentMethod(name: "Freedom", groupId: group.id))
    XCTAssertEqual(accounts.makeMain(abroad.id), .refused(.mainInExcludedGroup))
  }

  func testMakingTheMainOneMainAgainChangesNothing() async throws {
    let main = try await make(PaymentMethod(name: "Главный", isDefault: true))
    XCTAssertEqual(accounts.makeMain(main.id), .done)
    XCTAssertEqual(accounts.makeMain(UUID()), .refused(.notFound))
  }

  // MARK: The archive

  func testAnEmptyAccountGoesToTheArchiveAndUndoBringsItBack() async throws {
    try await make(PaymentMethod(name: "Главный", isDefault: true))
    let old = try await make(PaymentMethod(name: "Старый"), openings: [.rub: .zero])
    let books = try await freshBooks()
    XCTAssertEqual(accounts.archive(old.id, books: books), .done)
    XCTAssertTrue(try account(old.id).archived)
    store.undo()
    XCTAssertFalse(try account(old.id).archived)
  }

  func testTheMainAccountGoesToTheArchiveOnlyWithAnHeir() async throws {
    let main = try await make(PaymentMethod(name: "Главный", isDefault: true))
    let heir = try await make(PaymentMethod(name: "Наследник"))
    let books = try await freshBooks()
    XCTAssertEqual(accounts.archive(main.id, books: books), .refused(.needsNewMain))
    XCTAssertEqual(accounts.archive(main.id, newMain: heir.id, books: books), .done)
    XCTAssertTrue(try account(heir.id).isDefault)
    XCTAssertFalse(try account(main.id).isDefault)
    store.undo()
    XCTAssertTrue(try account(main.id).isDefault)
    XCTAssertFalse(try account(main.id).archived)
    XCTAssertFalse(try account(heir.id).isDefault)
  }

  func testTheLastLiveAccountStays() async throws {
    let main = try await make(PaymentMethod(name: "Единственный", isDefault: true))
    let books = try await freshBooks()
    XCTAssertEqual(accounts.archive(main.id, books: books), .refused(.lastLiveAccount))
  }

  func testAnAccountWithMoneyStaysOutOfTheArchive() async throws {
    try await make(PaymentMethod(name: "Главный", isDefault: true))
    let full = try await make(PaymentMethod(name: "Полный"), openings: [.rub: rub(500)])
    let books = try await freshBooks()
    XCTAssertEqual(accounts.archive(full.id, books: books), .refused(.hasMoney))
    XCTAssertFalse(try account(full.id).archived)
  }

  func testMoneySettledByATransferLetsItGoInOneStep() async throws {
    let main = try await make(
      PaymentMethod(name: "Главный", isDefault: true), openings: [.rub: .zero])
    let full = try await make(PaymentMethod(name: "Полный"), openings: [.rub: rub(500)])
    let books = try await freshBooks()
    let key = BalanceKey(accountId: full.id, currency: .rub)
    let move = Transfer(
      occurredAt: moment, fromAccountId: full.id, fromCurrency: .rub, fromAmountE4: rub(500),
      toAccountId: main.id, toCurrency: .rub, toAmountE4: rub(500), createdAt: moment,
      updatedAt: moment)
    XCTAssertEqual(
      accounts.archive(
        full.id, books: books, settling: [move], expecting: [key: rub(500)],
        expectingNow: [key: rub(500)]), .done)
    let mainMoney = try await balance(main.id)
    XCTAssertEqual(mainMoney, rub(500))
    XCTAssertTrue(try account(full.id).archived)
    store.undo()
    XCTAssertFalse(try account(full.id).archived)
    let transfersAfter = try await storedTransfers()
    XCTAssertTrue(transfersAfter.isEmpty, "the transfer goes back with the archive")
  }

  func testASettlementExpectingOtherMoneyWritesNothing() async throws {
    let main = try await make(
      PaymentMethod(name: "Главный", isDefault: true), openings: [.rub: .zero])
    let full = try await make(PaymentMethod(name: "Полный"), openings: [.rub: rub(500)])
    let books = try await freshBooks()
    let key = BalanceKey(accountId: full.id, currency: .rub)
    let move = Transfer(
      occurredAt: moment, fromAccountId: full.id, fromCurrency: .rub, fromAmountE4: rub(500),
      toAccountId: main.id, toCurrency: .rub, toAmountE4: rub(500), createdAt: moment,
      updatedAt: moment)
    XCTAssertEqual(
      accounts.archive(full.id, books: books, settling: [move], expecting: [key: rub(400)]),
      .refused(.balanceChanged(key)))
    XCTAssertFalse(try account(full.id).archived)
  }

  func testAnArchivedAccountsNameIsNeverTakenByARename() async throws {
    try await make(PaymentMethod(name: "Главный", isDefault: true))
    let old = try await make(PaymentMethod(name: "Альфа"), bank: "Банк А")
    var books = try await freshBooks()
    XCTAssertEqual(accounts.archive(old.id, books: books), .done)
    let beta = try await make(PaymentMethod(name: "Бета"), bank: "Банк Б")
    var renamed = beta
    renamed.name = "АЛЬФА"
    books = try await freshBooks()
    XCTAssertEqual(accounts.save(renamed, previous: beta, books: books), .refused(.nameTaken))
    XCTAssertEqual(accounts.restore(old.id), .done, "so the old account always comes back")
  }

  func testARestoredAccountIsNotMainAndBringsItsBankBack() async throws {
    try await make(PaymentMethod(name: "Главный", isDefault: true))
    let old = try await make(PaymentMethod(name: "Вклад"), bank: "ВТБ")
    let books = try await freshBooks()
    XCTAssertEqual(accounts.archive(old.id, books: books), .done)
    let bankId = try XCTUnwrap(old.bankId)
    XCTAssertEqual(accounts.archiveBank(bankId), .done)
    XCTAssertEqual(accounts.restore(old.id), .done)
    XCTAssertFalse(try account(old.id).isDefault)
    XCTAssertEqual(accounts.banks.first { $0.id == bankId }?.archived, false)
  }

  func testRestoringASecondTimeChangesNothing() async throws {
    let main = try await make(PaymentMethod(name: "Главный", isDefault: true))
    XCTAssertEqual(accounts.restore(main.id), .done)
    XCTAssertEqual(accounts.restore(UUID()), .refused(.notFound))
  }

  // MARK: Order

  func testTheMainAccountStaysFirstWhateverIsDragged() async throws {
    let main = try await make(PaymentMethod(name: "Я", isDefault: true))
    let a = try await make(PaymentMethod(name: "А"))
    let b = try await make(PaymentMethod(name: "Б"))
    XCTAssertEqual(accounts.reorder(from: [2], to: 0), .done)
    XCTAssertEqual(accounts.ordered(accounts.all).map(\.id), [main.id, b.id, a.id])
  }

  func testMovingUpStopsBelowTheMainAccount() async throws {
    let main = try await make(PaymentMethod(name: "Я", isDefault: true))
    let a = try await make(PaymentMethod(name: "А"))
    XCTAssertEqual(accounts.move(a.id, by: -1), .done)
    XCTAssertEqual(accounts.ordered(accounts.all).map(\.id), [main.id, a.id])
  }

  func testAlphabetizingForgetsTheDraggedPlaces() async throws {
    let main = try await make(PaymentMethod(name: "Я", isDefault: true))
    let a = try await make(PaymentMethod(name: "Альфа"))
    let b = try await make(PaymentMethod(name: "Бета"))
    XCTAssertEqual(accounts.reorder(from: [2], to: 1), .done)
    XCTAssertEqual(accounts.ordered(accounts.all).map(\.id), [main.id, b.id, a.id])
    XCTAssertEqual(accounts.alphabetize(), .done)
    XCTAssertEqual(accounts.ordered(accounts.all).map(\.id), [main.id, a.id, b.id])
    XCTAssertTrue(accounts.all.allSatisfy { $0.sort == 0 })
  }

  // MARK: Deleting for good

  func testAnUnusedEmptyAccountIsDeletedForGood() async throws {
    try await make(PaymentMethod(name: "Главный", isDefault: true))
    let spare = try await make(PaymentMethod(name: "Лишний"), openings: [.rub: .zero])
    XCTAssertEqual(accounts.delete([spare.id]), .done)
    XCTAssertNil(accounts.all.first { $0.id == spare.id })
    XCTAssertFalse(store.canUndo, "a deletion for good forgets the steps of ⌘Z")
  }

  func testAnAccountACountSaysHoldsMoneyIsNotDeleted() async throws {
    try await make(PaymentMethod(name: "Главный", isDefault: true))
    let full = try await make(PaymentMethod(name: "Полный"), openings: [.rub: rub(1)])
    XCTAssertEqual(accounts.delete([full.id]), .refused(.deletesWithMoney))
  }

  func testAnAccountWithOperationsIsInUse() async throws {
    try await make(PaymentMethod(name: "Главный", isDefault: true))
    let used = try await make(PaymentMethod(name: "Рабочий"))
    try spend(100, on: used.id)
    guard case .refused(.inUse(let id, let usage)) = accounts.delete([used.id]) else {
      return XCTFail("an account with an operation was deleted")
    }
    XCTAssertEqual(id, used.id)
    XCTAssertEqual(usage.operations, 1)
  }

  func testDeletingTheMainAccountNeedsAnHeir() async throws {
    let main = try await make(PaymentMethod(name: "Главный", isDefault: true))
    let heir = try await make(PaymentMethod(name: "Наследник"))
    XCTAssertEqual(accounts.delete([main.id]), .refused(.needsNewMain))
    XCTAssertEqual(accounts.delete([main.id], newMain: heir.id), .done)
    XCTAssertTrue(try account(heir.id).isDefault)
  }
}

/// Groups of accounts as the owner files them: a group out of the summary, its name, the
/// archive and the main account that never goes out of the summary.
final class AccountsScenarioGroupActionTests: AccountsScenarioDatabaseCase {
  func testAGroupNameIsItsOwnAndAnArchivedOneIsOfferedBack() async throws {
    let group = AccountGroup(name: "Семья")
    XCTAssertEqual(accounts.save(group: group), .done)
    XCTAssertEqual(accounts.save(group: AccountGroup(name: " СЕМЬЯ ")), .refused(.groupNameTaken))
    XCTAssertEqual(accounts.archiveGroup(group.id), .done)
    XCTAssertEqual(
      accounts.save(group: AccountGroup(name: "семья")), .refused(.inArchive(group.id)))
  }

  func testAnEmptyGroupNameIsRefused() {
    XCTAssertEqual(accounts.save(group: AccountGroup(name: "  ")), .refused(.emptyName))
  }

  func testTheGroupOfTheMainAccountStaysInTheSummary() async throws {
    let group = AccountGroup(name: "Основные")
    XCTAssertEqual(accounts.save(group: group), .done)
    try await make(PaymentMethod(name: "Главный", isDefault: true, groupId: group.id))
    XCTAssertEqual(accounts.setInSummary(group.id, false), .refused(.groupHoldsMain))
  }

  func testAGroupWithALiveAccountStaysOutOfTheArchive() async throws {
    try await make(PaymentMethod(name: "Главный", isDefault: true))
    let group = AccountGroup(name: "Вклады")
    XCTAssertEqual(accounts.save(group: group), .done)
    let deposit = try await make(PaymentMethod(name: "Вклад", groupId: group.id))
    XCTAssertEqual(accounts.archiveGroup(group.id), .refused(.groupHasLiveAccounts))
    let books = try await freshBooks()
    XCTAssertEqual(accounts.archive(deposit.id, books: books), .done)
    XCTAssertEqual(accounts.archiveGroup(group.id), .done)
  }

  func testRestoringAnAccountBringsItsArchivedGroupBack() async throws {
    try await make(PaymentMethod(name: "Главный", isDefault: true))
    let group = AccountGroup(name: "Вклады")
    XCTAssertEqual(accounts.save(group: group), .done)
    let deposit = try await make(PaymentMethod(name: "Вклад", groupId: group.id))
    let books = try await freshBooks()
    XCTAssertEqual(accounts.archive(deposit.id, books: books), .done)
    XCTAssertEqual(accounts.archiveGroup(group.id), .done)
    XCTAssertEqual(accounts.restore(deposit.id), .done)
    XCTAssertEqual(accounts.groups.first { $0.id == group.id }?.archived, false)
  }

  func testAGroupComesBackOnlyUnderAFreeName() async throws {
    let old = AccountGroup(name: "Семья")
    XCTAssertEqual(accounts.save(group: old), .done)
    XCTAssertEqual(accounts.archiveGroup(old.id), .done)
    XCTAssertEqual(accounts.save(group: AccountGroup(name: "Дети")), .done)
    var renamed = try XCTUnwrap(accounts.groups.first { $0.name == "Дети" })
    renamed.name = "семья"
    // The live group cannot take a name an archived group keeps either.
    XCTAssertEqual(accounts.save(group: renamed), .refused(.inArchive(old.id)))
    XCTAssertEqual(accounts.restoreGroup(old.id), .done)
    XCTAssertEqual(accounts.restoreGroup(old.id), .done, "twice changes nothing")
  }

  func testAGroupInUseIsNotDeletedButAnEmptyOneIs() async throws {
    try await make(PaymentMethod(name: "Главный", isDefault: true))
    let used = AccountGroup(name: "Занята")
    let empty = AccountGroup(name: "Пустая")
    XCTAssertEqual(accounts.save(group: used), .done)
    XCTAssertEqual(accounts.save(group: empty), .done)
    try await make(PaymentMethod(name: "Счёт", groupId: used.id))
    XCTAssertEqual(accounts.deleteGroup(used.id), .refused(.groupInUse))
    XCTAssertEqual(accounts.deleteGroup(empty.id), .done)
    XCTAssertEqual(accounts.deleteGroup(empty.id), .refused(.notFound))
  }

  func testAGroupLeftOutOfTheSummaryIsUndoneInOneStep() async throws {
    let group = AccountGroup(name: "Заграница")
    XCTAssertEqual(accounts.save(group: group), .done)
    XCTAssertEqual(accounts.setInSummary(group.id, false), .done)
    XCTAssertEqual(accounts.groups.first?.inSummary, false)
    store.undo()
    XCTAssertEqual(accounts.groups.first?.inSummary, true)
  }
}

/// Banks as the owner arranges his books under them: one bank grows a second account, a bank
/// goes to the archive with its last account, two banks are merged, and a bank is deleted only
/// once nothing is under it.
final class AccountsScenarioBankActionTests: AccountsScenarioDatabaseCase {
  @discardableResult
  private func makeBank(_ name: String) async throws -> UUID {
    let creation = accounts.createBank(named: name, books: try await freshBooks())
    XCTAssertEqual(creation.outcome, .done, name)
    return try XCTUnwrap(creation.accountId)
  }

  private func bank(of account: UUID) throws -> Bank {
    let id = try XCTUnwrap(try self.account(account).bankId)
    return try XCTUnwrap(accounts.banks.first { $0.id == id })
  }

  func testABankWithALiveAccountStaysOutOfTheArchive() async throws {
    let main = try await makeBank("Сбер")
    XCTAssertEqual(accounts.archiveBank(try bank(of: main).id), .refused(.bankHasLiveAccounts))
  }

  func testABankGoesToTheArchiveWithItsLastAccount() async throws {
    try await makeBank("Сбер")
    let second = try await makeBank("ВТБ")
    let books = try await freshBooks()
    XCTAssertEqual(accounts.archive(second, books: books), .done)
    let vtb = try bank(of: second)
    XCTAssertEqual(accounts.archiveBank(vtb.id), .done)
    XCTAssertEqual(accounts.archiveBank(vtb.id), .done, "twice changes nothing")
    XCTAssertTrue(try bank(of: second).archived)
  }

  func testANewBankMayTakeTheNameOfAnArchivedOne() async throws {
    try await makeBank("Сбер")
    let old = try await makeBank("Тинькофф")
    let books = try await freshBooks()
    XCTAssertEqual(accounts.archive(old, books: books), .done)
    XCTAssertEqual(accounts.archiveBank(try bank(of: old).id), .done)
    let renamed = Bank(name: "Тинькофф")
    XCTAssertEqual(accounts.save(bank: renamed), .done)
    XCTAssertEqual(
      accounts.restoreBank(try bank(of: old).id), .refused(.bankNameTaken),
      "the old one meets the live one when it comes back")
  }

  func testABankWithAnArchivedAccountIsNotDeleted() async throws {
    try await makeBank("Сбер")
    let old = try await makeBank("ВТБ")
    let books = try await freshBooks()
    XCTAssertEqual(accounts.archive(old, books: books), .done)
    XCTAssertEqual(accounts.deleteBank(try bank(of: old).id), .refused(.bankInUse))
  }

  func testAnEmptyBankIsDeletedForGood() async throws {
    try await makeBank("Сбер")
    let empty = Bank(name: "Пустой")
    XCTAssertEqual(accounts.save(bank: empty), .done)
    XCTAssertEqual(accounts.deleteBank(empty.id), .done)
    XCTAssertNil(accounts.banks.first { $0.id == empty.id })
    XCTAssertEqual(accounts.deleteBank(empty.id), .refused(.notFound))
  }

  func testRenamingABankKeepsItsAccountsAndIsOneStep() async throws {
    let main = try await makeBank("Тинькофф")
    var bank = try bank(of: main)
    bank.name = "Т-Банк"
    XCTAssertEqual(accounts.save(bank: bank), .done)
    XCTAssertEqual(try self.bank(of: main).name, "Т-Банк")
    XCTAssertEqual(try account(main).name, "Тинькофф", "the account keeps its own name")
    store.undo()
    XCTAssertEqual(try self.bank(of: main).name, "Тинькофф")
  }

  func testMergingBanksMovesEveryAccountArchivedOnesTooInOneStep() async throws {
    let keep = try await makeBank("Т-Банк")
    let merged = try await makeBank("Тинькофф")
    let mergedBank = try bank(of: merged)
    let books = try await freshBooks()
    XCTAssertEqual(
      accounts.save(
        PaymentMethod(name: "Старый вклад", bankId: mergedBank.id), previous: nil, books: books),
      .done)
    let oldDeposit = try XCTUnwrap(accounts.all.first { $0.name == "Старый вклад" })
    let later = try await freshBooks()
    XCTAssertEqual(accounts.archive(oldDeposit.id, books: later), .done)

    XCTAssertEqual(accounts.mergeBank(mergedBank.id, into: try bank(of: keep).id), .done)
    let keptId = try bank(of: keep).id
    XCTAssertEqual(try account(merged).bankId, keptId)
    XCTAssertEqual(try account(oldDeposit.id).bankId, keptId)
    XCTAssertNil(accounts.banks.first { $0.id == mergedBank.id })
    store.undo()
    XCTAssertEqual(try account(merged).bankId, mergedBank.id)
    XCTAssertNotNil(accounts.banks.first { $0.id == mergedBank.id })
  }

  func testABankIsNotMergedIntoItself() async throws {
    let main = try await makeBank("Сбер")
    let id = try bank(of: main).id
    guard case .refused(.bankMerge) = accounts.mergeBank(id, into: id) else {
      return XCTFail("a bank merged into itself")
    }
  }

  func testAfterTheBanksAreMergedTheirAccountsMayMerge() async throws {
    let keep = try await makeBank("Т-Банк")
    let other = try await makeBank("Тинькофф")
    XCTAssertTrue(accounts.mergeTargets(for: try account(other)).isEmpty)
    XCTAssertEqual(
      accounts.mergeBank(try bank(of: other).id, into: try bank(of: keep).id), .done)
    XCTAssertEqual(accounts.mergeTargets(for: try account(other)).map(\.id), [keep])
  }
}

/// Cards as the owner adds them to an account, makes one the main card, puts one in the archive,
/// brings it back, merges two and deletes one nothing points at.
final class AccountsScenarioCardActionTests: AccountsScenarioDatabaseCase {
  private func setUpBank() async throws -> PaymentMethod {
    try await make(PaymentMethod(name: "Т-Банк", isDefault: true))
  }

  private func card(named name: String) throws -> PaymentCard {
    try XCTUnwrap(cardActions.cards.first { $0.name == name }, name)
  }

  func testASecondCardIsAddedAndUndone() async throws {
    let bank = try await setUpBank()
    XCTAssertEqual(
      cardActions.save(PaymentCard(accountId: bank.id, name: " Black "), previous: nil), .done)
    XCTAssertEqual(try card(named: "Black").accountId, bank.id)
    store.undo()
    XCTAssertNil(cardActions.cards.first { $0.name == "Black" })
  }

  func testACardNamedLikeAnotherAccountIsRefused() async throws {
    let bank = try await setUpBank()
    let other = try await make(PaymentMethod(name: "Наличные", kind: .cash))
    XCTAssertEqual(
      cardActions.save(PaymentCard(accountId: bank.id, name: "наличные"), previous: nil),
      .refused(.card(.nameTaken(owner: .account(other.id)))))
  }

  func testMakingACardMainAndArchivingItClearsTheMarkInOneStep() async throws {
    let bank = try await setUpBank()
    XCTAssertEqual(
      cardActions.save(PaymentCard(accountId: bank.id, name: "Black"), previous: nil), .done)
    let black = try card(named: "Black")
    XCTAssertEqual(cardActions.makeMain(black.id), .done)
    XCTAssertEqual(try account(bank.id).mainCardId, black.id)
    XCTAssertEqual(cardActions.archive(black.id), .done)
    XCTAssertNil(try account(bank.id).mainCardId)
    XCTAssertTrue(try card(named: "Black").archived)
    store.undo()
    XCTAssertEqual(try account(bank.id).mainCardId, black.id)
    XCTAssertFalse(try card(named: "Black").archived)
  }

  func testAnArchivedCardCannotBeMain() async throws {
    let bank = try await setUpBank()
    XCTAssertEqual(
      cardActions.save(PaymentCard(accountId: bank.id, name: "Old"), previous: nil), .done)
    let old = try card(named: "Old")
    XCTAssertEqual(cardActions.archive(old.id), .done)
    XCTAssertEqual(cardActions.makeMain(old.id), .refused(.notFound))
  }

  func testACardComesBackUnlessALiveCardTookItsName() async throws {
    let bank = try await setUpBank()
    XCTAssertEqual(
      cardActions.save(PaymentCard(accountId: bank.id, name: "Visa"), previous: nil), .done)
    let first = try card(named: "Visa")
    XCTAssertEqual(cardActions.archive(first.id), .done)
    XCTAssertEqual(
      cardActions.save(PaymentCard(accountId: bank.id, name: "VISA"), previous: nil), .done)
    guard case .refused(.card(.nameTaken)) = cardActions.restore(first.id) else {
      return XCTFail("two live cards answer to one name")
    }
  }

  func testAnUnusedCardIsDeletedAndAUsedOneIsNot() async throws {
    let bank = try await setUpBank()
    XCTAssertEqual(
      cardActions.save(PaymentCard(accountId: bank.id, name: "Spare"), previous: nil), .done)
    XCTAssertEqual(
      cardActions.save(PaymentCard(accountId: bank.id, name: "Used"), previous: nil), .done)
    let used = try card(named: "Used")
    try spend(300, on: bank.id, card: used.id)
    XCTAssertEqual(cardActions.delete(try card(named: "Spare").id), .done)
    XCTAssertEqual(
      cardActions.delete(used.id), .refused(.inUse(CardUsage(operations: 1, scheduled: 0))))
    XCTAssertEqual(cardActions.delete(UUID()), .refused(.notFound))
  }

  func testMergingCardsMovesTheOperationsAndKeepsTheMainMark() async throws {
    let bank = try await setUpBank()
    XCTAssertEqual(
      cardActions.save(PaymentCard(accountId: bank.id, name: "Old"), previous: nil), .done)
    let old = try card(named: "Old")
    let kept = try card(named: "Т-Банк")
    XCTAssertEqual(cardActions.makeMain(old.id), .done)
    let purchase = try spend(450, on: bank.id, card: old.id)
    XCTAssertEqual(cardActions.merge(old.id, into: kept.id), .done)
    XCTAssertNil(cardActions.cards.first { $0.id == old.id })
    let moved = try XCTUnwrap(try liveEntries().first { $0.id == purchase.id })
    XCTAssertEqual(moved.transaction.cardId, kept.id)
    XCTAssertEqual(try account(bank.id).mainCardId, kept.id, "the kept card takes the mark")
    XCTAssertTrue(try card(named: "Т-Банк").aliases.contains("Old"))
  }

  func testCardsOfTwoAccountsDoNotMerge() async throws {
    let bank = try await setUpBank()
    let other = try await make(PaymentMethod(name: "Альфа"))
    let mine = try card(named: "Т-Банк")
    let theirs = try XCTUnwrap(cardActions.cards.first { $0.accountId == other.id })
    XCTAssertTrue(cardActions.mergeTargets(for: mine).isEmpty)
    guard case .refused(.merge) = cardActions.merge(theirs.id, into: mine.id) else {
      return XCTFail("cards of two accounts merged")
    }
    XCTAssertEqual(
      try XCTUnwrap(cardActions.cards.first { $0.id == theirs.id }).accountId, other.id)
    _ = bank
  }
}
