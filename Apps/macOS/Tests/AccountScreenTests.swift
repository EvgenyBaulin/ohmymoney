import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The screens of an account and of a group, and the «Счета» part of the sidebar: which
/// operations and transfers a screen lists and how, what a row of the sidebar shows, how a
/// drag in a group lands in the order of every list, and what the sidebar's choice means for
/// the window.
@MainActor
final class AccountScreenTests: XCTestCase {
  private let calendar = CalendarContext(timeZone: TimeZone(identifier: "Europe/Moscow")!)
  private let money = MoneyFormatter(locale: Locale(identifier: "ru"))

  private let sber = PaymentMethod(name: "Сбер", currency: .rub, isDefault: true)
  private let tbank = PaymentMethod(name: "Т-Банк", currency: .rub)
  private let kaspi = PaymentMethod(name: "Kaspi", currency: CurrencyCode("KZT"))

  // MARK: History

  /// An account's screen lists its operations — and, on the main account, those with no
  /// account of their own — and every transfer in or out, by day, newest first. Deleted
  /// operations and those of other accounts are not there, and transfers count in no total.
  func testAnAccountListsItsOperationsAndTransfersByDay() throws {
    let day1 = DateOnly(year: 2026, month: 9, day: 20)
    let day2 = DateOnly(year: 2026, month: 9, day: 21)
    let coffee = try expense(250, on: day1, hour: 9, account: sber.id)
    let lunch = try expense(700, on: day1, hour: 13, account: nil)
    let taxi = try expense(400, on: day2, hour: 10, account: tbank.id)
    var gone = try expense(999, on: day2, hour: 11, account: sber.id)
    gone.transaction.deletedAt = Date()
    let out = transfer(from: sber.id, to: tbank.id, 1_000, on: day2, hour: 12)
    let back = transfer(from: tbank.id, to: sber.id, 300, on: day1, hour: 18)
    let elsewhere = transfer(from: tbank.id, to: kaspi.id, 50, on: day2, hour: 15)
    let dataset = Dataset(
      entries: [coffee, lunch, taxi, gone], paymentMethods: [sber, tbank, kaspi],
      transfers: [out, back, elsewhere])

    let history = AccountHistory.build(accountIds: [sber.id], dataset: dataset, calendar: calendar)
    XCTAssertEqual(history.days.map(\.day), [day2, day1], "newest day first")
    XCTAssertEqual(history.days[0].items.map(\.id), ["tr.\(out.id.uuidString)"])
    XCTAssertEqual(
      history.days[1].items.map(\.id),
      ["tr.\(back.id.uuidString)", "op.\(lunch.id.uuidString)", "op.\(coffee.id.uuidString)"],
      "newest first inside a day; an operation with no account is on the main account")
    XCTAssertEqual(history.operationIds, [coffee.id, lunch.id])
    XCTAssertEqual(history.days[0].totals, .zero, "a day of transfers alone comes to nothing")
    XCTAssertEqual(history.days[1].totals.myExpenses, AmountE4(whole: 950))

    let other = AccountHistory.build(accountIds: [tbank.id], dataset: dataset, calendar: calendar)
    XCTAssertEqual(other.operationIds, [taxi.id], "no account means the main one, not this one")
    XCTAssertEqual(other.days.flatMap(\.items).count, 4)
  }

  /// A group lists its accounts together; a transfer between two of them is one row, and
  /// its fee is found for it.
  func testAGroupListsATransferBetweenItsAccountsOnce() throws {
    let day = DateOnly(year: 2026, month: 9, day: 22)
    let inside = transfer(from: sber.id, to: tbank.id, 500, on: day, hour: 10)
    var fee = try expense(15, on: day, hour: 10, account: sber.id)
    fee.transaction.externalId = TransferRules.feeKey(of: inside.id)
    let dataset = Dataset(
      entries: [fee], paymentMethods: [sber, tbank, kaspi], transfers: [inside])

    let history = AccountHistory.build(
      accountIds: [sber.id, tbank.id], dataset: dataset, calendar: calendar)
    XCTAssertEqual(history.days.count, 1)
    XCTAssertEqual(
      history.days[0].items.filter { $0.id.hasPrefix("tr.") }.count, 1,
      "one transfer, one row")
    XCTAssertEqual(history.fees[inside.id]?.id, fee.id)
  }

