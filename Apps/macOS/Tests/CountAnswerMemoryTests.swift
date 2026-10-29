import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Больше не спрашивать для этой сверки»: the answer is kept by the reconciliation it was
/// about, read back from the database at once, and let go of when that reconciliation is no
/// count of the latest counted day of any balance any more.
@MainActor
final class CountAnswerMemoryTests: XCTestCase {
  private var environment: AppEnvironment!
  private var account: PaymentMethod!
  private var cash: PaymentMethod!

  override func setUp() async throws {
    environment = AppEnvironment()
    environment.calendar = .utc  // days are UTC days here
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    XCTAssertEqual(environment.state, .ready)
    account = PaymentMethod(name: "Card", kind: .card, currency: .rub, isDefault: true)
    cash = PaymentMethod(name: "Cash", kind: .cash, currency: .rub)
    _ = try XCTUnwrap(environment.planning).apply(
      PlanningChange(upsert: PlanningRows(paymentMethods: [account, cash])))
  }

  override func tearDown() async throws {
    await environment.close()
    environment = nil
  }

  /// A reconciliation at `hour` (UTC) of `day` counting `accounts`.
  @discardableResult
  private func count(
    on day: DateOnly, hour: Int, _ accounts: [PaymentMethod]
  ) throws -> Reconciliation {
    let at = CalendarContext.utc.startOfDay(day).addingTimeInterval(TimeInterval(hour * 3_600))
    let reconciliation = Reconciliation(
      date: day, reconciledAt: at, actualTotalRubE4: .zero, kind: .accounts)
    let balances = accounts.map {
      ReconciledBalance(
        reconciliationId: reconciliation.id, accountId: $0.id, currency: .rub,
        actualE4: AmountE4(whole: 1_000))
    }
    _ = try XCTUnwrap(environment.planning).apply(
      PlanningChange(
        upsert: PlanningRows(reconciliations: [reconciliation], reconciledBalances: balances)))
    return reconciliation
  }

  private func storedText() throws -> String? {
    try XCTUnwrap(environment.settings).string(PlanningSettings.beforeCountAnswersKey)
  }

  func testARememberedAnswerIsReadBackFresh() throws {
    let count = try count(on: DateOnly(year: 2026, month: 9, day: 20), hour: 11, [account])
    XCTAssertEqual(environment.rememberedCountAnswers(), [:])

    XCTAssertTrue(environment.rememberCountAnswer(reconciliation: count.id, wasBefore: true))
    XCTAssertEqual(environment.rememberedCountAnswers(), [count.id: true])
    XCTAssertEqual(try storedText(), "\(count.id.uuidString) before")

    // Answered again the other way: the later answer is the one kept.
    XCTAssertTrue(environment.rememberCountAnswer(reconciliation: count.id, wasBefore: false))
    XCTAssertEqual(environment.rememberedCountAnswers(), [count.id: false])

    // Read from the database, not from what the numbers were built on: a write made anywhere
    // is seen at once.
    let other = try self.count(on: DateOnly(year: 2026, month: 9, day: 20), hour: 15, [cash])
    try XCTUnwrap(environment.settings).set(
      PlanningSettings.beforeCountAnswersKey, to: "\(other.id.uuidString) after")
    XCTAssertEqual(environment.rememberedCountAnswers(), [other.id: false])
  }

  /// An answer kept for a count of the 10th is no answer once both balances it counted are
  /// counted on the 20th, though no write has let it go yet: the read lets it go, and an
  /// operation dated the 10th is asked about that count again instead of being dated by it.
  func testAStaleAnswerIsNotReadOnceALaterDayIsCounted() throws {
    let early = try count(on: DateOnly(year: 2026, month: 9, day: 10), hour: 11, [account, cash])
    XCTAssertTrue(environment.rememberCountAnswer(reconciliation: early.id, wasBefore: true))
    try count(on: DateOnly(year: 2026, month: 9, day: 20), hour: 11, [account, cash])

    XCTAssertEqual(try storedText(), "\(early.id.uuidString) before")
    XCTAssertEqual(environment.rememberedCountAnswers(), [:])
  }

