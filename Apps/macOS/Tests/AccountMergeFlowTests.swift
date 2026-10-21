import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Merging accounts from the settings, against a database on disk: the merged account holds
/// what the two held, the one merged away comes back from the archive empty — nothing is
/// counted twice —, transfers between the two in one currency go, and after every archive,
/// merge, deletion and a restart exactly one live account is main.
@MainActor
final class AccountMergeFlowTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  private var databaseURL: URL { directory.appendingPathComponent("accounts.sqlite") }

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-merge-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    try await open()
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

  /// A new environment on the same file: what a quit and a launch do.
  private func open() async throws {
    let url = databaseURL
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(url: url, schema: BundleSchemaSource(bundle: .main))
    })
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
  }

  private func restart() async throws {
    await environment.close()
    try await open()
  }

  private var actions: AccountActions { AccountActions(environment: environment, store: store) }

  // MARK: What the merged accounts hold

  /// 1 000 ₽ and 500 ₽ merge into 1 500 ₽ on the target; «Вернуть» brings the source back at
  /// zero, and the money of the live accounts is still 1 500 ₽ — nothing counted twice. The
  /// source's name, kept as another name of the target, goes back to it.
  func testBringingAMergedAccountBackCountsNothingTwice() async throws {
    let tbank = try account("Т-Банк", main: true)
    let tinkoff = try account("Тинькофф")
    try count([(tbank.id, .rub, AmountE4(whole: 500)), (tinkoff.id, .rub, AmountE4(whole: 1_000))])
    let total1 = try await liveTotal(.rub)
    XCTAssertEqual(total1, AmountE4(whole: 1_500))

    let books2 = try await freshBooks()
    let preview = try XCTUnwrap(
      actions.mergePreview(tinkoff.id, into: tbank.id, books: books2))
    XCTAssertEqual(
      preview.balancesAfter[BalanceKey(accountId: tbank.id, currency: .rub)],
      AmountE4(whole: 1_500), "the dialog shows what the merged account will hold")
    XCTAssertEqual(actions.merge(preview), .done)

    let books = try await freshBooks()
    XCTAssertEqual(balance(books, tbank.id, .rub), AmountE4(whole: 1_500))
    XCTAssertEqual(try stored(tinkoff.id).archived, true)
    XCTAssertEqual(try stored(tbank.id).aliases, ["Тинькофф"], "the old name is another name")
    let total3 = try await liveTotal(.rub)
    XCTAssertEqual(total3, AmountE4(whole: 1_500))

    XCTAssertEqual(actions.restore(tinkoff.id), .done)
    let back = try await freshBooks()
    XCTAssertEqual(balance(back, tinkoff.id, .rub), .zero, "it comes back empty")
    let total4 = try await liveTotal(.rub)
    XCTAssertEqual(total4, AmountE4(whole: 1_500), "«Всего» does not change")
    XCTAssertEqual(try stored(tbank.id).aliases, [], "its name goes back to it")
  }

  /// The other names of the account merged away go back with it too: after «Вернуть» each
  /// name is on one account only, and both accounts save as before.
  func testBringingAMergedAccountBackTakesItsOtherNamesBack() async throws {
    let tbank = try account("Т-Банк", main: true, aliases: ["тбанк"])
    let tinkoff = try account("Тинькофф", aliases: ["тинек"])

    let before = try await freshBooks()
    let preview = try XCTUnwrap(actions.mergePreview(tinkoff.id, into: tbank.id, books: before))
    XCTAssertEqual(actions.merge(preview), .done)
    XCTAssertEqual(try stored(tbank.id).aliases, ["тбанк", "Тинькофф", "тинек"])

    XCTAssertEqual(actions.restore(tinkoff.id), .done)
    XCTAssertEqual(try stored(tbank.id).aliases, ["тбанк"], "its own other names stay")
    XCTAssertEqual(try stored(tinkoff.id).aliases, ["тинек"])

    let books = try await freshBooks()
    for id in [tbank.id, tinkoff.id] {
      let account = try stored(id)
      XCTAssertEqual(
        actions.save(account, previous: account, books: books), .done,
        "\(account.name) saves: no name of it is on the other account")
    }
  }

  /// Operations follow the merge; a transfer between the two in one currency goes, since it
  /// would move money from the account to itself; an exchange between them stays. A merge is
  /// not undone, and ⌘Z forgets what came before it.
  func testAMergeTakesTheOperationsAndDeletesTransfersBetweenTheTwo() async throws {
    let main = try account("Сбер", main: true, currencies: [.rub, .usd])
    let other = try account("Сбер-2", currencies: [.rub, .usd])
    let spent = try spend(on: other.id)
    let now = Date().addingTimeInterval(-600)
    let sameCurrency = Transfer(
      occurredAt: now, fromAccountId: main.id, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 100), toAccountId: other.id, toCurrency: .rub,
      toAmountE4: AmountE4(whole: 100))
    let exchange = Transfer(
      occurredAt: now, fromAccountId: main.id, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 9_000), toAccountId: other.id, toCurrency: .usd,
      toAmountE4: AmountE4(whole: 100))
    XCTAssertTrue(
      store.apply(PlanningChange(upsert: PlanningRows(transfers: [sameCurrency, exchange]))))
    XCTAssertTrue(store.canUndo)

    let books5 = try await freshBooks()
    let preview = try XCTUnwrap(
      actions.mergePreview(other.id, into: main.id, books: books5))
    XCTAssertEqual(preview.deletedTransfers, 1, "the dialog says how many go")
    XCTAssertEqual(actions.merge(preview), .done)
    XCTAssertFalse(store.canUndo, "a merge is not undone")

    let books = try await freshBooks()
    XCTAssertEqual(books.dataset.transfers.map(\.id), [exchange.id])
    XCTAssertEqual(
      books.dataset.entries.first { $0.id == spent.id }?.transaction.paymentMethodId, main.id)
  }

  /// A key the books cannot work out is asked: typed, it is counted now; left empty, the
  /// target keeps its own latest count and the other account's past becomes history.
  func testAKeyNobodyCanWorkOutIsAsked() async throws {
    let main = try account("Сбер", main: true)
    let freedom = try account("Freedom", currencies: [.usd])
    let other = try account("Freedom-2", currencies: [.usd])
    try count([(freedom.id, .usd, AmountE4(whole: 70))])
    try spend(on: other.id, currency: .usd, amount: AmountE4(whole: 5))

    let books = try await freshBooks()
    let key = BalanceKey(accountId: freedom.id, currency: .usd)
    let asked = try XCTUnwrap(actions.mergePreview(other.id, into: freedom.id, books: books))
    XCTAssertEqual(asked.needsBalance, [key], "moved but never counted: nobody knows its money")
    XCTAssertEqual(asked.plan.opening[key], AmountE4(whole: 70), "empty: its own latest count")
    XCTAssertTrue(asked.keepsItsCountWhenEmpty(key))

    let answered = try XCTUnwrap(
      actions.mergePreview(
        other.id, into: freedom.id, answers: [key: AmountE4(whole: 60)], books: books))
    XCTAssertEqual(answered.plan.opening[key], AmountE4(whole: 60))
    XCTAssertEqual(actions.merge(answered), .done)
    let books6 = try await freshBooks()
    XCTAssertEqual(balance(books6, freedom.id, .usd), AmountE4(whole: 60))
    _ = main
  }

  // MARK: A merge is no count

  /// Both accounts counted earlier the same day, merged now: the merged account rests on that
  /// count, not on the merge — «сверено» and «до сверки?» name the count's moment — and the
  /// openings the merge writes say they came from a merge. The count is an hour ago, or at
  /// midnight when the day is younger than that: «до сверки?» asks only about counts of the
  /// operation's own day, so a count of the day before would leave nothing to ask about.
  func testTheMergeMomentIsNoCount() async throws {
    let sber = try account("Сбер", main: true)
    let cash = try account("Наличные", kind: .cash)
    let now = Date()
    let calendar = environment.calendar
    let earlierToday = max(
      calendar.startOfDay(calendar.day(of: now)), now.addingTimeInterval(-3_600))
    try count(
      [(sber.id, .rub, AmountE4(whole: 100_000)), (cash.id, .rub, AmountE4(whole: 5_000))],
      at: earlierToday)
    let books = try await freshBooks()
    let key = BalanceKey(accountId: sber.id, currency: .rub)
    let counted = try XCTUnwrap(books.balances.latestAnchor(key)).at
    let preview = try XCTUnwrap(actions.mergePreview(cash.id, into: sber.id, books: books))
    XCTAssertEqual(preview.balancesAfter[key], AmountE4(whole: 105_000))
    XCTAssertEqual(actions.merge(preview), .done)

    let after = try await freshBooks()
    XCTAssertEqual(balance(after, sber.id, .rub), AmountE4(whole: 105_000))
    XCTAssertEqual(after.balances.latestAnchor(key)?.at, counted, "the count, not the merge")
    let origins = after.dataset.planning.reconciliations.filter { $0.kind == .opening }
      .map(\.origin)
    XCTAssertEqual(origins, [.merge])
    let counts = AccountReconciliation.countsOfTheDay(
      occurredAt: now, savedAt: Date(), keys: [key], balances: after.balances,
      calendar: calendar)
    XCTAssertEqual(Set(counts.map(\.at)), [counted], "only the real count is asked about")
  }

  /// «Сбер» 100,000 and «Наличные» 5,000 counted an hour ago, merged; a coffee of half an
  /// hour ago entered afterwards on «Сбер» moves money — 104,700, not 105,000.
  func testACoffeeBeforeTheMergeMovesMoney() async throws {
    let sber = try account("Сбер", main: true)
    let cash = try account("Наличные", kind: .cash)
    try count([(sber.id, .rub, AmountE4(whole: 100_000)), (cash.id, .rub, AmountE4(whole: 5_000))])
    let books = try await freshBooks()
    let preview = try XCTUnwrap(actions.mergePreview(cash.id, into: sber.id, books: books))
    XCTAssertEqual(actions.merge(preview), .done)
    try spend(on: sber.id, amount: AmountE4(whole: 300))
    let after = try await freshBooks()
    XCTAssertEqual(balance(after, sber.id, .rub), AmountE4(whole: 104_700))
    XCTAssertEqual(balance(after, cash.id, .rub), .zero, "the archived source holds nothing")
  }

  // MARK: The main account

  /// Merged away, the main account passes the flag to the account it went into; into a group
  /// left out of the summary it cannot go.
  func testMergingTheMainAccountMakesTheTargetMain() async throws {
    let main = try account("Сбер", main: true)
    let tbank = try account("Т-Банк")
    let kazakhstan = AccountGroup(name: "Казахстан", inSummary: false)
    XCTAssertEqual(actions.save(group: kazakhstan), .done)
    let kaspi = try account("Kaspi", group: kazakhstan.id)

    let books7 = try await freshBooks()
    let intoExcluded = try XCTUnwrap(
      actions.mergePreview(main.id, into: kaspi.id, books: books7))
    XCTAssertEqual(actions.merge(intoExcluded), .refused(.mainInExcludedGroup))
    XCTAssertEqual(try mains(), [main.id], "nothing was written")

    let books8 = try await freshBooks()
    let preview = try XCTUnwrap(
      actions.mergePreview(main.id, into: tbank.id, books: books8))
    XCTAssertEqual(actions.merge(preview), .done)
    XCTAssertEqual(try mains(), [tbank.id])
  }

  /// After an archive, a merge, a deletion, ⌘Z and a restart exactly one live account is main,
  /// and it is the one the owner left main — the open repairs nothing.
  func testExactlyOneMainAccountAfterEveryActionAndARestart() async throws {
    let sber = try account("Сбер", main: true)
    let alfa = try account("Альфа")
    let vtb = try account("ВТБ")
    let cash = try account("Наличные", kind: .cash)
    try spend(on: alfa.id)

    let books9 = try await freshBooks()
    XCTAssertEqual(
      actions.archive(sber.id, newMain: alfa.id, books: books9), .done)
    XCTAssertEqual(try mains(), [alfa.id])
    store.undo()
    XCTAssertEqual(try mains(), [sber.id])
    let books10 = try await freshBooks()
    XCTAssertEqual(
      actions.archive(sber.id, newMain: alfa.id, books: books10), .done)

    let books11 = try await freshBooks()
    let preview = try XCTUnwrap(
      actions.mergePreview(alfa.id, into: vtb.id, books: books11))
    XCTAssertEqual(actions.merge(preview), .done)
    XCTAssertEqual(try mains(), [vtb.id])

    XCTAssertEqual(
      actions.delete([vtb.id], newMain: cash.id), .refused(.inUse(vtb.id, try usage(vtb.id))))
    XCTAssertEqual(actions.restore(sber.id), .done)
    XCTAssertEqual(try mains(), [vtb.id], "brought back, it is not main again")

    let spare = try account("Запасной")
    XCTAssertEqual(actions.makeMain(spare.id), .done)
    XCTAssertEqual(actions.delete([spare.id], newMain: cash.id), .done)
    XCTAssertEqual(try mains(), [cash.id])

    try await restart()
    XCTAssertEqual(try mains(), [cash.id], "the open finds one main account and keeps it")
    XCTAssertEqual(actions.ordered(actions.all).first?.id, cash.id, "first in every list")
  }

  // MARK: Helpers

  /// Every account of these tests is under one bank: only accounts of one bank merge.
  private var bank: Bank?

  private func theBank() throws -> UUID {
    if let bank { return bank.id }
    let made = Bank(name: "Банк")
    _ = try XCTUnwrap(environment.planning).apply(
      PlanningChange(upsert: PlanningRows(banks: [made])))
    bank = made
    return made.id
  }

  @discardableResult
  private func account(
    _ name: String, main: Bool = false, kind: PaymentMethodKind = .card,
    currencies: [CurrencyCode] = [.rub], group: UUID? = nil, aliases: [String] = []
  ) throws -> PaymentMethod {
    let account = PaymentMethod(
      name: name, kind: kind, currency: currencies.first, aliases: aliases, isDefault: main,
      groupId: group, otherCurrencies: Array(currencies.dropFirst()), bankId: try theBank())
    try XCTUnwrap(environment.references).save(account)
    return account
  }

  /// Counts of keys at one moment — an hour ago unless said —, as a reconciliation of accounts
  /// writes them.
  private func count(
    _ counts: [(UUID, CurrencyCode, AmountE4)], at: Date = Date().addingTimeInterval(-3_600)
  ) throws {
    let reconciliation = Reconciliation(
      date: environment.calendar.day(of: at), reconciledAt: at, actualTotalRubE4: .zero,
      kind: .accounts)
    let balances = counts.map { account, currency, amount in
      ReconciledBalance(
        reconciliationId: reconciliation.id, accountId: account, currency: currency,
        actualE4: amount)
    }
    XCTAssertTrue(
      store.apply(
        PlanningChange(
          upsert: PlanningRows(reconciliations: [reconciliation], reconciledBalances: balances))))
  }

  @discardableResult
  private func spend(
    on accountId: UUID, currency: CurrencyCode = .rub, amount: AmountE4 = AmountE4(whole: 100)
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(
      occurredAt: Date().addingTimeInterval(-1_800), currency: currency, amount: amount,
      rate: currency == .rub ? nil : 90, note: "coffee", paymentMethodId: accountId)
    draft.normalizeSinglePart()
    let entry = try draft.materialize()
    XCTAssertTrue(store.save(entry))
    return entry
  }

  private func freshBooks() async throws -> AccountBooks {
    let books = await actions.books()
    return try XCTUnwrap(books)
  }

  private func balance(_ books: AccountBooks, _ id: UUID, _ currency: CurrencyCode) -> AmountE4? {
    books.balances.balance(BalanceKey(accountId: id, currency: currency), at: books.at)
  }

  /// What the live accounts hold together in one currency, every key counted.
  private func liveTotal(_ currency: CurrencyCode) async throws -> AmountE4 {
    let books = try await freshBooks()
    var total = AmountE4.zero
    for account in actions.all where !account.archived {
      total = total + (balance(books, account.id, currency) ?? .zero)
    }
    return total
  }

  private func stored(_ id: UUID) throws -> PaymentMethod {
    let all = try XCTUnwrap(environment.accounts).accounts(includeArchived: true)
    return try XCTUnwrap(all.first { $0.id == id })
  }

  private func usage(_ id: UUID) throws -> AccountUsage {
    try XCTUnwrap(environment.accounts).usage(of: id)
  }

  /// The live main accounts: exactly one, always.
  private func mains() throws -> [UUID] {
    try XCTUnwrap(environment.accounts).accounts(includeArchived: true)
      .filter { $0.isDefault && !$0.archived }.map(\.id)
  }
}
