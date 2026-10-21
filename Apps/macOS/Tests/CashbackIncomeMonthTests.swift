import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Cashback that the bank pays by a day of the next month is the income of the month before: a
/// new income in the cashback category gets that month in the ↓ panel unless the owner picks
/// another, and the account's screen then sees the month as paid.
@MainActor
final class CashbackIncomeMonthTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  private let tBank = PaymentMethod(
    name: "Т-Банк", kind: .card, currency: .rub, isDefault: true,
    cashbackPayout: CashbackPayout.later(day: 10))
  private let cash = PaymentMethod(name: "Наличные", kind: .cash, currency: .rub)
  private let cashback = CoreKit.Category(kind: .income, name: "Кэшбэк")
  private let salary = CoreKit.Category(kind: .income, name: "Зарплата")
  private let calendar = CalendarContext.utc

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-cashback-month-\(UUID().uuidString)", isDirectory: true)
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
    let references = try XCTUnwrap(environment.references)
    for account in [tBank, cash] { try references.save(account) }
    for category in [cashback, salary] { try references.save(category) }
    try XCTUnwrap(environment.settings).set(
      AnalyticsSettings.cashbackCategoryKey, to: cashback.id.uuidString)
  }

  override func tearDown() async throws {
    await environment.close()
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    try? FileManager.default.removeItem(at: directory)
  }

  private var today: DateOnly { environment.today }
  private let march = MonthKey(year: 2026, month: 3)
  private let february = MonthKey(year: 2026, month: 2)

  private func noon(_ day: Int, of month: MonthKey = MonthKey(year: 2026, month: 3)) -> Date {
    environment.calendar.noon(of: DateOnly(year: month.year, month: month.month, day: day))
  }

  /// A new income of 120 in the panel, dated `day` of March, on T-Bank.
  private func income(on day: Int, category: CoreKit.Category) -> EntryDraftModel {
    let model = EntryDraftModel(environment: environment)
    model.reload()
    model.draft.kind = .income
    model.applyDefaults(today: today)
    model.setTotal(AmountE4(whole: 120))
    model.setDate(noon(day), today: today)
    model.setPaymentMethod(tBank.id)
    model.setCategory(category.id, forPartAt: 0)
    return model
  }

  /// Cashback on March 5th, the bank paying by the 10th: February's, shown and said so; saved
  /// with February as its month.
  func testCashbackBeforeThePayoutDayIsTheMonthBefore() throws {
    let model = income(on: 5, category: cashback)
    XCTAssertEqual(model.draft.periodMonth, february)
    XCTAssertEqual(model.shownPeriodMonth, february)
    XCTAssertTrue(model.periodMonthIsCashbackOfTheMonthBefore)

    model.takeTheMomentOfSaving()
    let written = try XCTUnwrap(try EntrySave.write(model, environment: environment, store: store))
    let stored = try XCTUnwrap(try XCTUnwrap(environment.transactions).entry(id: written.entry.id))
    XCTAssertEqual(stored.transaction.periodMonth, february)
  }

  /// After the payout day, a salary, an account that has not said how its bank pays: the month
  /// of the date.
  func testOtherwiseTheMonthOfTheDate() {
    XCTAssertNil(income(on: 11, category: cashback).draft.periodMonth)
    XCTAssertNil(income(on: 5, category: salary).draft.periodMonth)

    let onCash = income(on: 5, category: cashback)
    onCash.setPaymentMethod(cash.id)
    XCTAssertNil(onCash.draft.periodMonth, "cash has not said when its bank pays")
    XCTAssertFalse(onCash.periodMonthIsCashbackOfTheMonthBefore)
  }

  /// The default follows the category, the account and the date until the owner picks a month.
  func testTheDefaultFollowsUntilTheOwnerPicks() {
    let model = income(on: 5, category: salary)
    XCTAssertNil(model.draft.periodMonth)
    model.setCategory(cashback.id, forPartAt: 0)
    XCTAssertEqual(model.draft.periodMonth, february)
    model.setDate(noon(20), today: today)
    XCTAssertNil(model.draft.periodMonth, "the 20th is after the payout day")
    model.setDate(noon(9), today: today)
    XCTAssertEqual(model.draft.periodMonth, february)
    model.draft.kind = .expense
    model.applyDefaults(today: today)
    XCTAssertNil(model.draft.periodMonth, "an expense is for no month")
  }

  /// A month picked in the panel stays — even the month of the date, and whatever changes after.
  func testAMonthPickedByHandStays() {
    let model = income(on: 5, category: cashback)
    model.choosePeriodMonth(march)
    XCTAssertEqual(model.draft.periodMonth, march)
    XCTAssertFalse(model.periodMonthIsCashbackOfTheMonthBefore)
    model.setDate(noon(4), today: today)
    model.setCategory(salary.id, forPartAt: 0)
    model.setCategory(cashback.id, forPartAt: 0)
    XCTAssertEqual(model.draft.periodMonth, march)

    // The next operation starts afresh.
    model.reset()
    XCTAssertNil(model.draft.periodMonth)
  }

  /// A saved operation keeps the month it was saved with: the editor lays no default.
  func testTheEditorKeepsTheSavedMonth() throws {
    let saved = TransactionEntry(
      transaction: Transaction(
        kind: .income, occurredAt: noon(5), amountE4: AmountE4(whole: 120),
        paymentMethodId: tBank.id, createdAt: noon(5), updatedAt: noon(5)),
      parts: [])
    var draft = TransactionDraft(entry: saved)
    draft.parts = [PartDraft(categoryId: cashback.id, amount: AmountE4(whole: 120))]
    let editor = EntryDraftModel(environment: environment, editsSavedOperation: true)
    editor.reload()
    editor.draft = draft
    XCTAssertNil(editor.draft.periodMonth)
    editor.setDate(noon(6), today: today)
    XCTAssertNil(editor.draft.periodMonth)
  }

  // MARK: The account's screen

  /// September's purchases on T-Bank, 5 % of 1,000 expected; cashback of 50 comes on October
  /// 8th with the month the panel lays. On October 12th September is paid, not late.
  func testTheAccountScreenSeesTheMonthPaid() throws {
    let cafes = CoreKit.Category(kind: .expense, name: "Cafes")
    let september = MonthKey(year: 2026, month: 9)
    let october8 = DateOnly(year: 2026, month: 10, day: 8)
    func operation(
      _ kind: TransactionKind, on day: DateOnly, _ category: UUID, _ amount: Int64,
      period: MonthKey?
    ) -> TransactionEntry {
      let at = calendar.noon(of: day)
      let transaction = Transaction(
        kind: kind, occurredAt: at, amountE4: AmountE4(whole: amount), paymentMethodId: tBank.id,
        periodMonth: period, createdAt: at, updatedAt: at)
      return TransactionEntry(
        transaction: transaction,
        parts: [
          TransactionPart(
            transactionId: transaction.id, categoryId: category,
            amountE4: AmountE4(whole: amount))
        ])
    }
    let categories = [cafes, cashback]
    let laid = CashbackIncomeMonth.month(
      forIncomeOn: october8, categoryIds: [cashback.id], accountId: tBank.id,
      cashbackCategoryId: cashback.id, tree: CategoryTree(categories), accounts: [tBank],
      calendar: calendar)
    XCTAssertEqual(laid, september)
    let dataset = Dataset(
      entries: [
        operation(
          .expense, on: DateOnly(year: 2026, month: 9, day: 12), cafes.id, 1_000, period: nil),
        operation(.income, on: october8, cashback.id, 50, period: laid),
      ],
      categories: categories, paymentMethods: [tBank],
      settings: AnalyticsSettings(cashbackCategoryId: cashback.id),
      cashbackRules: [
        CashbackRule(
          accountId: tBank.id, categoryId: cafes.id, percent: CashbackPercent(e4: 50_000)!)
      ])
    let model = AccountCashbackModel.build(
      month: MonthKey(year: 2026, month: 10), accountId: tBank.id,
      ledger: Ledger(dataset: dataset, calendar: calendar),
      today: DateOnly(year: 2026, month: 10, day: 12))
    XCTAssertNil(model.late, "September's cashback came")
    XCTAssertEqual(
      CashbackSchedule.status(
        of: september, payout: tBank.cashbackPayout,
        today: DateOnly(year: 2026, month: 10, day: 12),
        expectedRub: AmountE4(whole: 50),
        receivedRub: AmountE4.sum(
          AccountCashbackSummary.month(
            september, accountId: tBank.id, ledger: Ledger(dataset: dataset, calendar: calendar)
          ).map(\.receivedRub)),
        calendar: calendar),
      .paid(DateOnly(year: 2026, month: 10, day: 10)))
  }
}