  /// What a transfer did to the accounts on screen: out with a minus, in with a plus, inside
  /// a group or an account both amounts of an exchange.
  func testATransferRowSaysWhichWayTheMoneyWent() {
    let day = DateOnly(year: 2026, month: 9, day: 22)
    let out = transfer(from: sber.id, to: tbank.id, 1_000, on: day, hour: 10)
    XCTAssertEqual(
      AccountHistory.amountText(out, accountIds: [sber.id], money: money),
      "\u{2212}1,000\u{00A0}₽")
    XCTAssertEqual(
      AccountHistory.amountText(out, accountIds: [tbank.id], money: money), "+1,000\u{00A0}₽")
    XCTAssertEqual(
      AccountHistory.amountText(out, accountIds: [sber.id, tbank.id], money: money),
      "1,000\u{00A0}₽")
    var exchange = out
    exchange.toAccountId = kaspi.id
    exchange.toCurrency = CurrencyCode("KZT")
    exchange.toAmountE4 = AmountE4(whole: 5_700)
    XCTAssertEqual(
      AccountHistory.amountText(exchange, accountIds: [sber.id, kaspi.id], money: money),
      "1,000\u{00A0}₽ → 5,700\u{00A0}₸")
  }

  /// A transfer reads the same on the screen of an account as in the lists of Overview and
  /// Transactions: «Перевод: Сбер → Kaspi», «Обмен в Freedom: RUB → KZT»; an account gone is
  /// named by the word for it.
  func testATransferRowReadsAsInTheListsOfDays() {
    let language = AppLanguage()
    let day = DateOnly(year: 2026, month: 9, day: 22)
    let out = transfer(from: sber.id, to: kaspi.id, 1_000, on: day, hour: 10)
    let names = [sber.id: "Сбер", kaspi.id: "Kaspi"]
    XCTAssertEqual(
      AccountTransferRow.title(out, names: names, unknown: "?", language: language),
      TransferRowText(out, names: names).title(language: language))
    let freedom = UUID()
    var exchange = out
    exchange.fromAccountId = freedom
    exchange.toAccountId = freedom
    exchange.toCurrency = CurrencyCode("KZT")
    XCTAssertEqual(
      AccountTransferRow.title(
        exchange, names: [freedom: "Freedom"], unknown: "?", language: language),
      TransferRowText(exchange, names: [freedom: "Freedom"]).title(language: language))
    XCTAssertEqual(
      AccountTransferRow.title(out, names: [sber.id: "Сбер"], unknown: "?", language: language),
      TransferRowText(out, names: [sber.id: "Сбер", kaspi.id: "?"]).title(language: language),
      "a deleted account is named by the word for it")
  }

  /// A history built for data a newer build replaced meanwhile is dropped, not laid over the
  /// newer one: a transfer just deleted does not come back on screen.
  func testAHistoryBuiltForReplacedDataIsDropped() async {
    let snapshot = DataSnapshot.build(
      dataset: Dataset(paymentMethods: [sber]), calendar: calendar,
      today: DateOnly(year: 2026, month: 9, day: 22),
      context: SnapshotContext(rubPerUnit: [:], localeIdentifier: "ru"),
      version: DataVersion(load: 1))
    let calendar = self.calendar
    let stale = Task {
      await AccountHistoryBuilder.build(
        accountIds: [sber.id], snapshot: snapshot, calendar: calendar)
    }
    stale.cancel()
    let dropped = await stale.value
    XCTAssertNil(dropped, "the build the screen gave up on shows nothing")
    let fresh = await AccountHistoryBuilder.build(
      accountIds: [sber.id], snapshot: snapshot, calendar: calendar)
    XCTAssertNotNil(fresh)
  }

  // MARK: The sidebar