  /// The card counted on the 10th — the owner answered «до» and ticked «Больше не спрашивать» —
  /// and counted again on the 20th; a dinner dated the 10th in the evening, typed on the 21st,
  /// is asked about the count of the 10th, not put before it by the old answer.
  func testAnOperationOnAnOldCountsDayIsAskedAfterALaterCount() throws {
    let september10 = DateOnly(year: 2026, month: 9, day: 10)
    let early = try count(on: september10, hour: 11, [account, cash])
    XCTAssertTrue(environment.rememberCountAnswer(reconciliation: early.id, wasBefore: true))
    try count(on: DateOnly(year: 2026, month: 9, day: 20), hour: 11, [account, cash])

    let dinner = CalendarContext.utc.startOfDay(september10).addingTimeInterval(20 * 3_600)
    let saved = CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 21))
      .addingTimeInterval(12 * 3_600)
    let book = try XCTUnwrap(environment.planning).book()
    let balances = AccountBalances.build(
      entries: [], transfers: [], debtEntries: [], debts: [:],
      reconciliations: book.reconciliations, balances: book.reconciledBalances,
      accounts: [account, cash], tree: CategoryTree(), now: saved, calendar: .utc)
    guard
      case .ask(let questions) = AccountReconciliation.countToAsk(
        occurredAt: dinner, savedAt: saved,
        keys: [BalanceKey(accountId: account.id, currency: .rub)], balances: balances,
        calendar: .utc, remembered: environment.rememberedCountAnswers())
    else { return XCTFail("the count of the 10th is asked about again") }
    XCTAssertEqual(questions.reconciliation, early.id)
    XCTAssertFalse(questions.remembers, "an answer for it would not be kept")
  }

  /// Card and Cash counted in one sheet on the 10th — «до» answered and remembered — and Card
  /// alone counted again on the 20th. The answer is still read, the sheet being Cash's latest
  /// count, yet a dinner on the card dated the 10th in the evening, typed on the 21st, is asked
  /// about the sheet again and not put before it; the same dinner paid in cash is dated by the
  /// answer.
  func testAnAnswerIsNotUsedForAnAccountCountedAgainAlone() throws {
    let september10 = DateOnly(year: 2026, month: 9, day: 10)
    let early = try count(on: september10, hour: 11, [account, cash])
    XCTAssertTrue(environment.rememberCountAnswer(reconciliation: early.id, wasBefore: true))
    try count(on: DateOnly(year: 2026, month: 9, day: 20), hour: 11, [account])
    XCTAssertEqual(environment.rememberedCountAnswers(), [early.id: true])

    let dinner = CalendarContext.utc.startOfDay(september10).addingTimeInterval(20 * 3_600)
    let saved = CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 21))
      .addingTimeInterval(12 * 3_600)
    let book = try XCTUnwrap(environment.planning).book()
    let balances = AccountBalances.build(
      entries: [], transfers: [], debtEntries: [], debts: [:],
      reconciliations: book.reconciliations, balances: book.reconciledBalances,
      accounts: [account, cash], tree: CategoryTree(), now: saved, calendar: .utc)
    func ask(_ paidWith: PaymentMethod) -> CountAsk {
      AccountReconciliation.countToAsk(
        occurredAt: dinner, savedAt: saved,
        keys: [BalanceKey(accountId: paidWith.id, currency: .rub)], balances: balances,
        calendar: .utc, remembered: environment.rememberedCountAnswers())
    }
    guard case .ask(let questions) = ask(account) else {
      return XCTFail("the sheet of the 10th is asked about again for the card")
    }
    XCTAssertEqual(questions.reconciliation, early.id)
    XCTAssertFalse(questions.remembers, "an answer for it would not answer the card")
    guard case .answered(let stamp) = ask(cash) else {
      return XCTFail("the remembered answer still dates a cash dinner of the 10th")
    }
    XCTAssertEqual(stamp, early.reconciledAt?.addingTimeInterval(-1))
  }

  /// An answer about a count of an earlier day goes once a later day is counted; the counts of
  /// one day keep theirs — an operation of that day is asked about each of them in turn.
  func testAnswersOfOlderCountsArePruned() throws {
    let september10 = DateOnly(year: 2026, month: 9, day: 10)
    let september20 = DateOnly(year: 2026, month: 9, day: 20)
    let early = try count(on: september10, hour: 11, [account, cash])
    XCTAssertTrue(environment.rememberCountAnswer(reconciliation: early.id, wasBefore: true))
    XCTAssertEqual(environment.rememberedCountAnswers(), [early.id: true])

    // The card is counted on a later day; the cash is not: the answer still answers the cash.
    let morning = try count(on: september20, hour: 9, [account])
    XCTAssertTrue(environment.rememberCountAnswer(reconciliation: morning.id, wasBefore: false))
    XCTAssertEqual(environment.rememberedCountAnswers(), [early.id: true, morning.id: false])

    // A second count of the card that day keeps the morning's answer; once the cash is counted
    // on a later day too, the answer of the 10th has nothing left to answer.
    let evening = try count(on: september20, hour: 15, [account, cash])
    XCTAssertTrue(environment.rememberCountAnswer(reconciliation: evening.id, wasBefore: true))
    XCTAssertEqual(
      environment.rememberedCountAnswers(), [morning.id: false, evening.id: true])

    // An answer about a reconciliation that is no count at all is not kept, and says so.
    XCTAssertFalse(environment.rememberCountAnswer(reconciliation: UUID(), wasBefore: true))
    XCTAssertEqual(
      environment.rememberedCountAnswers(), [morning.id: false, evening.id: true])
  }

  /// An operation dated back to the 10th is asked about the count of the 10th; once both
  /// balances it counted are counted on the 20th, the answer about it is let go of by the very
  /// write that would keep it — and the dialog is told so, not that it will not ask again.
  func testAnAnswerAboutACountOfAnEarlierDayIsNotKept() throws {
    let september10 = DateOnly(year: 2026, month: 9, day: 10)
    let september20 = DateOnly(year: 2026, month: 9, day: 20)
    let early = try count(on: september10, hour: 11, [account, cash])
    let later = try count(on: september20, hour: 9, [account, cash])
    XCTAssertTrue(environment.rememberCountAnswer(reconciliation: later.id, wasBefore: false))

    XCTAssertFalse(environment.rememberCountAnswer(reconciliation: early.id, wasBefore: true))
    XCTAssertEqual(environment.rememberedCountAnswers(), [later.id: false])
    XCTAssertEqual(try storedText(), "\(later.id.uuidString) after")

    // With nothing else kept, the text left is empty: it reads as no answer at all.
    try XCTUnwrap(environment.settings).set(PlanningSettings.beforeCountAnswersKey, to: "")
    XCTAssertFalse(environment.rememberCountAnswer(reconciliation: early.id, wasBefore: false))
    XCTAssertEqual(environment.rememberedCountAnswers(), [:])
    XCTAssertEqual(try storedText(), "")
  }
}
