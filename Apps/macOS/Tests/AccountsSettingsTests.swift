import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Settings → Счета against a real database: the order of the accounts, the currencies of one,
/// the main account that is only ever passed on, groups and «Учитывать в общей сводке», the
/// archive with «Вернуть», deleting what nothing points at — and the word «Счёт» where
/// «Способ оплаты» stood.
@MainActor
final class AccountsSettingsTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-accounts-\(UUID().uuidString)", isDirectory: true)
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

  // MARK: Order

  /// The main account first and marked, then in the order the owner dragged, alphabetical
  /// until then. A drag numbers every live account 1…n and is one step of ⌘Z; nothing is
  /// dragged above the main account.
  func testTheMainAccountIsFirstAndTheRestKeepTheOrderTheOwnerDragged() throws {
    let main = try account("Сбер", main: true)
    let alfa = try account("Альфа")
    let vtb = try account("ВТБ")
    XCTAssertEqual(names(), ["Сбер", "Альфа", "ВТБ"], "main first, the rest alphabetical")

    XCTAssertEqual(actions.reorder(from: [2], to: 1), .done)
    XCTAssertEqual(names(), ["Сбер", "ВТБ", "Альфа"])
    XCTAssertEqual(
      try stored().filter { !$0.archived }.sorted { $0.sort < $1.sort }.map(\.sort), [1, 2, 3],
      "the order is written as 1…n")

    XCTAssertEqual(actions.reorder(from: [2], to: 0), .done)
    XCTAssertEqual(names().first, "Сбер", "dragged above it, the main account stays first")
    XCTAssertEqual(names(), ["Сбер", "Альфа", "ВТБ"])

    store.undo()
    XCTAssertEqual(names(), ["Сбер", "ВТБ", "Альфа"], "one drag is one step of ⌘Z")
    _ = (main, alfa, vtb)
  }

  /// «Сортировать по алфавиту» forgets every place dragged to, in one step of ⌘Z.
  func testSortingAlphabeticallyForgetsTheDraggedOrder() throws {
    _ = try account("Сбер", main: true)
    _ = try account("Альфа")
    _ = try account("ВТБ")
    XCTAssertEqual(actions.reorder(from: [2], to: 1), .done)
    XCTAssertEqual(names(), ["Сбер", "ВТБ", "Альфа"])

    XCTAssertEqual(actions.alphabetize(), .done)
    XCTAssertEqual(names(), ["Сбер", "Альфа", "ВТБ"])
    XCTAssertTrue(try stored().allSatisfy { $0.sort == 0 })

    store.undo()
    XCTAssertEqual(names(), ["Сбер", "ВТБ", "Альфа"])
  }

  /// «Вернуть» after a drag puts the account after every other, like a new one; while nothing
  /// was dragged it goes back to its alphabetical place.
  func testAnAccountBroughtBackAfterADragGoesLast() async throws {
    _ = try account("Сбер", main: true)
    _ = try account("Альфа")
    _ = try account("ВТБ")
    let cash = try account("Наличные", kind: .cash)
    let before = try await freshBooks()
    XCTAssertEqual(actions.archive(cash.id, books: before), .done)
    XCTAssertEqual(actions.restore(cash.id), .done)
    XCTAssertEqual(names(), ["Сбер", "Альфа", "ВТБ", "Наличные"], "nothing dragged: by name")
    XCTAssertEqual(try stored().first { $0.id == cash.id }?.sort, 0)

    let again = try await freshBooks()
    XCTAssertEqual(actions.archive(cash.id, books: again), .done)
    XCTAssertEqual(actions.reorder(from: [2], to: 1), .done)
    XCTAssertEqual(names(), ["Сбер", "ВТБ", "Альфа"])
    XCTAssertEqual(actions.restore(cash.id), .done)
    XCTAssertEqual(names(), ["Сбер", "ВТБ", "Альфа", "Наличные"], "after a drag: last")
  }

  /// «Выше» / «Ниже» move an account by one place, like a drag — for the keyboard and
  /// VoiceOver; nothing goes above the main account.
  func testAnAccountMovesUpAndDownWithoutADrag() throws {
    _ = try account("Сбер", main: true)
    let alfa = try account("Альфа")
    let vtb = try account("ВТБ")
    XCTAssertEqual(actions.move(vtb.id, by: -1), .done)
    XCTAssertEqual(names(), ["Сбер", "ВТБ", "Альфа"])
    XCTAssertEqual(actions.move(vtb.id, by: 1), .done)
    XCTAssertEqual(names(), ["Сбер", "Альфа", "ВТБ"])
    XCTAssertEqual(actions.move(alfa.id, by: -1), .done)
    XCTAssertEqual(names(), ["Сбер", "Альфа", "ВТБ"], "the main account stays first")
    store.undo()
    XCTAssertEqual(names(), ["Сбер", "ВТБ", "Альфа"], "one step of ⌘Z each")
  }

  // MARK: The editor

  /// A new account holds its currencies in the order chosen, the first being the main one; a
  /// balance typed for one is its starting point, written with the account in one step of ⌘Z.
  func testANewAccountHoldsItsCurrenciesInOrderAndCountsItsBalanceNow() async throws {
    _ = try account("Сбер", main: true)
    var draft = AccountDraft(newIn: .rub)
    draft.name = "Freedom"
    draft.add(.usd)
    draft.add(CurrencyCode("EUR"))
    draft.makeMain(.usd)
    draft.move(CurrencyCode("EUR"), by: -1)
    XCTAssertEqual(draft.currencies, [.usd, CurrencyCode("EUR"), .rub])
    draft.openings[.usd] = "1,250.50"

    let openings = try draft.typedOpenings().get()
    let books = try await freshBooks()
    XCTAssertEqual(
      actions.save(draft.account(over: nil), previous: nil, openings: openings, books: books),
      .done)

    let saved = try XCTUnwrap(try stored().first { $0.name == "Freedom" })
    XCTAssertEqual(saved.mainCurrency, .usd)
    XCTAssertEqual(saved.otherCurrencies, [CurrencyCode("EUR"), .rub])
    XCTAssertFalse(saved.isDefault)
    let after = try await freshBooks()
    XCTAssertEqual(
      after.balances.balance(BalanceKey(accountId: saved.id, currency: .usd), at: after.at),
      try AmountE4(decimal: Decimal(string: "1250.5")!))
    XCTAssertNil(
      after.balances.latestAnchor(BalanceKey(accountId: saved.id, currency: .rub)),
      "an empty field counts nothing")
    XCTAssertEqual(
      after.dataset.planning.reconciliations.map(\.origin), [.account],
      "the history says the balance came with a new account")

    store.undo()
    XCTAssertFalse(try stored().contains { $0.name == "Freedom" }, "one step of ⌘Z")
    let undone = try await freshBooks()
    XCTAssertTrue(undone.dataset.planning.reconciledBalances.isEmpty, "the count went with it")
  }

  /// A zero typed for «Остаток сейчас» is a count of zero, not «не знаю»: Return writes it back
  /// as «0», and the save counts the pair at 0. Only an empty field counts nothing.
  func testATypedZeroSurvivesReturnAndIsCounted() async throws {
    _ = try account("Сбер", main: true)
    var draft = AccountDraft(newIn: .rub)
    draft.name = "Кредитка"
    for typed in ["0", "0.00", " 0 "] {
      draft.openings[.rub] = typed
      draft.settleOpening(.rub)
      XCTAssertEqual(draft.typedOpenings(), .success([.rub: .zero]), "«\(typed)» after Return")
    }
    draft.openings[.rub] = "-30000"
    draft.settleOpening(.rub)
    XCTAssertEqual(
      draft.typedOpenings(), .success([.rub: AmountE4(whole: -30_000)]), "a card owing the bank")
    draft.openings[.rub] = ""
    draft.settleOpening(.rub)
    XCTAssertEqual(draft.typedOpenings(), .success([:]), "empty stays «не знаю»")

    draft.openings[.rub] = "0"
    draft.settleOpening(.rub)
    let books = try await freshBooks()
    XCTAssertEqual(
      actions.save(
        draft.account(over: nil), previous: nil, openings: try draft.typedOpenings().get(),
        books: books),
      .done)
    let saved = try XCTUnwrap(try stored().first { $0.name == "Кредитка" })
    let key = BalanceKey(accountId: saved.id, currency: .rub)
    let after = try await freshBooks()
    XCTAssertNotNil(after.balances.latestAnchor(key), "the zero typed is the starting point")
    XCTAssertEqual(after.balances.balance(key, at: after.at), .zero)
  }

  /// A balance that does not read as an amount is refused by its currency, not taken for zero.
  func testABalanceThatDoesNotReadIsRefused() {
    var draft = AccountDraft(newIn: .rub)
    draft.openings[.rub] = "12 abc"
    XCTAssertEqual(draft.typedOpenings(), .failure(.unreadableBalance(.rub)))
    draft.openings[.rub] = ""
    XCTAssertEqual(draft.typedOpenings(), .success([:]))
  }

  /// A currency with money on the account stays; once its balance is zero it can go.
  func testACurrencyWithMoneyCannotBeTakenOff() async throws {
    _ = try account("Сбер", main: true)
    let freedom = try account("Freedom", currencies: [.rub, .usd])
    try count(freedom.id, .usd, AmountE4(whole: 50))

    var draft = AccountDraft(freedom)
    draft.remove(.usd)
    let books1 = try await freshBooks()
    let refused = actions.save(
      draft.account(over: freedom), previous: freedom, books: books1)
    XCTAssertEqual(refused, .refused(.removesCurrencyWithMoney(.usd)))

    try count(freedom.id, .usd, .zero)
    let books2 = try await freshBooks()
    XCTAssertEqual(
      actions.save(draft.account(over: freedom), previous: freedom, books: books2),
      .done)
    XCTAssertEqual(try stored().first { $0.id == freedom.id }?.currencies, [.rub])
  }

  /// The main account is only ever passed on: saved with the switch off it stays main, and
  /// «Сделать основным» on another takes the flag from it in one step of ⌘Z.
  func testTheMainAccountIsOnlyEverPassedOn() async throws {
    let main = try account("Сбер", main: true)
    let cash = try account("Наличные")
    var draft = AccountDraft(main)
    draft.isMain = false
    let books3 = try await freshBooks()
    XCTAssertEqual(
      actions.save(draft.account(over: main), previous: main, books: books3),
      .done)
    XCTAssertEqual(try mains(), [main.id], "the switch never takes the main account away")

    XCTAssertEqual(actions.makeMain(cash.id), .done)
    XCTAssertEqual(try mains(), [cash.id])
    XCTAssertEqual(names().first, "Наличные", "the main account moves to the top")
    store.undo()
    XCTAssertEqual(try mains(), [main.id])
  }

  /// Other names are checked against the names and other names of the other live accounts.
  func testAnotherNameOfAnotherAccountIsRefused() async throws {
    _ = try account("Сбер", main: true)
    let tbank = try account("Т-Банк", aliases: ["тинек"])
    var draft = AccountDraft(newIn: .rub)
    draft.name = "Тинькофф Black"
    draft.aliases = ["Тинек"]
    let books4 = try await freshBooks()
    XCTAssertEqual(
      actions.save(draft.account(over: nil), previous: nil, books: books4),
      .refused(.otherNameTaken("Тинек")))
    draft.aliases = ["т-банк "]
    let books5 = try await freshBooks()
    XCTAssertEqual(
      actions.save(draft.account(over: nil), previous: nil, books: books5),
      .refused(.otherNameTaken("т-банк")))
    _ = tbank
  }

  /// A name differing from another account's name or other name only by «ё» against «е» is
  /// the same name, the way the entry line reads it.
  func testANameThatDiffersOnlyByYoIsTaken() async throws {
    let sber = try account("Сбер", main: true)
    let tree = try account("Ёлка")
    _ = try account("Т-Банк", aliases: ["Тинёк"])
    let books = try await freshBooks()

    var draft = AccountDraft(newIn: .rub)
    draft.name = "Елка"
    XCTAssertEqual(
      actions.save(draft.account(over: nil), previous: nil, books: books), .refused(.nameTaken))
    draft.name = "тинек"
    XCTAssertEqual(
      actions.save(draft.account(over: nil), previous: nil, books: books), .refused(.nameTaken))

    var renamed = AccountDraft(sber)
    renamed.name = "ёлка"
    XCTAssertEqual(
      actions.save(renamed.account(over: sber), previous: sber, books: books),
      .refused(.nameTaken))
    var same = AccountDraft(tree)
    same.name = "ёЛКА"
    XCTAssertEqual(
      actions.save(same.account(over: tree), previous: tree, books: books), .done,
      "its own name, spelt otherwise, is its own")
  }

  /// A new account named like one in the archive brings that one back instead.
  func testANewAccountNamedLikeOneInTheArchiveBringsItBack() async throws {
    _ = try account("Сбер", main: true)
    let old = try account("Альфа")
    let books6 = try await freshBooks()
    XCTAssertEqual(actions.archive(old.id, books: books6), .done)

    var draft = AccountDraft(newIn: .rub)
    draft.name = " альфа"
    let books7 = try await freshBooks()
    XCTAssertEqual(
      actions.save(draft.account(over: nil), previous: nil, books: books7),
      .refused(.inArchive(old.id)))
    XCTAssertEqual(actions.restore(old.id), .done)
    XCTAssertEqual(try stored().filter { $0.name == "Альфа" }.map(\.archived), [false])
  }

  // MARK: Groups

  /// «Учитывать в общей сводке» is one step of ⌘Z; a group holding the main account stays in,
  /// and the main account never moves into a group left out.
  func testTheMainAccountNeverSitsInAGroupLeftOutOfTheSummary() async throws {
    let main = try account("Сбер", main: true)
    let kaspi = try account("Kaspi")
    let russia = AccountGroup(name: "Россия")
    let kazakhstan = AccountGroup(name: "Казахстан")
    XCTAssertEqual(actions.save(group: russia), .done)
    XCTAssertEqual(actions.save(group: kazakhstan), .done)

    XCTAssertEqual(actions.setInSummary(kazakhstan.id, false), .done)
    XCTAssertEqual(try groups().first { $0.id == kazakhstan.id }?.inSummary, false)
    store.undo()
    XCTAssertEqual(try groups().first { $0.id == kazakhstan.id }?.inSummary, true)
    XCTAssertEqual(actions.setInSummary(kazakhstan.id, false), .done)

    var inKazakhstan = AccountDraft(main)
    inKazakhstan.groupId = kazakhstan.id
    let books8 = try await freshBooks()
    XCTAssertEqual(
      actions.save(inKazakhstan.account(over: main), previous: main, books: books8),
      .refused(.mainInExcludedGroup))

    var inRussia = AccountDraft(main)
    inRussia.groupId = russia.id
    let books9 = try await freshBooks()
    XCTAssertEqual(
      actions.save(inRussia.account(over: main), previous: main, books: books9),
      .done)
    XCTAssertEqual(actions.setInSummary(russia.id, false), .refused(.groupHoldsMain))

    var kaspiThere = AccountDraft(kaspi)
    kaspiThere.groupId = kazakhstan.id
    let books10 = try await freshBooks()
    XCTAssertEqual(
      actions.save(kaspiThere.account(over: kaspi), previous: kaspi, books: books10),
      .done)
    XCTAssertEqual(actions.makeMain(kaspi.id), .refused(.mainInExcludedGroup))
  }

  /// A group goes to the archive once all its accounts have, comes back with «Вернуть», and is
  /// deleted only while no account, archived ones included, is filed under it.
  func testAGroupIsArchivedOnceItsAccountsAreAndDeletedOnlyWhenEmpty() async throws {
    _ = try account("Сбер", main: true)
    let group = AccountGroup(name: "Казахстан")
    XCTAssertEqual(actions.save(group: group), .done)
    let kaspi = try account("Kaspi", group: group.id)

    XCTAssertEqual(actions.archiveGroup(group.id), .refused(.groupHasLiveAccounts))
    let books11 = try await freshBooks()
    XCTAssertEqual(actions.archive(kaspi.id, books: books11), .done)
    XCTAssertEqual(actions.archiveGroup(group.id), .done)
    XCTAssertEqual(try groups().first?.archived, true)
    XCTAssertEqual(actions.deleteGroup(group.id), .refused(.groupInUse))

    XCTAssertEqual(actions.restore(kaspi.id), .done)
    XCTAssertEqual(
      try groups().first?.archived, false, "an account brought back brings its group back")

    let empty = AccountGroup(name: "Пусто")
    XCTAssertEqual(actions.save(group: empty), .done)
    XCTAssertTrue(store.canUndo)
    XCTAssertEqual(actions.deleteGroup(empty.id), .done)
    XCTAssertFalse(try groups().contains { $0.id == empty.id })
    XCTAssertFalse(store.canUndo, "a deletion is not undone, and ⌘Z forgets what came before")
  }

  /// An account brought back brings its archived group back — unless a live group has taken
  /// that name meanwhile: then nothing comes back, as with «Вернуть» of the group itself.
  func testAGroupBroughtBackWithItsAccountNeverRepeatsALiveName() async throws {
    _ = try account("Сбер", main: true)
    let group = AccountGroup(name: "Казахстан")
    XCTAssertEqual(actions.save(group: group), .done)
    let kaspi = try account("Kaspi", group: group.id)
    let books = try await freshBooks()
    XCTAssertEqual(actions.archive(kaspi.id, books: books), .done)
    XCTAssertEqual(actions.archiveGroup(group.id), .done)
    // Written past the checks of the settings, as another way in could.
    var twin = AccountGroup(name: "казахстан")
    twin.sort = 0
    XCTAssertTrue(store.apply(PlanningChange(upsert: PlanningRows(accountGroups: [twin]))))

    XCTAssertEqual(actions.restore(kaspi.id), .refused(.groupNameTaken))
    XCTAssertEqual(try stored().first { $0.id == kaspi.id }?.archived, true, "nothing written")
    XCTAssertEqual(try groups().first { $0.id == group.id }?.archived, true)
  }

  /// The main account merged away hands the flag to its target, so a target in a group left
  /// out of the summary is not offered; any other account is offered every live account of its
  /// bank.
  func testTheMainAccountIsNotOfferedAMergeIntoAGroupLeftOut() async throws {
    let bank = Bank(name: "Банк")
    XCTAssertEqual(actions.save(bank: bank), .done)
    let main = try account("Сбер", main: true, bank: bank.id)
    let alfa = try account("Альфа", bank: bank.id)
    let kazakhstan = AccountGroup(name: "Казахстан", inSummary: false)
    XCTAssertEqual(actions.save(group: kazakhstan), .done)
    _ = try account("Kaspi", group: kazakhstan.id, bank: bank.id)
    XCTAssertEqual(actions.mergeTargets(for: main).map(\.name), ["Альфа"])
    XCTAssertEqual(actions.mergeTargets(for: alfa).map(\.name), ["Сбер", "Kaspi"])
  }

  // MARK: Archive and deletion

  /// A currency whose balance nobody knows is not said to hold money when it is taken off.
  func testTakingOffACurrencyNobodyCountedAsksToCountIt() async throws {
    _ = try account("Сбер", main: true)
    let freedom = try account("Freedom", currencies: [.rub, .usd])
    try spend(on: freedom.id)
    var draft = AccountDraft(freedom)
    draft.makeMain(.usd)
    draft.remove(.rub)
    let books = try await freshBooks()
    XCTAssertEqual(
      actions.save(draft.account(over: freedom), previous: freedom, books: books),
      .refused(.currencyBalanceUnknown(.rub)))
  }

  /// An account whose balance nobody knows — moved but never counted — is not said to hold
  /// money: the refusal asks to count it. Counted at zero, it goes.
  func testAnAccountWithABalanceNobodyKnowsAsksToBeCounted() async throws {
    _ = try account("Сбер", main: true)
    let alfa = try account("Альфа")
    try spend(on: alfa.id)
    let unknown = try await freshBooks()
    XCTAssertEqual(actions.archive(alfa.id, books: unknown), .refused(.balanceUnknown))

    try count(alfa.id, .rub, AmountE4(whole: 20))
    let known = try await freshBooks()
    XCTAssertEqual(actions.archive(alfa.id, books: known), .refused(.hasMoney))

    try count(alfa.id, .rub, .zero)
    let zero = try await freshBooks()
    XCTAssertEqual(actions.archive(alfa.id, books: zero), .done)
  }

  /// Into the archive and back with «Вернуть», one step of ⌘Z each; money on the account and
  /// the last live account keep it out.
  func testAnAccountGoesToTheArchiveAndComesBack() async throws {
    let main = try account("Сбер", main: true)
    let cash = try account("Наличные", kind: .cash)
    let books12 = try await freshBooks()
    XCTAssertEqual(actions.archive(cash.id, books: books12), .done)
    XCTAssertEqual(try stored().first { $0.id == cash.id }?.archived, true)
    XCTAssertEqual(names(), ["Сбер"])
    XCTAssertEqual(actions.restore(cash.id), .done)
    XCTAssertEqual(names(), ["Сбер", "Наличные"])

    try count(cash.id, .rub, AmountE4(whole: 300))
    let books13 = try await freshBooks()
    XCTAssertEqual(actions.archive(cash.id, books: books13), .refused(.hasMoney))

    let alone = try await freshBooks()
    XCTAssertEqual(
      actions.archive(main.id, newMain: cash.id, books: alone), .done,
      "the main account goes once another takes over")
    let books14 = try await freshBooks()
    XCTAssertEqual(
      actions.archive(cash.id, books: books14), .refused(.lastLiveAccount))
    XCTAssertEqual(
      actions.delete([cash.id]), .refused(.noSuccessor), "the last live account is never deleted")
  }

  /// «В архив» on «Наличные» with 3,000 ₽ asks where the money goes (the main account is
  /// offered first); the transfer and the archive are one step of ⌘Z, and the archived account
  /// ends at zero while «Сбер» holds the money. An amount that changed since the question was
  /// shown is refused and nothing is written.
  func testArchivingWithMoneyRecordsTheTransferInOneStep() async throws {
    let sber = try account("Сбер", main: true)
    let cash = try account("Наличные", kind: .cash)
    try count(sber.id, .rub, AmountE4(whole: 10_000))
    try count(cash.id, .rub, AmountE4(whole: 3_000))
    store.forgetUndoHistory()
    let books = try await freshBooks()
    XCTAssertEqual(actions.archiveRefusal(cash, books: books), .hasMoney)

    let check = ArchivedMoney.balancesToMove(of: cash, balances: books.balances)
    let form = ArchivedMoneyForm(
      check: check, accounts: books.dataset.paymentMethods, locale: Locale(identifier: "en"))
    XCTAssertEqual(form.rows.map(\.chosen), [sber.id])
    let settling = form.transfers(now: environment.now(), note: "left over")
    let cashKey = BalanceKey(accountId: cash.id, currency: .rub)
    XCTAssertEqual(
      actions.archive(
        cash.id, books: books, settling: settling, expecting: [cashKey: AmountE4(whole: 2_000)]),
      .refused(.balanceChanged(cashKey)))
    XCTAssertEqual(try stored().first { $0.id == cash.id }?.archived, false)

    XCTAssertEqual(
      actions.archive(cash.id, books: books, settling: settling, expecting: form.shown), .done)
    let after = try await freshBooks()
    XCTAssertEqual(try stored().first { $0.id == cash.id }?.archived, true)
    XCTAssertEqual(after.balances[cashKey]?.amountE4, .zero)
    XCTAssertEqual(
      after.balances[BalanceKey(accountId: sber.id, currency: .rub)]?.amountE4,
      AmountE4(whole: 13_000))

    store.undo()
    let undone = try await freshBooks()
    XCTAssertEqual(try stored().first { $0.id == cash.id }?.archived, false)
    XCTAssertTrue(undone.dataset.transfers.isEmpty, "one ⌘Z: the archive and its transfer")
    XCTAssertEqual(undone.balances[cashKey]?.amountE4, AmountE4(whole: 3_000))
  }

  /// Rent of 30,000 typed ahead on «Наличные», which holds 12,000 now: the question names the
  /// 12,000 it holds, and the write agrees with both figures. The 12,000 go to «Сбер» now and
  /// the rent comes back from «Сбер» on its day, so the archived account is at zero from now on
  /// — no money sits on it, in no total, until the rent — and nothing is left to offer. One ⌘Z
  /// takes the archive and both transfers back.
  func testArchivingCountsMoneyTypedAhead() async throws {
    let sber = try account("Сбер", main: true)
    let cash = try account("Наличные", kind: .cash)
    try count(sber.id, .rub, AmountE4(whole: 50_000))
    try count(cash.id, .rub, AmountE4(whole: 12_000))
    let paid = Date().addingTimeInterval(3 * 86_400)
    var rent = TransactionDraft(
      occurredAt: paid, amount: AmountE4(whole: 30_000), note: "rent", paymentMethodId: cash.id)
    rent.normalizeSinglePart()
    XCTAssertTrue(store.save(try rent.materialize()))
    store.forgetUndoHistory()

    let books = try await freshBooks()
    let cashKey = BalanceKey(accountId: cash.id, currency: .rub)
    let sberKey = BalanceKey(accountId: sber.id, currency: .rub)
    XCTAssertEqual(books.balances[cashKey]?.amountE4, AmountE4(whole: 12_000))
    let check = ArchivedMoney.balancesToMove(of: cash, balances: books.balances)
    XCTAssertEqual(check.leftovers.map(\.amount), [AmountE4(whole: -18_000)])
    XCTAssertEqual(check.leftovers.map(\.shownAmount), [AmountE4(whole: 12_000)])
    let form = ArchivedMoneyForm(
      check: check, accounts: books.dataset.paymentMethods, locale: Locale(identifier: "en"))
    let settling = form.transfers(now: environment.now(), note: "left over")
    XCTAssertEqual(settling.count, 2, "what it holds now, and the rent")
    XCTAssertEqual(
      actions.archive(
        cash.id, books: books, settling: settling, expecting: form.shown,
        expectingNow: [cashKey: AmountE4(whole: 10_000)]),
      .refused(.balanceChanged(cashKey)), "the money of now is checked too")
    XCTAssertEqual(try stored().first { $0.id == cash.id }?.archived, false)
    XCTAssertEqual(
      actions.archive(
        cash.id, books: books, settling: settling, expecting: form.shown,
        expectingNow: form.shownNow), .done)

    let after = try await freshBooks()
    let archived = try XCTUnwrap(try stored().first { $0.id == cash.id })
    XCTAssertTrue(archived.archived)
    XCTAssertEqual(after.balances[cashKey]?.amountE4, .zero, "at zero before the rent")
    XCTAssertEqual(after.balances[sberKey]?.amountE4, AmountE4(whole: 62_000))
    let later = paid.addingTimeInterval(60)
    XCTAssertEqual(after.balances.balance(cashKey, at: later), .zero)
    XCTAssertEqual(after.balances.balance(sberKey, at: later), AmountE4(whole: 32_000))
    XCTAssertTrue(
      ArchivedMoney.balancesToMove(of: archived, balances: after.balances).leftovers.isEmpty,
      "«Стоит посмотреть» offers nothing")

    store.undo()
    let undone = try await freshBooks()
    XCTAssertEqual(try stored().first { $0.id == cash.id }?.archived, false)
    XCTAssertTrue(undone.dataset.transfers.isEmpty, "one ⌘Z: the archive and both transfers")
    XCTAssertEqual(undone.balances[cashKey]?.amountE4, AmountE4(whole: 12_000))
  }

  /// «Наличные» holds 30,000 now and rent of 30,000 is typed ahead: once the rent is paid it
  /// holds nothing, but until then its 30,000 are real money. «В архив» asks where they go and
  /// brings the rent back on its day, so no total misses them meanwhile.
  func testArchivingMoneyTheRentTakesBackAsksToo() async throws {
    let sber = try account("Сбер", main: true)
    let cash = try account("Наличные", kind: .cash)
    try count(sber.id, .rub, AmountE4(whole: 50_000))
    try count(cash.id, .rub, AmountE4(whole: 30_000))
    let paid = Date().addingTimeInterval(3 * 86_400)
    var rent = TransactionDraft(
      occurredAt: paid, amount: AmountE4(whole: 30_000), note: "rent", paymentMethodId: cash.id)
    rent.normalizeSinglePart()
    XCTAssertTrue(store.save(try rent.materialize()))
    store.forgetUndoHistory()

    let books = try await freshBooks()
    XCTAssertEqual(actions.archive(cash.id, books: books), .refused(.hasMoney))
    let check = ArchivedMoney.balancesToMove(of: cash, balances: books.balances)
    XCTAssertEqual(check.leftovers.map(\.shownAmount), [AmountE4(whole: 30_000)])
    let form = ArchivedMoneyForm(
      check: check, accounts: books.dataset.paymentMethods, locale: Locale(identifier: "en"))
    let settling = form.transfers(now: environment.now(), note: "left over")
    XCTAssertEqual(
      actions.archive(
        cash.id, books: books, settling: settling, expecting: form.shown,
        expectingNow: form.shownNow), .done)

    let after = try await freshBooks()
    let cashKey = BalanceKey(accountId: cash.id, currency: .rub)
    let sberKey = BalanceKey(accountId: sber.id, currency: .rub)
    XCTAssertEqual(after.balances[cashKey]?.amountE4, .zero)
    XCTAssertEqual(after.balances[sberKey]?.amountE4, AmountE4(whole: 80_000))
    let later = paid.addingTimeInterval(60)
    XCTAssertEqual(after.balances.balance(cashKey, at: later), .zero)
    XCTAssertEqual(after.balances.balance(sberKey, at: later), AmountE4(whole: 50_000))
  }

  /// An account the archive took with money before 1.2 asked: what it holds is moved to a live
  /// account in one step of ⌘Z, and it is at zero after.
  func testALeftoverOfAnArchivedAccountIsMovedInOneStep() async throws {
    let sber = try account("Сбер", main: true)
    var cash = try account("Наличные", kind: .cash)
    try count(sber.id, .rub, AmountE4(whole: 10_000))
    try count(cash.id, .rub, AmountE4(whole: 1_000))
    cash.archived = true
    try XCTUnwrap(environment.references).save(cash)
    store.forgetUndoHistory()

    let books = try await freshBooks()
    let check = ArchivedMoney.balancesToMove(of: cash, balances: books.balances)
    XCTAssertEqual(check.leftovers.map(\.amount), [AmountE4(whole: 1_000)])
    let form = ArchivedMoneyForm(
      check: check, accounts: books.dataset.paymentMethods, locale: Locale(identifier: "en"))
    let settling = form.transfers(now: environment.now(), note: "left over")
    XCTAssertEqual(
      actions.settleLeftovers(of: cash, books: books, settling: settling, expecting: form.shown),
      .done)
    let after = try await freshBooks()
    XCTAssertEqual(after.balances[BalanceKey(accountId: cash.id, currency: .rub)]?.amountE4, .zero)
    XCTAssertEqual(
      after.balances[BalanceKey(accountId: sber.id, currency: .rub)]?.amountE4,
      AmountE4(whole: 11_000))
    store.undo()
    let undone = try await freshBooks()
    XCTAssertTrue(undone.dataset.transfers.isEmpty)
  }

  /// «Вернуть» switches the account's currencies on: every currency a live account holds is
  /// on, or the entry line would not know it and the bank's table would not be checked for it.
  /// Tenge switched off meanwhile comes back with «Kaspi». There is no limit of ten any more:
  /// with ten currencies on, «Swiss» comes back and switches the eleventh on.
  func testAnAccountBroughtBackSwitchesItsCurrenciesOn() throws {
    let settings = try XCTUnwrap(environment.settings)
    let kzt = CurrencyCode("KZT")
    _ = try account("Сбер", main: true)
    var kaspi = try account("Kaspi", currencies: [kzt, .usd])
    kaspi.archived = true
    try XCTUnwrap(environment.references).save(kaspi)
    try settings.setEnabledCurrencies([.rub, .usd])

    XCTAssertEqual(actions.restore(kaspi.id), .done)
    XCTAssertEqual(try stored().first { $0.id == kaspi.id }?.archived, false)
    XCTAssertEqual(try settings.enabledCurrencies(), [.rub, .usd, kzt])

    let chf = CurrencyCode("CHF")
    var swiss = try account("Swiss", currencies: [chf])
    swiss.archived = true
    try XCTUnwrap(environment.references).save(swiss)
    try settings.setEnabledCurrencies(CurrencyCode.defaultEnabled)
    XCTAssertEqual(actions.restore(swiss.id), .done)
    XCTAssertEqual(try stored().first { $0.id == swiss.id }?.archived, false)
    XCTAssertEqual(try settings.enabledCurrencies(), CurrencyCode.defaultEnabled + [chf])
  }

  /// Archiving the main account passes the flag on in the same step: to the account named, the
  /// most used one being offered. Nothing is left without a main account, and ⌘Z puts it back.
  func testArchivingTheMainAccountPassesItOn() async throws {
    let main = try account("Сбер", main: true)
    let alfa = try account("Альфа")
    let vtb = try account("ВТБ")
    try spend(on: vtb.id)
    try spend(on: vtb.id)
    try spend(on: alfa.id)

    let books = try await freshBooks()
    let next = actions.successors(leaving: main.id, books: books)
    XCTAssertEqual(next.all.map(\.name), ["Альфа", "ВТБ"])
    XCTAssertEqual(next.preselected, vtb.id, "the most used one is offered")

    XCTAssertEqual(actions.archive(main.id, books: books), .refused(.needsNewMain))
    XCTAssertEqual(try mains(), [main.id])
    XCTAssertEqual(actions.archive(main.id, newMain: vtb.id, books: books), .done)
    XCTAssertEqual(try mains(), [vtb.id])
    XCTAssertEqual(try stored().first { $0.id == main.id }?.archived, true)

    store.undo()
    XCTAssertEqual(try mains(), [main.id], "one step of ⌘Z")
    XCTAssertEqual(try stored().first { $0.id == main.id }?.archived, false)
  }

  /// Only an account nothing points at is deleted — the operations in the bin count — and a
  /// deletion forgets the ⌘Z history. The main account goes once another takes over.
  func testOnlyAnAccountNothingPointsAtIsDeleted() async throws {
    let main = try account("Сбер", main: true)
    let used = try account("Альфа")
    let unused = try account("ВТБ")
    let spent = try spend(on: used.id)
    XCTAssertTrue(store.delete(id: spent.id), "the operation goes to the bin")

    guard case .refused(.inUse(let id, let usage)) = actions.delete([used.id]) else {
      return XCTFail("an account with an operation in the bin was deleted")
    }
    XCTAssertEqual(id, used.id, "the refusal names the account, to merge or archive it")
    XCTAssertEqual(usage.operations, 1)

    XCTAssertTrue(store.canUndo)
    XCTAssertEqual(actions.delete([unused.id]), .done)
    XCTAssertFalse(try stored().contains { $0.id == unused.id })
    XCTAssertFalse(store.canUndo, "⌘Z forgets what came before a deletion")

    let other = try account("Наличные")
    XCTAssertEqual(actions.delete([main.id]), .refused(.needsNewMain))
    XCTAssertEqual(actions.delete([main.id], newMain: other.id), .done)
    XCTAssertEqual(try mains(), [other.id])
    XCTAssertEqual(
      actions.delete([other.id]), .refused(.needsNewMain), "the main account names who takes over")
  }

  /// Several accounts deleted at once, the main one among them: none of them is offered to take
  /// over, and the one chosen does.
  func testDeletingSeveralWithTheMainOneHandsItToAnotherFirst() async throws {
    let main = try account("Сбер", main: true)
    let alfa = try account("Альфа")
    let vtb = try account("ВТБ")
    let books = try await freshBooks()
    let next = actions.successors(leaving: [main.id, alfa.id], books: books)
    XCTAssertEqual(next.all.map(\.id), [vtb.id])
    XCTAssertEqual(next.preselected, vtb.id)
    XCTAssertEqual(actions.delete([main.id, alfa.id], newMain: vtb.id), .done)
    XCTAssertEqual(try mains(), [vtb.id])
    XCTAssertEqual(try stored().map(\.id), [vtb.id])
  }

  // MARK: Words

  /// «Способ оплаты» is gone from every table in both languages: an account is what it was.
  func testNoCaptionStillSaysPaymentMethod() throws {
    let stale = try NSRegularExpression(
      pattern: "[Сс]пособ[а-яё]* оплат|payment method", options: [.caseInsensitive])
    for code in ["en", "ru"] {
      let folder = try XCTUnwrap(Bundle.main.url(forResource: code, withExtension: "lproj"))
      let tables = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        .filter { $0.hasSuffix(".strings") || $0.hasSuffix(".stringsdict") }
      XCTAssertTrue(tables.contains("Accounts.strings"), "\(tables)")
      for table in tables {
        let strings = try XCTUnwrap(
          NSDictionary(contentsOf: folder.appendingPathComponent(table)) as? [String: Any], table)
        for (key, value) in strings {
          // Every text of the entry, the plural forms of a `.stringsdict` included: printing
          // the dictionary would escape Cyrillic and hide it from the pattern.
          for text in Self.texts(in: value) {
            XCTAssertNil(
              stale.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              "\(code)/\(table): «\(key)» still says «\(text)»")
          }
        }
      }
    }
  }

  /// The ↓ panel says where the money went: «Со счёта» for spending, «На счёт» for money in;
  /// and the other screens say «Счёт» / «Счета», in both languages.
  func testThePanelSaysFromWhichAccountAndToWhich() throws {
    func text(_ key: String, _ table: String, _ code: String) throws -> String {
      let folder = try XCTUnwrap(Bundle.main.url(forResource: code, withExtension: "lproj"))
      return try XCTUnwrap(Bundle(url: folder)).localizedString(
        forKey: key, value: "<none>", table: table)
    }
    XCTAssertEqual(try text("entry.account.from", "Entry", "ru"), "Со счёта")
    XCTAssertEqual(try text("entry.account.to", "Entry", "ru"), "На счёт")
    XCTAssertEqual(try text("entry.account.from", "Entry", "en"), "From account")
    XCTAssertEqual(try text("entry.account.to", "Entry", "en"), "To account")
    XCTAssertEqual(try text("entry.paymentMethod", "Entry", "ru"), "Счёт")
    XCTAssertEqual(try text("transactions.column.paymentMethod", "Transactions", "ru"), "Счёт")
    XCTAssertEqual(try text("analytics.section.paymentMethods", "Analytics", "ru"), "Счета")
    XCTAssertEqual(try text("analytics.section.paymentMethods", "Analytics", "en"), "Accounts")
    XCTAssertEqual(try text("reports.by.paymentMethod", "Reports", "ru"), "по счёту")
  }

  /// The texts a pattern sees must be found in plural forms too: the Russian ones are read
  /// as written, not as the escaped description of their dictionary.
  func testTheWordingCheckReadsRussianPluralForms() {
    let plural: [String: Any] = [
      "NSStringLocalizedFormatKey": "%#@n@",
      "n": ["NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "few": "%d способа оплаты"],
    ]
    XCTAssertTrue(Self.texts(in: plural).contains("%d способа оплаты"))
  }

  // MARK: Helpers

  /// Every string in a value of a strings table, walking nested dictionaries and arrays.
  private static func texts(in value: Any) -> [String] {
    switch value {
    case let text as String: [text]
    case let dictionary as [String: Any]: dictionary.values.flatMap { texts(in: $0) }
    case let array as [Any]: array.flatMap { texts(in: $0) }
    default: []
    }
  }

  @discardableResult
  private func account(
    _ name: String, main: Bool = false, kind: PaymentMethodKind = .card,
    currencies: [CurrencyCode] = [.rub], group: UUID? = nil, aliases: [String] = [],
    bank: UUID? = nil
  ) throws -> PaymentMethod {
    let account = PaymentMethod(
      name: name, kind: kind, currency: currencies.first, aliases: aliases, isDefault: main,
      groupId: group, otherCurrencies: Array(currencies.dropFirst()), bankId: bank)
    try XCTUnwrap(environment.references).save(account)
    return account
  }

  /// A count of the key at this moment, as a reconciliation of accounts would write it.
  private func count(_ accountId: UUID, _ currency: CurrencyCode, _ amount: AmountE4) throws {
    let at = Date()
    let reconciliation = Reconciliation(
      date: environment.calendar.day(of: at), reconciledAt: at, actualTotalRubE4: .zero,
      kind: .accounts)
    let balance = ReconciledBalance(
      reconciliationId: reconciliation.id, accountId: accountId, currency: currency,
      actualE4: amount)
    XCTAssertTrue(
      store.apply(
        PlanningChange(
          upsert: PlanningRows(
            reconciliations: [reconciliation], reconciledBalances: [balance]))))
  }

  @discardableResult
  private func spend(on accountId: UUID) throws -> TransactionEntry {
    var draft = TransactionDraft(
      occurredAt: Date().addingTimeInterval(-3_600), amount: AmountE4(whole: 100),
      note: "coffee", paymentMethodId: accountId)
    draft.normalizeSinglePart()
    let entry = try draft.materialize()
    XCTAssertTrue(store.save(entry))
    return entry
  }

  private func freshBooks() async throws -> AccountBooks {
    let books = await actions.books()
    return try XCTUnwrap(books)
  }

  private func stored() throws -> [PaymentMethod] {
    try XCTUnwrap(environment.accounts).accounts(includeArchived: true)
  }

  private func groups() throws -> [AccountGroup] {
    try XCTUnwrap(environment.accounts).groups(includeArchived: true)
  }

  /// The live main accounts: exactly one, always.
  private func mains() throws -> [UUID] {
    try stored().filter { $0.isDefault && !$0.archived }.map(\.id)
  }

  /// The live accounts in the order of every list.
  private func names() -> [String] {
    actions.ordered(actions.all).map(\.name)
  }
}