  /// A row of an account: its balance rounded as Overview rounds, «≈ ₽» under another
  /// currency, «не сверен» while never counted, and for several currencies «≈ ₽» of them all
  /// with each balance under it.
  func testAnAccountRowShowsItsBalanceRoundedWithRublesForAnotherCurrency() {
    let words: (String) -> String = { $0 }
    let rubles = AccountsSnapshot.AccountLine(
      account: sber,
      keys: [key(sber, .rub, balance: "12345.67", rub: "12345.67")],
      totalRub: AmountE4(raw: 123_456_700), unknown: 0)
    XCTAssertEqual(
      SidebarFigure.of(rubles, money: money, words: words, withoutRate: withoutRate).main,
      "12,346\u{00A0}₽")
    XCTAssertNil(
      SidebarFigure.of(rubles, money: money, words: words, withoutRate: withoutRate).caption)
    XCTAssertEqual(
      SidebarFigure.of(rubles, money: money, words: words, withoutRate: withoutRate).help,
      "12,345.67\u{00A0}₽",
      "the pointer shows the balance to the kopeck")

    let tenge = AccountsSnapshot.AccountLine(
      account: kaspi,
      keys: [key(kaspi, CurrencyCode("KZT"), balance: "57000", rub: "10000")],
      totalRub: AmountE4(whole: 10_000), unknown: 0)
    let figure = SidebarFigure.of(tenge, money: money, words: words, withoutRate: withoutRate)
    XCTAssertEqual(figure.main, "57,000\u{00A0}₸")
    XCTAssertEqual(figure.caption, "≈\u{00A0}10,000\u{00A0}₽")

    let noRate = AccountsSnapshot.AccountLine(
      account: kaspi, keys: [key(kaspi, CurrencyCode("KZT"), balance: "57000", rub: nil)],
      totalRub: nil, unknown: 0, withoutRate: [CurrencyCode("KZT")])
    XCTAssertEqual(
      SidebarFigure.of(noRate, money: money, words: words, withoutRate: withoutRate).caption,
      "sidebar.noRate")

    let never = AccountsSnapshot.AccountLine(
      account: tbank, keys: [key(tbank, .rub, balance: nil, rub: nil)], totalRub: nil,
      unknown: 1)
    XCTAssertEqual(
      SidebarFigure.of(never, money: money, words: words, withoutRate: withoutRate).main, "—")
    XCTAssertEqual(
      SidebarFigure.of(never, money: money, words: words, withoutRate: withoutRate).caption,
      "sidebar.notCounted")

    let freedom = PaymentMethod(
      name: "Freedom", currency: CurrencyCode("EUR"), otherCurrencies: [.usd, .rub])
    let several = AccountsSnapshot.AccountLine(
      account: freedom,
      keys: [
        key(freedom, CurrencyCode("EUR"), balance: "1200", rub: "120000"),
        key(freedom, .usd, balance: "300.4", rub: "27000"),
        key(freedom, .rub, balance: nil, rub: nil),
      ],
      totalRub: AmountE4(whole: 147_000), unknown: 1)
    let many = SidebarFigure.of(several, money: money, words: words, withoutRate: withoutRate)
    XCTAssertEqual(many.main, "≈\u{00A0}147,000\u{00A0}₽")
    XCTAssertEqual(many.caption, "1,200\u{00A0}€ · 300\u{00A0}$ · —\u{00A0}₽")
    XCTAssertFalse(many.help?.contains("without rate") ?? false, "every rate is known")

    // A currency without a rate is left out of «≈ ₽», and the row says which.
    let partly = AccountsSnapshot.AccountLine(
      account: freedom,
      keys: [
        key(freedom, CurrencyCode("EUR"), balance: "1200", rub: "120000"),
        key(freedom, .usd, balance: "300", rub: nil),
      ],
      totalRub: AmountE4(whole: 120_000), unknown: 0, withoutRate: [.usd])
    let short = SidebarFigure.of(partly, money: money, words: words, withoutRate: withoutRate)
    XCTAssertEqual(short.main, "≈\u{00A0}120,000\u{00A0}₽")
    XCTAssertEqual(short.missing, "without rate: USD")
    XCTAssertTrue(short.help?.contains("without rate: USD") ?? false, "the pointer says so")
  }

