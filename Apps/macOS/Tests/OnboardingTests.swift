import AppCore
import AppDatabase
import SQLite3
import XCTest

@testable import OhMyMoney

/// The setup of the accounts: when the main window asks for it, the plan the answers come to,
/// what «Готово» and «Позже» write, and the banks offered with one click.
@MainActor
final class OnboardingTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-onboarding-\(UUID().uuidString)", isDirectory: true)
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

  private var accounts: AccountRepository { get throws { try XCTUnwrap(environment.accounts) } }

  // MARK: When it is asked

  func testTheSetupIsAskedOfAnOpenDatabaseThatHasNotBeenThroughIt() {
    XCTAssertTrue(
      AccountSetupOffer.asks(setup: nil, isOpen: true, isTestHost: false, dataSet: nil),
      "a fresh install is asked")
    XCTAssertFalse(
      AccountSetupOffer.asks(setup: .later, isOpen: true, isTestHost: false, dataSet: nil),
      "«Позже» ends the question; the card of Overview leads back")
    XCTAssertFalse(
      AccountSetupOffer.asks(setup: .done, isOpen: true, isTestHost: false, dataSet: nil))
    XCTAssertFalse(
      AccountSetupOffer.asks(setup: nil, isOpen: false, isTestHost: false, dataSet: nil),
      "nothing is asked before the database is open")
    XCTAssertFalse(
      AccountSetupOffer.asks(setup: nil, isOpen: true, isTestHost: true, dataSet: nil),
      "never in the host of the unit tests")
    for dataSet in AppPaths.DataSet.allCases {
      XCTAssertFalse(
        AccountSetupOffer.asks(setup: nil, isOpen: true, isTestHost: false, dataSet: dataSet),
        "never in the data set \(dataSet.rawValue) — the UI tests open one")
    }
    XCTAssertFalse(
      AccountSetupOffer.asks(
        setup: nil, isOpen: true, isTestHost: false, dataSet: nil, archiveWaits: true),
      "an archive double-clicked in Finder is about to replace the database")
  }

  /// The setup is the first question of the window: the questions after an import or a restore
  /// wait for it and come once it is answered.
  func testTheOtherQuestionsOfTheWindowWaitForTheSetup() {
    XCTAssertFalse(AccountSetupOffer.lets(true, asksSetup: true))
    XCTAssertTrue(AccountSetupOffer.lets(true, asksSetup: false))
    XCTAssertFalse(AccountSetupOffer.lets(false, asksSetup: false))

    // The fresh database of this test is asked as a window outside the tests' host would ask
    // it — until an archive waits in the environment, which keeps the setup back.
    XCTAssertTrue(AccountSetupOffer.asks(environment, isTestHost: false))
    environment.pendingArchiveImport = URL(fileURLWithPath: "/tmp/archive.ohmymoney")
    XCTAssertFalse(AccountSetupOffer.asks(environment, isTestHost: false))
    environment.pendingArchiveImport = nil
    XCTAssertTrue(AccountSetupOffer.asks(environment, isTestHost: false))
    XCTAssertFalse(AccountSetupOffer.asks(environment), "the tests' host itself is never asked")
  }

  /// The sheet opened from the card of Overview is as much on screen as the one the window
  /// asks with: the reminders and the notice of currencies wait for it, and come once it is
  /// closed.
  func testTheSheetTheCardAskedForHoldsTheOtherQuestionsBackToo() {
    let request = AccountSetupRequest()
    XCTAssertFalse(AccountSetupOffer.isUp(environment, isTestHost: true, request: request))
    request.isRequested = true
    XCTAssertTrue(
      AccountSetupOffer.isUp(environment, isTestHost: true, request: request),
      "«Настроить счета…» pressed before the reminders were counted")
    XCTAssertFalse(
      AccountSetupOffer.lets(
        true, asksSetup: AccountSetupOffer.isUp(environment, isTestHost: true, request: request)))
    request.isRequested = false
    XCTAssertTrue(AccountSetupOffer.isUp(environment, isTestHost: false, request: request))
  }

  /// The offer of a report after a crash is raised only once the window knows whether the
  /// setup comes: raised while the database opens, it would be taken down by the setup a
  /// moment later, with the report it led to.
  func testTheOfferOfAReportWaitsForTheStartTheArchiveAndTheSetup() async {
    XCTAssertFalse(
      AccountSetupOffer.letsReportOffer(isStarting: true, archiveWaits: false, setupIsUp: false),
      "the database is still opening")
    XCTAssertFalse(
      AccountSetupOffer.letsReportOffer(isStarting: false, archiveWaits: true, setupIsUp: false),
      "an archive from Finder is about to be taken up, and the setup may come after it")
    XCTAssertFalse(
      AccountSetupOffer.letsReportOffer(isStarting: false, archiveWaits: false, setupIsUp: true))
    XCTAssertTrue(
      AccountSetupOffer.letsReportOffer(isStarting: false, archiveWaits: false, setupIsUp: false))

    let starting = AppEnvironment()
    XCTAssertEqual(starting.state, .starting)
    XCTAssertFalse(AccountSetupOffer.letsReportOffer(starting, setupIsUp: false))
    XCTAssertTrue(AccountSetupOffer.letsReportOffer(environment, setupIsUp: false))
    environment.pendingArchiveImport = URL(fileURLWithPath: "/tmp/archive.ohmymoney")
    XCTAssertFalse(AccountSetupOffer.letsReportOffer(environment, setupIsUp: false))
    environment.pendingArchiveImport = nil
    await starting.close()
  }

  /// A database of the first version — the schema up to `0003_model`, two payment methods,
  /// both flagged default as that version allowed — comes out of the update with them as
  /// accounts, exactly one main, and no mark of the setup: it is asked like a fresh install.
  func testADatabaseOfTheFirstVersionIsAskedAfterTheUpdate() async throws {
    await environment.close()
    let url = directory.appendingPathComponent("first-version/finance.sqlite")
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try DatabaseStack(url: url, schema: FirstVersionSchema()).close()
    try Self.execute(
      at: url,
      """
      INSERT INTO payment_methods (id, name, kind, currency, aliases, is_default, archived) VALUES
        ('0A000000-0000-0000-0000-000000000001', 'Visa', 'card', 'RUB', '', 1, 0),
        ('0A000000-0000-0000-0000-000000000002', 'Wallet', 'cash', NULL, '', 1, 0);
      """)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(url: url, schema: BundleSchemaSource(bundle: .main))
    })
    XCTAssertEqual(environment.state, .ready)

    XCTAssertNil(environment.accountSetup)
    XCTAssertTrue(
      AccountSetupOffer.asks(
        setup: environment.accountSetup, isOpen: environment.state == .ready, isTestHost: false,
        dataSet: nil))
    XCTAssertFalse(
      AccountSetupOffer.asks(environment), "the host of the unit tests is never asked")
    XCTAssertFalse(AccountsSetupCard.shows(setup: environment.accountSetup))

    let model = try XCTUnwrap(AccountSetupModel.load(from: environment))
    XCTAssertEqual(Set(model.accounts.map(\.name)), ["Visa", "Wallet"], "they are listed")
    XCTAssertEqual(try accounts.accounts().filter(\.isDefault).count, 1, "exactly one main")
    XCTAssertNotNil(model.accounts.first { $0.id == model.mainId })
    XCTAssertTrue(model.accounts.allSatisfy { !$0.isNew })
  }

  /// A database of the first version that flags no payment method as default and has an
  /// operation written without one: the update puts that operation on a new «Основной счёт»,
  /// and the setup lists it first, as the main account of the database, next to the others.
  func testTheMainAccountTheUpdateMadeIsListedAsTheMainOne() async throws {
    await environment.close()
    let url = directory.appendingPathComponent("first-version-unassigned/finance.sqlite")
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try DatabaseStack(url: url, schema: FirstVersionSchema()).close()
    try Self.execute(
      at: url,
      """
      INSERT INTO categories (id, kind, name, quality) VALUES
        ('0C000000-0000-0000-0000-000000000001', 'expense', 'Groceries', 'neutral');
      INSERT INTO payment_methods (id, name, kind, currency, aliases, is_default, archived) VALUES
        ('0A000000-0000-0000-0000-000000000001', 'Visa', 'card', 'RUB', '', 0, 0);
      INSERT INTO transactions (id, kind, occurred_at, currency, amount_e4, amount_rub_e4,
        created_at, updated_at, deleted_at, payment_method_id, period_month) VALUES
        ('0D000000-0000-0000-0000-000000000001', 'expense', '2026-08-01 10:00:00.000', 'RUB',
          2500000, 2500000, '2026-08-01 10:00:00.000', '2026-08-01 10:00:00.000', NULL,
          NULL, NULL);
      INSERT INTO transaction_parts (id, transaction_id, category_id, amount_e4, amount_rub_e4,
        reimbursable, debtor_person_id, reimbursement_status, for_person_id) VALUES
        ('0E000000-0000-0000-0000-000000000001', '0D000000-0000-0000-0000-000000000001',
          '0C000000-0000-0000-0000-000000000001', 2500000, 2500000, 0, NULL, NULL, NULL);
      """)
    let mainName = "Основной счёт"
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(
        url: url, schema: BundleSchemaSource(bundle: .main),
        context: MigrationContext(mainAccountName: mainName))
    })
    XCTAssertEqual(environment.state, .ready)

    XCTAssertNil(environment.accountSetup, "the update leaves the setup to be asked")
    XCTAssertTrue(
      AccountSetupOffer.asks(
        setup: environment.accountSetup, isOpen: environment.state == .ready, isTestHost: false,
        dataSet: nil))
    let model = try XCTUnwrap(AccountSetupModel.load(from: environment))
    XCTAssertEqual(model.accounts.map(\.name), [mainName, "Visa"], "the main account first")
    let main = try XCTUnwrap(model.accounts.first)
    XCTAssertEqual(model.mainId, main.id)
    XCTAssertFalse(main.isNew, "made by the update, it is an account of the database")
    XCTAssertEqual(main.currencies, [.rub])
    let operation = try XCTUnwrap(
      try XCTUnwrap(environment.transactions).entries(from: .distantPast, to: .distantFuture)
        .first)
    XCTAssertEqual(operation.transaction.paymentMethodId, main.id)
  }

  // MARK: The plan

  func testThePlanHasOneMainAccountAndTheCurrenciesInTheOwnersOrder() throws {
    let visa = PaymentMethod(name: "Visa", kind: .card, isDefault: true)
    let old = PaymentMethod(name: "Old card", kind: .card, archived: true)
    var model = AccountSetupModel(
      accounts: [visa, old], groups: [], defaultCurrency: .rub,
      enabled: CurrencyCode.defaultEnabled)
    XCTAssertEqual(model.accounts.map(\.id), [visa.id], "an archived account is not listed")

    let freedom = try XCTUnwrap(BankCatalog.banks.first { $0.id == "freedom" })
    model.toggle(freedom, languageCode: "en", countryName: "Kazakhstan")
    let freedomId = try XCTUnwrap(model.account(named: "Freedom")?.id)
    XCTAssertEqual(model.account(named: "Freedom")?.currencies, [CurrencyCode("KZT")])
    model.addCurrency(.eur, to: freedomId)
    model.addCurrency(.usd, to: freedomId)
    model.addCurrency(.rub, to: freedomId)
    model.makeMainCurrency(.eur, of: freedomId)
    XCTAssertEqual(
      model.account(named: "Freedom")?.currencies,
      [.eur, CurrencyCode("KZT"), .usd, .rub], "the first currency is the main one")
    model.mainId = freedomId
    XCTAssertNil(model.plan(at: Date()), "no plan before the balances expected are read")
    model.setExpected([:])

    let plan = try XCTUnwrap(model.plan(at: Date()))
    XCTAssertEqual(plan.mainAccountId, freedomId)
    XCTAssertEqual(plan.accounts.filter(\.isDefault).map(\.id), [freedomId], "exactly one main")
    let written = try XCTUnwrap(plan.accounts.first { $0.id == freedomId })
    XCTAssertEqual(written.currency, .eur)
    XCTAssertEqual(written.otherCurrencies, [CurrencyCode("KZT"), .usd, .rub])
    XCTAssertFalse(try XCTUnwrap(plan.accounts.first { $0.id == visa.id }).isDefault)
    XCTAssertFalse(plan.accounts.contains { $0.id == old.id }, "the archive is left as it is")
  }

  func testTheMainAccountCannotSitInAGroupOutOfTheSummary() throws {
    let card = PaymentMethod(name: "Card", kind: .card, isDefault: true)
    var model = AccountSetupModel(
      accounts: [card], groups: [], defaultCurrency: .rub, enabled: CurrencyCode.defaultEnabled)
    model.setExpected([:])
    let kazakhstan = try XCTUnwrap(model.addGroup(name: "Kazakhstan", inSummary: false))
    XCTAssertNil(model.addGroup(name: " kazakhstan "), "a group is not made twice")
    model.accounts[0].groupId = kazakhstan

    XCTAssertEqual(model.issues, [.mainInExcludedGroup])
    XCTAssertNil(model.plan(at: Date()))

    model.groups[0].inSummary = true
    XCTAssertEqual(model.issues, [])
    let plan = try XCTUnwrap(model.plan(at: Date()))
    XCTAssertEqual(plan.groups.map(\.name), ["Kazakhstan"])
    XCTAssertEqual(plan.accounts.first?.groupId, kazakhstan)
  }

  func testNamesMustBeThereAndDifferent() {
    var model = AccountSetupModel(
      accounts: [PaymentMethod(name: "Sber", kind: .card, isDefault: true)], groups: [],
      defaultCurrency: .rub, enabled: CurrencyCode.defaultEnabled)
    XCTAssertNil(model.addAccount(name: "  ", kind: .card), "nothing under an empty name")
    let sber = model.accounts[0].id
    let copy = model.addAccount(name: "SBER", kind: .card)
    XCTAssertEqual(Set(model.issues), [.nameTaken(sber), .nameTaken(copy!)])
    model.removeAccount(copy!)
    XCTAssertEqual(model.issues, [])

    let empty = AccountSetupModel(
      accounts: [], groups: [], defaultCurrency: .rub, enabled: CurrencyCode.defaultEnabled)
    XCTAssertEqual(empty.issues, [.noAccount])
    XCTAssertNil(empty.plan(at: Date()))
  }

  /// The balances typed become the first count of their account and currency; a field left
  /// empty is «не знаю» and writes nothing.
  func testTheBalancesBecomeTheFirstCountOfEveryAccountAndCurrency() throws {
    var model = AccountSetupModel(
      accounts: [], groups: [], defaultCurrency: .rub, enabled: CurrencyCode.defaultEnabled)
    let cash = try XCTUnwrap(model.addAccount(name: "Cash", kind: .cash))
    XCTAssertEqual(model.mainId, cash, "the first account of the setup is the main one")
    let card = try XCTUnwrap(model.addAccount(name: "Card", kind: .card))
    model.addCurrency(.usd, to: card)
    model.setBalance(AmountE4(whole: 12_000), for: BalanceKey(accountId: cash, currency: .rub))
    model.setBalance(AmountE4(whole: 300), for: BalanceKey(accountId: card, currency: .usd))
    model.setExpected([:])

    let plan = try XCTUnwrap(model.plan(at: Date()))
    XCTAssertEqual(
      plan.openingBalances,
      [
        BalanceKey(accountId: cash, currency: .rub): AmountE4(whole: 12_000),
        BalanceKey(accountId: card, currency: .usd): AmountE4(whole: 300),
      ], "a field left empty is no count")
    XCTAssertEqual(plan.expected, [:], "every key is a starting point")
  }

  /// «Card» 12,000 and «Dollars» 0 typed, «Cash» left empty: «Готово» writes one opening of
  /// the setup with the two typed balances; Cash stays uncounted — out of «Всего» —, and its
  /// first count will be its starting point.
  func testAnEmptyFieldWritesNoOpening() async throws {
    var model = try XCTUnwrap(AccountSetupModel.load(from: environment))
    let card = try XCTUnwrap(model.addAccount(name: "Card", kind: .card))
    let dollars = try XCTUnwrap(model.addAccount(name: "Dollars", kind: .account, currency: .usd))
    let cash = try XCTUnwrap(model.addAccount(name: "Cash", kind: .cash))
    let cashKey = BalanceKey(accountId: cash, currency: .rub)
    model.setBalance(AmountE4(whole: 12_000), for: BalanceKey(accountId: card, currency: .rub))
    model.setBalance(.zero, for: BalanceKey(accountId: dollars, currency: .usd))
    let at = Date()
    let read = await AccountSetupExpectations.load(from: environment, at: at)
    model.setExpected(try XCTUnwrap(read))
    XCTAssertNil(model.balance(cashKey), "an empty field is «не знаю», not zero")
    XCTAssertTrue(model.leavesAccountsUncounted)
    let plan = try XCTUnwrap(model.plan(at: at))
    XCTAssertEqual(
      plan.openingBalances,
      [
        BalanceKey(accountId: card, currency: .rub): AmountE4(whole: 12_000),
        BalanceKey(accountId: dollars, currency: .usd): .zero,
      ])

    XCTAssertEqual(
      AccountSetupWrites.finish(plan, environment: environment, store: store), .written)
    let book = try XCTUnwrap(environment.planning).book()
    let openings = book.reconciliations.filter { $0.kind == .opening }
    XCTAssertEqual(openings.count, 1)
    XCTAssertEqual(openings.first?.origin, .setup)
    XCTAssertEqual(Set(book.reconciledBalances.map(\.key)), Set(plan.openingBalances.keys))
    XCTAssertFalse(book.reconciledBalances.contains { $0.key == cashKey }, "Cash was counted")
  }

  /// A 0 typed is a count of zero, and shows «0»; emptied again, it is «не знаю» once more.
  func testATypedZeroIsWritten() throws {
    var model = AccountSetupModel(
      accounts: [], groups: [], defaultCurrency: .rub, enabled: CurrencyCode.defaultEnabled)
    let cash = try XCTUnwrap(model.addAccount(name: "Cash", kind: .cash))
    let key = BalanceKey(accountId: cash, currency: .rub)
    model.setExpected([:])
    model.setBalance(.zero, for: key)
    XCTAssertEqual(model.balance(key), .zero)
    XCTAssertFalse(model.leavesAccountsUncounted)
    XCTAssertEqual(try XCTUnwrap(model.plan(at: Date())).openingBalances, [key: .zero])
    XCTAssertEqual(BalanceField.text(for: .zero), "0", "a zero typed shows as zero")
    XCTAssertEqual(BalanceField.read("0"), .amount(.zero))

    model.setBalance(nil, for: key)
    XCTAssertNil(model.balance(key))
    XCTAssertTrue(model.leavesAccountsUncounted)
    XCTAssertEqual(try XCTUnwrap(model.plan(at: Date())).openingBalances, [:])
    XCTAssertEqual(BalanceField.read("  "), .unknown)
    XCTAssertEqual(BalanceField.text(for: nil), "")
  }

  /// A credit card's balance is what is owed, typed with a minus — «-» or «−» —; it is written
  /// as the card's first count and counts below zero.
  func testANegativeBalanceIsAccepted() async throws {
    XCTAssertEqual(BalanceField.read("−30,000"), .amount(AmountE4(whole: -30_000)))
    XCTAssertEqual(BalanceField.read("-30000"), .amount(AmountE4(whole: -30_000)))
    XCTAssertEqual(BalanceField.read("-1500-500"), .amount(AmountE4(whole: -2_000)))
    XCTAssertEqual(BalanceField.read("30,000-"), .unreadable, "half typed")
    XCTAssertEqual(BalanceField.text(for: AmountE4(whole: -30_000)), "-30,000")
    XCTAssertEqual(BalanceField.settledText("−30000"), "-30,000")
    XCTAssertNil(BalanceField.settledText("-30,000"), "already written the app's way")

    var model = try XCTUnwrap(AccountSetupModel.load(from: environment))
    let credit = try XCTUnwrap(model.addAccount(name: "Credit", kind: .card))
    let sber = try XCTUnwrap(model.addAccount(name: "Sber", kind: .card))
    model.setBalance(
      AmountE4(whole: -30_000), for: BalanceKey(accountId: credit, currency: .rub))
    model.setBalance(AmountE4(whole: 100_000), for: BalanceKey(accountId: sber, currency: .rub))
    let at = Date().addingTimeInterval(-1)
    let read = await AccountSetupExpectations.load(from: environment, at: at)
    model.setExpected(try XCTUnwrap(read))
    XCTAssertEqual(model.issues, [])
    let plan = try XCTUnwrap(model.plan(at: at))
    XCTAssertEqual(
      AccountSetupWrites.finish(plan, environment: environment, store: store), .written)

    let readAfter = await AccountSetupExpectations.load(from: environment, at: Date())
    let expected = try XCTUnwrap(readAfter)
    XCTAssertEqual(
      expected[BalanceKey(accountId: credit, currency: .rub)], AmountE4(whole: -30_000))
    XCTAssertNotEqual(
      environment.language("account.balance.creditHint", table: "Accounts"),
      "account.balance.creditHint")
  }

  /// A name that is another name of an account says whose: «Card» against «Cash», which also
  /// goes by «card».
  func testTheClashNamesTheAccountOfTheOtherName() throws {
    let cash = PaymentMethod(name: "Cash", kind: .cash, aliases: ["card"], isDefault: true)
    var model = AccountSetupModel(
      accounts: [cash], groups: [], defaultCurrency: .rub, enabled: CurrencyCode.defaultEnabled)
    model.setExpected([:])
    let card = try XCTUnwrap(model.addAccount(name: "Card", kind: .card))
    let issue = AccountSetupModel.Issue.nameIsOtherNameOf(card, rival: "Cash")
    XCTAssertEqual(model.issues, [issue])
    XCTAssertNil(model.plan(at: Date()))
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      let message = model.message(for: issue, language: environment.language)
      XCTAssertTrue(message.contains("«Cash»"), message)
      XCTAssertNotEqual(message, "onboarding.issue.nameIsOtherName")
    }
    environment.language.choice = .russian

    // Named like the account itself, it is the plain clash of names.
    model.accounts[model.accounts.firstIndex { $0.id == card }!].name = "CASH"
    XCTAssertEqual(Set(model.issues), [.nameTaken(card), .nameTaken(cash.id)])
  }

  // MARK: What the answers write

  func testDoneWritesTheAccountsGroupsAndOpeningCountsAndForgetsUndo() async throws {
    XCTAssertTrue(store.save(try expense(AmountE4(whole: 100), at: Date())))
    XCTAssertTrue(store.canUndo)

    var model = try XCTUnwrap(AccountSetupModel.load(from: environment))
    let russia = try XCTUnwrap(model.addGroup(name: "Russia"))
    let sber = try XCTUnwrap(BankCatalog.banks.first { $0.id == "sber" })
    model.toggle(sber, languageCode: "en", countryName: "Russia")
    let sberId = try XCTUnwrap(model.account(named: "Sber")?.id)
    XCTAssertEqual(model.account(named: "Sber")?.groupId, russia, "it goes into its country")
    model.setBalance(AmountE4(whole: 5_000), for: BalanceKey(accountId: sberId, currency: .rub))
    let at = Date()
    let expected = await AccountSetupExpectations.load(from: environment, at: at)
    model.setExpected(try XCTUnwrap(expected))
    let plan = try XCTUnwrap(model.plan(at: at))

    XCTAssertEqual(
      AccountSetupWrites.finish(plan, environment: environment, store: store), .written)

    XCTAssertFalse(store.canUndo, "the setup is no step of ⌘Z and forgets the steps before")
    XCTAssertEqual(environment.accountSetup, .done)
    XCTAssertFalse(
      AccountSetupOffer.asks(setup: .done, isOpen: true, isTestHost: false, dataSet: nil))
    XCTAssertFalse(AccountsSetupCard.shows(setup: environment.accountSetup))
    let stored = try accounts.accounts()
    XCTAssertEqual(stored.filter(\.isDefault).map(\.id), [sberId])
    XCTAssertEqual(try accounts.groups().map(\.name), ["Russia"])
    let book = try XCTUnwrap(environment.planning).book()
    let opening = try XCTUnwrap(book.reconciliations.last)
    XCTAssertEqual(opening.kind, .opening)
    let counted = book.reconciledBalances.filter { $0.reconciliationId == opening.id }
    XCTAssertEqual(counted.map(\.actualE4), [AmountE4(whole: 5_000)])
    XCTAssertTrue(counted.allSatisfy(\.isStartingPoint), "the first count compares nothing")
    let operation = try XCTUnwrap(
      try XCTUnwrap(environment.transactions).entries(from: .distantPast, to: .distantFuture)
        .first)
    XCTAssertEqual(
      operation.transaction.paymentMethodId, sberId,
      "an operation written before any account existed goes to the main one")
  }

  func testLaterMakesAMainAccountOnlyWhenThereIsNone() async throws {
    XCTAssertTrue(try accounts.accounts().isEmpty)
    XCTAssertTrue(store.save(try expense(AmountE4(whole: 100), at: Date())))

    XCTAssertTrue(AccountSetupWrites.postpone(environment: environment, store: store))

    XCTAssertFalse(store.canUndo)
    XCTAssertEqual(environment.accountSetup, .later)
    XCTAssertTrue(AccountsSetupCard.shows(setup: environment.accountSetup))
    let made = try accounts.accounts()
    XCTAssertEqual(made.count, 1)
    let main = try XCTUnwrap(made.first)
    XCTAssertTrue(main.isDefault)
    XCTAssertEqual(main.name, environment.language("accounts.mainDefaultName"))
    XCTAssertEqual(main.kind, .account)
    XCTAssertEqual(main.mainCurrency, environment.defaultCurrency)
    let operation = try XCTUnwrap(
      try XCTUnwrap(environment.transactions).entries(from: .distantPast, to: .distantFuture)
        .first)
    XCTAssertEqual(operation.transaction.paymentMethodId, main.id)

    // Another database, whose main account is there: «Позже» makes nothing.
    await environment.close()
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    let visa = PaymentMethod(name: "Visa", kind: .card, isDefault: true)
    try XCTUnwrap(environment.references).save(visa)
    XCTAssertTrue(AccountSetupWrites.postpone(environment: environment, store: store))
    XCTAssertEqual(try accounts.accounts().map(\.id), [visa.id])
    XCTAssertEqual(environment.accountSetup, .later)
  }

  /// A key counted after «Позже» is no starting point: the setup shows what the books expect
  /// for it — its count plus what moved since. Left empty, it keeps its count; typed, it is
  /// compared, and the difference is written with the count.
  func testAKeyCountedAfterLaterShowsItsDifference() async throws {
    XCTAssertTrue(AccountSetupWrites.postpone(environment: environment, store: store))
    let main = try XCTUnwrap(try accounts.accounts().first)
    let key = BalanceKey(accountId: main.id, currency: main.mainCurrency)
    let counted = Date().addingTimeInterval(-3_600)
    // Counted by the editor of the account, as Settings does it: the setup is still put off.
    let count = Reconciliation(
      date: environment.calendar.day(of: counted), reconciledAt: counted,
      actualTotalRubE4: .zero, kind: .opening)
    XCTAssertTrue(
      store.apply(
        PlanningChange(
          upsert: PlanningRows(
            reconciliations: [count],
            reconciledBalances: [
              ReconciledBalance(
                reconciliationId: count.id, accountId: main.id, currency: key.currency,
                actualE4: AmountE4(whole: 10_000))
            ]), at: counted)))
    environment.refreshAccountSettings()
    XCTAssertEqual(environment.accountSetup, .later)
    XCTAssertTrue(AccountsSetupCard.shows(setup: environment.accountSetup))
    XCTAssertTrue(
      store.save(
        try expense(AmountE4(whole: 1_500), at: counted.addingTimeInterval(600), on: main.id)))

    var model = try XCTUnwrap(AccountSetupModel.load(from: environment))
    let now = Date()
    let expected = await AccountSetupExpectations.load(from: environment, at: now)
    model.setExpected(try XCTUnwrap(expected))
    XCTAssertEqual(model.expected[key], AmountE4(whole: 8_500), "the count less what was spent")
    XCTAssertNil(model.balance(key), "left alone, nothing is counted")
    XCTAssertNil(model.difference(key))
    XCTAssertFalse(model.leavesAccountsUncounted, "a key counted before keeps its count")
    XCTAssertEqual(try XCTUnwrap(model.plan(at: now)).openingBalances, [:])
    model.setBalance(AmountE4(whole: 8_000), for: key)
    XCTAssertEqual(model.difference(key), AmountE4(whole: -500))

    let plan = try XCTUnwrap(model.plan(at: now))
    XCTAssertEqual(plan.expected, [key: AmountE4(whole: 8_500)])
    XCTAssertEqual(
      AccountSetupWrites.finish(plan, environment: environment, store: store), .written)
    let book = try XCTUnwrap(environment.planning).book()
    let last = try XCTUnwrap(book.reconciledBalances.last { $0.key == key })
    XCTAssertEqual(last.actualE4, AmountE4(whole: 8_000))
    XCTAssertEqual(last.expectedE4, AmountE4(whole: 8_500))
    XCTAssertEqual(last.differenceE4, AmountE4(whole: -500))
    XCTAssertNil(last.transactionId, "the difference is shown, never written as an operation")
  }

  /// A key counted before shows what the books expect in its empty field, as a hint, not a
  /// value: left alone it writes nothing, so what moves while the sheet is open never becomes a
  /// count nobody made. What the owner types is the count, whatever the books say after.
  func testAnUntouchedBalanceFollowsTheBooksPastTheEchoOfItsField() throws {
    let card = PaymentMethod(name: "Card", kind: .card, isDefault: true)
    var model = AccountSetupModel(
      accounts: [card], groups: [], defaultCurrency: .rub, enabled: CurrencyCode.defaultEnabled)
    let key = BalanceKey(accountId: card.id, currency: .rub)
    model.setExpected([key: AmountE4(whole: 8_500)])
    // The field shows nothing and tells nothing back.
    model.setBalance(model.balance(key), for: key)
    // An operation of 500 is written in another window; «Готово» reads the books again.
    model.setExpected([key: AmountE4(whole: 8_000)])

    XCTAssertNil(model.balance(key))
    XCTAssertNil(model.difference(key))
    let plan = try XCTUnwrap(model.plan(at: Date()))
    XCTAssertNil(plan.openingBalances[key])
    XCTAssertNil(plan.expected[key])

    model.setBalance(AmountE4(whole: 7_000), for: key)
    model.setExpected([key: AmountE4(whole: 7_500)])
    let typed = try XCTUnwrap(model.plan(at: Date()))
    XCTAssertEqual(typed.openingBalances[key], AmountE4(whole: 7_000))
    XCTAssertEqual(typed.expected[key], AmountE4(whole: 7_500))
    XCTAssertEqual(model.difference(key), AmountE4(whole: -500))
  }

  /// Settings stays usable while the sheet is open. «Готово» reads the accounts again: an
  /// account archived meanwhile is not written back live, one made meanwhile joins the list, a
  /// field left alone here takes what was written there, and a field changed here keeps it.
  func testTheAccountsAreReadAgainAndOnlyTheEditsOfTheSheetAreWritten() throws {
    let visa = PaymentMethod(
      name: "Visa", kind: .card, currency: .rub, aliases: ["Old Visa"], isDefault: true)
    let wallet = PaymentMethod(name: "Wallet", kind: .cash, currency: .rub)
    let spare = PaymentMethod(name: "Spare", kind: .card, currency: .rub)
    var model = AccountSetupModel(
      accounts: [visa, wallet, spare], groups: [], defaultCurrency: .rub,
      enabled: CurrencyCode.defaultEnabled)
    model.setExpected([:])
    model.accounts[model.accounts.firstIndex { $0.id == visa.id }!].kind = .account
    model.setBalance(
      AmountE4(whole: 700), for: BalanceKey(accountId: spare.id, currency: .rub))

    // Meanwhile, in Settings: Visa renamed, Spare merged into Wallet (archived), Bonus made.
    var renamed = visa
    renamed.name = "Visa Gold"
    var merged = spare
    merged.archived = true
    let bonus = PaymentMethod(name: "Bonus", kind: .card, currency: .usd)

    XCTAssertTrue(
      model.rebase(accounts: [renamed, wallet, merged, bonus], groups: []),
      "the list changed: the owner sees it again before anything is written")
    XCTAssertEqual(Set(model.accounts.map(\.id)), [visa.id, wallet.id, bonus.id])
    let plan = try XCTUnwrap(model.plan(at: Date()))
    XCTAssertFalse(plan.accounts.contains { $0.id == spare.id }, "no merged account comes back")
    XCTAssertNil(plan.openingBalances[BalanceKey(accountId: spare.id, currency: .rub)])
    let written = try XCTUnwrap(plan.accounts.first { $0.id == visa.id })
    XCTAssertEqual(written.name, "Visa Gold", "the name was not touched here")
    XCTAssertEqual(written.kind, .account, "the kind was changed here")
    XCTAssertEqual(written.aliases, ["Old Visa"], "what the sheet does not edit stays")
    XCTAssertEqual(plan.mainAccountId, visa.id)
    XCTAssertNil(
      plan.openingBalances[BalanceKey(accountId: bonus.id, currency: .usd)],
      "an account made meanwhile, never typed, stays uncounted")
    XCTAssertEqual(
      plan.openingBalances[BalanceKey(accountId: spare.id, currency: .rub)], nil,
      "no merged account is counted")

    XCTAssertFalse(
      model.rebase(accounts: [renamed, wallet, merged, bonus], groups: []),
      "read again with nothing new: nothing changed")
    XCTAssertEqual(
      AccountSetupModel.merged([.usd, .rub], before: [.rub], now: [.rub, .eur]),
      [.usd, .rub, .eur], "the order made here, with a currency added there at the end")
    XCTAssertEqual(
      AccountSetupModel.merged([.rub, .usd], before: [.rub, .eur], now: [.rub]), [.rub, .usd],
      "a currency taken away there stays away")
  }

  /// The names follow the rules Settings saves accounts and groups by.
  func testNamesFollowTheRulesOfSettings() throws {
    let visa = PaymentMethod(name: "Visa", kind: .card, aliases: ["Tinkoff"], isDefault: true)
    let old = PaymentMethod(name: "Old card", kind: .card, archived: true)
    let trip = AccountGroup(name: "Trips", archived: true)
    var model = AccountSetupModel(
      accounts: [visa, old], groups: [trip], defaultCurrency: .rub,
      enabled: CurrencyCode.defaultEnabled)
    model.setExpected([:])

    let tinkoff = try XCTUnwrap(model.addAccount(name: "tinkoff", kind: .card))
    XCTAssertEqual(
      model.issues, [.nameIsOtherNameOf(tinkoff, rival: "Visa")],
      "another name of an account is taken, and the words say whose")
    model.removeAccount(tinkoff)

    model.accounts[0].name = "Old Card"
    XCTAssertEqual(
      model.issues, [.nameArchived(visa.id)], "renamed to the name of an archived account")
    model.accounts[0].name = "Visa"

    XCTAssertTrue(model.hasGroup(named: "trips"), "an archived group has the name")
    XCTAssertNil(model.addGroup(name: "Trips"), "it is not made twice")
    let other = try XCTUnwrap(model.addGroup(name: "Travel"))
    model.groups[model.groups.firstIndex { $0.id == other }!].name = "TRIPS"
    XCTAssertEqual(model.issues, [.groupNameArchived(other)])
  }

  /// When the balances expected cannot be read, nothing is counted: a key counted before would
  /// be taken for a starting point and written as zero.
  func testNothingIsCountedWhileTheBalancesExpectedCannotBeRead() async throws {
    var model = try XCTUnwrap(AccountSetupModel.load(from: environment))
    model.addAccount(name: "Cash", kind: .cash)
    XCTAssertNil(model.plan(at: Date()), "not read yet")

    await environment.close()
    let expected = await AccountSetupExpectations.load(from: environment, at: Date())
    XCTAssertNil(expected, "a read that fails is no empty book")
    XCTAssertNil(AccountSetupModel.load(from: environment))
    XCTAssertNil(model.rebase(on: environment))
    XCTAssertNil(model.plan(at: Date()))
  }

  // MARK: The banks

  func testTheBanksOfferedWithOneClick() throws {
    XCTAssertEqual(
      BankCatalog.banks(in: .russia).map(\.russian),
      [
        "Сбер", "Т-Банк", "ВТБ", "Альфа-Банк", "Газпромбанк", "Совкомбанк", "Озон Банк",
        "Райффайзенбанк", "Россельхозбанк", "ПСБ",
      ])
    XCTAssertEqual(
      BankCatalog.banks(in: .kazakhstan).map(\.russian),
      ["Kaspi", "Halyk", "Freedom", "Банк ЦентрКредит", "ForteBank"])
    XCTAssertEqual(Set(BankCatalog.banks.map(\.id)).count, BankCatalog.banks.count)
    let tbank = try XCTUnwrap(BankCatalog.banks.first { $0.id == "tbank" })
    XCTAssertEqual(tbank.name(languageCode: "ru"), "Т-Банк")
    XCTAssertEqual(tbank.name(languageCode: "en"), "T-Bank")
    XCTAssertEqual(BankCatalog.bank(named: "t-bank")?.id, "tbank", "either spelling is the bank")
    XCTAssertEqual(BankCatalog.bank(named: "Т-БАНК")?.id, "tbank")
    let kaspi = try XCTUnwrap(BankCatalog.banks.first { $0.id == "kaspi" })
    XCTAssertEqual(kaspi.names, ["Kaspi"], "a name spelled alike is given once")
    XCTAssertEqual(kaspi.country.currency, CurrencyCode("KZT"))
    XCTAssertEqual(tbank.country.currency, .rub)
  }

  /// Cash is cash in either language: «Cash» of a database kept in English is not added again
  /// as «Наличные».
  func testCashIsKnownByTheNameOfEitherLanguage() {
    XCTAssertEqual(Set(BankCatalog.cashNames), ["Наличные", "Cash"])
    let model = AccountSetupModel(
      accounts: [PaymentMethod(name: "Cash", kind: .cash, isDefault: true)], groups: [],
      defaultCurrency: .rub, enabled: CurrencyCode.defaultEnabled)
    XCTAssertTrue(model.lists(names: BankCatalog.cashNames))
  }

  func testABankIsAddedAndTakenAwayButAnAccountOfTheDatabaseStays() throws {
    let stored = PaymentMethod(name: "Т-Банк", kind: .card, isDefault: true)
    var model = AccountSetupModel(
      accounts: [stored], groups: [], defaultCurrency: .rub, enabled: CurrencyCode.defaultEnabled)
    let tbank = try XCTUnwrap(BankCatalog.banks.first { $0.id == "tbank" })
    XCTAssertTrue(model.lists(tbank), "the database's account is that bank in either language")
    model.toggle(tbank, languageCode: "en", countryName: "Russia")
    XCTAssertEqual(model.accounts.map(\.id), [stored.id], "an account of the database stays")

    let vtb = try XCTUnwrap(BankCatalog.banks.first { $0.id == "vtb" })
    model.toggle(vtb, languageCode: "ru", countryName: "Россия")
    XCTAssertEqual(model.accounts.map(\.name), ["Т-Банк", "ВТБ"])
    XCTAssertEqual(model.mainId, stored.id, "the main account of the database stays main")
    model.toggle(vtb, languageCode: "ru", countryName: "Россия")
    XCTAssertEqual(model.accounts.map(\.name), ["Т-Банк"])
  }

  // MARK: Helpers

  /// SQL run on a database file, as the first version would have left it.
  private static func execute(at url: URL, _ sql: String) throws {
    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
      sqlite3_close(handle)
      throw CocoaError(.fileReadCorruptFile)
    }
    defer { sqlite3_close(handle) }
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
      throw NSError(
        domain: "sqlite", code: Int(sqlite3_errcode(handle)),
        userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(handle))])
    }
  }

  private func expense(
    _ amount: AmountE4, at instant: Date, on account: UUID? = nil
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(
      occurredAt: instant, amount: amount, note: "coffee", paymentMethodId: account)
    draft.normalizeSinglePart()
    return try draft.materialize()
  }
}

/// The schema of the first version of the app: the migrations up to `0003_model`.
private struct FirstVersionSchema: SchemaSource {
  func migrations() throws -> [SchemaMigration] {
    try BundleSchemaSource(bundle: .main).migrations().filter { $0.name <= "0003_model" }
  }
}
