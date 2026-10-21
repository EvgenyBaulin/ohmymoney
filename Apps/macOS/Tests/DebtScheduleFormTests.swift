import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «График» of a loan's form: the grace period and its payments, the main payment over a term,
/// «Как банк засчитывает платёж?» — asked of a loan with a rate, never assumed —, the preset of
/// the education loan of the state programme, and a schedule saved and changed in one step of ⌘Z
/// each.
@MainActor
final class DebtScheduleFormTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private let today = DateOnly(year: 2026, month: 10, day: 11)

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-debt-schedule-\(UUID().uuidString)", isDirectory: true)
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
    compute = ComputeStore(calendar: .system, rebuildsInline: true)
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

  private var actions: DebtActions {
    DebtActions(AppDependencies(environment: environment, store: store, compute: compute))
  }

  private func stored(_ debt: Debt) throws -> Debt? {
    try XCTUnwrap(environment.references).debts(includeClosed: true).first { $0.id == debt.id }
  }

  // MARK: The preset

  func testThePresetIsTheEducationLoanOfTheStateProgramme() {
    let start = DebtSheetView.newDebt(defaultCurrency: .rub)
    let preset = DebtSheetView.educationLoan(start, today: today, language: environment.language)
    XCTAssertEqual(preset.debt.direction, .iOwe)
    XCTAssertEqual(preset.debt.type, .loan)
    XCTAssertFalse(preset.debt.paymentsAreExpenses, "the tranches are the expense")
    XCTAssertFalse(preset.debt.name.isEmpty)
    XCTAssertEqual(preset.rateText, "3")
    XCTAssertTrue(preset.schedule.hasGrace)
    XCTAssertEqual(preset.schedule.graceKind, .programme)
    XCTAssertTrue(preset.schedule.byTerm)
    XCTAssertEqual(preset.schedule.months, 180)
    XCTAssertNil(preset.schedule.order, "how the bank counts a payment is still asked")
    XCTAssertGreaterThan(preset.schedule.mainFrom, today)

    let made = DebtSheetView.made(
      preset.debt, rateText: preset.rateText, schedule: preset.schedule)
    XCTAssertEqual(
      preset.schedule.issues(
        rate: made.interestRate, monthly: made.monthlyPaymentE4, direction: .iOwe),
      [.orderUnanswered], "not saved before the question is answered")
    XCTAssertEqual(made.interestRate, 3)
    XCTAssertEqual(made.grace?.payment, .programme)
    XCTAssertEqual(made.repayMonths, 180)
    XCTAssertEqual(made.paymentDay, 1, "monthly dues need a day")
  }

  // MARK: What keeps the form from saving

  func testTheQuestionIsAskedOfALoanWithARateOnly() {
    var schedule = DebtSchedule(mainFrom: today)
    XCTAssertEqual(schedule.issues(rate: 12, monthly: nil, direction: .iOwe), [.orderUnanswered])
    XCTAssertEqual(schedule.issues(rate: nil, monthly: nil, direction: .iOwe), [])
    XCTAssertEqual(schedule.issues(rate: 12, monthly: nil, direction: .owedToMe), [])
    schedule.order = .allToDebt
    XCTAssertEqual(schedule.issues(rate: 12, monthly: nil, direction: .iOwe), [])
  }

  func testAGracePeriodNeedsItsRateItsSumAndAMainPayment() {
    var schedule = DebtSchedule(mainFrom: today)
    schedule.hasGrace = true
    schedule.graceKind = .interest
    XCTAssertEqual(
      schedule.issues(rate: nil, monthly: nil, direction: .iOwe),
      [.rateMissing, .mainPaymentMissing])
    schedule.order = .interestFirst
    XCTAssertEqual(
      schedule.issues(rate: 3, monthly: AmountE4(whole: 9_000), direction: .iOwe), [])
    schedule.graceKind = .fixed
    XCTAssertEqual(
      schedule.issues(rate: nil, monthly: AmountE4(whole: 9_000), direction: .iOwe),
      [.graceAmountMissing])
    schedule.graceAmount = AmountE4(whole: 500)
    XCTAssertEqual(
      schedule.issues(rate: nil, monthly: AmountE4(whole: 9_000), direction: .iOwe), [])
    schedule.byTerm = true
    XCTAssertEqual(
      schedule.issues(rate: nil, monthly: nil, direction: .iOwe), [.rateMissing],
      "a term is worked out at a rate")
  }

  // MARK: What is saved

  func testTheScheduleIsWhatTheDebtSays() {
    let debt = Debt(
      direction: .iOwe, type: .loan, name: "Study", monthlyPaymentE4: AmountE4(whole: 9_000),
      paymentDay: 5)
    var schedule = DebtSchedule(mainFrom: DateOnly(year: 2029, month: 3, day: 1))
    schedule.hasGrace = true
    schedule.graceKind = .fixed
    schedule.graceAmount = AmountE4(whole: 700)
    schedule.order = .interestFirst
    let made = schedule.applied(to: debt, rate: 3)
    XCTAssertEqual(
      made.grace,
      DebtGrace(
        mainFrom: DateOnly(year: 2029, month: 3, day: 1), payment: .fixed(AmountE4(whole: 700))))
    XCTAssertTrue(made.accruesInterest)
    XCTAssertEqual(made.monthlyPaymentE4, AmountE4(whole: 9_000))
    XCTAssertNil(made.repayMonths)

    schedule.order = .allToDebt
    schedule.byTerm = true
    schedule.months = 120
    let byTerm = schedule.applied(to: debt, rate: 3)
    XCTAssertFalse(byTerm.accruesInterest)
    XCTAssertEqual(byTerm.repayMonths, 120)
    XCTAssertNil(byTerm.monthlyPaymentE4, "the term works the payment out")
    XCTAssertFalse(schedule.applied(to: debt, rate: nil).accruesInterest, "no rate, no interest")

    var lent = debt
    lent.direction = .owedToMe
    XCTAssertNil(schedule.applied(to: lent, rate: 3).grace, "a grace period is of a debt I owe")

    // A debt that has a schedule reads it back as it was saved; an older loan with a rate keeps
    // the answer it gives by not accruing interest.
    XCTAssertEqual(DebtSchedule(debt: made, today: today).graceAmount, AmountE4(whole: 700))
    XCTAssertEqual(DebtSchedule(debt: made, today: today).order, .interestFirst)
    var older = debt
    older.interestRate = 18
    XCTAssertEqual(DebtSchedule(debt: older, today: today).order, .allToDebt)
    XCTAssertNil(DebtSchedule(debt: debt, today: today).order)
  }

  func testTheTermShowsItsPayment() {
    var schedule = DebtSchedule(mainFrom: today)
    XCTAssertNil(schedule.annuity(principal: AmountE4(whole: 120_000), rate: 12))
    schedule.byTerm = true
    schedule.months = 12
    XCTAssertEqual(
      schedule.annuity(principal: AmountE4(whole: 120_000), rate: 12),
      InterestMath.annuity(principal: AmountE4(whole: 120_000), percent: 12, months: 12))
    XCTAssertNil(schedule.annuity(principal: AmountE4(whole: 120_000), rate: nil))
  }

  func testAScheduledLoanIsSavedWithADayOfPayment() {
    XCTAssertEqual(DebtSheetView.savedPaymentDay(monthly: nil, day: nil, scheduled: true), 1)
    XCTAssertEqual(DebtSheetView.savedPaymentDay(monthly: nil, day: 10, scheduled: true), 10)
    XCTAssertNil(DebtSheetView.savedPaymentDay(monthly: nil, day: 10))
  }

  // MARK: Saved, changed, and ⌘Z

  func testTheLoanAndEveryChangeOfItsScheduleIsOneStepOfUndo() throws {
    var schedule = DebtSchedule.educationLoan(today: today)
    schedule.order = .interestFirst
    var start = DebtSheetView.newDebt(defaultCurrency: .rub)
    start.name = "Study"
    let preset = DebtSheetView.educationLoan(start, today: today, language: environment.language)
    let debt = DebtSheetView.made(preset.debt, rateText: preset.rateText, schedule: schedule)
    XCTAssertTrue(
      actions.create(debt, balance: AmountE4(whole: 100_000), on: today, moneyMovedNow: false))

    let saved = try XCTUnwrap(try stored(debt))
    XCTAssertEqual(saved.grace?.payment, .programme)
    XCTAssertEqual(saved.grace?.mainFrom, schedule.mainFrom)
    XCTAssertEqual(saved.repayMonths, 180)
    XCTAssertTrue(saved.accruesInterest)
    XCTAssertEqual(saved.interestRate, 3)
    XCTAssertFalse(saved.paymentsAreExpenses)

    // «График…»: the main schedule a year later, a fixed grace payment.
    var changed = DebtSchedule(debt: saved, today: today)
    changed.mainFrom = DateOnly(year: schedule.mainFrom.year + 1, month: 3, day: 1)
    changed.graceKind = .fixed
    changed.graceAmount = AmountE4(whole: 1_500)
    XCTAssertTrue(actions.save(DebtSheetView.made(saved, rateText: "3", schedule: changed)))
    XCTAssertEqual(try stored(debt)?.grace?.payment, .fixed(AmountE4(whole: 1_500)))
    XCTAssertEqual(try stored(debt)?.grace?.mainFrom, changed.mainFrom)

    store.undo()
    XCTAssertEqual(try stored(debt)?.grace, saved.grace, "one ⌘Z gives the schedule back")
    store.undo()
    XCTAssertNil(try stored(debt), "and one more takes the loan away")
  }

  // MARK: The card

  func testTheCardTellsTheGracePeriodTheMainScheduleAndTheTranches() {
    let mainFrom = DateOnly(year: 2029, month: 3, day: 1)
    let debt = Debt(
      direction: .iOwe, type: .loan, name: "Study", interestRate: 3, paymentDay: 1,
      paymentsAreExpenses: false, accruesInterest: true,
      grace: DebtGrace(mainFrom: mainFrom, payment: .programme), repayMonths: 180)
    let first = DebtEntry(
      debtId: debt.id, date: today.adding(days: -100), amountE4: AmountE4(whole: 100_000),
      kind: .borrowed, tranche: true)
    let second = DebtEntry(
      debtId: debt.id, date: today.adding(days: -10), amountE4: AmountE4(whole: 50_000),
      kind: .borrowed, tranche: true)
    let line = DebtLine(
      debt: debt, balance: AmountE4(whole: 150_000), balanceRub: AmountE4(whole: 150_000),
      groups: [], nextPayment: nil, paidThisMonth: false, entries: [second, first],
      schedule: DebtScheduleSummary(
        phase: .grace, current: AmountE4(whole: 150), mainFrom: mainFrom,
        mainAmount: AmountE4(whole: 1_036), drawnE4: AmountE4(whole: 150_000),
        accruedInterestE4: AmountE4(whole: 37)),
      accruedInterestE4: AmountE4(whole: 37))
    XCTAssertEqual(line.loanYear(on: today), 1)
    XCTAssertEqual(line.loanYear(on: today.adding(days: 300)), 2)
    XCTAssertEqual(line.tranches?.count, 2)
    XCTAssertEqual(line.tranches?.total, AmountE4(whole: 150_000))

    let language = environment.language
    let money = environment.money
    let dates = environment.dates
    let lines = DebtScheduleText.lines(
      line, today: today, language: language, money: money, dates: dates)
    let share = language.format(
      "schedule.card.kind.programme", table: "Debts", money.number(40, fractionDigits: 0...0))
    XCTAssertEqual(
      lines,
      [
        language.format(
          "schedule.card.grace", table: "Debts", dates.longDay(mainFrom),
          money.exact(AmountE4(whole: 150)), share),
        language.format(
          "schedule.card.main", table: "Debts", dates.longDay(mainFrom),
          money.rounded(AmountE4(whole: 1_036))),
        language.format(
          "schedule.card.tranches", table: "Debts", money.count(2),
          money.rounded(AmountE4(whole: 150_000))),
        language.format(
          "schedule.card.accrued", table: "Debts", money.exact(AmountE4(whole: 37))),
      ])
  }

  /// «Оплачено X из Y» is said of what the due asks for, not of a monthly payment the loan
  /// does not have.
  func testThePartOfADueIsOfWhatThatDueAsksFor() {
    let debt = Debt(
      direction: .iOwe, type: .loan, name: "Study", interestRate: 3, paymentDay: 1,
      repayMonths: 12)
    let dues = DebtDueState(
      debtId: debt.id, firstDue: DateOnly(year: 2026, month: 9, day: 1), paidCount: 1,
      owes: true, paymentDay: 1, partialE4: AmountE4(whole: 300),
      instalments: DebtInstalments(steps: [
        .init(fromIndex: 0, amountE4: AmountE4(whole: 200)),
        .init(fromIndex: 1, amountE4: AmountE4(whole: 1_000)),
      ]))
    let line = DebtLine(
      debt: debt, balance: AmountE4(whole: 10_000), balanceRub: nil, groups: [],
      nextPayment: nil, paidThisMonth: false, entries: [], dues: dues)
    let partial = line.partialDue
    XCTAssertEqual(partial?.due, AmountE4(whole: 1_000))
    XCTAssertEqual(partial?.left, AmountE4(whole: 700))
  }
}