  /// A drag inside a group lands in the order of every list: the account goes before the one
  /// it was dropped on, or after the last of the group.
  func testADragInsideAGroupLandsInTheOrderOfEveryList() {
    let a = UUID()
    let b = UUID()
    let c = UUID()
    let d = UUID()
    let e = UUID()
    // Every list: a (main), b, c, d, e; the group shows b and d.
    let ordered = [a, b, c, d, e]
    let group = [b, d]

    let down = SidebarOrder.move(in: group, from: [0], to: 2, ordered: ordered)
    XCTAssertEqual(down?.source, IndexSet([1]))
    XCTAssertEqual(down?.destination, 4, "after d, the last of the group")
    var list = ordered
    list.move(fromOffsets: down!.source, toOffset: down!.destination)
    XCTAssertEqual(list, [a, c, d, b, e])

    let up = SidebarOrder.move(in: group, from: [1], to: 0, ordered: ordered)
    XCTAssertEqual(up?.source, IndexSet([3]))
    XCTAssertEqual(up?.destination, 1, "before b")
    list = ordered
    list.move(fromOffsets: up!.source, toOffset: up!.destination)
    XCTAssertEqual(list, [a, d, b, c, e])

    XCTAssertNil(SidebarOrder.move(in: [], from: [0], to: 0, ordered: ordered))
  }

  /// «Выше» and «Ниже» move an account among the rows it is shown with, never past a row of
  /// another group the sidebar shows elsewhere, and never above the main account.
  func testUpAndDownMoveAnAccountWithinItsSection() {
    let main = UUID()
    let a = UUID()
    let x = UUID()
    let b = UUID()
    // Every list: main, a, x (of a group), b; the accounts of no group show main, a, b.
    let ordered = [main, a, x, b]
    let section = [main, a, b]

    let up = SidebarOrder.step(b, by: -1, in: section, main: main, ordered: ordered)
    var list = ordered
    list.move(fromOffsets: up!.source, toOffset: up!.destination)
    XCTAssertEqual(list.filter(section.contains), [main, b, a], "b goes above a, as shown")
    XCTAssertNil(
      SidebarOrder.step(a, by: -1, in: section, main: main, ordered: ordered),
      "nothing goes above the main account")
    XCTAssertNil(
      SidebarOrder.step(b, by: 1, in: section, main: main, ordered: ordered),
      "the last row has nowhere lower to go")

    let down = SidebarOrder.step(a, by: 1, in: section, main: main, ordered: ordered)
    list = ordered
    list.move(fromOffsets: down!.source, toOffset: down!.destination)
    XCTAssertEqual(list.filter(section.contains), [main, b, a], "a goes below b, as shown")
    XCTAssertNil(SidebarOrder.step(x, by: 1, in: [x], main: main, ordered: ordered))
  }

  /// What the choice of the sidebar means for the window: the account whose screen is open
  /// takes new operations, the journal gets a word and never a name, the screens of accounts
  /// list operations like «Операции», and a screen whose account or group is gone goes back to
  /// Overview.
  func testTheChoiceOfTheSidebarFocusesTheAccountAndFallsBackWhenItIsGone() {
    let id = UUID()
    let group = UUID()
    XCTAssertEqual(SidebarItem.account(id).focusedAccountId, id)
    XCTAssertNil(SidebarItem.group(group).focusedAccountId)
    XCTAssertNil(SidebarItem.section(.overview).focusedAccountId)

    XCTAssertEqual(SidebarItem.account(id).journalToken, "account")
    XCTAssertEqual(SidebarItem.group(group).journalToken, "group")
    XCTAssertEqual(SidebarItem.section(.planning).journalToken, "planning")

    // Overview shows tiles only: the list of operations is «Операции».
    XCTAssertTrue(SidebarItem.section(.operations).listsOperations)
    XCTAssertFalse(SidebarItem.section(.overview).listsOperations)
    XCTAssertFalse(SidebarItem.section(.planning).listsOperations)
    XCTAssertTrue(SidebarItem.allAccounts.listsOperations)
    XCTAssertTrue(SidebarItem.account(id).listsOperations)
    XCTAssertTrue(SidebarItem.group(group).listsOperations)
    XCTAssertFalse(SidebarItem.section(.debts).listsOperations)

    XCTAssertNil(SidebarItem.account(id).fallback(liveAccounts: [id], liveGroups: []))
    XCTAssertEqual(
      SidebarItem.account(id).fallback(liveAccounts: [], liveGroups: [group]),
      .section(.overview))
    XCTAssertEqual(
      SidebarItem.group(group).fallback(liveAccounts: [id], liveGroups: []), .section(.overview))
    XCTAssertNil(SidebarItem.section(.debts).fallback(liveAccounts: [], liveGroups: []))
  }

