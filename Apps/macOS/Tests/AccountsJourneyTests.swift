import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The accounts end to end, as the owner would live through a month of them, against a real
/// database and the actions the screens call: accounts in several currencies and groups (one
/// left out of the summary), opening balances, operations, a transfer with a fee, an exchange
/// inside one account, the reconciliation sheet, the free sum and the sidebar — and ⌘Z.
///
/// Every figure is checked against arithmetic done by hand in the test, never against another
/// figure of the app: the money now is the counts plus every real movement after them, in
/// rubles at today's rate; a group left out of the summary is shown apart with its own total.
///
/// The clock stands still at noon of 16 September 2026 (a Wednesday), so the day, the month and
/// D are the same whenever the test runs; accounts are made at 06:00 of that day, so what they
/// were opened with is counted before the moves of the day. Rates: 1 $ = 90 ₽, 1 ₸ = 0.2 ₽.
@MainActor
final class AccountsJourneyTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  private let kzt = CurrencyCode("KZT")
  private let today = DateOnly(year: 2026, month: 9, day: 16)
  private var rates: [CurrencyCode: Decimal] = [
    .usd: 90, CurrencyCode("KZT"): Decimal(string: "0.2")!,
  ]
  private var noon: Date { environment.calendar.noon(of: today) }
  /// The clock of the app: noon, except while an account is made at 06:00 (`make`).
  private var moment = Date()

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-journey-\(UUID().uuidString)", isDirectory: true)
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
    compute = ComputeStore(calendar: environment.calendar, rebuildsInline: true)
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

  // MARK: The accounts of the month

  /// Сбер (main, ₽), Наличные (₽), Freedom ($ and ₸) in «Казахстан», a group left out of the
  /// summary. Each account is made through the editor with its balance now, which is its first
  /// count: nothing is compared, nothing is written but the count.
  private struct Books {
    var sber: PaymentMethod
    var cash: PaymentMethod
    var freedom: PaymentMethod
    var kazakhstan: AccountGroup
  }

  private func openTheBooks() async throws -> Books {
    let kazakhstan = AccountGroup(name: "Казахстан", inSummary: false)
    XCTAssertEqual(accounts.save(group: kazakhstan), .done)
    let sber = try await make(
      PaymentMethod(name: "Сбер", currency: .rub, isDefault: true),
      openings: [.rub: AmountE4(whole: 100_000)])
    let cash = try await make(
      PaymentMethod(name: "Наличные", kind: .cash, currency: .rub),
      openings: [.rub: AmountE4(whole: 5_000)])
    let freedom = try await make(
      PaymentMethod(
        name: "Freedom", currency: .usd, groupId: kazakhstan.id, otherCurrencies: [kzt]),
      openings: [.usd: AmountE4(whole: 1_000), kzt: AmountE4(whole: 200_000)])
    return Books(sber: sber, cash: cash, freedom: freedom, kazakhstan: kazakhstan)
  }

  /// The month after the opening counts, each move one action of its screen:
  /// −3 000 ₽ coffee and groceries on Сбер, +50 000 ₽ salary on Сбер, 10 000 ₽ from Сбер to
  /// the cash with a 100 ₽ fee, 100 $ changed into 48 000 ₸ inside Freedom, and 20 $ paid with
  /// the ruble card, the bank charging 1 850 ₽.
  private func liveTheMonth(_ books: Books) async throws {
    try spend(3_000, on: books.sber.id, at: noon.addingTimeInterval(-5 * 3_600))
    try earn(50_000, on: books.sber.id, at: noon.addingTimeInterval(-4 * 3_600))
    try await transfer(
      from: books.sber, .rub, to: books.cash, .rub, sent: 10_000, fee: 100,
      at: noon.addingTimeInterval(-3 * 3_600))
    try await transfer(
      from: books.freedom, .usd, to: books.freedom, kzt, sent: 100, received: 48_000,
      at: noon.addingTimeInterval(-2 * 3_600))
    try spend(
      20, currency: .usd, charged: 1_850, on: books.sber.id,
      at: noon.addingTimeInterval(-3_600))
  }

  /// What the month leaves on each balance, worked out by hand.
  private let sberAfter: Int64 = 100_000 - 3_000 + 50_000 - 10_000 - 100 - 1_850  // 135 050
  private let cashAfter: Int64 = 5_000 + 10_000  // 15 000
  private let usdAfter: Int64 = 1_000 - 100  // 900
  private let kztAfter: Int64 = 200_000 + 48_000  // 248 000
  /// 900 × 90 + 248 000 × 0.2
  private let kazakhstanAfter: Int64 = 81_000 + 49_600

  /// The balances typed in the editor are the first counts: the money now is exactly them,
  /// the group left out is apart with its own total, the sheet expects each of them, and
  /// nothing was written as an operation.
  func testTheOpeningBalancesAreTheStartingPointAndTheMoneyNow() async throws {
    let books = try await openTheBooks()
    let snapshot = try await show()

    let free = snapshot.planning.freeMoney
    XCTAssertEqual(free.state, .ready)
    XCTAssertEqual(free.main, AmountE4(whole: 105_000), "Сбер 100 000 + cash 5 000")
    XCTAssertEqual(free.excluded.map(\.group.id), [books.kazakhstan.id])
    XCTAssertEqual(
      free.excluded.first?.totalRub, AmountE4(whole: 90_000 + 40_000),
      "1 000 $ × 90 + 200 000 ₸ × 0.2, apart")
    XCTAssertTrue(free.unanchored.isEmpty, "every balance was counted when it was made")

    let book = try XCTUnwrap(environment.planning).book()
    XCTAssertTrue(book.reconciledBalances.allSatisfy(\.isStartingPoint))
    XCTAssertEqual(book.reconciledBalances.count, 4)
    XCTAssertTrue(try entries().isEmpty, "an opening balance is no income")

    let rows = sheet(snapshot)
    XCTAssertEqual(rows.count, 4, "every account × each of its currencies")
    XCTAssertEqual(expected(rows, books.sber.id, .rub), AmountE4(whole: 100_000))
    XCTAssertEqual(expected(rows, books.cash.id, .rub), AmountE4(whole: 5_000))
    XCTAssertEqual(expected(rows, books.freedom.id, .usd), AmountE4(whole: 1_000))
    XCTAssertEqual(expected(rows, books.freedom.id, kzt), AmountE4(whole: 200_000))
    XCTAssertEqual(
      rows.filter { !$0.isInSummary }.map(\.key.accountId), [books.freedom.id, books.freedom.id],
      "Freedom's rows say they are out of the summary")
  }

  /// After a month of moves every balance is what the arithmetic says: a transfer moves money
  /// and is spent by nobody, its fee is spent, an exchange keeps both amounts, a dollar
  /// purchase on the ruble card takes what the bank charged. The sheet expects exactly that,
  /// so saving it untouched with «Записать разницу» writes nothing.
  func testAMonthOfMovesAddsUpOnEveryBalanceAndTheSheetFindsNoDifference() async throws {
    let books = try await openTheBooks()
    try await liveTheMonth(books)
    let snapshot = try await show()

    let free = snapshot.planning.freeMoney
    XCTAssertEqual(free.main, AmountE4(whole: sberAfter + cashAfter), "135 050 + 15 000")
    XCTAssertEqual(free.excluded.first?.totalRub, AmountE4(whole: kazakhstanAfter))

    let rows = sheet(snapshot)
    XCTAssertEqual(expected(rows, books.sber.id, .rub), AmountE4(whole: sberAfter))
    XCTAssertEqual(expected(rows, books.cash.id, .rub), AmountE4(whole: cashAfter))
    XCTAssertEqual(expected(rows, books.freedom.id, .usd), AmountE4(whole: usdAfter))
    XCTAssertEqual(expected(rows, books.freedom.id, kzt), AmountE4(whole: kztAfter))

    let before = try entries().count
    let saved = try await saveSheet(typed: [:], record: true)
    XCTAssertNil(saved)
    XCTAssertEqual(try entries().count, before, "a sheet left as expected wrote a difference")
    let book = try XCTUnwrap(environment.planning).book()
    let latest = book.reconciledBalances.filter { !$0.isStartingPoint }
    XCTAssertEqual(latest.count, 4)
    XCTAssertTrue(latest.allSatisfy { $0.differenceE4 == .zero }, "\(latest)")

    let after = try await show()
    XCTAssertEqual(after.planning.freeMoney.main, free.main, "the count changed the money")

    // The month's spending: the coffee and the dollar purchase and the fee — not the transfer,
    // not the exchange.
    XCTAssertEqual(
      after.summary.expenses.current, AmountE4(whole: 3_000 + 1_850 + 100),
      "a transfer or an exchange was counted as spending")
    XCTAssertEqual(after.summary.income.current, AmountE4(whole: 50_000))
  }

  /// A later count is compared: 50 ₽ missing on Сбер is one expense of 50 ₽ on Сбер, in ₽, at
  /// the moment of the count, in «Сверка»; the other balances counted as expected write
  /// nothing. Right after, the money now is the count. One ⌘Z takes the whole sheet back.
  func testALaterCountWritesOnlyTheMoneyMissingOnItsAccount() async throws {
    let books = try await openTheBooks()
    try await liveTheMonth(books)
    let before = try entries().count
    let sberKey = BalanceKey(accountId: books.sber.id, currency: .rub)

    let saved = try await saveSheet(
      typed: [sberKey: AmountE4(whole: sberAfter - 50)], record: true)
    XCTAssertNil(saved)
    let written = try entries()
    XCTAssertEqual(written.count, before + 1, "one difference, one operation")
    let difference = try XCTUnwrap(written.first { $0.transaction.occurredAt == noon })
    XCTAssertEqual(difference.transaction.kind, .expense)
    XCTAssertEqual(difference.transaction.amountE4, AmountE4(whole: 50))
    XCTAssertEqual(difference.transaction.currency, .rub)
    XCTAssertEqual(difference.transaction.paymentMethodId, books.sber.id)

    let after = try await show()
    XCTAssertEqual(
      after.planning.freeMoney.main, AmountE4(whole: sberAfter - 50 + cashAfter),
      "right after the count the money now is the count")
    XCTAssertEqual(
      expected(sheet(after), books.sber.id, .rub), AmountE4(whole: sberAfter - 50),
      "the next sheet expects what was counted")

    store.undo()
    XCTAssertEqual(try entries().count, before, "⌘Z left the difference")
    let undone = try await show()
    XCTAssertEqual(undone.planning.freeMoney.main, AmountE4(whole: sberAfter + cashAfter))
    let book = try XCTUnwrap(environment.planning).book()
    XCTAssertTrue(
      book.reconciledBalances.allSatisfy(\.isStartingPoint), "⌘Z left part of the sheet")
  }

  /// Money found on the cash — 700 ₽ more than the books — is income of 700 ₽ on the cash in
  /// the income twin of «Сверка»; a dollar difference on Freedom is written in dollars on
  /// Freedom, though Freedom is out of the summary.
  func testMoreMoneyAndAForeignDifferenceAreWrittenInTheirOwnCurrencyAndAccount() async throws {
    let books = try await openTheBooks()
    try await liveTheMonth(books)
    let cashKey = BalanceKey(accountId: books.cash.id, currency: .rub)
    let usdKey = BalanceKey(accountId: books.freedom.id, currency: .usd)
    let saved = try await saveSheet(
      typed: [cashKey: AmountE4(whole: cashAfter + 700), usdKey: AmountE4(whole: usdAfter - 12)],
      record: true)
    XCTAssertNil(saved)
    let differences = try entries().filter { $0.transaction.occurredAt == noon }
    XCTAssertEqual(differences.count, 2)
    let found = try XCTUnwrap(differences.first { $0.transaction.paymentMethodId == books.cash.id })
    XCTAssertEqual(found.transaction.kind, .income)
    XCTAssertEqual(found.transaction.amountE4, AmountE4(whole: 700))
    XCTAssertEqual(found.transaction.currency, .rub)
    let lost = try XCTUnwrap(
      differences.first { $0.transaction.paymentMethodId == books.freedom.id })
    XCTAssertEqual(lost.transaction.kind, .expense)
    XCTAssertEqual(lost.transaction.amountE4, AmountE4(whole: 12))
    XCTAssertEqual(lost.transaction.currency, .usd, "a dollar difference turned into rubles")
    XCTAssertNil(lost.transaction.accountAmountE4, "Freedom holds dollars: nothing apart")

    let after = try await show()
    XCTAssertEqual(after.planning.freeMoney.main, AmountE4(whole: sberAfter + cashAfter + 700))
    XCTAssertEqual(
      after.planning.freeMoney.excluded.first?.totalRub,
      AmountE4(whole: (usdAfter - 12) * 90 + kztAfter / 5))
  }

  // MARK: Rates are never a difference

  /// 1 000 $ counted when a dollar was 90 ₽ and counted again as 1 000 $ when it is 100 ₽: the
  /// money now in rubles follows the rate, but the sheet expects 1 000 $ and writes nothing —
  /// the rate moved, not the money.
  func testARateMoveIsNeverADifference() async throws {
    let main = try await make(
      PaymentMethod(name: "Сбер", currency: .rub, isDefault: true),
      openings: [.rub: AmountE4(whole: 10_000)])
    let wise = try await make(
      PaymentMethod(name: "Wise", currency: .usd), openings: [.usd: AmountE4(whole: 1_000)])
    let at90 = try await show()
    XCTAssertEqual(at90.planning.freeMoney.main, AmountE4(whole: 10_000 + 90_000))

    rates[.usd] = 100
    let at100 = try await show()
    XCTAssertEqual(
      at100.planning.freeMoney.main, AmountE4(whole: 10_000 + 100_000),
      "the money now is converted at today's rate")
    let rows = sheet(at100)
    XCTAssertEqual(expected(rows, wise.id, .usd), AmountE4(whole: 1_000), "expected in dollars")
    XCTAssertFalse(
      ReconcileSheet.differs(
        rows: rows,
        counted: [BalanceKey(accountId: wise.id, currency: .usd): AmountE4(whole: 1_000)]))

    let saved = try await saveSheet(typed: [:], record: true)
    XCTAssertNil(saved)
    XCTAssertTrue(try entries().isEmpty, "a rate move was written as a difference")
    let book = try XCTUnwrap(environment.planning).book()
    XCTAssertTrue(
      book.reconciledBalances.filter { !$0.isStartingPoint }.allSatisfy { $0.differenceE4 == .zero }
    )
    _ = main
  }

  // MARK: The question «Это было до сверки?»

  /// Counted 20 000 ₽ at 11:00; a 500 ₽ coffee of 11:30 typed afterwards. «Да» stamps it just
  /// before the count, so the count already holds it and the money now stays 20 000 ₽; «Нет»
  /// keeps it after the count, and the money now is 19 500 ₽. Neither moves it to another day.
  func testTheAnswerAboutTheCountDecidesWhetherTheCountHoldsTheOperation() async throws {
    let sber = try await make(PaymentMethod(name: "Сбер", currency: .rub, isDefault: true))
    let counted = noon.addingTimeInterval(-3_600)
    let key = BalanceKey(accountId: sber.id, currency: .rub)
    let saved = try await saveSheet(
      typed: [key: AmountE4(whole: 20_000)], record: true, at: counted)
    XCTAssertNil(saved)

    let typedAt = noon.addingTimeInterval(-1_800)
    let yes = AccountReconciliation.stamped(
      occurredAt: typedAt, count: counted, wasBefore: true, calendar: environment.calendar)
    XCTAssertLessThan(yes, counted)
    XCTAssertEqual(environment.calendar.day(of: yes), today)
    let coffee = try spend(500, on: sber.id, at: yes)
    let inside = try await show()
    XCTAssertEqual(
      inside.planning.freeMoney.main, AmountE4(whole: 20_000),
      "an operation from before the count was taken off the count again")

    XCTAssertTrue(store.delete(id: coffee.id))
    let no = AccountReconciliation.stamped(
      occurredAt: typedAt, count: counted, wasBefore: false, calendar: environment.calendar)
    XCTAssertGreaterThan(no, counted)
    try spend(500, on: sber.id, at: no)
    let outside = try await show()
    XCTAssertEqual(outside.planning.freeMoney.main, AmountE4(whole: 19_500))
  }

  // MARK: A group left out of the summary

  /// «Учитывать в общей сводке» off: the group's money leaves the free sum and is shown apart
  /// with its own total, while its spending still counts in the month's figures of Overview.
  /// On again, it is back; each switch is one step of ⌘Z.
  func testAGroupLeftOutTakesItsMoneyOutButNotItsSpending() async throws {
    let group = AccountGroup(name: "Семья", inSummary: true)
    XCTAssertEqual(accounts.save(group: group), .done)
    let sber = try await make(
      PaymentMethod(name: "Сбер", currency: .rub, isDefault: true),
      openings: [.rub: AmountE4(whole: 40_000)])
    let family = try await make(
      PaymentMethod(name: "Общий", currency: .rub, groupId: group.id),
      openings: [.rub: AmountE4(whole: 25_000)])
    try spend(2_000, on: family.id, at: noon.addingTimeInterval(-600))

    let inside = try await show()
    XCTAssertEqual(inside.planning.freeMoney.main, AmountE4(whole: 40_000 + 23_000))
    XCTAssertTrue(inside.planning.freeMoney.excluded.isEmpty)
    XCTAssertEqual(inside.summary.expenses.current, AmountE4(whole: 2_000))

    XCTAssertEqual(accounts.setInSummary(group.id, false), .done)
    let apart = try await show()
    XCTAssertEqual(apart.planning.freeMoney.main, AmountE4(whole: 40_000))
    XCTAssertEqual(apart.planning.freeMoney.excluded.map(\.group.id), [group.id])
    XCTAssertEqual(apart.planning.freeMoney.excluded.first?.totalRub, AmountE4(whole: 23_000))
    XCTAssertEqual(
      apart.summary.expenses.current, AmountE4(whole: 2_000),
      "a group left out hides its money, never its spending")
    let sections = apart.planning.accounts.ordered(locale: Locale(identifier: "ru")).sections
    XCTAssertEqual(sections.last?.group?.id, group.id, "a group left out comes last")
    XCTAssertEqual(sections.last?.inSummary, false)
    XCTAssertEqual(apart.planning.accounts.inSummaryTotalRub, AmountE4(whole: 40_000))

    store.undo()
    let back = try await show()
    XCTAssertEqual(back.planning.freeMoney.main, AmountE4(whole: 63_000), "one ⌘Z, one switch")
    _ = sber
  }

  // MARK: Merge, archive, delete

  /// The cash merged into Сбер: the money now does not move by a kopeck. The transfer between
  /// the two goes (it would move money from Сбер to itself), but the fee the bank took for it
  /// stays spent — it left the account for good.
  func testAMergeKeepsTheMoneyNowAndTheFeeOfATransferBetweenTheTwo() async throws {
    let books = try await openTheBooks()
    try await liveTheMonth(books)
    let before = try await show()
    XCTAssertEqual(before.planning.freeMoney.main, AmountE4(whole: sberAfter + cashAfter))

    let current = try await freshBooks()
    try inOneBank(books.cash.id, books.sber.id)
    let preview = try XCTUnwrap(
      accounts.mergePreview(books.cash.id, into: books.sber.id, books: current))
    XCTAssertEqual(preview.deletedTransfers, 1)
    XCTAssertEqual(accounts.merge(preview), .done)

    let after = try await show()
    XCTAssertEqual(
      after.planning.freeMoney.main, AmountE4(whole: sberAfter + cashAfter),
      "a merge made money appear or vanish")
    let merged = try await freshBooks()
    XCTAssertEqual(
      merged.balances.balance(BalanceKey(accountId: books.sber.id, currency: .rub), at: noon),
      AmountE4(whole: sberAfter + cashAfter))
    XCTAssertEqual(
      after.summary.expenses.current, AmountE4(whole: 3_000 + 1_850 + 100),
      "the fee stays spent after the transfer went")
    XCTAssertTrue(
      merged.dataset.transfers.allSatisfy {
        $0.fromAccountId != $0.toAccountId || $0.fromCurrency != $0.toCurrency
      })
  }

  /// A dollar account merged into the ruble main one: the main one takes the dollars as a
  /// currency of its own, and the dollars keep their balance.
  func testAForeignAccountMergedIntoTheMainOneBringsItsCurrency() async throws {
    let sber = try await make(
      PaymentMethod(name: "Сбер", currency: .rub, isDefault: true),
      openings: [.rub: AmountE4(whole: 10_000)])
    let wise = try await make(
      PaymentMethod(name: "Wise", currency: .usd), openings: [.usd: AmountE4(whole: 300)])
    try spend(50, currency: .usd, on: wise.id, at: noon.addingTimeInterval(-600))
    let before = try await show()
    XCTAssertEqual(before.planning.freeMoney.main, AmountE4(whole: 10_000 + 250 * 90))

    let books = try await freshBooks()
    try inOneBank(wise.id, sber.id)
    let preview = try XCTUnwrap(accounts.mergePreview(wise.id, into: sber.id, books: books))
    XCTAssertTrue(preview.needsBalance.isEmpty, "\(preview.needsBalance)")
    XCTAssertEqual(accounts.merge(preview), .done)

    let stored = try XCTUnwrap(accounts.all.first { $0.id == sber.id })
    XCTAssertEqual(stored.mainCurrency, .rub, "the main currency stays the target's")
    XCTAssertTrue(stored.holds(.usd))
    XCTAssertTrue(stored.isDefault)
    let after = try await show()
    XCTAssertEqual(after.planning.freeMoney.main, AmountE4(whole: 10_000 + 250 * 90))
    let rows = sheet(after)
    XCTAssertEqual(expected(rows, sber.id, .usd), AmountE4(whole: 250))
    XCTAssertNil(rows.first { $0.key.accountId == wise.id }, "the merged account is still counted")
  }

  /// Money on the cash keeps it out of the archive. «Перевести остаток…» moves all of it to
  /// the main account; then the cash goes to the archive, the money now has not moved, the
  /// sheet has no row for it, and its history is still there. ⌘Z brings it back.
  func testAnAccountGoesToTheArchiveOnlyOnceItsMoneyIsMovedAway() async throws {
    let books = try await openTheBooks()
    try await liveTheMonth(books)
    let full = try await freshBooks()
    XCTAssertEqual(accounts.archive(books.cash.id, books: full), .refused(.hasMoney))

    let form = TransferForm(
      movingBalanceOf: books.cash, balances: full.balances, accounts: accounts.all,
      day: today)
    XCTAssertEqual(form.toAccountId, books.sber.id)
    XCTAssertEqual(form.sent, AmountE4(whole: cashAfter))
    XCTAssertEqual(
      transfers.save(
        form, occurredAt: form.occurredAt(now: noon, calendar: environment.calendar), books: full),
      .done)

    let empty = try await freshBooks()
    XCTAssertEqual(accounts.archive(books.cash.id, books: empty), .done)
    let after = try await show()
    XCTAssertEqual(after.planning.freeMoney.main, AmountE4(whole: sberAfter + cashAfter))
    XCTAssertNil(
      sheet(after).first { $0.key.accountId == books.cash.id },
      "an empty account in the archive is still on the sheet")
    let history = AccountHistory.build(
      accountIds: [books.cash.id], dataset: after.dataset, calendar: environment.calendar)
    XCTAssertEqual(history.days.flatMap(\.items).count, 2, "both transfers of the cash")

    store.undo()
    XCTAssertEqual(accounts.all.first { $0.id == books.cash.id }?.archived, false)
  }

  /// Only an account nothing points at is deleted; one with an operation is offered the
  /// archive or a merge instead. A group is deleted only once nothing is filed under it.
  func testOnlyWhatNothingPointsAtIsDeleted() async throws {
    let books = try await openTheBooks()
    try await liveTheMonth(books)
    let spare = try await make(PaymentMethod(name: "Запасная", currency: .rub))

    guard case .refused(.inUse(let id, _)) = accounts.delete([books.cash.id]) else {
      return XCTFail("an account with transfers was deleted")
    }
    XCTAssertEqual(id, books.cash.id)
    XCTAssertEqual(accounts.deleteGroup(books.kazakhstan.id), .refused(.groupInUse))

    XCTAssertEqual(accounts.delete([spare.id]), .done)
    XCTAssertNil(accounts.all.first { $0.id == spare.id })
    let after = try await show()
    XCTAssertEqual(after.planning.freeMoney.main, AmountE4(whole: sberAfter + cashAfter))
  }

  // MARK: The free sum

  /// The free sum until D with a bill, a goal and an event:
  /// money now 105 000 ₽; a 7 000 ₽ bill due on the 20th; a goal planned at 10 000 ₽ a month
  /// with 4 000 ₽ put in this month; a trip on the 25th with a 5 000 ₽ budget.
  /// D = 30 September: grey = 105 000 − 7 000 − 4 000 saved − 6 000 still planned − 5 000.
  /// The contribution leaves the grey line as it was — before it the grey line took 10 000 of
  /// plan and nothing saved —, while the main figure no longer counts the 4 000 ₽ in the goal
  /// as money to spend (101 000). D = 31 October adds the next bill and a full month of the
  /// plan.
  func testTheGreyLineTakesTheBillTheGoalAndTheTripAndAContributionLeavesItAsItWas() async throws {
    let books = try await openTheBooks()
    let bill = ScheduledPayment(
      name: "Аренда", amountE4: AmountE4(whole: 7_000), paymentMethodId: books.sber.id,
      day: 20, nextDate: DateOnly(year: 2026, month: 9, day: 20))
    XCTAssertTrue(planning.save(bill, previous: nil))
    let goal = Goal(
      name: "Отпуск", targetE4: AmountE4(whole: 200_000), monthlyPlanE4: AmountE4(whole: 10_000))
    _ = try await show()
    XCTAssertTrue(planning.save(goal))
    let trip = Event(
      name: "Поездка", startDate: DateOnly(year: 2026, month: 9, day: 25),
      endDate: DateOnly(year: 2026, month: 9, day: 27), budgetE4: AmountE4(whole: 5_000))
    XCTAssertTrue(planning.save(trip))

    let first = try await show()
    let untilMonthEnd = first.planning.freeMoney
    XCTAssertEqual(untilMonthEnd.until, DateOnly(year: 2026, month: 9, day: 30))
    XCTAssertEqual(untilMonthEnd.main, AmountE4(whole: 105_000))
    XCTAssertEqual(untilMonthEnd.grey, AmountE4(whole: 105_000 - 7_000 - 10_000 - 5_000))
    XCTAssertEqual(untilMonthEnd.days, 15, "16…30 September, today included")

    let stored = try XCTUnwrap(try environment.references?.goals().first { $0.id == goal.id })
    XCTAssertTrue(
      planning.move(
        stored, amount: AmountE4(whole: 4_000), currency: .rub,
        on: noon.addingTimeInterval(-600), account: books.sber.id, withdraw: false))
    let second = try await show()
    let after = second.planning.freeMoney
    XCTAssertEqual(
      after.main, AmountE4(whole: 101_000), "the 4 000 ₽ put into the goal are not to be spent")
    XCTAssertEqual(after.plan.goalSavings, AmountE4(whole: 4_000))
    XCTAssertEqual(after.plan.goalPlans, AmountE4(whole: 6_000))
    XCTAssertEqual(after.grey, untilMonthEnd.grey, "a contribution changed what is free")
    XCTAssertEqual(
      after.grey.map { $0 + AmountE4.sum(after.lines.map(\.amount)) }, after.main,
      "the lines do not add up to the grey line")

    let october = second.planning.freeMoney(
      until: DateOnly(year: 2026, month: 10, day: 31), ledger: second.ledger)
    XCTAssertEqual(
      october.grey,
      AmountE4(whole: 105_000 - 2 * 7_000 - 4_000 - (6_000 + 10_000) - 5_000),
      "a later D takes the October bill and a full month of the plan")
    XCTAssertEqual(october.days, 46)

    let farAway = second.planning.freeMoney(
      until: DateOnly(year: 2028, month: 1, day: 1), ledger: second.ledger)
    XCTAssertEqual(farAway.until, DateOnly(year: 2027, month: 9, day: 16), "D is a year at most")
  }

  /// «Деньги целей лежат на счетах в сводке» on: the 4 000 ₽ in the goal are no money to spend
  /// (101 000). Off: the goal money is taken to be elsewhere, so neither the main figure nor
  /// the grey line takes it away; the plans still are.
  func testTheSwitchOfTheGoalMoneyStopsTakingTheSavingsAway() async throws {
    let books = try await openTheBooks()
    let goal = Goal(
      name: "Отпуск", targetE4: AmountE4(whole: 200_000), monthlyPlanE4: AmountE4(whole: 10_000))
    _ = try await show()
    XCTAssertTrue(planning.save(goal))
    let stored = try XCTUnwrap(try environment.references?.goals().first { $0.id == goal.id })
    XCTAssertTrue(
      planning.move(
        stored, amount: AmountE4(whole: 4_000), currency: .rub,
        on: noon.addingTimeInterval(-600), account: books.sber.id, withdraw: false))
    let on = try await show()
    XCTAssertEqual(on.planning.freeMoney.main, AmountE4(whole: 105_000 - 4_000))
    XCTAssertEqual(on.planning.freeMoney.grey, AmountE4(whole: 105_000 - 4_000 - 6_000))

    try XCTUnwrap(environment.settings).set(
      PlanningSettings.reconcileIncludesGoalSavingsKey, to: "0")
    let off = try await show()
    XCTAssertEqual(off.planning.freeMoney.main, AmountE4(whole: 105_000))
    XCTAssertEqual(
      off.planning.freeMoney.grey, AmountE4(whole: 105_000 - 6_000),
      "the savings are still taken away with the switch off")
  }

  /// The switch of the block — hold this month's goal plans back — off: the 6 000 ₽ still
  /// planned is not taken away, the 4 000 ₽ saved still is.
  func testTheSwitchOfTheGoalPlansStopsHoldingThePlanBack() async throws {
    let books = try await openTheBooks()
    let goal = Goal(
      name: "Отпуск", targetE4: AmountE4(whole: 200_000), monthlyPlanE4: AmountE4(whole: 10_000))
    _ = try await show()
    XCTAssertTrue(planning.save(goal))
    let stored = try XCTUnwrap(try environment.references?.goals().first { $0.id == goal.id })
    XCTAssertTrue(
      planning.move(
        stored, amount: AmountE4(whole: 4_000), currency: .rub,
        on: noon.addingTimeInterval(-600), account: books.sber.id, withdraw: false))
    try XCTUnwrap(environment.settings).set(PlanningSettings.reserveGoalPlanKey, to: "0")
    let off = try await show()
    XCTAssertEqual(off.planning.freeMoney.plan.goalPlans, .zero)
    XCTAssertEqual(off.planning.freeMoney.grey, AmountE4(whole: 105_000 - 4_000))
    XCTAssertFalse(off.planning.freeMoney.lines.contains { $0.key == FreeMoney.Key.goalPlans })
  }

  /// A 50 000 ₽ salary expected on the 25th is shown as «ещё ждём до 30 сентября», and never
  /// added: neither the money now nor the grey line counts money that has not come. Once it
  /// comes, the money now has it and nothing is waited for.
  func testIncomeStillExpectedIsShownAndNeverAdded() async throws {
    let books = try await openTheBooks()
    let salary = ExpectedIncome(
      name: "Зарплата", totalE4: AmountE4(whole: 50_000),
      dueDate: DateOnly(year: 2026, month: 9, day: 25))
    _ = try await show()
    XCTAssertTrue(planning.save(salary))
    let waiting = try await show()
    let free = waiting.planning.freeMoney
    XCTAssertEqual(free.main, AmountE4(whole: 105_000))
    XCTAssertEqual(free.grey, AmountE4(whole: 105_000))
    XCTAssertEqual(
      free.info.first { $0.key == FreeMoney.Key.stillExpected }?.amount,
      AmountE4(whole: 50_000))
    XCTAssertTrue(
      FreeMoneyBlock.parts(of: free).contains(.stillExpected(AmountE4(whole: 50_000))))

    try earn(50_000, on: books.sber.id, at: noon.addingTimeInterval(-600))
    let saved = try XCTUnwrap(waiting.planning.book.expected.first)
    let income = try XCTUnwrap(try entries().first { $0.transaction.kind == .income })
    XCTAssertTrue(planning.link(income: income.id, to: saved))
    let came = try await show()
    XCTAssertEqual(came.planning.freeMoney.main, AmountE4(whole: 155_000))
    XCTAssertEqual(
      came.planning.freeMoney.info.first { $0.key == FreeMoney.Key.stillExpected }?.amount,
      .zero, "the salary that came is still waited for")
  }

  /// Before any count the block has nothing to start from: «Мало данных» and the way to the
  /// first count, never a figure from money nobody counted.
  func testWithoutACountThereIsNoFreeSumOnlyTheWayToTheFirstOne() async throws {
    let sber = try await make(PaymentMethod(name: "Сбер", currency: .rub, isDefault: true))
    try earn(50_000, on: sber.id, at: noon.addingTimeInterval(-600))
    let snapshot = try await show()
    XCTAssertEqual(snapshot.planning.freeMoney.state, .noReconciliation)
    XCTAssertEqual(FreeMoneyBlock.parts(of: snapshot.planning.freeMoney), [.firstCount])
    XCTAssertNil(expected(sheet(snapshot), sber.id, .rub), "the first count compares nothing")
  }

  /// What an account left out of the summary pays is not taken from the summary's money: a
  /// 7 000 ₽ bill on Freedom leaves the grey line alone, a 3 000 ₽ bill with no account is
  /// the main account's and is taken away.
  func testABillOfAGroupLeftOutIsNotTakenFromTheSummary() async throws {
    let books = try await openTheBooks()
    let apart = ScheduledPayment(
      name: "Квартира в Алматы", amountE4: AmountE4(whole: 7_000),
      paymentMethodId: books.freedom.id, day: 20,
      nextDate: DateOnly(year: 2026, month: 9, day: 20))
    let phone = ScheduledPayment(
      name: "Телефон", amountE4: AmountE4(whole: 3_000), day: 22,
      nextDate: DateOnly(year: 2026, month: 9, day: 22))
    XCTAssertTrue(planning.save(apart, previous: nil))
    XCTAssertTrue(planning.save(phone, previous: nil))
    let snapshot = try await show()
    let free = snapshot.planning.freeMoney
    XCTAssertEqual(free.main, AmountE4(whole: 105_000))
    XCTAssertEqual(free.plan.scheduled, AmountE4(whole: 3_000), "Freedom's bill was taken away")
    XCTAssertEqual(free.grey, AmountE4(whole: 102_000))
    XCTAssertEqual(free.dailyGuide, AmountE4(whole: 6_800), "102 000 over 15 days")
  }

  /// A planned one-off expense — a 12 000 ₽ sofa on 10 October — is taken away once D reaches
  /// its day, and only once however far D goes.
  func testAOneOffPlannedExpenseIsTakenAwayOnceDReachesIt() async throws {
    let books = try await openTheBooks()
    let day = DateOnly(year: 2026, month: 10, day: 10)
    let sofa = ScheduledPayment(
      name: "Диван", amountE4: AmountE4(whole: 12_000), paymentMethodId: books.sber.id,
      day: 10, nextDate: day, endDate: day)
    XCTAssertTrue(planning.save(sofa, previous: nil))
    let snapshot = try await show()
    XCTAssertEqual(snapshot.planning.freeMoney.plan.scheduled, .zero, "not due by 30 September")
    for until in [
      day, DateOnly(year: 2026, month: 12, day: 31), DateOnly(year: 2027, month: 9, day: 16),
    ] {
      let free = snapshot.planning.freeMoney(until: until, ledger: snapshot.ledger)
      XCTAssertEqual(free.plan.scheduled, AmountE4(whole: 12_000), "D = \(until)")
      XCTAssertEqual(free.grey, AmountE4(whole: 105_000 - 12_000), "D = \(until)")
    }
  }

  /// Money moved between the summary and a group left out of it leaves the one and arrives at
  /// the other: 9 000 ₽ sent from Сбер that arrive as 100 $ on Freedom take 9 000 ₽ off the
  /// main figure and add 100 $ × 90 to Freedom's total — nothing is spent.
  func testATransferIntoAGroupLeftOutMovesMoneyFromTheSummaryToTheGroup() async throws {
    let books = try await openTheBooks()
    try await transfer(
      from: books.sber, .rub, to: books.freedom, .usd, sent: 9_000, received: 100,
      at: noon.addingTimeInterval(-3_600))
    let snapshot = try await show()
    XCTAssertEqual(snapshot.planning.freeMoney.main, AmountE4(whole: 105_000 - 9_000))
    XCTAssertEqual(
      snapshot.planning.freeMoney.excluded.first?.totalRub, AmountE4(whole: 130_000 + 9_000))
    XCTAssertEqual(snapshot.summary.expenses.current, .zero)
    XCTAssertEqual(snapshot.summary.income.current, .zero)
    XCTAssertEqual(expected(sheet(snapshot), books.freedom.id, .usd), AmountE4(whole: 1_100))
  }

  /// A purchase refunded in part: 2 000 ₽ of groceries on Сбер at 07:00, 500 ₽ back on Сбер at
  /// 09:00. The account holds 100 000 − 2 000 + 500, the sheet expects it, and the month spent
  /// 1 500 ₽ — as if the purchase were cheaper.
  func testARefundComesBackOnItsAccountAndMakesThePurchaseCheaper() async throws {
    let books = try await openTheBooks()
    let groceries = CoreKit.Category(kind: .expense, name: "Продукты")
    try XCTUnwrap(environment.references).save(groceries)
    var draft = TransactionDraft(
      occurredAt: noon.addingTimeInterval(-5 * 3_600), amount: AmountE4(whole: 2_000),
      note: "groceries", paymentMethodId: books.sber.id)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = groceries.id
    let purchase = try draft.materialize()
    XCTAssertTrue(store.save(purchase))

    var back = TransactionDraft(
      kind: .refund, occurredAt: noon.addingTimeInterval(-3 * 3_600),
      amount: AmountE4(whole: 500), paymentMethodId: books.sber.id)
    back.normalizeSinglePart()
    back.parts[0].categoryId = groceries.id
    back.parts[0].refundOfPartId = purchase.parts.first?.id
    XCTAssertTrue(store.save(try back.materialize()))

    let snapshot = try await show()
    XCTAssertEqual(
      snapshot.planning.freeMoney.main, AmountE4(whole: 100_000 - 2_000 + 500 + 5_000))
    XCTAssertEqual(
      expected(sheet(snapshot), books.sber.id, .rub), AmountE4(whole: 100_000 - 2_000 + 500))
    XCTAssertEqual(snapshot.summary.expenses.current, AmountE4(whole: 1_500))
    XCTAssertEqual(snapshot.summary.income.current, .zero, "a refund is no income")
  }

  /// A 7 000 ₽ rent due on the 20th: paid with «Провести» or typed as an ordinary expense in
  /// its category, it leaves the account — the money now drops by 7 000 — and it is no longer
  /// waited for, so the grey line stays where it was: paid once, counted once.
  func testPayingABillEitherWayMovesTheMoneyAndLeavesTheGreyLineAsItWas() async throws {
    let books = try await openTheBooks()
    let rent = CoreKit.Category(kind: .expense, name: "Аренда")
    try XCTUnwrap(environment.references).save(rent)
    let bill = ScheduledPayment(
      name: "Аренда", amountE4: AmountE4(whole: 7_000), categoryId: rent.id,
      paymentMethodId: books.sber.id, day: 20, nextDate: DateOnly(year: 2026, month: 9, day: 20))
    XCTAssertTrue(planning.save(bill, previous: nil))
    let waiting = try await show()
    XCTAssertEqual(waiting.planning.freeMoney.main, AmountE4(whole: 105_000))
    XCTAssertEqual(waiting.planning.freeMoney.grey, AmountE4(whole: 98_000))

    let stored = try XCTUnwrap(waiting.planning.book.scheduled.first)
    XCTAssertTrue(
      planning.markAsPaid(
        stored, due: DateOnly(year: 2026, month: 9, day: 20), amount: AmountE4(whole: 7_000),
        on: noon.addingTimeInterval(-600), paymentMethodId: books.sber.id, updatePrice: false))
    let paid = try await show()
    XCTAssertEqual(paid.planning.freeMoney.main, AmountE4(whole: 98_000))
    XCTAssertEqual(paid.planning.freeMoney.plan.scheduled, .zero)
    XCTAssertEqual(paid.planning.freeMoney.grey, AmountE4(whole: 98_000), "«Провести»")

    store.undo()
    let again = try await show()
    XCTAssertEqual(again.planning.freeMoney.grey, AmountE4(whole: 98_000))
    XCTAssertEqual(again.planning.freeMoney.main, AmountE4(whole: 105_000))

    var draft = TransactionDraft(
      occurredAt: noon.addingTimeInterval(-600), amount: AmountE4(whole: 7_000), note: "rent",
      paymentMethodId: books.sber.id)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = rent.id
    XCTAssertTrue(store.save(try draft.materialize()))
    let typed = try await show()
    XCTAssertEqual(typed.planning.freeMoney.main, AmountE4(whole: 98_000))
    XCTAssertEqual(
      typed.planning.freeMoney.grey, AmountE4(whole: 98_000),
      "a bill paid by an ordinary operation is taken away twice")
  }

  /// A 10 $ subscription on the ruble card, «Провести» with 950 ₽ typed from the statement:
  /// the card loses 950 ₽ — what the bank charged, not 10 × 90 —, the month spent 950 ₽, the
  /// grey line took 900 ₽ for it until then; one ⌘Z puts the card back.
  func testADollarSubscriptionPaidFromTheRubleCardTakesWhatTheBankCharged() async throws {
    let books = try await openTheBooks()
    let cloud = ScheduledPayment(
      name: "Облако", kind: .subscription, amountE4: AmountE4(whole: 10), currency: .usd,
      paymentMethodId: books.sber.id, day: 20, nextDate: DateOnly(year: 2026, month: 9, day: 20))
    XCTAssertTrue(planning.save(cloud, previous: nil))
    let waiting = try await show()
    XCTAssertEqual(waiting.planning.freeMoney.plan.scheduled, AmountE4(whole: 900))

    let stored = try XCTUnwrap(waiting.planning.book.scheduled.first)
    XCTAssertTrue(
      planning.markAsPaid(
        stored, due: DateOnly(year: 2026, month: 9, day: 20), amount: AmountE4(whole: 10),
        on: noon.addingTimeInterval(-600), account: books.sber.id,
        charged: Money(amount: AmountE4(whole: 950), currency: .rub), updatePrice: false))
    let paid = try await show()
    XCTAssertEqual(paid.planning.freeMoney.main, AmountE4(whole: 105_000 - 950))
    XCTAssertEqual(paid.planning.freeMoney.plan.scheduled, .zero)
    XCTAssertEqual(paid.summary.expenses.current, AmountE4(whole: 950))
    let entry = try XCTUnwrap(try entries().first)
    XCTAssertEqual(entry.transaction.currency, .usd)
    XCTAssertEqual(entry.transaction.accountCurrency, .rub)
    XCTAssertEqual(entry.transaction.accountAmountE4, AmountE4(whole: 950))

    store.undo()
    let back = try await show()
    XCTAssertEqual(back.planning.freeMoney.main, AmountE4(whole: 105_000))
    XCTAssertEqual(back.planning.freeMoney.plan.scheduled, AmountE4(whole: 900))
  }

  /// 30 000 ₽ borrowed today onto Сбер, paid back 5 000 ₽ on the 25th of each month: the money
  /// came onto the account, and the grey line takes this month's 5 000 ₽ away. Paying it from
  /// Сбер takes 5 000 ₽ off the money and the line alike; ⌘Z puts both back.
  func testMoneyBorrowedIsOnTheAccountAndItsPaymentIsTakenAwayOnce() async throws {
    let books = try await openTheBooks()
    _ = try await show()
    let debts = DebtActions(deps)
    let loan = Debt(
      direction: .iOwe, type: .personal, name: "Брат", monthlyPaymentE4: AmountE4(whole: 5_000),
      paymentDay: 25)
    XCTAssertTrue(
      debts.create(
        loan, balance: AmountE4(whole: 30_000), on: today, moneyMovedNow: true,
        account: books.sber.id, at: noon.addingTimeInterval(-2 * 3_600)))
    let borrowed = try await show()
    XCTAssertEqual(borrowed.planning.freeMoney.main, AmountE4(whole: 135_000))
    XCTAssertEqual(borrowed.planning.freeMoney.plan.debts, AmountE4(whole: 5_000))
    XCTAssertEqual(borrowed.planning.freeMoney.grey, AmountE4(whole: 130_000))
    XCTAssertEqual(borrowed.summary.income.current, .zero, "borrowed money is no income")

    let saved = try XCTUnwrap(try environment.references?.debts(includeClosed: true).first)
    XCTAssertTrue(
      debts.pay(
        saved, amount: AmountE4(whole: 5_000), on: noon.addingTimeInterval(-600),
        paymentMethodId: books.sber.id))
    let paid = try await show()
    XCTAssertEqual(paid.planning.freeMoney.main, AmountE4(whole: 130_000))
    XCTAssertEqual(paid.planning.freeMoney.plan.debts, .zero)
    XCTAssertEqual(paid.planning.freeMoney.grey, AmountE4(whole: 130_000))

    store.undo()
    let back = try await show()
    XCTAssertEqual(back.planning.freeMoney.main, AmountE4(whole: 135_000))
    XCTAssertEqual(back.planning.freeMoney.grey, AmountE4(whole: 130_000))
  }

  /// A subscription paid for Anna — 1 000 ₽ she gives back — is taken away in full: the money
  /// leaves the account first, whoever gives it back later.
  func testASubscriptionPaidForSomebodyElseIsTakenAwayInFull() async throws {
    let books = try await openTheBooks()
    let anna = Person(name: "Аня", relation: .friend)
    try XCTUnwrap(environment.references).save(anna)
    let music = ScheduledPayment(
      name: "Музыка", kind: .subscription, amountE4: AmountE4(whole: 1_000),
      paymentMethodId: books.sber.id, forWhom: .friends, forPersonId: anna.id,
      reimbursable: true, debtorPersonId: anna.id, reimbursementAmountE4: AmountE4(whole: 1_000),
      day: 25, nextDate: DateOnly(year: 2026, month: 9, day: 25))
    XCTAssertTrue(planning.save(music, previous: nil))
    let snapshot = try await show()
    XCTAssertEqual(snapshot.planning.freeMoney.plan.scheduled, AmountE4(whole: 1_000))
    XCTAssertEqual(snapshot.planning.freeMoney.grey, AmountE4(whole: 104_000))
  }

  /// A trip under way with a 5 000 ₽ budget, 1 500 ₽ of it spent from Сбер: the money now is
  /// 1 500 ₽ less, and the grey line keeps back only the 3 500 ₽ left of the budget — the
  /// trip costs 5 000 ₽ in all, never 6 500 ₽.
  func testAnEventUnderWayKeepsBackWhatIsLeftOfItsBudget() async throws {
    let books = try await openTheBooks()
    let trip = Event(
      name: "Поездка", startDate: DateOnly(year: 2026, month: 9, day: 15),
      endDate: DateOnly(year: 2026, month: 9, day: 18), budgetE4: AmountE4(whole: 5_000))
    _ = try await show()
    XCTAssertTrue(planning.save(trip))
    var draft = TransactionDraft(
      occurredAt: noon.addingTimeInterval(-3_600), amount: AmountE4(whole: 1_500),
      note: "taxi", paymentMethodId: books.sber.id)
    draft.normalizeSinglePart()
    draft.parts[0].eventId = trip.id
    XCTAssertTrue(store.save(try draft.materialize()))

    let snapshot = try await show()
    XCTAssertEqual(snapshot.planning.freeMoney.main, AmountE4(whole: 103_500))
    XCTAssertEqual(snapshot.planning.freeMoney.plan.events, AmountE4(whole: 3_500))
    XCTAssertEqual(snapshot.planning.freeMoney.grey, AmountE4(whole: 100_000))
  }

  /// A currency added to Freedom in the editor with «Остаток сейчас» 500 € is counted from
  /// that moment, the counted dollars and tenge untouched; one ⌘Z takes both the currency and
  /// its count back.
  func testACurrencyAddedWithItsBalanceIsOneStepOfUndo() async throws {
    let books = try await openTheBooks()
    var edited = books.freedom
    edited.otherCurrencies = [kzt, .eur]
    let current = try await freshBooks()
    XCTAssertEqual(
      accounts.save(
        edited, previous: books.freedom,
        openings: [.eur: AmountE4(whole: 500), .usd: AmountE4(whole: 7_777)], books: current),
      .done)
    let added = try await show()
    XCTAssertEqual(expected(sheet(added), books.freedom.id, .eur), AmountE4(whole: 500))
    XCTAssertEqual(
      expected(sheet(added), books.freedom.id, .usd), AmountE4(whole: 1_000),
      "«Остаток сейчас» recounted a currency counted before")

    store.undo()
    let back = try await show()
    XCTAssertEqual(accounts.all.first { $0.id == books.freedom.id }?.otherCurrencies, [kzt])
    XCTAssertNil(
      sheet(back).first { $0.key == BalanceKey(accountId: books.freedom.id, currency: .eur) })
    XCTAssertFalse(
      try XCTUnwrap(environment.planning).book().reconciledBalances.contains { $0.currency == .eur }
    )
  }

  /// A first sheet for an account that moved before it was ever counted: the count is its
  /// starting point, whatever moved before — nothing is compared, nothing written — and a
  /// currency left blank is not counted at all. One ⌘Z takes the count back.
  func testAFirstCountAfterMovesIsTheStartingPointAndABlankIsNotACount() async throws {
    let kaspi = try await make(
      PaymentMethod(name: "Kaspi", currency: .rub, isDefault: true, otherCurrencies: [kzt]))
    try spend(1_000, on: kaspi.id, at: noon.addingTimeInterval(-3_600))
    let before = try await show()
    XCTAssertEqual(before.planning.freeMoney.state, .noReconciliation)

    let rows = sheet(before)
    let rub = BalanceKey(accountId: kaspi.id, currency: .rub)
    let tenge = BalanceKey(accountId: kaspi.id, currency: kzt)
    let counted = try XCTUnwrap(
      ReconcileSheet.counted(
        rows: rows, typed: [rub: AmountE4(whole: 20_000), tenge: .zero], blank: [tenge]))
    XCTAssertEqual(counted, [rub: AmountE4(whole: 20_000)])
    XCTAssertNil(planning.reconcile(counted: counted, rows: rows, recordDifference: true, at: noon))
    XCTAssertEqual(try entries().count, 1, "a starting point wrote a difference")

    let after = try await show()
    XCTAssertEqual(after.planning.freeMoney.main, AmountE4(whole: 20_000))
    XCTAssertEqual(after.planning.freeMoney.unanchored, [tenge])

    store.undo()
    let undone = try await show()
    XCTAssertEqual(undone.planning.freeMoney.state, .noReconciliation)
  }

  // MARK: The sidebar and the screens

  /// After the month the sidebar adds up: the groups in the summary make «Всего», which is the
  /// free sum's main figure; the group left out comes last with the total the free sum shows
  /// apart; the main account is first; every account's figure is its balances at today's rate.
  func testTheSidebarAddsUpToTheFreeSum() async throws {
    let books = try await openTheBooks()
    try await liveTheMonth(books)
    let snapshot = try await show()
    let sidebar = snapshot.planning.accounts.ordered(locale: Locale(identifier: "ru"))

    XCTAssertEqual(sidebar.inSummaryTotalRub, snapshot.planning.freeMoney.main)
    XCTAssertEqual(
      AmountE4.sum(sidebar.sections.filter(\.inSummary).compactMap(\.totalRub)),
      sidebar.inSummaryTotalRub)
    XCTAssertEqual(sidebar.sections.last?.group?.id, books.kazakhstan.id)
    XCTAssertEqual(sidebar.sections.last?.totalRub, AmountE4(whole: kazakhstanAfter))
    XCTAssertEqual(sidebar.sections.first?.accounts.first?.account.id, books.sber.id)

    let freedom = try XCTUnwrap(sidebar.line(of: books.freedom.id))
    XCTAssertEqual(freedom.totalRub, AmountE4(whole: kazakhstanAfter))
    XCTAssertEqual(
      freedom.keys.map(\.balance), [AmountE4(whole: usdAfter), AmountE4(whole: kztAfter)],
      "the balances in the account's order of currencies")
    XCTAssertEqual(
      sidebar.line(of: books.sber.id)?.totalRub, AmountE4(whole: sberAfter))
  }

  /// Without a tenge rate today Freedom's «≈ ₽» holds its dollars only and says which
  /// currency it leaves out — in the sidebar row and in the group apart — never taking the
  /// tenge for zero in silence.
  func testACurrencyWithoutARateIsNamedWhereverItIsLeftOut() async throws {
    let books = try await openTheBooks()
    try await liveTheMonth(books)
    rates[kzt] = nil
    let snapshot = try await show()
    let line = try XCTUnwrap(snapshot.planning.accounts.line(of: books.freedom.id))
    XCTAssertEqual(line.totalRub, AmountE4(whole: usdAfter * 90))
    XCTAssertEqual(line.withoutRate, [kzt])
    let figure = SidebarFigure.of(
      line, money: environment.money,
      words: { self.environment.language($0, table: AccountText.table) },
      withoutRate: {
        self.environment.format("sidebar.withoutRate", table: AccountText.table, $0)
      })
    XCTAssertEqual(
      figure.main, "≈\u{00A0}" + environment.money.rounded(AmountE4(whole: usdAfter * 90)))
    XCTAssertTrue(figure.missing?.contains("KZT") ?? false, "\(figure)")
    XCTAssertTrue(
      figure.caption?.contains("KZT") ?? false || figure.caption?.contains("₸") ?? false)

    let apart = try XCTUnwrap(snapshot.planning.freeMoney.excluded.first)
    XCTAssertEqual(apart.totalRub, AmountE4(whole: usdAfter * 90))
    XCTAssertEqual(apart.withoutRate, [kzt])
    XCTAssertEqual(
      snapshot.planning.freeMoney.main, AmountE4(whole: sberAfter + cashAfter),
      "a rate missing apart touched the summary")
  }

  /// A8 across the screens: one order everywhere. Сбер is main; ВТБ dragged above Альфа. The
  /// sidebar, the reconciliation sheet and the account menus of the forms all list Сбер, ВТБ,
  /// Альфа; «Сортировать по алфавиту» brings Альфа back before ВТБ in all of them at once.
  func testEveryListShowsTheAccountsInTheOneOrder() async throws {
    let sber = try await make(
      PaymentMethod(name: "Сбер", currency: .rub, isDefault: true),
      openings: [.rub: AmountE4(whole: 1_000)])
    let alfa = try await make(
      PaymentMethod(name: "Альфа", currency: .rub), openings: [.rub: AmountE4(whole: 2_000)])
    let vtb = try await make(
      PaymentMethod(name: "ВТБ", currency: .rub), openings: [.rub: AmountE4(whole: 3_000)])
    let locale = Locale(identifier: "ru")

    func orders() async throws -> (sidebar: [UUID], sheet: [UUID], menu: [UUID]) {
      let snapshot = try await show()
      let sidebar = snapshot.planning.accounts.ordered(locale: locale).sections
        .flatMap(\.accounts).map(\.account.id)
      let sheet = ReconcileSheet.rows(of: snapshot, at: noon, first: nil, locale: locale)
        .map(\.key.accountId)
      let menu = FormAccounts.offered(accounts.all, locale: locale).map(\.id)
      return (sidebar, sheet, menu)
    }

    let before = try await orders()
    XCTAssertEqual(before.sidebar, [sber.id, alfa.id, vtb.id])
    XCTAssertEqual(before.sheet, before.sidebar)
    XCTAssertEqual(before.menu, before.sidebar)

    XCTAssertEqual(accounts.move(vtb.id, by: -1), .done)
    let dragged = try await orders()
    XCTAssertEqual(dragged.sidebar, [sber.id, vtb.id, alfa.id])
    XCTAssertEqual(dragged.sheet, dragged.sidebar)
    XCTAssertEqual(dragged.menu, dragged.sidebar)

    XCTAssertEqual(accounts.alphabetize(), .done)
    let sorted = try await orders()
    XCTAssertEqual(sorted.sidebar, [sber.id, alfa.id, vtb.id])
    XCTAssertEqual(sorted.sheet, sorted.sidebar)
    XCTAssertEqual(sorted.menu, sorted.sidebar)
  }

  /// The screen of Сбер lists its day: the two operations, the dollar purchase, the transfer
  /// to the cash with its fee beside it; the screen of Freedom lists its exchange, which is no
  /// operation. A group of several accounts is in
  /// `testTheScreenOfAGroupShowsATransferInsideItOnceAndSpendsOnlyItsFee`.
  func testTheScreensOfAnAccountAndAGroupListWhatMovedThem() async throws {
    let books = try await openTheBooks()
    try await liveTheMonth(books)
    let snapshot = try await show()

    let sber = AccountHistory.build(
      accountIds: [books.sber.id], dataset: snapshot.dataset, calendar: environment.calendar)
    XCTAssertEqual(sber.days.map(\.day), [today])
    let items = try XCTUnwrap(sber.days.first).items
    XCTAssertEqual(items.count, 5, "coffee, salary, fee, transfer, dollar purchase")
    XCTAssertEqual(sber.fees.count, 1, "the fee is shown with its transfer")

    let freedom = AccountHistory.build(
      accountIds: [books.freedom.id], dataset: snapshot.dataset, calendar: environment.calendar)
    XCTAssertEqual(freedom.days.flatMap(\.items).count, 1, "the exchange is its only move")
    XCTAssertTrue(freedom.operationIds.isEmpty, "an exchange is no operation")
  }

  // MARK: ⌘Z, one step each

  /// Every action of the month is one step of ⌘Z: undone one by one from the last, the money
  /// now walks back through every figure it had — the dollar purchase, the exchange, the
  /// transfer with its fee, the salary, the coffee — to the opening balances; and on to the
  /// accounts themselves and the group.
  func testEveryActionIsOneStepOfUndo() async throws {
    let books = try await openTheBooks()
    try await liveTheMonth(books)
    var figures: [(main: Int64, kazakhstan: Int64)] = [
      (sberAfter + cashAfter, kazakhstanAfter),
      // before the dollar purchase
      (sberAfter + 1_850 + cashAfter, kazakhstanAfter),
      // before the exchange
      (sberAfter + 1_850 + cashAfter, 90_000 + 40_000),
      // before the transfer and its fee
      (100_000 - 3_000 + 50_000 + 5_000, 130_000),
      // before the salary
      (100_000 - 3_000 + 5_000, 130_000),
      // before the coffee
      (105_000, 130_000),
    ]
    let first = figures.removeFirst()
    let now = try await show()
    XCTAssertEqual(now.planning.freeMoney.main, AmountE4(whole: first.main))
    for (step, figure) in figures.enumerated() {
      store.undo()
      let snapshot = try await show()
      XCTAssertEqual(
        snapshot.planning.freeMoney.main, AmountE4(whole: figure.main),
        "after ⌘Z number \(step + 1)")
      XCTAssertEqual(
        snapshot.planning.freeMoney.excluded.first?.totalRub, AmountE4(whole: figure.kazakhstan),
        "after ⌘Z number \(step + 1)")
    }
    XCTAssertTrue(try entries().isEmpty)
    let emptied = try await freshBooks()
    XCTAssertTrue(emptied.dataset.transfers.isEmpty)

    store.undo()
    XCTAssertNil(accounts.all.first { $0.id == books.freedom.id }, "⌘Z of the new Freedom")
    let withoutFreedom = try XCTUnwrap(environment.planning).book()
    XCTAssertFalse(
      withoutFreedom.reconciledBalances.contains { $0.accountId == books.freedom.id },
      "its opening counts outlived it")
    store.undo()
    XCTAssertNil(accounts.all.first { $0.id == books.cash.id })
    store.undo()
    XCTAssertNil(accounts.all.first { $0.id == books.sber.id })
    store.undo()
    XCTAssertTrue(accounts.groups.isEmpty, "⌘Z of the new group")
  }

  /// The actions on accounts and groups the sidebar offers are one step of ⌘Z each: making
  /// another account main, renaming a group, an account into the archive (its group, still
  /// holding it, is refused). A merge is not undone, and ⌘Z forgets what came before it. The
  /// archive of a group, «Вернуть», the drag, «по алфавиту», the deletion of a transfer and a
  /// contribution are in `testAnEmptyGroupGoesToTheArchive…` and
  /// `testRestoreDragAlphabetTransferDeletionAndContributionAreOneStepEach`.
  func testEachActionOnAccountsAndGroupsIsOneStepAndAMergeForgetsThem() async throws {
    let books = try await openTheBooks()
    XCTAssertEqual(accounts.makeMain(books.cash.id), .done)
    XCTAssertEqual(accounts.all.first(where: \.isDefault)?.id, books.cash.id)
    store.undo()
    XCTAssertEqual(accounts.all.first(where: \.isDefault)?.id, books.sber.id)

    var renamed = books.kazakhstan
    renamed.name = "KZ"
    XCTAssertEqual(accounts.save(group: renamed), .done)
    store.undo()
    XCTAssertEqual(accounts.groups.first?.name, "Казахстан")

    let spare = try await make(
      PaymentMethod(name: "Kaspi", currency: kzt, groupId: books.kazakhstan.id))
    let empty = try await freshBooks()
    XCTAssertEqual(accounts.archive(spare.id, books: empty), .done)
    XCTAssertEqual(accounts.archiveGroup(books.kazakhstan.id), .refused(.groupHasLiveAccounts))
    store.undo()
    XCTAssertEqual(accounts.all.first { $0.id == spare.id }?.archived, false)

    try await transfer(
      from: books.sber, .rub, to: books.cash, .rub, sent: 1_000,
      at: noon.addingTimeInterval(-3_600))
    let current = try await freshBooks()
    try inOneBank(spare.id, books.freedom.id)
    let preview = try XCTUnwrap(
      accounts.mergePreview(spare.id, into: books.freedom.id, books: current))
    XCTAssertEqual(accounts.merge(preview), .done)
    XCTAssertFalse(store.canUndo, "a merge left steps of ⌘Z that may name the account gone")
    store.undo()
    let after = try await freshBooks()
    XCTAssertEqual(after.dataset.transfers.count, 1)
    XCTAssertEqual(accounts.all.first { $0.id == spare.id }?.archived, true)
  }

  /// An edit of a transfer — 10 000 ₽ becomes 12 000 ₽, the fee 100 ₽ becomes 150 ₽ — moves
  /// both balances and the fee in one step; ⌘Z brings back all of it.
  func testAnEditOfATransferMovesBothBalancesAndItsFeeInOneStep() async throws {
    let books = try await openTheBooks()
    try await transfer(
      from: books.sber, .rub, to: books.cash, .rub, sent: 10_000, fee: 100,
      at: noon.addingTimeInterval(-3_600))
    let current = try await freshBooks()
    let saved = try XCTUnwrap(current.dataset.transfers.first)
    let fee = TransferActions.fee(of: saved.id, in: current.dataset.entries)
    XCTAssertEqual(fee?.transaction.amountE4, AmountE4(whole: 100))

    var form = TransferForm(
      editing: saved, fee: fee?.transaction.amountE4, calendar: environment.calendar)
    form.sent = AmountE4(whole: 12_000)
    form.fee = AmountE4(whole: 150)
    XCTAssertEqual(
      transfers.save(
        form, occurredAt: form.occurredAt(now: noon, calendar: environment.calendar),
        books: current), .done)
    let edited = try await freshBooks()
    XCTAssertEqual(balance(edited, books.sber.id, .rub), AmountE4(whole: 100_000 - 12_000 - 150))
    XCTAssertEqual(balance(edited, books.cash.id, .rub), AmountE4(whole: 5_000 + 12_000))
    XCTAssertEqual(edited.dataset.transfers.count, 1)
    XCTAssertEqual(
      edited.dataset.entries.filter { !$0.transaction.isDeleted }.count, 1, "one fee, not two")

    store.undo()
    let back = try await freshBooks()
    XCTAssertEqual(balance(back, books.sber.id, .rub), AmountE4(whole: 100_000 - 10_000 - 100))
    XCTAssertEqual(balance(back, books.cash.id, .rub), AmountE4(whole: 15_000))
  }

  /// Turned around — from the cash to Сбер, 1 000 ₽ with a 50 ₽ fee — the transfer takes its
  /// fee along to the account the money now leaves: the cash pays it, Сбер no longer does.
  func testAnEditThatTurnsATransferAroundMovesTheFeeToTheAccountTheMoneyLeaves() async throws {
    let books = try await openTheBooks()
    try await transfer(
      from: books.sber, .rub, to: books.cash, .rub, sent: 10_000, fee: 100,
      at: noon.addingTimeInterval(-3_600))
    let current = try await freshBooks()
    let saved = try XCTUnwrap(current.dataset.transfers.first)
    let fee = TransferActions.fee(of: saved.id, in: current.dataset.entries)

    var form = TransferForm(
      editing: saved, fee: fee?.transaction.amountE4, calendar: environment.calendar)
    form.chooseFrom(books.cash)
    form.chooseTo(books.sber)
    form.sent = AmountE4(whole: 1_000)
    form.fee = AmountE4(whole: 50)
    XCTAssertEqual(
      transfers.save(
        form, occurredAt: form.occurredAt(now: noon, calendar: environment.calendar),
        books: current), .done)

    let edited = try await freshBooks()
    XCTAssertEqual(balance(edited, books.cash.id, .rub), AmountE4(whole: 5_000 - 1_000 - 50))
    XCTAssertEqual(balance(edited, books.sber.id, .rub), AmountE4(whole: 100_000 + 1_000))
    let moved = try XCTUnwrap(TransferActions.fee(of: saved.id, in: edited.dataset.entries))
    XCTAssertEqual(moved.transaction.paymentMethodId, books.cash.id)
    XCTAssertEqual(moved.id, fee?.id, "the fee was made again rather than moved")
  }

  /// The fee taken off in an edit is gone from the books and from the money; ⌘Z brings the
  /// fee and the transfer back as they were in one step.
  func testAnEditThatTakesTheFeeOffIsUndoneWithTheFee() async throws {
    let books = try await openTheBooks()
    try await transfer(
      from: books.sber, .rub, to: books.cash, .rub, sent: 10_000, fee: 100,
      at: noon.addingTimeInterval(-3_600))
    let current = try await freshBooks()
    let saved = try XCTUnwrap(current.dataset.transfers.first)
    var form = TransferForm(
      editing: saved, fee: AmountE4(whole: 100), calendar: environment.calendar)
    form.fee = .zero
    XCTAssertEqual(
      transfers.save(
        form, occurredAt: form.occurredAt(now: noon, calendar: environment.calendar),
        books: current), .done)
    let without = try await show()
    XCTAssertEqual(without.planning.freeMoney.main, AmountE4(whole: 105_000))
    XCTAssertEqual(without.summary.expenses.current, .zero)
    XCTAssertTrue(try entries().isEmpty)

    store.undo()
    let back = try await show()
    XCTAssertEqual(back.planning.freeMoney.main, AmountE4(whole: 105_000 - 100))
    XCTAssertEqual(back.summary.expenses.current, AmountE4(whole: 100))
    let fee = try await freshBooks()
    XCTAssertNotNil(TransferActions.fee(of: saved.id, in: fee.dataset.entries))
  }

  /// The owner put «Комиссии» into the archive. The next fee goes to that category brought
  /// back — the way «Сверка» is, and the way every «Добавить» brings an archived name back —
  /// rather than to a second «Комиссии» beside the archived one. ⌘Z of the transfer sends the
  /// category back to the archive.
  func testTheNextFeeBringsTheArchivedCategoryOfFeesBackRatherThanMakingASecond() async throws {
    let books = try await openTheBooks()
    try await transfer(
      from: books.sber, .rub, to: books.cash, .rub, sent: 1_000, fee: 10,
      at: noon.addingTimeInterval(-3_600))
    let first = try await freshBooks()
    let feeCategory = try XCTUnwrap(
      TransferActions.fee(
        of: try XCTUnwrap(first.dataset.transfers.first).id,
        in: first.dataset.entries)?.parts.first?.categoryId)
    var archived = try XCTUnwrap(store.categories().first { $0.id == feeCategory })
    archived.archived = true
    try XCTUnwrap(environment.references).save(archived)

    try await transfer(
      from: books.sber, .rub, to: books.cash, .rub, sent: 2_000, fee: 20,
      at: noon.addingTimeInterval(-1_800))
    let second = try await freshBooks()
    let newTransfer = try XCTUnwrap(
      second.dataset.transfers.first { $0.fromAmountE4 == AmountE4(whole: 2_000) })
    let newFee = try XCTUnwrap(TransferActions.fee(of: newTransfer.id, in: second.dataset.entries))
    XCTAssertEqual(newFee.parts.first?.categoryId, feeCategory, "a second category of fees")
    let named = store.categories().filter { $0.name == archived.name }
    XCTAssertEqual(named.count, 1, "\(named.map(\.archived))")
    XCTAssertEqual(named.first?.archived, false, "the fees went into an archived category")

    store.undo()
    XCTAssertEqual(
      store.categories().first { $0.id == feeCategory }?.archived, true,
      "⌘Z of the transfer left the category it brought back out of the archive")
  }

  /// The remembered category of fees filed under «Банк», and the whole «Банк» put into the
  /// archive. The next fee — 2,000 ₽ from Сбер to the cash with 20 ₽ — says under the fee that
  /// «Комиссии» comes back with «Банк», and saving brings both back in the step that writes the
  /// transfer and its fee: one «Комиссии», live, under a live «Банк»; Сбер pays 2,020 ₽, the
  /// cash gets 2,000 ₽. ⌘Z takes the transfer and the fee away and puts both categories back
  /// into the archive.
  func testAFeeUnderAnArchivedParentBringsBothBack() async throws {
    let books = try await openTheBooks()
    try await transfer(
      from: books.sber, .rub, to: books.cash, .rub, sent: 1_000, fee: 10,
      at: noon.addingTimeInterval(-3_600))
    let first = try await freshBooks()
    let feeCategory = try XCTUnwrap(
      TransferActions.fee(
        of: try XCTUnwrap(first.dataset.transfers.first).id,
        in: first.dataset.entries)?.parts.first?.categoryId)
    let references = try XCTUnwrap(environment.references)
    var bank = CoreKit.Category(kind: .expense, name: "Банк")
    try references.save(bank)
    var fees = try XCTUnwrap(store.categories().first { $0.id == feeCategory })
    fees.parentId = bank.id
    fees.archived = true
    try references.save(fees)
    bank.archived = true
    try references.save(bank)
    let categoriesBefore = store.categories().count
    let sberBefore = try XCTUnwrap(balance(first, books.sber.id, .rub))
    let cashBefore = try XCTUnwrap(balance(first, books.cash.id, .rub))

    let comingBack = try XCTUnwrap(transfers.feeCategoryComingBack(), "nothing said under the fee")
    XCTAssertEqual(comingBack, FeeCategoryComingBack(category: fees.name, parent: "Банк"))
    let caption = TransferText.feeComingBack(comingBack, environment)
    XCTAssertTrue(caption.contains(fees.name) && caption.contains("Банк"), caption)
    XCTAssertFalse(caption.hasPrefix("transfer."), "the key itself was shown: \(caption)")

    try await transfer(
      from: books.sber, .rub, to: books.cash, .rub, sent: 2_000, fee: 20,
      at: noon.addingTimeInterval(-1_800))
    let second = try await freshBooks()
    let newTransfer = try XCTUnwrap(
      second.dataset.transfers.first { $0.fromAmountE4 == AmountE4(whole: 2_000) })
    let newFee = try XCTUnwrap(TransferActions.fee(of: newTransfer.id, in: second.dataset.entries))
    XCTAssertEqual(newFee.parts.first?.categoryId, feeCategory, "a second category of fees")
    XCTAssertEqual(newFee.transaction.amountE4, AmountE4(whole: 20))
    XCTAssertEqual(newFee.transaction.paymentMethodId, books.sber.id)
    let named = store.categories().filter { $0.name == fees.name }
    XCTAssertEqual(named.map(\.id), [feeCategory], "one «\(fees.name)», the one brought back")
    XCTAssertEqual(named.first?.archived, false)
    XCTAssertEqual(store.categories().first { $0.id == bank.id }?.archived, false)
    XCTAssertEqual(store.categories().count, categoriesBefore, "a category was made")
    XCTAssertEqual(balance(second, books.sber.id, .rub), sberBefore - AmountE4(whole: 2_020))
    XCTAssertEqual(balance(second, books.cash.id, .rub), cashBefore + AmountE4(whole: 2_000))
    XCTAssertNil(transfers.feeCategoryComingBack(), "the caption stayed with both live")

    store.undo()
    let back = try await freshBooks()
    XCTAssertNil(back.dataset.transfers.first { $0.id == newTransfer.id })
    XCTAssertNil(TransferActions.fee(of: newTransfer.id, in: back.dataset.entries))
    XCTAssertEqual(balance(back, books.sber.id, .rub), sberBefore)
    XCTAssertEqual(balance(back, books.cash.id, .rub), cashBefore)
    XCTAssertEqual(store.categories().first { $0.id == feeCategory }?.archived, true)
    XCTAssertEqual(store.categories().first { $0.id == bank.id }?.archived, true)
  }

  /// The starter «Комиссии» and its «Прочее» put into the archive before any fee was written:
  /// the first fee brings both back — said under the fee first — and remembers the category,
  /// rather than making a second «Комиссии». ⌘Z sends both back to the archive.
  func testTheFirstFeeBringsBackAnArchivedStarterFees() async throws {
    let books = try await openTheBooks()
    let references = try XCTUnwrap(environment.references)
    let starter = store.categories()
    var other = try XCTUnwrap(
      starter.first {
        $0.parentId == nil && $0.kind == .expense
          && ["прочее", "other"].contains($0.name.lowercased())
      }, "the starter tree has no «Прочее»")
    var fees = try XCTUnwrap(
      starter.first {
        $0.parentId == other.id && ["комиссии", "fees"].contains($0.name.lowercased())
      }, "the starter tree has no «Комиссии»")
    XCTAssertNil(
      try environment.settings?.string(AccountSettings.transferFeeCategoryKey),
      "a category of fees was remembered before any fee")
    fees.archived = true
    try references.save(fees)
    other.archived = true
    try references.save(other)
    let count = store.categories().count

    XCTAssertEqual(
      transfers.feeCategoryComingBack(),
      FeeCategoryComingBack(category: fees.name, parent: other.name))

    try await transfer(
      from: books.sber, .rub, to: books.cash, .rub, sent: 1_000, fee: 10,
      at: noon.addingTimeInterval(-3_600))
    let written = try await freshBooks()
    let fee = try XCTUnwrap(
      TransferActions.fee(
        of: try XCTUnwrap(written.dataset.transfers.first).id, in: written.dataset.entries))
    XCTAssertEqual(fee.parts.first?.categoryId, fees.id, "the fee did not go to the starter one")
    XCTAssertEqual(fee.parts.first?.quality, .bad)
    XCTAssertEqual(store.categories().count, count, "a second category of fees was made")
    XCTAssertEqual(store.categories().first { $0.id == fees.id }?.archived, false)
    XCTAssertEqual(store.categories().first { $0.id == other.id }?.archived, false)
    XCTAssertEqual(
      try environment.settings?.string(AccountSettings.transferFeeCategoryKey), fees.id.uuidString)

    store.undo()
    let back = try await freshBooks()
    XCTAssertTrue(back.dataset.transfers.isEmpty)
    XCTAssertEqual(store.categories().count, count)
    XCTAssertEqual(store.categories().first { $0.id == fees.id }?.archived, true)
    XCTAssertEqual(store.categories().first { $0.id == other.id }?.archived, true)
  }

  // MARK: A merge, and the money of an account in the archive

  /// A merge is no count: the merged account behaves as if the two had always been one.
  /// Counted at 06:00 (Сбер 100 000 ₽, cash 5 000 ₽), merged at 12:00 (105 000 ₽), a 300 ₽
  /// coffee of 09:00 typed after the merge is after the real count, so it moves the money:
  /// 104 700 ₽. And an operation of today typed after the merge is asked about the real count
  /// of 06:00, never about 12:00, when nobody counted.
  func testAMergeIsNoCountForWhatHappenedBeforeIt() async throws {
    let books = try await openTheBooks()
    let current = try await freshBooks()
    try inOneBank(books.cash.id, books.sber.id)
    let preview = try XCTUnwrap(
      accounts.mergePreview(books.cash.id, into: books.sber.id, books: current))
    XCTAssertEqual(accounts.merge(preview), .done)

    try spend(300, on: books.sber.id, at: noon.addingTimeInterval(-3 * 3_600))
    let after = try await show()
    XCTAssertEqual(after.planning.freeMoney.main, AmountE4(whole: 104_700))

    var typed = TransactionDraft(
      occurredAt: noon.addingTimeInterval(3_600), amount: AmountE4(whole: 100),
      paymentMethodId: books.sber.id)
    typed.normalizeSinglePart()
    XCTAssertEqual(
      FormAccounts.countToAsk(
        about: try typed.materialize(), savedAt: noon.addingTimeInterval(3_600),
        snapshot: after, calendar: environment.calendar),
      noon.addingTimeInterval(-6 * 3_600), "the real count is asked about, not the merge")
  }

  /// Money an edit brings back onto an account in the archive goes to a live account in the
  /// same step: the cash emptied by a 5 000 ₽ purchase and archived, the purchase then made
  /// 4 000 ₽ the way the editor saves it. The 1 000 ₽ would be left on the cash, where no total
  /// sees it; the save asks, and the transfer to Сбер lands with the edit: the cash stays at
  /// zero, Сбер holds 101 000 ₽, and so do «Всего» and the free sum. One ⌘Z takes both back.
  func testMoneyAnEditLeavesOnAnArchivedAccountGoesToALiveOneInTheSameStep() async throws {
    let books = try await openTheBooks()
    let purchase = try spend(5_000, on: books.cash.id, at: noon.addingTimeInterval(-5 * 3_600))
    let emptied = try await freshBooks()
    XCTAssertEqual(accounts.archive(books.cash.id, books: emptied), .done)

    var cheaper = purchase
    cheaper.transaction.amountE4 = AmountE4(whole: 4_000)
    cheaper.transaction.amountRubE4 = AmountE4(whole: 4_000)
    cheaper.parts[0].amountE4 = AmountE4(whole: 4_000)
    cheaper.parts[0].amountRubE4 = AmountE4(whole: 4_000)
    let current = try await freshBooks()
    store.show(Ledger(dataset: current.dataset, calendar: environment.calendar))
    let check = store.archivedLeftovers(
      editing: purchase, into: cheaper, balances: current.balances)
    XCTAssertEqual(check.leftovers.map(\.amount), [AmountE4(whole: 1_000)])
    let settling = ArchivedMoneyForm(
      check: check, accounts: current.dataset.paymentMethods, locale: Locale(identifier: "ru")
    ).transfers(now: noon, note: "остаток")
    XCTAssertEqual(settling.first?.toAccountId, books.sber.id, "the main account is offered")
    XCTAssertEqual(
      settling.map(\.occurredAt), [noon.addingTimeInterval(-5 * 3_600 + 1)],
      "dated a second after the purchase, the last movement of the cash")
    XCTAssertEqual(
      store.saveEdit(cheaper, calendar: environment.calendar, settling: settling), .saved)

    let after = try await freshBooks()
    XCTAssertEqual(
      after.dataset.transfers.filter { $0.id == settling.first?.id }.map(\.occurredAt),
      [noon.addingTimeInterval(-5 * 3_600 + 1)], "and written with that moment")
    XCTAssertEqual(balance(after, books.cash.id, .rub), .zero, "the archived cash stays at zero")
    XCTAssertEqual(balance(after, books.sber.id, .rub), AmountE4(whole: 101_000))
    let snapshot = try await show()
    XCTAssertEqual(snapshot.planning.freeMoney.main, AmountE4(whole: 101_000))
    XCTAssertEqual(snapshot.planning.accounts.inSummaryTotalRub, AmountE4(whole: 101_000))

    store.undo()
    let undone = try await freshBooks()
    XCTAssertTrue(undone.dataset.transfers.isEmpty, "one ⌘Z takes the transfer back")
    XCTAssertEqual(
      undone.dataset.entries.first { $0.id == purchase.id }?.transaction.amountE4,
      AmountE4(whole: 5_000))
    XCTAssertEqual(balance(undone, books.sber.id, .rub), AmountE4(whole: 100_000))
  }

  /// An old transfer to the cash, once the cash is in the archive: its comment is edited — it
  /// moves no money —, and deleting it would take 1 000 ₽ back off the archived cash, which no
  /// total counts, and hand them to Сбер, so «Всего» would grow out of nothing. So the deletion
  /// alone is refused; with the transfer that brings the 1 000 ₽ back to the cash from Сбер it
  /// goes, in one step of ⌘Z, the cash stays at zero and the money stays 105 000 ₽. Сбер
  /// 100 000 ₽ and cash 5 000 ₽ counted at 06:00; 1 000 ₽ to the cash at 09:00, 6 000 ₽ back at
  /// 10:00; the empty cash archived.
  func testATransferOfAnArchivedAccountIsDeletedOnlyWithTheMoneyMoved() async throws {
    let books = try await openTheBooks()
    try await transfer(
      from: books.sber, .rub, to: books.cash, .rub, sent: 1_000,
      at: noon.addingTimeInterval(-3 * 3_600))
    try await transfer(
      from: books.cash, .rub, to: books.sber, .rub, sent: 6_000,
      at: noon.addingTimeInterval(-2 * 3_600))
    let emptied = try await freshBooks()
    XCTAssertEqual(accounts.archive(books.cash.id, books: emptied), .done)

    let current = try await freshBooks()
    let old = try XCTUnwrap(current.dataset.transfers.first { $0.fromAccountId == books.sber.id })
    var form = TransferForm(editing: old, fee: nil, calendar: environment.calendar)
    form.note = "на обед"
    XCTAssertEqual(
      transfers.save(
        form, occurredAt: form.occurredAt(now: noon, calendar: environment.calendar),
        books: current), .done, "a comment moves no money")
    let noted = try await freshBooks()
    XCTAssertEqual(
      transfers.delete(old, books: noted), .refused(.issue(.archivedAccount)),
      "a deletion that leaves the archived cash below zero moves the money first")
    let kept = try await show()
    XCTAssertEqual(kept.planning.freeMoney.main, AmountE4(whole: 105_000))
    XCTAssertEqual(kept.planning.accounts.inSummaryTotalRub, AmountE4(whole: 105_000))

    let check = transfers.deletion(of: old, books: noted)
    XCTAssertEqual(check.leftovers.map(\.amount), [AmountE4(whole: -1_000)])
    let settling = ArchivedMoneyForm(
      check: check, accounts: noted.dataset.paymentMethods, locale: Locale(identifier: "ru")
    ).transfers(now: noon, note: "остаток")
    XCTAssertEqual(transfers.delete(old, books: noted, settling: settling), .done)
    let deleted = try await show()
    XCTAssertEqual(deleted.planning.freeMoney.main, AmountE4(whole: 105_000))
    XCTAssertEqual(deleted.planning.accounts.inSummaryTotalRub, AmountE4(whole: 105_000))
    store.undo()
    let undone = try await freshBooks()
    XCTAssertEqual(undone.dataset.transfers.count, 2, "one ⌘Z brings the transfer back")
  }

  // MARK: The question of the app about the count

  /// «Это было до сверки в 11:00?» asked the way the forms ask it: Сбер and the cash counted
  /// at 11:00 (20 000 ₽ and 3 000 ₽). A 500 ₽ coffee dated 09:00 and typed at noon is asked
  /// about 11:00; «Да» keeps its 09:00 — it is before the count already — and the money now
  /// stays 20 000 ₽ on Сбер. A 1 000 ₽ transfer from Сбер to the cash dated 09:00 is asked
  /// about the same count; «Да» keeps its 09:00 too, as the operation did, and no balance
  /// moves. A second 1 000 ₽ transfer answered «Нет» lands after the count and moves both.
  func testTheQuestionOfTheFormsKeepsWhatIsDatedBeforeTheCountInsideIt() async throws {
    let sber = try await make(PaymentMethod(name: "Сбер", currency: .rub, isDefault: true))
    let cash = try await make(PaymentMethod(name: "Наличные", kind: .cash, currency: .rub))
    let counted = noon.addingTimeInterval(-3_600)
    let sberKey = BalanceKey(accountId: sber.id, currency: .rub)
    let cashKey = BalanceKey(accountId: cash.id, currency: .rub)
    let first = try await saveSheet(
      typed: [sberKey: AmountE4(whole: 20_000), cashKey: AmountE4(whole: 3_000)],
      record: true, at: counted)
    XCTAssertNil(first)
    let nine = noon.addingTimeInterval(-3 * 3_600)
    let calendar = environment.calendar

    var coffee = TransactionDraft(
      occurredAt: nine, amount: AmountE4(whole: 500), note: "coffee",
      paymentMethodId: sber.id)
    coffee.normalizeSinglePart()
    let entry = try coffee.materialize()
    let asked = try await show()
    let count = try XCTUnwrap(
      FormAccounts.countToAsk(about: entry, savedAt: noon, snapshot: asked, calendar: calendar),
      "an operation of the count's day typed after it is asked about")
    XCTAssertEqual(count, counted)
    let yes = FormAccounts.stamped(nine, (count, true), calendar: calendar)
    XCTAssertEqual(yes, nine, "«Да» keeps a moment before the count")
    var stamped = entry
    stamped.transaction.occurredAt = yes
    XCTAssertTrue(store.save(stamped))
    let inside = try await show()
    XCTAssertEqual(inside.planning.freeMoney.main, AmountE4(whole: 23_000))
    XCTAssertEqual(expected(sheet(inside), sber.id, .rub), AmountE4(whole: 20_000))

    var form = TransferForm(from: sber, accounts: accounts.all, day: today)
    form.chooseFrom(sber)
    form.fromCurrency = .rub
    form.toAccountId = cash.id
    form.toCurrency = .rub
    form.sent = AmountE4(whole: 1_000)
    form.received = AmountE4(whole: 1_000)
    let books = try await freshBooks()
    let draft = try XCTUnwrap(form.transfer(id: UUID(), occurredAt: nine, now: noon))
    XCTAssertTrue(form.asksAboutTheCount(draft, calendar: calendar))
    guard
      case .ask(let questions) = transfers.countStep(
        for: form, occurredAt: nine, books: books, now: noon, remembered: [:])
    else { return XCTFail("a transfer of the count's day typed after it is asked about") }
    XCTAssertEqual(questions.counts, [counted])
    guard case .stamp(let before) = questions.answer(wasBefore: true) else {
      return XCTFail("«Да» to the only count stamps")
    }
    XCTAssertEqual(before, nine, "«Да» keeps a transfer dated before the count where it was")
    XCTAssertEqual(transfers.save(form, occurredAt: before, books: books), .done)
    let held = try await show()
    XCTAssertEqual(expected(sheet(held), sber.id, .rub), AmountE4(whole: 20_000))
    XCTAssertEqual(expected(sheet(held), cash.id, .rub), AmountE4(whole: 3_000))

    guard case .stamp(let after) = questions.answer(wasBefore: false) else {
      return XCTFail("«Нет» to the only count stamps")
    }
    XCTAssertGreaterThan(after, counted)
    XCTAssertEqual(calendar.day(of: after), today)
    var second = TransferForm(from: sber, accounts: accounts.all, day: today)
    second.chooseFrom(sber)
    second.fromCurrency = .rub
    second.toAccountId = cash.id
    second.toCurrency = .rub
    second.sent = AmountE4(whole: 1_000)
    second.received = AmountE4(whole: 1_000)
    let latest = try await freshBooks()
    XCTAssertEqual(transfers.save(second, occurredAt: after, books: latest), .done)
    let moved = try await show()
    XCTAssertEqual(expected(sheet(moved), sber.id, .rub), AmountE4(whole: 19_000))
    XCTAssertEqual(expected(sheet(moved), cash.id, .rub), AmountE4(whole: 4_000))
    XCTAssertEqual(moved.planning.freeMoney.main, AmountE4(whole: 23_000))
  }

  // MARK: What an account still holds

  /// An account made with «Остаток сейчас» 5 000 ₽ and never used holds those 5 000 ₽: it is
  /// not deleted — the money would leave «Всего» with no ⌘Z to bring it back —, as it is not
  /// archived. Counted to zero with «Сохранить только» (no operation written, so nothing
  /// points at it) it is deleted, and the money now is Сбер's 100 000 ₽.
  func testAnAccountMadeWithMoneyIsDeletedOnlyOnceItIsCountedToZero() async throws {
    let sber = try await make(
      PaymentMethod(name: "Сбер", currency: .rub, isDefault: true),
      openings: [.rub: AmountE4(whole: 100_000)])
    let spare = try await make(
      PaymentMethod(name: "Копилка", kind: .cash, currency: .rub),
      openings: [.rub: AmountE4(whole: 5_000)])
    XCTAssertEqual(accounts.delete([spare.id]), .refused(.deletesWithMoney))
    XCTAssertEqual(
      accounts.delete([sber.id], newMain: spare.id), .refused(.deletesWithMoney),
      "the main account with money is not deleted either")
    XCTAssertEqual(
      accounts.all.first { $0.isDefault }?.id, sber.id, "a refused deletion passes no flag")
    let kept = try await show()
    XCTAssertEqual(kept.planning.freeMoney.main, AmountE4(whole: 105_000))
    XCTAssertTrue(accounts.all.contains { $0.id == spare.id })
    let books = try await freshBooks()
    XCTAssertEqual(accounts.archive(spare.id, books: books), .refused(.hasMoney))

    let before = try entries().count
    let zero = try await saveSheet(
      typed: [BalanceKey(accountId: spare.id, currency: .rub): .zero], record: false)
    XCTAssertNil(zero)
    XCTAssertEqual(try entries().count, before, "«Сохранить только» writes no operation")
    let counted = try await show()
    XCTAssertEqual(counted.planning.freeMoney.main, AmountE4(whole: 100_000))
    XCTAssertEqual(counted.summary.expenses.current, .zero, "a count saved only is no spending")

    XCTAssertEqual(accounts.delete([spare.id]), .done)
    XCTAssertFalse(accounts.all.contains { $0.id == spare.id })
    let gone = try await show()
    XCTAssertEqual(gone.planning.freeMoney.main, AmountE4(whole: 100_000))
  }

  // MARK: The differences in the month

  /// The differences of a later count are money of the month: 50 ₽ missing on Сбер and 12 $
  /// missing on Freedom (a group left out of the summary still spends, 12 × 90 = 1 080 ₽) are
  /// spending, 700 ₽ found on the cash is income. The month before the count spent 3 000 +
  /// 100 fee + 1 850 = 4 950 ₽ and earned 50 000 ₽; after it 6 080 ₽ and 50 700 ₽. Each
  /// difference is on its account's screen.
  func testTheDifferencesOfACountAreSpendingAndIncomeOfTheMonth() async throws {
    let books = try await openTheBooks()
    try await liveTheMonth(books)
    let before = try await show()
    XCTAssertEqual(before.summary.expenses.current, AmountE4(whole: 4_950))
    XCTAssertEqual(before.summary.income.current, AmountE4(whole: 50_000))

    let saved = try await saveSheet(
      typed: [
        BalanceKey(accountId: books.sber.id, currency: .rub): AmountE4(whole: sberAfter - 50),
        BalanceKey(accountId: books.cash.id, currency: .rub): AmountE4(whole: cashAfter + 700),
        BalanceKey(accountId: books.freedom.id, currency: .usd): AmountE4(whole: usdAfter - 12),
      ], record: true)
    XCTAssertNil(saved)
    let after = try await show()
    XCTAssertEqual(after.summary.expenses.current, AmountE4(whole: 4_950 + 50 + 1_080))
    XCTAssertEqual(after.summary.income.current, AmountE4(whole: 50_000 + 700))

    let differences = try entries().filter { $0.transaction.occurredAt == noon }
    XCTAssertEqual(differences.count, 3)
    for difference in differences {
      let account = try XCTUnwrap(difference.transaction.paymentMethodId)
      let screen = AccountHistory.build(
        accountIds: [account], dataset: after.dataset, calendar: environment.calendar)
      XCTAssertTrue(
        screen.operationIds.contains(difference.transaction.id),
        "the difference is on the screen of its account")
    }
  }

  // MARK: Groups

  /// An empty group goes to the archive, comes back with ⌘Z or «Вернуть», each one step, and is
  /// deleted for good — after which ⌘Z has nothing left to take back.
  func testAnEmptyGroupGoesToTheArchiveComesBackAndIsDeletedForGood() async throws {
    _ = try await make(PaymentMethod(name: "Сбер", currency: .rub, isDefault: true))
    let dacha = AccountGroup(name: "Дача", inSummary: true)
    XCTAssertEqual(accounts.save(group: dacha), .done)
    XCTAssertEqual(accounts.archiveGroup(dacha.id), .done)
    XCTAssertEqual(accounts.groups.first { $0.id == dacha.id }?.archived, true)
    store.undo()
    XCTAssertEqual(accounts.groups.first { $0.id == dacha.id }?.archived, false, "one ⌘Z")
    XCTAssertEqual(accounts.archiveGroup(dacha.id), .done)
    XCTAssertEqual(accounts.restoreGroup(dacha.id), .done)
    XCTAssertEqual(accounts.groups.first { $0.id == dacha.id }?.archived, false, "«Вернуть»")
    store.undo()
    XCTAssertEqual(accounts.groups.first { $0.id == dacha.id }?.archived, true, "one ⌘Z")

    XCTAssertEqual(accounts.deleteGroup(dacha.id), .done)
    XCTAssertFalse(accounts.groups.contains { $0.id == dacha.id })
    XCTAssertFalse(store.canUndo, "a deletion forgets the steps that may name the group")
  }

  /// Freedom moved out of «Казахстан» (left out of the summary) brings its 130 000 ₽ (1 000 $
  /// × 90 + 200 000 ₸ × 0.2) into the money now, and the group apart holds nothing; one ⌘Z
  /// takes it back.
  func testAnAccountMovedOutOfAGroupLeftOutBringsItsMoneyIntoTheSummary() async throws {
    let books = try await openTheBooks()
    let apart = try await show()
    XCTAssertEqual(apart.planning.freeMoney.main, AmountE4(whole: 105_000))
    XCTAssertEqual(apart.planning.freeMoney.excluded.first?.totalRub, AmountE4(whole: 130_000))

    var moved = books.freedom
    moved.groupId = nil
    let current = try await freshBooks()
    XCTAssertEqual(
      accounts.save(moved, previous: books.freedom, openings: [:], books: current), .done)
    let inside = try await show()
    XCTAssertEqual(inside.planning.freeMoney.main, AmountE4(whole: 235_000))
    XCTAssertEqual(
      AmountE4.sum(inside.planning.freeMoney.excluded.compactMap(\.totalRub)), .zero,
      "nothing is left apart")
    XCTAssertEqual(inside.planning.accounts.inSummaryTotalRub, AmountE4(whole: 235_000))

    store.undo()
    let back = try await show()
    XCTAssertEqual(back.planning.freeMoney.main, AmountE4(whole: 105_000))
    XCTAssertEqual(back.planning.freeMoney.excluded.first?.totalRub, AmountE4(whole: 130_000))
  }

  /// Freedom of «Казахстан» merged into Сбер: its dollars and tenge come with it, so the money
  /// now grows by the 130 000 ₽ that were apart.
  func testAnAccountOfAGroupLeftOutMergedIntoTheSummaryBringsItsMoneyIn() async throws {
    let books = try await openTheBooks()
    let current = try await freshBooks()
    try inOneBank(books.freedom.id, books.sber.id)
    let preview = try XCTUnwrap(
      accounts.mergePreview(books.freedom.id, into: books.sber.id, books: current))
    XCTAssertTrue(preview.needsBalance.isEmpty, "every balance of Freedom is counted")
    XCTAssertEqual(accounts.merge(preview), .done)
    let merged = try await show()
    XCTAssertEqual(merged.planning.freeMoney.main, AmountE4(whole: 235_000))
    XCTAssertEqual(
      AmountE4.sum(merged.planning.freeMoney.excluded.compactMap(\.totalRub)), .zero)
    XCTAssertEqual(expected(sheet(merged), books.sber.id, .usd), AmountE4(whole: 1_000))
    XCTAssertEqual(expected(sheet(merged), books.sber.id, kzt), AmountE4(whole: 200_000))
  }

  // MARK: Goals to the end

  /// A goal with no monthly plan: 10 000 ₽ put in stay on Сбер but are no longer money to
  /// spend — the main figure and the grey line both take them off (95 000); «Снять» 4 000 ₽
  /// gives those back (99 000); the goal in the archive saves nothing any more (105 000).
  func testAGoalWithdrawnOrArchivedGivesItsSavingsBackToBothFigures() async throws {
    let books = try await openTheBooks()
    let goal = Goal(name: "Велосипед", targetE4: AmountE4(whole: 60_000))
    _ = try await show()
    XCTAssertTrue(planning.save(goal))
    var stored = try XCTUnwrap(try environment.references?.goals().first { $0.id == goal.id })
    XCTAssertTrue(
      planning.move(
        stored, amount: AmountE4(whole: 10_000), currency: .rub,
        on: noon.addingTimeInterval(-600), account: books.sber.id, withdraw: false))
    let saved = try await show()
    XCTAssertEqual(saved.planning.freeMoney.main, AmountE4(whole: 95_000))
    XCTAssertEqual(saved.planning.freeMoney.grey, AmountE4(whole: 95_000))

    stored = try XCTUnwrap(try environment.references?.goals().first { $0.id == goal.id })
    XCTAssertTrue(
      planning.move(
        stored, amount: AmountE4(whole: 4_000), currency: .rub,
        on: noon.addingTimeInterval(-300), account: books.sber.id, withdraw: true))
    let withdrawn = try await show()
    XCTAssertEqual(withdrawn.planning.freeMoney.main, AmountE4(whole: 99_000))
    XCTAssertEqual(withdrawn.planning.freeMoney.plan.goalSavings, AmountE4(whole: 6_000))
    XCTAssertEqual(withdrawn.planning.freeMoney.grey, AmountE4(whole: 99_000))
    store.undo()
    let undone = try await show()
    XCTAssertEqual(undone.planning.freeMoney.main, AmountE4(whole: 95_000), "one ⌘Z")
    XCTAssertEqual(undone.planning.freeMoney.grey, AmountE4(whole: 95_000), "one ⌘Z")

    stored = try XCTUnwrap(try environment.references?.goals().first { $0.id == goal.id })
    XCTAssertTrue(planning.archive(stored))
    let archived = try await show()
    XCTAssertEqual(archived.planning.freeMoney.plan.goalSavings, .zero)
    XCTAssertEqual(archived.planning.freeMoney.grey, AmountE4(whole: 105_000))
    XCTAssertEqual(archived.planning.freeMoney.main, AmountE4(whole: 105_000))
  }

  // MARK: A year ahead

  /// D a year ahead (16.09.2027): the 7 000 ₽ rent due on the 20th comes twelve times
  /// (20.09.2026 … 20.08.2027), a 50 000 ₽ goal planned at 10 000 ₽ a month with nothing
  /// saved holds back no more than the 50 000 ₽ it still lacks, not thirteen months of plan,
  /// and a 30 000 ₽ debt paid 5 000 ₽ on the 25th no more than the 30 000 ₽ left of it, not
  /// twelve payments. Grey = 105 000 − 12 × 7 000 − 50 000 − 30 000 = −59 000.
  func testAYearAheadTakesTwelveBillsAndNoMoreOfTheGoalOrTheDebtThanIsLeft() async throws {
    let books = try await openTheBooks()
    let bill = ScheduledPayment(
      name: "Аренда", amountE4: AmountE4(whole: 7_000), paymentMethodId: books.sber.id,
      day: 20, nextDate: DateOnly(year: 2026, month: 9, day: 20))
    XCTAssertTrue(planning.save(bill, previous: nil))
    _ = try await show()
    XCTAssertTrue(
      planning.save(
        Goal(
          name: "Машина", targetE4: AmountE4(whole: 50_000),
          monthlyPlanE4: AmountE4(whole: 10_000))))
    _ = try await show()
    let loan = Debt(
      direction: .iOwe, type: .personal, name: "Брат", monthlyPaymentE4: AmountE4(whole: 5_000),
      paymentDay: 25)
    XCTAssertTrue(
      DebtActions(deps).create(
        loan, balance: AmountE4(whole: 30_000), on: today, moneyMovedNow: false))
    let snapshot = try await show()
    let year = snapshot.planning.freeMoney(
      until: DateOnly(year: 2027, month: 9, day: 16), ledger: snapshot.ledger)
    XCTAssertEqual(year.until, DateOnly(year: 2027, month: 9, day: 16))
    XCTAssertEqual(year.plan.scheduled, AmountE4(whole: 12 * 7_000))
    XCTAssertEqual(year.plan.goalPlans, AmountE4(whole: 50_000))
    XCTAssertEqual(year.plan.debts, AmountE4(whole: 30_000))
    XCTAssertEqual(year.grey, AmountE4(whole: 105_000 - 84_000 - 50_000 - 30_000))
    XCTAssertEqual(year.main, AmountE4(whole: 105_000), "a debt with no money moved is no money")
  }

  // MARK: Moves after now

  /// A 1 000 ₽ purchase and a 2 000 ₽ transfer to the cash dated 15:00 today, while the clock
  /// says noon, wait for their moment: no balance moves yet.
  func testWhatIsDatedAfterNowWaitsForItsMoment() async throws {
    let books = try await openTheBooks()
    let later = noon.addingTimeInterval(3 * 3_600)
    try spend(1_000, on: books.sber.id, at: later)
    try await transfer(from: books.sber, .rub, to: books.cash, .rub, sent: 2_000, at: later)
    let snapshot = try await show()
    XCTAssertEqual(snapshot.planning.freeMoney.main, AmountE4(whole: 105_000))
    XCTAssertEqual(expected(sheet(snapshot), books.sber.id, .rub), AmountE4(whole: 100_000))
    XCTAssertEqual(expected(sheet(snapshot), books.cash.id, .rub), AmountE4(whole: 5_000))
  }

  // MARK: A refund after the count

  /// A 3 000 ₽ purchase at 09:00, Сбер counted at 10:00 as the books expect (97 000 ₽), 1 000 ₽
  /// of it back at 11:00: the refund moves Сбер after the count (98 000 ₽), the purchase stays
  /// in its month 2 000 ₽ cheaper, and the refund is no income.
  func testARefundAfterTheCountMovesTheMoneyThenAndThePurchaseInItsMonth() async throws {
    let books = try await openTheBooks()
    let groceries = CoreKit.Category(kind: .expense, name: "Продукты")
    try XCTUnwrap(environment.references).save(groceries)
    var draft = TransactionDraft(
      occurredAt: noon.addingTimeInterval(-3 * 3_600), amount: AmountE4(whole: 3_000),
      note: "groceries", paymentMethodId: books.sber.id)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = groceries.id
    let purchase = try draft.materialize()
    XCTAssertTrue(store.save(purchase))
    let asExpected = try await saveSheet(
      typed: [:], record: true, at: noon.addingTimeInterval(-7_200))
    XCTAssertNil(asExpected)

    var back = TransactionDraft(
      kind: .refund, occurredAt: noon.addingTimeInterval(-3_600),
      amount: AmountE4(whole: 1_000), paymentMethodId: books.sber.id)
    back.normalizeSinglePart()
    back.parts[0].categoryId = groceries.id
    back.parts[0].refundOfPartId = purchase.parts.first?.id
    XCTAssertTrue(store.save(try back.materialize()))

    let snapshot = try await show()
    XCTAssertEqual(expected(sheet(snapshot), books.sber.id, .rub), AmountE4(whole: 98_000))
    XCTAssertEqual(snapshot.planning.freeMoney.main, AmountE4(whole: 98_000 + 5_000))
    XCTAssertEqual(snapshot.summary.expenses.current, AmountE4(whole: 2_000))
    XCTAssertEqual(snapshot.summary.income.current, .zero)
  }

  // MARK: The screen of a group and more steps of ⌘Z

  /// The screen of Сбер and the cash together, as a group of the two: the day lists the
  /// coffee, the salary, the dollar purchase, the fee and the transfer between them once; the
  /// transfer stayed inside, so it shows its amount with no sign; the day spent the coffee, the
  /// fee and the purchase (3 000 + 100 + 1 850 = 4 950 ₽) and earned 50 000 ₽ — the transfer
  /// is neither.
  func testTheScreenOfAGroupShowsATransferInsideItOnceAndSpendsOnlyItsFee() async throws {
    let books = try await openTheBooks()
    try await liveTheMonth(books)
    let snapshot = try await show()
    let ids: Set<UUID> = [books.sber.id, books.cash.id]
    let group = AccountHistory.build(
      accountIds: ids, dataset: snapshot.dataset, calendar: environment.calendar)
    let day = try XCTUnwrap(group.days.first)
    XCTAssertEqual(group.days.map(\.day), [today])
    let transfersListed = day.items.compactMap { item -> Transfer? in
      if case .transfer(let transfer) = item { return transfer }
      return nil
    }
    XCTAssertEqual(transfersListed.count, 1, "the transfer between the two is listed once")
    XCTAssertEqual(day.items.count, 5, "coffee, salary, purchase, fee, transfer")
    XCTAssertEqual(day.totals.myExpenses, AmountE4(whole: 4_950))
    XCTAssertEqual(day.totals.income, AmountE4(whole: 50_000))

    let money = MoneyFormatter(locale: Locale(identifier: "ru"))
    let inside = try XCTUnwrap(transfersListed.first)
    let text = AccountHistory.amountText(inside, accountIds: ids, money: money)
    XCTAssertEqual(text, money.exact(AmountE4(whole: 10_000), currency: .rub))
    XCTAssertEqual(
      AccountHistory.amountText(inside, accountIds: [books.sber.id], money: money),
      "\u{2212}" + text, "seen from Сбер alone the money left")
  }

  /// «Вернуть», a drag in the list, «по алфавиту», the deletion of a transfer and a
  /// contribution to a goal are one step of ⌘Z each.
  func testRestoreDragAlphabetTransferDeletionAndContributionAreOneStepEach() async throws {
    let books = try await openTheBooks()
    let spare = try await make(PaymentMethod(name: "Kaspi", currency: .rub))
    let empty = try await freshBooks()
    XCTAssertEqual(accounts.archive(spare.id, books: empty), .done)
    XCTAssertEqual(accounts.restore(spare.id), .done)
    XCTAssertEqual(accounts.all.first { $0.id == spare.id }?.archived, false)
    store.undo()
    XCTAssertEqual(
      accounts.all.first { $0.id == spare.id }?.archived, true, "⌘Z takes «Вернуть» back")

    func order() -> [UUID] { accounts.ordered(accounts.all.filter { !$0.archived }).map(\.id) }
    let byName = order()
    XCTAssertEqual(byName.first, books.sber.id, "the main account first")
    XCTAssertEqual(byName.count, 3)
    XCTAssertEqual(accounts.move(byName[1], by: 1), .done)
    let dragged = order()
    XCTAssertEqual(dragged, [byName[0], byName[2], byName[1]])
    store.undo()
    XCTAssertEqual(order(), byName, "one ⌘Z undoes the drag")
    XCTAssertEqual(accounts.move(byName[1], by: 1), .done)
    XCTAssertEqual(accounts.alphabetize(), .done)
    XCTAssertEqual(order(), byName)
    store.undo()
    XCTAssertEqual(order(), dragged, "one ⌘Z undoes «по алфавиту»")

    try await transfer(
      from: books.sber, .rub, to: books.cash, .rub, sent: 2_000, fee: 50,
      at: noon.addingTimeInterval(-3_600))
    let written = try await freshBooks()
    let made = try XCTUnwrap(written.dataset.transfers.first)
    XCTAssertEqual(transfers.delete(made, books: written), .done)
    let deleted = try await show()
    XCTAssertEqual(expected(sheet(deleted), books.sber.id, .rub), AmountE4(whole: 100_000))
    store.undo()
    let back = try await show()
    XCTAssertEqual(
      expected(sheet(back), books.sber.id, .rub), AmountE4(whole: 100_000 - 2_000 - 50),
      "one ⌘Z brings the transfer back with its fee")
    XCTAssertEqual(expected(sheet(back), books.cash.id, .rub), AmountE4(whole: 7_000))

    let goal = Goal(name: "Отпуск", targetE4: AmountE4(whole: 50_000))
    XCTAssertTrue(planning.save(goal))
    let stored = try XCTUnwrap(try environment.references?.goals().first { $0.id == goal.id })
    XCTAssertTrue(
      planning.move(
        stored, amount: AmountE4(whole: 3_000), currency: .rub,
        on: noon.addingTimeInterval(-600), account: books.sber.id, withdraw: false))
    let saved = try await show()
    XCTAssertEqual(saved.planning.freeMoney.plan.goalSavings, AmountE4(whole: 3_000))
    store.undo()
    let undone = try await show()
    XCTAssertEqual(undone.planning.freeMoney.plan.goalSavings, .zero, "one ⌘Z, one contribution")
    XCTAssertEqual(
      undone.planning.freeMoney.main, AmountE4(whole: 105_000 - 50),
      "only the fee left the money; a contribution never moves it")
  }

  /// An operation of an account in the archive written by the store's plain save, which asks
  /// nothing — the question about the money is the editor's, and its transfer goes with
  /// `saveEdit`: the cash emptied by a 5 000 ₽ purchase and archived, the purchase then saved as
  /// 4 000 ₽. The 1 000 ₽ back on the archived cash is on the sheet but in no total, which is
  /// why the editor asks first.
  func testAnEditOfAnOperationOfAnArchivedAccountPutsMoneyWhereNoTotalSeesIt() async throws {
    let books = try await openTheBooks()
    let purchase = try spend(5_000, on: books.cash.id, at: noon.addingTimeInterval(-5 * 3_600))
    let emptied = try await freshBooks()
    XCTAssertEqual(accounts.archive(books.cash.id, books: emptied), .done)

    var cheaper = purchase
    cheaper.transaction.amountE4 = AmountE4(whole: 4_000)
    cheaper.transaction.amountRubE4 = AmountE4(whole: 4_000)
    cheaper.parts[0].amountE4 = AmountE4(whole: 4_000)
    cheaper.parts[0].amountRubE4 = AmountE4(whole: 4_000)
    XCTAssertTrue(store.save(cheaper), "the store's plain save")

    let snapshot = try await show()
    XCTAssertEqual(
      sheet(snapshot).first { $0.key.accountId == books.cash.id }?.expected,
      AmountE4(whole: 1_000))
    XCTAssertEqual(snapshot.planning.freeMoney.main, AmountE4(whole: 100_000))
    XCTAssertEqual(snapshot.summary.expenses.current, AmountE4(whole: 4_000))
  }

  // MARK: Money lent and given back

  /// 20 000 ₽ lent to a friend from Сбер: the money now drops from 105 000 to 85 000 ₽ and
  /// nothing is spent; 8 000 ₽ given back onto Сбер brings it to 93 000 ₽ and is no income;
  /// one ⌘Z takes the 8 000 ₽ back off.
  func testMoneyLentLeavesTheAccountAndComesBackWithoutBeingSpentOrEarned() async throws {
    let books = try await openTheBooks()
    _ = try await show()
    let debts = DebtActions(deps)
    let lent = Debt(direction: .owedToMe, type: .personal, name: "Друг")
    XCTAssertTrue(
      debts.create(
        lent, balance: AmountE4(whole: 20_000), on: today, moneyMovedNow: true,
        account: books.sber.id, at: noon.addingTimeInterval(-2 * 3_600)))
    let out = try await show()
    XCTAssertEqual(out.planning.freeMoney.main, AmountE4(whole: 85_000))
    XCTAssertEqual(expected(sheet(out), books.sber.id, .rub), AmountE4(whole: 80_000))
    XCTAssertEqual(out.summary.expenses.current, .zero, "money lent is not spent")

    let saved = try XCTUnwrap(try environment.references?.debts(includeClosed: true).first)
    XCTAssertTrue(
      debts.pay(
        saved, amount: AmountE4(whole: 8_000), on: noon.addingTimeInterval(-600),
        paymentMethodId: books.sber.id))
    let back = try await show()
    XCTAssertEqual(back.planning.freeMoney.main, AmountE4(whole: 93_000))
    XCTAssertEqual(back.summary.income.current, .zero, "money given back is no income")
    XCTAssertEqual(back.summary.expenses.current, .zero)

    store.undo()
    let undone = try await show()
    XCTAssertEqual(undone.planning.freeMoney.main, AmountE4(whole: 85_000), "one ⌘Z")
  }

  // MARK: The main account merged away

  /// Сбер, the main account, merged into the cash: the cash becomes the main account and the
  /// money now stays 105 000 ₽, all of it on the cash.
  func testTheMainAccountMergedIntoAnotherPassesTheFlagAndKeepsTheMoney() async throws {
    let books = try await openTheBooks()
    let current = try await freshBooks()
    try inOneBank(books.sber.id, books.cash.id)
    let preview = try XCTUnwrap(
      accounts.mergePreview(books.sber.id, into: books.cash.id, books: current))
    XCTAssertEqual(accounts.merge(preview), .done)
    XCTAssertEqual(accounts.all.first { $0.isDefault && !$0.archived }?.id, books.cash.id)
    let merged = try await show()
    XCTAssertEqual(merged.planning.freeMoney.main, AmountE4(whole: 105_000))
    XCTAssertEqual(expected(sheet(merged), books.cash.id, .rub), AmountE4(whole: 105_000))
  }

  // MARK: A bill on the day of the count, a merge, goal money spent

  /// A bill due on the day of the latest count waits for its payment: counted at 06:00 of
  /// 16 September, a 7 000 ₽ rent due that day is held back until it is paid (grey 98 000 ₽,
  /// the money still 105 000 ₽). «Провести» asks «Это было до сверки в 06:00?». «Да» puts the
  /// payment inside the count, which already holds the money gone: the rent closes without a
  /// second deduction, 105 000 ₽ both. «Нет» (after one ⌘Z) dates it after the count, so it
  /// moves the money and the rent is taken away once: 98 000 ₽ both.
  func testABillDueOnTheDayOfTheCountWaitsForItsPayment() async throws {
    let books = try await openTheBooks()
    let count = noon.addingTimeInterval(-6 * 3_600)
    let bill = ScheduledPayment(
      name: "Аренда", amountE4: AmountE4(whole: 7_000), paymentMethodId: books.sber.id,
      day: 16, nextDate: today)
    XCTAssertTrue(planning.save(bill, previous: nil))
    let waiting = try await show()
    XCTAssertEqual(waiting.planning.freeMoney.main, AmountE4(whole: 105_000))
    XCTAssertEqual(waiting.planning.freeMoney.grey, AmountE4(whole: 98_000))

    let stored = try XCTUnwrap(waiting.planning.book.scheduled.first)
    guard
      case .sameDay(.ask(let questions)) = planning.countQuestion(
        paying: .scheduled(stored, amount: AmountE4(whole: 7_000)), due: today,
        on: noon.addingTimeInterval(-600), savedAt: noon)
    else { return XCTFail("«Провести» on the day of the count did not ask about it") }
    XCTAssertEqual(questions.counts, [count])

    guard case .stamp(let before) = questions.answer(wasBefore: true) else {
      return XCTFail("«Да, до сверки» asked about another count")
    }
    XCTAssertLessThan(before, count)
    XCTAssertTrue(
      planning.markAsPaid(
        stored, due: today, amount: AmountE4(whole: 7_000), on: before,
        paymentMethodId: books.sber.id, updatePrice: false))
    let inside = try await show()
    XCTAssertEqual(
      inside.planning.freeMoney.main, AmountE4(whole: 105_000),
      "the count already holds the rent gone")
    XCTAssertEqual(
      inside.planning.freeMoney.grey, AmountE4(whole: 105_000), "the rent is still held back")

    store.undo()
    let again = try await show()
    XCTAssertEqual(again.planning.freeMoney.grey, AmountE4(whole: 98_000), "one ⌘Z")

    guard case .stamp(let after) = questions.answer(wasBefore: false) else {
      return XCTFail("«Нет» asked about another count")
    }
    XCTAssertGreaterThan(after, count)
    XCTAssertTrue(
      planning.markAsPaid(
        stored, due: today, amount: AmountE4(whole: 7_000), on: after,
        paymentMethodId: books.sber.id, updatePrice: false))
    let paid = try await show()
    XCTAssertEqual(paid.planning.freeMoney.main, AmountE4(whole: 98_000))
    XCTAssertEqual(paid.planning.freeMoney.grey, AmountE4(whole: 98_000))
  }

  /// A merge is no count: the merged account rests on the last real count of the two, so a
  /// bill of that account overdue since then is still unpaid. Counted on 1 September, a 7 000 ₽
  /// rent due on the 10th and not paid is held back on the 16th (grey 98 000 ₽); the cash
  /// merged into Сбер, it still is — nothing was paid.
  func testAMergeIsNoCountForAnOverdueBill() async throws {
    let first = environment.calendar.noon(of: DateOnly(year: 2026, month: 9, day: 1))
    moment = first
    let sber = PaymentMethod(name: "Сбер", currency: .rub, isDefault: true)
    let cash = PaymentMethod(name: "Наличные", kind: .cash, currency: .rub)
    let empty = try await freshBooks()
    XCTAssertEqual(
      accounts.save(
        sber, previous: nil, openings: [.rub: AmountE4(whole: 100_000)], books: empty), .done)
    let one = try await freshBooks()
    XCTAssertEqual(
      accounts.save(
        cash, previous: nil, openings: [.rub: AmountE4(whole: 5_000)], books: one), .done)
    moment = noon
    let bill = ScheduledPayment(
      name: "Аренда", amountE4: AmountE4(whole: 7_000), paymentMethodId: sber.id,
      day: 10, nextDate: DateOnly(year: 2026, month: 9, day: 10))
    XCTAssertTrue(planning.save(bill, previous: nil))
    let overdue = try await show()
    XCTAssertEqual(overdue.planning.freeMoney.main, AmountE4(whole: 105_000))
    XCTAssertEqual(overdue.planning.freeMoney.grey, AmountE4(whole: 98_000))

    let both = try await freshBooks()
    try inOneBank(cash.id, sber.id)
    let preview = try XCTUnwrap(accounts.mergePreview(cash.id, into: sber.id, books: both))
    XCTAssertEqual(accounts.merge(preview), .done)
    let merged = try await show()
    XCTAssertEqual(merged.planning.freeMoney.main, AmountE4(whole: 105_000))
    XCTAssertEqual(merged.planning.freeMoney.grey, AmountE4(whole: 98_000))
  }

  /// Money of a goal spent by an ordinary operation, without «Снять»: 100 000 ₽ put into a goal
  /// with no plan leaves 5 000 ₽ free; a 100 000 ₽ hotel paid from Сбер takes the money on the
  /// accounts to 5 000 ₽ while the goal still holds its savings, so both figures take them away
  /// again: −95 000 ₽ — the goals hold more than the accounts, the case in which Overview asks
  /// «Потратили деньги цели? Нажмите «Забрать»». «Снять» first keeps both at 5 000 ₽, and
  /// nothing is asked.
  func testGoalMoneySpentWithoutWithdrawingStaysTakenAwayUntilWithdrawn() async throws {
    let books = try await openTheBooks()
    let goal = Goal(name: "Отпуск", targetE4: AmountE4(whole: 200_000))
    _ = try await show()
    XCTAssertTrue(planning.save(goal))
    var stored = try XCTUnwrap(try environment.references?.goals().first { $0.id == goal.id })
    XCTAssertTrue(
      planning.move(
        stored, amount: AmountE4(whole: 100_000), currency: .rub,
        on: noon.addingTimeInterval(-900), account: books.sber.id, withdraw: false))
    let saved = try await show()
    XCTAssertEqual(saved.planning.freeMoney.main, AmountE4(whole: 5_000))
    XCTAssertEqual(saved.planning.freeMoney.grey, AmountE4(whole: 5_000))
    XCTAssertFalse(saved.planning.freeMoney.goalsExceedMoney)

    let hotel = try spend(100_000, on: books.sber.id, at: noon.addingTimeInterval(-600))
    let twice = try await show()
    XCTAssertEqual(twice.planning.freeMoney.main, AmountE4(whole: -95_000))
    XCTAssertEqual(twice.planning.freeMoney.grey, AmountE4(whole: -95_000))
    XCTAssertEqual(twice.planning.freeMoney.moneyNow, AmountE4(whole: 5_000))
    XCTAssertEqual(twice.planning.freeMoney.goalSavings, AmountE4(whole: 100_000))
    XCTAssertTrue(
      twice.planning.freeMoney.goalsExceedMoney, "Overview does not ask about the goal money")

    XCTAssertTrue(store.delete(id: hotel.id))
    stored = try XCTUnwrap(try environment.references?.goals().first { $0.id == goal.id })
    XCTAssertTrue(
      planning.move(
        stored, amount: AmountE4(whole: 100_000), currency: .rub,
        on: noon.addingTimeInterval(-700), account: books.sber.id, withdraw: true))
    try spend(100_000, on: books.sber.id, at: noon.addingTimeInterval(-600))
    let once = try await show()
    XCTAssertEqual(once.planning.freeMoney.main, AmountE4(whole: 5_000))
    XCTAssertEqual(once.planning.freeMoney.grey, AmountE4(whole: 5_000))
    XCTAssertFalse(once.planning.freeMoney.goalsExceedMoney)
  }

  // MARK: Helpers

  private var deps: AppDependencies {
    AppDependencies(environment: environment, store: store, compute: compute)
  }
  private var accounts: AccountActions { AccountActions(environment: environment, store: store) }
  private var transfers: TransferActions { TransferActions(environment: environment, store: store) }
  private var planning: PlanningActions { PlanningActions(deps) }

  private var version = 0

  /// The data every screen reads, as the pipeline would build it now, at the test's rates.
  @discardableResult
  private func show() async throws -> DataSnapshot {
    let stack = try XCTUnwrap(environment.stack)
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    version += 1
    let snapshot = DataSnapshot.build(
      dataset: dataset, calendar: environment.calendar, today: today,
      context: SnapshotContext(rubPerUnit: rates), version: DataVersion(load: version),
      now: noon)
    compute.applyLight(snapshot)
    return snapshot
  }

  /// A new account saved through the editor at 06:00 of the day, with «Остаток сейчас» for its
  /// currencies — counted then, so the moves of the day come after the count.
  private func make(
    _ account: PaymentMethod, openings: [CurrencyCode: AmountE4] = [:]
  ) async throws -> PaymentMethod {
    moment = noon.addingTimeInterval(-6 * 3_600)
    defer { moment = noon }
    let books = try await freshBooks()
    XCTAssertEqual(
      accounts.save(account, previous: nil, openings: openings, books: books), .done,
      account.name)
    return try XCTUnwrap(accounts.all.first { $0.id == account.id })
  }

  /// Only accounts of one bank merge: the bank of `source` is merged into the bank of `target`
  /// first, as the owner would — one step of ⌘Z, which the account merge then forgets.
  private func inOneBank(_ source: UUID, _ target: UUID) throws {
    let all = accounts.all
    let from = try XCTUnwrap(all.first { $0.id == source }?.bankId)
    let into = try XCTUnwrap(all.first { $0.id == target }?.bankId)
    guard from != into else { return }
    XCTAssertEqual(accounts.mergeBank(from, into: into), .done)
  }

  private func freshBooks() async throws -> AccountBooks {
    let books = await accounts.books()
    return try XCTUnwrap(books)
  }

  private func balance(_ books: AccountBooks, _ id: UUID, _ currency: CurrencyCode) -> AmountE4? {
    books.balances.balance(BalanceKey(accountId: id, currency: currency), at: noon)
  }

  /// The rows of the reconciliation sheet at noon.
  private func sheet(_ snapshot: DataSnapshot) -> [ReconcileRow] {
    ReconcileSheet.rows(of: snapshot, at: noon, first: nil, locale: Locale(identifier: "en"))
  }

  private func expected(_ rows: [ReconcileRow], _ id: UUID, _ currency: CurrencyCode) -> AmountE4? {
    rows.first { $0.key == BalanceKey(accountId: id, currency: currency) }?.expected
  }

  /// The sheet saved as the owner leaves it: `typed` where he typed, the rest as expected.
  private func saveSheet(
    typed: [BalanceKey: AmountE4], record: Bool, at t0: Date? = nil
  ) async throws -> PlanningActions.ReconcileFailure? {
    let snapshot = try await show()
    let rows = ReconcileSheet.rows(
      of: snapshot, at: t0 ?? noon, first: nil, locale: Locale(identifier: "en"))
    let counted = try XCTUnwrap(ReconcileSheet.counted(rows: rows, typed: typed, blank: []))
    return planning.reconcile(
      counted: counted, rows: rows, recordDifference: record, at: t0 ?? noon)
  }

  private func entries() throws -> [TransactionEntry] {
    try XCTUnwrap(environment.transactions).entries(from: .distantPast, to: .distantFuture)
      .filter { !$0.transaction.isDeleted }
  }

  @discardableResult
  private func spend(
    _ whole: Int64, currency: CurrencyCode = .rub, charged: Int64? = nil, on accountId: UUID,
    at: Date
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(
      occurredAt: at, currency: currency, amount: AmountE4(whole: whole),
      rate: currency == .rub ? nil : rates[currency], note: "coffee", paymentMethodId: accountId)
    if let charged {
      draft.accountCurrency = .rub
      draft.accountAmount = AmountE4(whole: charged)
    }
    draft.normalizeSinglePart()
    let rate = draft.rate
    let entry = try draft.materialize { amount in
      guard let rate else { return amount }
      return try AmountE4(decimal: amount.decimal * rate)
    }
    XCTAssertTrue(store.save(entry))
    return entry
  }

  private func earn(_ whole: Int64, on accountId: UUID, at: Date) throws {
    var draft = TransactionDraft(
      kind: .income, occurredAt: at, amount: AmountE4(whole: whole), note: "salary",
      paymentMethodId: accountId)
    draft.normalizeSinglePart()
    XCTAssertTrue(store.save(try draft.materialize()))
  }

  private func transfer(
    from: PaymentMethod, _ fromCurrency: CurrencyCode, to: PaymentMethod,
    _ toCurrency: CurrencyCode, sent: Int64, received: Int64? = nil, fee: Int64 = 0, at: Date
  ) async throws {
    var form = TransferForm(from: from, accounts: accounts.all, day: today)
    form.chooseFrom(from)
    form.fromCurrency = fromCurrency
    form.toAccountId = to.id
    form.toCurrency = toCurrency
    form.sent = AmountE4(whole: sent)
    form.received = AmountE4(whole: received ?? sent)
    form.fee = AmountE4(whole: fee)
    let books = try await freshBooks()
    XCTAssertEqual(transfers.save(form, occurredAt: at, books: books), .done)
  }
}
