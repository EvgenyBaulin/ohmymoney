import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Это было до сверки в 14:05?»: an operation dated on the day of the latest count of its
/// account and saved after that count asks whether its money was already in what was counted.
/// «Да» dates it a second before the count, «Нет» after it.
@MainActor
final class BeforeTheCountTests: XCTestCase {
  private var stack: DatabaseStack!
  private var references: ReferenceRepository!
  private var transactions: TransactionRepository!

  private let card = PaymentMethod(name: "Card", currency: .rub, isDefault: true)
  private let cash = PaymentMethod(name: "Cash", kind: .cash, currency: .rub)

  private let today = DateOnly(year: 2026, month: 9, day: 18)
  private var yesterday: DateOnly { DateOnly(year: 2026, month: 9, day: 17) }

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    transactions = TransactionRepository(writer: stack.writer)
    try references.save(card)
    try references.save(cash)
  }

  private func moment(_ day: DateOnly, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
    CalendarContext.utc.startOfDay(day)
      .addingTimeInterval(TimeInterval(hour * 3600 + minute * 60 + second))
  }

  /// The card counted at `at`, as the reconciliation sheet writes it.
  private func counted(at: Date, account: PaymentMethod? = nil, now: Date) -> AccountBalances {
    let reconciliation = Reconciliation(
      date: CalendarContext.utc.day(of: at), reconciledAt: at, actualTotalRubE4: .zero,
      kind: .accounts)
    let balance = ReconciledBalance(
      reconciliationId: reconciliation.id, accountId: (account ?? card).id, currency: .rub,
      actualE4: AmountE4(whole: 10_000))
    return AccountBalances.build(
      entries: [], transfers: [], debtEntries: [], debts: [:], reconciliations: [reconciliation],
      balances: [balance], accounts: [card, cash], tree: CategoryTree(), now: now,
      calendar: .utc)
  }

  private func makeModel() -> EntryDraftModel {
    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc)
    model.openAccountScreen = { nil }
    model.rateTable = { RateTable() }
    model.reload()
    return model
  }

  /// A line typed and about to be saved at `savedAt`.
  private func typed(
    _ model: EntryDraftModel, date: DateOnly? = nil, account: UUID? = nil, savedAt: Date
  ) {
    model.apply(
      ParsedInput(amount: 500, date: date, paymentMethodId: account, note: "taxi"),
      amount: AmountE4(whole: 500), today: today)
    model.takeTheMomentOfSaving(now: savedAt)
  }

  func testAnOperationOfTodaySavedAfterTodaysCountAsks() throws {
    let count = moment(today, 14, 5)
    let saved = moment(today, 15)
    let balances = counted(at: count, now: saved)
    let model = makeModel()
    typed(model, savedAt: saved)

    XCTAssertEqual(model.countToAskAbout(savedAt: saved, balances: balances), count)

    // «Да»: a second before the count, and the save that follows does not ask again.
    model.answerCount(count, wasBefore: true)
    XCTAssertEqual(model.draft.occurredAt, moment(today, 14, 4, 59))
    model.takeTheMomentOfSaving(now: saved)
    XCTAssertEqual(model.draft.occurredAt, moment(today, 14, 4, 59))
    XCTAssertNil(model.countToAskAbout(savedAt: saved, balances: balances))
  }

  func testYesterdayTypedTodayAfterYesterdaysCountAsks() throws {
    let count = moment(yesterday, 14, 5)
    let saved = moment(today, 10)
    let balances = counted(at: count, now: saved)
    let model = makeModel()
    typed(model, date: yesterday, savedAt: saved)
    // «вчера» carries noon, which says nothing about before or after the count.
    XCTAssertEqual(model.draft.occurredAt, moment(yesterday, 12))

    XCTAssertEqual(model.countToAskAbout(savedAt: saved, balances: balances), count)

    // «Нет»: after the count, whatever time the day carried.
    model.answerCount(count, wasBefore: false)
    XCTAssertEqual(model.draft.occurredAt, moment(yesterday, 14, 5, 1))
    XCTAssertNil(model.countToAskAbout(savedAt: saved, balances: balances))
  }

  /// The answer never moves the operation to another day, and so to another month of reports
  /// and limits: a count in the first second of its day answered «Да» keeps the operation on
  /// that day, and a count in the last second answered «Нет» keeps it there too.
  func testTheAnswerKeepsTheOperationOnTheDayOfTheCount() throws {
    let midnight = moment(today, 0)
    let morning = moment(today, 9)
    let early = makeModel()
    typed(early, savedAt: morning)
    XCTAssertEqual(
      early.countToAskAbout(savedAt: morning, balances: counted(at: midnight, now: morning)),
      midnight)
    early.answerCount(midnight, wasBefore: true)
    XCTAssertEqual(CalendarContext.utc.day(of: early.draft.occurredAt), today)
    XCTAssertEqual(early.draft.occurredAt, midnight)

    let lastSecond = moment(yesterday, 23, 59, 59)
    let afterMidnight = moment(today, 0, 10)
    let late = makeModel()
    typed(late, date: yesterday, savedAt: afterMidnight)
    XCTAssertEqual(
      late.countToAskAbout(
        savedAt: afterMidnight, balances: counted(at: lastSecond, now: afterMidnight)),
      lastSecond)
    late.answerCount(lastSecond, wasBefore: false)
    XCTAssertEqual(CalendarContext.utc.day(of: late.draft.occurredAt), yesterday)
    XCTAssertGreaterThan(late.draft.occurredAt, lastSecond)
  }

  func testAnAnswerKeepsALaterTimeOfTheDayAfterTheCount() throws {
    let count = moment(today, 9)
    let saved = moment(today, 15)
    let model = makeModel()
    typed(model, savedAt: saved)
    model.answerCount(count, wasBefore: false)
    XCTAssertEqual(model.draft.occurredAt, saved)
  }

  func testAnotherDayOrAnotherAccountDoesNotAsk() throws {
    let saved = moment(today, 15)
    // The count was the day before; the operation is today's.
    let earlier = counted(at: moment(yesterday, 14, 5), now: saved)
    let model = makeModel()
    typed(model, savedAt: saved)
    XCTAssertNil(model.countToAskAbout(savedAt: saved, balances: earlier))

    // Today's count was of the cash; the operation is on the card.
    let ofTheCash = counted(at: moment(today, 14, 5), account: cash, now: saved)
    XCTAssertNil(model.countToAskAbout(savedAt: saved, balances: ofTheCash))
    // On the cash it asks.
    let onCash = makeModel()
    typed(onCash, account: cash.id, savedAt: saved)
    XCTAssertEqual(
      onCash.countToAskAbout(savedAt: saved, balances: ofTheCash), moment(today, 14, 5))
  }

  /// The whole way of a save: asked, answered «Да», written — the database holds the operation
  /// a second before the count.
  func testTheAnswerReachesTheDatabase() throws {
    let count = moment(today, 14, 5)
    let saved = moment(today, 15)
    let balances = counted(at: count, now: saved)
    let model = makeModel()
    typed(model, savedAt: saved)
    let asked = try XCTUnwrap(model.countToAskAbout(savedAt: saved, balances: balances))
    model.answerCount(asked, wasBefore: true)
    // The save goes on: the moment of saving again, and no second question.
    model.takeTheMomentOfSaving(now: saved)
    XCTAssertNil(model.countToAskAbout(savedAt: saved, balances: balances))
    let entry = try model.draft.materialize(now: saved)
    try transactions.save(entry)
    XCTAssertEqual(
      try transactions.entry(id: entry.id)?.transaction.occurredAt, moment(today, 14, 4, 59))
  }

  /// A time the owner set in the panel that is already before the count answers «Да» by itself:
  /// the answer keeps it instead of moving it to the second before the count.
  func testYesKeepsATimeChosenBeforeTheCount() throws {
    let count = moment(today, 14, 5)
    let saved = moment(today, 15)
    let balances = counted(at: count, now: saved)
    let model = makeModel()
    typed(model, savedAt: saved)
    model.setDate(moment(today, 13), today: today)
    let asked = try XCTUnwrap(model.countToAskAbout(savedAt: saved, balances: balances))
    model.answerCount(asked, wasBefore: true)
    XCTAssertEqual(model.draft.occurredAt, moment(today, 13))
  }

  func testTheNextOperationAsksAgain() throws {
    let count = moment(today, 14, 5)
    let saved = moment(today, 15)
    let balances = counted(at: count, now: saved)
    let model = makeModel()
    typed(model, savedAt: saved)
    model.answerCount(count, wasBefore: true)
    model.reset()
    typed(model, savedAt: saved)
    XCTAssertEqual(model.countToAskAbout(savedAt: saved, balances: balances), count)
  }

  // MARK: Every count of the day, one after another

  /// The card counted at 09:00 by the setup and at 21:00 by a sheet; a taxi typed at 22:00 is
  /// asked about 09:00 first. «Да» saves it at 08:59:59; «Нет» asks about 21:00, whose «Да»
  /// saves it between the two and whose «Нет» after both. The question carries the
  /// reconciliation of each count, and the walk keeps the payment it is about.
  func testTheDialogWalksTheCountsOfTheDay() throws {
    let setup = moment(today, 9)
    let sheet = moment(today, 21)
    let saved = moment(today, 22)
    let opening = Reconciliation(
      date: today, reconciledAt: setup, actualTotalRubE4: .zero, kind: .opening)
    let counted = Reconciliation(
      date: today, reconciledAt: sheet, actualTotalRubE4: .zero, kind: .accounts)
    let balances = AccountBalances.build(
      entries: [], transfers: [], debtEntries: [], debts: [:],
      reconciliations: [opening, counted],
      balances: [
        ReconciledBalance(
          reconciliationId: opening.id, accountId: card.id, currency: .rub,
          actualE4: AmountE4(whole: 10_000)),
        ReconciledBalance(
          reconciliationId: counted.id, accountId: card.id, currency: .rub,
          actualE4: AmountE4(whole: 9_700)),
      ],
      accounts: [card, cash], tree: CategoryTree(), now: saved, calendar: .utc)
    let key = BalanceKey(accountId: card.id, currency: .rub)
    guard
      case .ask(let questions) = AccountReconciliation.countToAsk(
        occurredAt: saved, savedAt: saved, keys: [key], balances: balances, calendar: .utc,
        remembered: [:])
    else { return XCTFail("the counts of the day are asked about") }
    let first = BeforeTheCountQuestion(
      count: questions.count, reconciliation: questions.reconciliation, name: "Rent",
      questions: questions)
    XCTAssertEqual(first.count, setup)
    XCTAssertEqual(first.reconciliation, opening.id)

    XCTAssertEqual(first.answered(wasBefore: true), .stamp(moment(today, 8, 59, 59)))
    guard case .next(let second) = first.answered(wasBefore: false) else {
      return XCTFail("«Нет» asks about 21:00")
    }
    XCTAssertEqual(second.count, sheet)
    XCTAssertEqual(second.reconciliation, counted.id)
    XCTAssertEqual(second.name, "Rent")
    XCTAssertNotEqual(second, first)
    guard case .stamp(let between) = second.answered(wasBefore: true) else {
      return XCTFail("«Да» stamps")
    }
    XCTAssertGreaterThan(between, setup)
    XCTAssertLessThan(between, sheet)
    XCTAssertEqual(second.answered(wasBefore: false), .stamp(saved))

    // A question of one count with no walk is answered by the dialog of one question only.
    XCTAssertNil(BeforeTheCountQuestion(count: setup).answered(wasBefore: true))
  }

  // MARK: «Больше не спрашивать для этой сверки»

  /// An environment on a database of its own, with the card and the cash, and a sheet counting
  /// both at each of `hours` of today (UTC); the reconciliations, oldest first.
  private func environmentCounting(
    at hours: [Int]
  ) async throws -> (AppEnvironment, [Reconciliation]) {
    let environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    let planning = try XCTUnwrap(environment.planning)
    _ = try planning.apply(PlanningChange(upsert: PlanningRows(paymentMethods: [card, cash])))
    var made: [Reconciliation] = []
    for hour in hours {
      let reconciliation = Reconciliation(
        date: today, reconciledAt: moment(today, hour), actualTotalRubE4: .zero,
        kind: .accounts)
      _ = try planning.apply(
        PlanningChange(
          upsert: PlanningRows(
            reconciliations: [reconciliation],
            reconciledBalances: [card, cash].map {
              ReconciledBalance(
                reconciliationId: reconciliation.id, accountId: $0.id, currency: .rub,
                actualE4: AmountE4(whole: 1_000))
            })))
      made.append(reconciliation)
    }
    return (environment, made)
  }

  private func balances(_ environment: AppEnvironment, now: Date) throws -> AccountBalances {
    let book = try XCTUnwrap(environment.planning).book()
    return AccountBalances.build(
      entries: [], transfers: [], debtEntries: [], debts: [:],
      reconciliations: book.reconciliations, balances: book.reconciledBalances,
      accounts: [card, cash], tree: CategoryTree(), now: now, calendar: .utc)
  }

  /// «Больше не спрашивать» ticked with «Нет, после»: the answer is kept for the reconciliation
  /// of the question, and the next operation of that day on either account is dated after the
  /// count without a question. Unticked, or a question that does not know its reconciliation,
  /// keeps nothing.
  func testARememberedAnswerIsUsedSilently() async throws {
    let (environment, counts) = try await environmentCounting(at: [14])
    let count = try XCTUnwrap(counts.first)
    let saved = moment(today, 16)
    let key = BalanceKey(accountId: cash.id, currency: .rub)
    let question = BeforeTheCountQuestion(count: moment(today, 14), reconciliation: count.id)

    XCTAssertFalse(
      BeforeTheCountDialog.remember(question, wasBefore: false, dontAsk: false, in: environment))
    XCTAssertFalse(
      BeforeTheCountDialog.remember(
        BeforeTheCountQuestion(count: moment(today, 14)), wasBefore: false, dontAsk: true,
        in: environment))
    XCTAssertEqual(environment.rememberedCountAnswers(), [:])
    guard
      case .ask = AccountReconciliation.countToAsk(
        occurredAt: saved, savedAt: saved, keys: [key],
        balances: try balances(environment, now: saved), calendar: .utc,
        remembered: environment.rememberedCountAnswers())
    else { return XCTFail("nothing remembered, the count asks") }

    XCTAssertTrue(
      BeforeTheCountDialog.remember(question, wasBefore: false, dontAsk: true, in: environment))
    XCTAssertEqual(environment.rememberedCountAnswers(), [count.id: false])
    let later = moment(today, 17)
    guard
      case .answered(let stamp) = AccountReconciliation.countToAsk(
        occurredAt: later, savedAt: later, keys: [BalanceKey(accountId: card.id, currency: .rub)],
        balances: try balances(environment, now: later), calendar: .utc,
        remembered: environment.rememberedCountAnswers())
    else { return XCTFail("a remembered answer asked again") }
    XCTAssertGreaterThan(stamp, moment(today, 14), "«Нет, после» dates it after the count")
    XCTAssertEqual(CalendarContext.utc.day(of: stamp), today)
    await environment.close()
  }

  /// The card counted on the 10th and on the 20th; an expense dated the 10th, saved on the
  /// 25th, is asked about the count of the 10th without «Больше не спрашивать»: an answer for a
  /// count of an earlier day than its balance's latest would not be kept, and the next
  /// expense of that day would be asked again. One dated the 20th is offered it.
  func testACountOfAnEarlierDayOffersNoToggle() async throws {
    let environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    let planning = try XCTUnwrap(environment.planning)
    _ = try planning.apply(PlanningChange(upsert: PlanningRows(paymentMethods: [card, cash])))
    let september10 = DateOnly(year: 2026, month: 9, day: 10)
    let september20 = DateOnly(year: 2026, month: 9, day: 20)
    var made: [Reconciliation] = []
    for day in [september10, september20] {
      let reconciliation = Reconciliation(
        date: day, reconciledAt: moment(day, 11), actualTotalRubE4: .zero, kind: .accounts)
      _ = try planning.apply(
        PlanningChange(
          upsert: PlanningRows(
            reconciliations: [reconciliation],
            reconciledBalances: [
              ReconciledBalance(
                reconciliationId: reconciliation.id, accountId: card.id, currency: .rub,
                actualE4: AmountE4(whole: 1_000))
            ])))
      made.append(reconciliation)
    }
    let saved = moment(DateOnly(year: 2026, month: 9, day: 25), 12)
    let balances = try balances(environment, now: saved)
    func question(on day: DateOnly) -> BeforeTheCountQuestion? {
      guard
        case .ask(let questions) = AccountReconciliation.countToAsk(
          occurredAt: moment(day, 15), savedAt: saved,
          keys: [BalanceKey(accountId: card.id, currency: .rub)], balances: balances,
          calendar: .utc, remembered: environment.rememberedCountAnswers())
      else { return nil }
      // As every view that saves makes it.
      return BeforeTheCountQuestion(
        count: questions.count, reconciliation: questions.reconciliation, questions: questions)
    }

    let old = try XCTUnwrap(question(on: september10))
    XCTAssertEqual(old.reconciliation, made[0].id)
    XCTAssertFalse(old.remembers)
    XCTAssertFalse(
      BeforeTheCountDialog.remember(old, wasBefore: true, dontAsk: true, in: environment))
    XCTAssertEqual(environment.rememberedCountAnswers(), [:])

    let latest = try XCTUnwrap(question(on: september20))
    XCTAssertEqual(latest.reconciliation, made[1].id)
    XCTAssertTrue(latest.remembers)
    // A question about a due date has no walk: its count is the latest of its balance.
    XCTAssertTrue(
      BeforeTheCountQuestion(
        count: moment(september20, 11), reconciliation: made[1].id, due: september10,
        name: "Rent"
      ).remembers)
    XCTAssertFalse(BeforeTheCountQuestion(count: moment(september20, 11)).remembers)
    await environment.close()
  }

  /// A newer reconciliation of the account has no answer of its own: an operation of the day is
  /// asked about it, while the older count stays answered.
  func testANewerReconciliationAsksAgain() async throws {
    let (environment, counts) = try await environmentCounting(at: [10])
    let first = try XCTUnwrap(counts.first)
    XCTAssertTrue(
      BeforeTheCountDialog.remember(
        BeforeTheCountQuestion(count: moment(today, 10), reconciliation: first.id),
        wasBefore: false, dontAsk: true, in: environment))
    let evening = Reconciliation(
      date: today, reconciledAt: moment(today, 18), actualTotalRubE4: .zero, kind: .accounts)
    _ = try XCTUnwrap(environment.planning).apply(
      PlanningChange(
        upsert: PlanningRows(
          reconciliations: [evening],
          reconciledBalances: [
            ReconciledBalance(
              reconciliationId: evening.id, accountId: card.id, currency: .rub,
              actualE4: AmountE4(whole: 900))
          ])))

    let saved = moment(today, 19)
    guard
      case .ask(let questions) = AccountReconciliation.countToAsk(
        occurredAt: saved, savedAt: saved, keys: [BalanceKey(accountId: card.id, currency: .rub)],
        balances: try balances(environment, now: saved), calendar: .utc,
        remembered: environment.rememberedCountAnswers())
    else { return XCTFail("the newer reconciliation did not ask") }
    XCTAssertEqual(questions.count, moment(today, 18))
    XCTAssertEqual(questions.reconciliation, evening.id)
    await environment.close()
  }

  /// A question about a due date names the payment, the day and the time of the count, and
  /// says what either answer does with the due day — in both languages; a question of an
  /// operation keeps its own words.
  func testTheDatedQuestionNamesThePaymentAndTheCount() async throws {
    let environment = AppEnvironment()
    let count = moment(today, 14, 5)
    let due = DateOnly(year: 2026, month: 9, day: 15)
    let dated = BeforeTheCountQuestion(count: count, due: due, name: "Аренда")
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      let time = environment.dates.time(count)
      let countDay = environment.dates.dayAndMonth(environment.calendar.day(of: count))
      let title = BeforeTheCountDialog.title(of: dated, environment)
      XCTAssertTrue(title.contains("«Аренда»"), title)
      XCTAssertTrue(title.contains(time), title)
      XCTAssertTrue(title.contains(countDay), title)
      XCTAssertNotEqual(title, "planning.dueBeforeCount.title")
      let message = BeforeTheCountDialog.message(of: dated, environment)
      XCTAssertTrue(message.contains(environment.dates.dayAndMonth(due)), message)

      let plain = BeforeTheCountQuestion(count: count)
      XCTAssertEqual(
        BeforeTheCountDialog.title(of: plain, environment),
        environment.language.format("entry.beforeCount.title", table: "Entry", time))
      XCTAssertEqual(
        BeforeTheCountDialog.message(of: plain, environment),
        environment.language("entry.beforeCount.message", table: "Entry"))
      XCTAssertNotEqual(
        environment.language("entry.beforeCount.dontAsk", table: "Entry"),
        "entry.beforeCount.dontAsk")
    }
    environment.language.choice = .russian
    await environment.close()
  }
}