  /// The sidebar and the screens read the sections of the accounts from the snapshot: an
  /// excluded group comes last with its own total, out of «Всего».
  func testAnExcludedGroupComesLastWithItsOwnTotalOutOfTheTotal() throws {
    let kz = AccountGroup(name: "Казахстан", inSummary: false)
    var kaspi = self.kaspi
    kaspi.groupId = kz.id
    let at = Date(timeIntervalSince1970: 1_790_000_000)
    let count = Reconciliation(
      date: calendar.day(of: at), reconciledAt: at, actualTotalRubE4: .zero, kind: .accounts)
    let balances = [
      ReconciledBalance(
        reconciliationId: count.id, accountId: sber.id, currency: .rub,
        actualE4: AmountE4(whole: 1_000)),
      ReconciledBalance(
        reconciliationId: count.id, accountId: kaspi.id, currency: CurrencyCode("KZT"),
        actualE4: AmountE4(whole: 57_000)),
    ]
    let dataset = Dataset(
      paymentMethods: [kaspi, sber],
      planning: PlanningBook(
        reconciliations: [count], reconciledBalances: balances),
      accountGroups: [kz])
    let snapshot = AccountsSnapshot.build(
      dataset: dataset, now: at.addingTimeInterval(60), calendar: calendar,
      rubPerUnit: [CurrencyCode("KZT"): Decimal(string: "0.175")!], localeIdentifier: "ru")
    XCTAssertEqual(snapshot.sections.map(\.group?.name), [nil, "Казахстан"])
    XCTAssertEqual(snapshot.inSummaryTotalRub, AmountE4(whole: 1_000))
    XCTAssertEqual(snapshot.sections.last?.totalRub, AmountE4(whole: 9_975))
    XCTAssertEqual(snapshot.sections.last?.inSummary, false)
    XCTAssertEqual(
      SidebarFigure.of(
        try XCTUnwrap(snapshot.line(of: kaspi.id)), money: money, words: { $0 },
        withoutRate: withoutRate
      )
      .caption, "≈\u{00A0}9,975\u{00A0}₽")
  }

  // MARK: On screen

  /// The sidebar with its accounts, the screen of an account and that of a group, laid out in
  /// a window over a real database: every one of them gets the app's dependencies — its sheets
  /// too are handed them — and none changes state while it is drawn.
  func testTheSidebarAndTheScreensAreShownWithTheirDependencies() async throws {
    let missingBefore = AppDependencies.missingReaders
    AppDependencies.missingReaders = []
    defer { AppDependencies.missingReaders = missingBefore }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-account-screen-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    let environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    let store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
    let compute = ComputeStore(calendar: .system, rebuildsInline: true)
    defer {
      if let dataDirectoryBefore {
        setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
      } else {
        unsetenv("OHMYMONEY_DATA_DIR")
      }
      try? FileManager.default.removeItem(at: directory)
    }

    let kz = AccountGroup(name: "Казахстан", inSummary: false)
    let main = PaymentMethod(name: "Сбер", currency: .rub, isDefault: true)
    let freedom = PaymentMethod(
      name: "Freedom", currency: CurrencyCode("KZT"), groupId: kz.id, otherCurrencies: [.usd])
    let at = Date().addingTimeInterval(-3_600)
    let count = Reconciliation(
      date: environment.calendar.day(of: at), reconciledAt: at, actualTotalRubE4: .zero,
      kind: .accounts)
    XCTAssertTrue(
      store.apply(
        PlanningChange(
          upsert: PlanningRows(
            reconciliations: [count], accountGroups: [kz], paymentMethods: [main, freedom],
            reconciledBalances: [
              ReconciledBalance(
                reconciliationId: count.id, accountId: main.id, currency: .rub,
                actualE4: AmountE4(whole: 150_000)),
              ReconciledBalance(
                reconciliationId: count.id, accountId: freedom.id, currency: CurrencyCode("KZT"),
                actualE4: AmountE4(whole: 570_000)),
            ]))))
    let read = await AccountActions(environment: environment, store: store).books()
    let books = try XCTUnwrap(read)
    var form = TransferForm(from: main, accounts: [main, freedom], day: environment.today)
    form.chooseTo(freedom)
    form.toCurrency = CurrencyCode("KZT")
    form.sent = AmountE4(whole: 10_000)
    form.received = AmountE4(whole: 57_000)
    form.fee = AmountE4(whole: 99)
    XCTAssertEqual(
      TransferActions(environment: environment, store: store).save(
        form, occurredAt: Date(), books: books), .done)

    let dataset = try await DatasetRepository(writer: try XCTUnwrap(environment.stack).writer)
      .load(version: 0)
    compute.applyLight(
      DataSnapshot.build(
        dataset: dataset, calendar: environment.calendar, today: environment.today,
        context: SnapshotContext(
          rubPerUnit: [CurrencyCode("KZT"): Decimal(string: "0.175")!, .usd: 81],
          localeIdentifier: "ru"),
        version: DataVersion(load: 1)))
    let deps = AppDependencies(environment: environment, store: store, compute: compute)
    let actions = OperationActions()
    let probe = LogProbe()
    let before = probe.counts(of: [LogProbe.Message.stateDuringUpdate])

    await show(
      MainSidebar(selection: .constant(.account(main.id))).appDependencies(deps),
      width: 260, height: 520)
    await show(
      AccountScreen(accountId: freedom.id, actions: actions).appDependencies(deps),
      width: 820, height: 620)
    await show(
      GroupScreen(scope: .group(kz.id), actions: actions, openAccount: { _ in })
        .appDependencies(deps),
      width: 820, height: 620)
    await show(
      TransferSheet(form: form) { _ in }.appDependencies(deps),
      width: 460, height: 640)

    XCTAssertEqual(AppDependencies.missingReaders, [], "a view went without the dependencies")
    probe.assertQuiet(
      about: [LogProbe.Message.stateDuringUpdate], comparedWith: before, "the accounts' screens")
    await environment.close()
  }

  // MARK: Cards, cashback, payments

  /// The history names the card beside an operation only on an account with more than one
  /// card — archived ones counted —: one card alone says nothing its account does not.
  func testTheHistoryNamesTheCardOnlyWhereThereAreSeveral() {
    let black = PaymentCard(accountId: tbank.id, name: "Black")
    let old = PaymentCard(accountId: tbank.id, name: "Old", archived: true)
    let only = PaymentCard(accountId: sber.id, name: "Сбер")
    let cards = [black, old, only]
    XCTAssertEqual(
      AccountHistory.cardNames(of: [tbank.id, sber.id], cards: cards),
      [black.id: "Black", old.id: "Old"])
    XCTAssertEqual(AccountHistory.cardNames(of: [sber.id], cards: cards), [:])
  }

  /// The screen of «Т-Банк» over a real database: under its balances and forecast, «Карты»,
  /// «Кэшбэк · месяц» — 10 % of a coffee of 350 on Black is 35.00 expected, 20 received — and
  /// «Платежи и подписки» with the payment paid by Black, not Сбер's; laid out in a window, every
  /// block gets the dependencies.
  func testThePaymentsAndCashbackBlocksShowWhatTheAccountHas() async throws {
    self.executionTimeAllowance = 240
    let missingBefore = AppDependencies.missingReaders
    AppDependencies.missingReaders = []
    defer { AppDependencies.missingReaders = missingBefore }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-account-blocks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    let environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    let store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
    let compute = ComputeStore(calendar: .system, rebuildsInline: true)
    defer {
      if let dataDirectoryBefore {
        setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
      } else {
        unsetenv("OHMYMONEY_DATA_DIR")
      }
      try? FileManager.default.removeItem(at: directory)
    }

    let main = PaymentMethod(name: "Сбер", kind: .card, currency: .rub, isDefault: true)
    let tBank = PaymentMethod(name: "Т-Банк", kind: .card, currency: .rub)
    let black = PaymentCard(accountId: tBank.id, name: "Black")
    let virtual = PaymentCard(accountId: tBank.id, name: "Virtual")
    let cafes = CoreKit.Category(kind: .expense, name: "Кафе")
    let cashback = CoreKit.Category(kind: .income, name: "Кэшбэк")
    let today = environment.today
    let music = ScheduledPayment(
      name: "Музыка", amountE4: AmountE4(whole: 299), currency: .rub,
      paymentMethodId: tBank.id, nextDate: today, cardId: black.id)
    let gym = ScheduledPayment(
      name: "Спортзал", amountE4: AmountE4(whole: 3_000), currency: .rub,
      paymentMethodId: main.id, nextDate: today)
    XCTAssertTrue(
      store.apply(
        PlanningChange(
          upsert: PlanningRows(
            categories: [cafes, cashback], scheduled: [music, gym],
            paymentMethods: [main, tBank], cards: [black, virtual],
            cashbackRules: [
              CashbackRule(
                accountId: tBank.id, cardId: black.id, percent: CashbackPercent(e4: 100_000)!)
            ]))))
    try XCTUnwrap(environment.settings).set(
      AnalyticsSettings.cashbackCategoryKey, to: cashback.id.uuidString)
    let at = environment.calendar.noon(of: today)
    func operation(
      _ kind: TransactionKind, _ category: UUID, _ amount: Int64
    ) throws -> TransactionEntry {
      var draft = TransactionDraft(
        kind: kind, occurredAt: at, amount: AmountE4(whole: amount), paymentMethodId: tBank.id)
      draft.cardId = black.id
      draft.normalizeSinglePart()
      draft.parts[0].categoryId = category
      return try draft.materialize(now: at)
    }
    try XCTUnwrap(environment.transactions).insert([
      operation(.expense, cafes.id, 350), operation(.income, cashback.id, 20),
    ])

    let dataset = try await DatasetRepository(writer: try XCTUnwrap(environment.stack).writer)
      .load(version: 0)
    let snapshot = DataSnapshot.build(
      dataset: dataset, calendar: environment.calendar, today: today,
      context: SnapshotContext(rubPerUnit: [:], localeIdentifier: "ru"),
      version: DataVersion(load: 1))
    compute.applyLight(snapshot)

    let payments = AccountPaymentsModel(
      accountId: tBank.id, statuses: snapshot.planning.scheduled, cards: dataset.cards,
      mainAccountId: main.id)
    XCTAssertEqual(payments.rows.map(\.status.payment.name), ["Музыка"])
    XCTAssertEqual(payments.rows.first?.cardName, "Black")
    let cashbackLines = AccountCashbackModel.build(
      month: today.monthKey, accountId: tBank.id, ledger: snapshot.ledger, today: today
    ).lines
    let line = try XCTUnwrap(cashbackLines.first { $0.cardId == black.id })
    XCTAssertEqual(line.expected, [Money(amount: AmountE4(whole: 35), currency: .rub)])
    XCTAssertEqual(line.received, [Money(amount: AmountE4(whole: 20), currency: .rub)])

    let deps = AppDependencies(environment: environment, store: store, compute: compute)
    await show(
      AccountScreen(accountId: tBank.id, actions: OperationActions()).appDependencies(deps),
      width: 820, height: 900)
    XCTAssertEqual(AppDependencies.missingReaders, [], "a block went without the dependencies")
    await environment.close()
  }

  /// The window opened on the screen of an account tells the entry line which account a new
  /// operation goes to; closed, it tells nothing.
  func testTheScreenOfAnAccountFocusesTheEntryLineOnIt() async {
    let environment = AppEnvironment()
    let deps = AppDependencies(
      environment: environment, store: TransactionsStore(),
      compute: ComputeStore(calendar: .system))
    let id = UUID()
    await show(
      AppScenes.root(deps, window: .main, launches: false) {
        MainWindow(deps: $0, selection: .account(id))
      },
      width: 1_000, height: 700)
    XCTAssertNil(environment.focusedAccountId, "the window went, and the focus with it")

    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 1_000, height: 700), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    // dependencies: the root is built by `AppScenes.root`, which hands them over
    window.contentView = NSHostingView(
      rootView: AppScenes.root(deps, window: .main, launches: false) {
        MainWindow(deps: $0, selection: .account(id))
      })
    window.orderFront(nil)
    for _ in 0..<6 { try? await Task.sleep(for: .milliseconds(50)) }
    XCTAssertEqual(environment.focusedAccountId, id)
    window.contentView = nil
    window.close()
  }

  /// Two main windows on two accounts: the one opened last holds the focus, and closing the
  /// other leaves it — a window takes back only the focus it gave.
  func testClosingOneMainWindowLeavesTheFocusOfAnother() async {
    let environment = AppEnvironment()
    let deps = AppDependencies(
      environment: environment, store: TransactionsStore(),
      compute: ComputeStore(calendar: .system))
    let first = UUID()
    let second = UUID()
    let one = mainWindow(deps, on: .account(first))
    for _ in 0..<6 { try? await Task.sleep(for: .milliseconds(50)) }
    XCTAssertEqual(environment.focusedAccountId, first)
    let two = mainWindow(deps, on: .account(second))
    for _ in 0..<6 { try? await Task.sleep(for: .milliseconds(50)) }
    XCTAssertEqual(environment.focusedAccountId, second)

    one.contentView = nil
    one.close()
    for _ in 0..<6 { try? await Task.sleep(for: .milliseconds(50)) }
    XCTAssertEqual(
      environment.focusedAccountId, second, "the other window's account keeps the entry line")
    two.contentView = nil
    two.close()
    for _ in 0..<6 { try? await Task.sleep(for: .milliseconds(50)) }
    XCTAssertNil(environment.focusedAccountId, "the last window takes its own focus along")
  }

  private func mainWindow(_ deps: AppDependencies, on selection: SidebarItem) -> NSWindow {
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 1_000, height: 700), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    // dependencies: the root is built by `AppScenes.root`, which hands them over
    window.contentView = NSHostingView(
      rootView: AppScenes.root(deps, window: .main, launches: false) {
        MainWindow(deps: $0, selection: selection)
      })
    window.orderFront(nil)
    return window
  }

  /// Lays the view out in a window and lets its tasks finish — the history, the books of the
  /// sheet — suspended rather than spun, so they run on the main actor this test runs on.
  private func show<V: View>(_ view: V, width: CGFloat, height: CGFloat) async {
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    // dependencies: every view given here was handed them by the caller
    window.contentView = NSHostingView(rootView: view)
    window.orderFront(nil)
    defer {
      window.contentView = nil
      window.close()
    }
    for _ in 0..<10 { try? await Task.sleep(for: .milliseconds(50)) }
    window.layoutIfNeeded()
  }

  // MARK: Helpers

  private let withoutRate: (String) -> String = { "without rate: \($0)" }

  private func expense(
    _ whole: Int64, on day: DateOnly, hour: Int, account: UUID?
  ) throws
    -> TransactionEntry
  {
    var draft = TransactionDraft(
      occurredAt: calendar.startOfDay(day).addingTimeInterval(TimeInterval(hour * 3_600)),
      amount: AmountE4(whole: whole), paymentMethodId: account)
    draft.normalizeSinglePart()
    return try draft.materialize(now: draft.occurredAt)
  }

  private func transfer(
    from: UUID, to: UUID, _ whole: Int64, on day: DateOnly, hour: Int
  ) -> Transfer {
    let at = calendar.startOfDay(day).addingTimeInterval(TimeInterval(hour * 3_600))
    return Transfer(
      occurredAt: at, fromAccountId: from, fromCurrency: .rub, fromAmountE4: AmountE4(whole: whole),
      toAccountId: to, toCurrency: .rub, toAmountE4: AmountE4(whole: whole), createdAt: at,
      updatedAt: at)
  }

  private func key(
    _ account: PaymentMethod, _ currency: CurrencyCode, balance: String?, rub: String?
  ) -> AccountsSnapshot.KeyLine {
    AccountsSnapshot.KeyLine(
      key: BalanceKey(accountId: account.id, currency: currency),
      balance: balance.flatMap { Decimal(string: $0) }.flatMap { try? AmountE4(decimal: $0) },
      rub: rub.flatMap { Decimal(string: $0) }.flatMap { try? AmountE4(decimal: $0) },
      anchorAt: nil, isHeld: true)
  }
}
