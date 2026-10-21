import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// What Planning and Overview show of the credits, the allocation of income and
/// self-employment: the new lines of the free sum, the block «Самозанятость» and the tax in the
/// payments, the debt load month by month, where the money of a goal lies, no limit on the tax,
/// the questions after the reminders, the lines of «Стоит посмотреть» with what this Mac
/// remembers of them, and the tiles «Рассрочки» and «Самозанятость» — in both languages, and laid
/// out in windows.
@MainActor
final class PlanningOverview19Tests: XCTestCase {
  private var windows: [NSWindow] = []
  private var suites: [String] = []

  override func tearDown() async throws {
    for window in windows {
      window.contentView = nil
      window.close()
    }
    windows = []
    for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
    suites = []
    BurnoutShowing.shownThisLaunch = nil
  }

  private func defaults() throws -> UserDefaults {
    let suite = "ohmymoney.tests.planning19.\(UUID().uuidString)"
    suites.append(suite)
    return try XCTUnwrap(UserDefaults(suiteName: suite))
  }

  private func environment(_ choice: AppLanguage.Choice) -> AppEnvironment {
    let environment = AppEnvironment()
    environment.language.choice = choice
    return environment
  }

  private func settle(_ seconds: TimeInterval = 0.3) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  private func rub(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }

  // MARK: - A book

  private let main = UUID()
  private let card = UUID()
  private let apart = UUID()

  /// One operation of one part, at noon of `day`.
  private func operation(
    _ kind: TransactionKind, _ amount: Int64, on day: DateOnly, category: UUID?,
    externalId: String? = nil
  ) -> TransactionEntry {
    let id = UUID()
    let at = CalendarContext.system.noon(of: day)
    let transaction = Transaction(
      id: id, kind: kind, occurredAt: at, currency: .rub, amountE4: rub(amount),
      amountRubE4: rub(amount), paymentMethodId: main, externalId: externalId, createdAt: at,
      updatedAt: at)
    let part = TransactionPart(
      transactionId: id, categoryId: category, amountE4: rub(amount), amountRubE4: rub(amount))
    return TransactionEntry(transaction: transaction, parts: [part])
  }

  /// A counted main account, a credit card in a group out of the summary, and — with
  /// `selfEmployed` — an income of last month in «Самозанятость → от физлиц» (4 %).
  private func dataset(
    today: DateOnly, selfEmployed: Bool = false, otherRate: Bool = false
  ) -> Dataset {
    let counted = Reconciliation(
      date: today.adding(days: -1), reconciledAt: Date().addingTimeInterval(-86_400),
      actualTotalRubE4: rub(200_000), kind: .accounts)
    let balance = ReconciledBalance(
      reconciliationId: counted.id, accountId: main, currency: .rub, actualE4: rub(200_000))
    let group = AccountGroup(id: apart, name: "Apart", inSummary: false)
    let earnings = CoreKit.Category(kind: .income, name: "Заработок")
    let selfEmployment = CoreKit.Category(
      parentId: earnings.id, kind: .income, name: "Самозанятость")
    let individuals = CoreKit.Category(
      parentId: selfEmployment.id, kind: .income, name: "от физлиц",
      tax: IncomeTax(rate: 4, npd: true))
    var categories = [earnings, selfEmployment, individuals]
    if otherRate {
      categories.append(
        CoreKit.Category(
          parentId: earnings.id, kind: .income, name: "ИП", tax: IncomeTax(rate: 6, npd: false)))
    }
    let lastMonth = today.monthKey.previous.firstDay.adding(days: 4)
    return Dataset(
      entries: selfEmployed
        ? [operation(.income, 120_000, on: lastMonth, category: individuals.id)] : [],
      categories: categories,
      paymentMethods: [
        PaymentMethod(id: main, name: "Main", currency: .rub, isDefault: true),
        PaymentMethod(id: card, name: "T-Card", currency: .rub, groupId: apart),
      ],
      planning: PlanningBook(reconciliations: [counted], reconciledBalances: [balance]),
      accountGroups: [group],
      selfEmployment: SelfEmploymentSettings(enabled: selfEmployed))
  }

  private func snapshot(_ dataset: Dataset, today: DateOnly) -> DataSnapshot {
    DataSnapshot.build(
      dataset: dataset, calendar: .system, today: today, context: SnapshotContext(),
      version: DataVersion(load: 0))
  }

  /// `snapshot` with `planning` changed by `change`.
  private func replacing(
    _ snapshot: DataSnapshot, _ change: (inout PlanningSnapshot) -> Void
  ) -> DataSnapshot {
    var planning = snapshot.planning
    change(&planning)
    return DataSnapshot(
      ledger: snapshot.ledger, summary: snapshot.summary, planning: planning,
      accountPlan: snapshot.accountPlan, owed: snapshot.owed, recentGroups: snapshot.recentGroups,
      recentIds: snapshot.recentIds, context: snapshot.context, today: snapshot.today,
      version: snapshot.version, burnout: snapshot.burnout)
  }

  private func deps(_ environment: AppEnvironment, _ snapshot: DataSnapshot) -> AppDependencies {
    let compute = ComputeStore(calendar: .system, rebuildsInline: true)
    compute.applyLight(snapshot)
    return AppDependencies(environment: environment, store: TransactionsStore(), compute: compute)
  }

  // MARK: - The free sum

  /// A month paid twice adds «До 25-го: X · в день Y» under the figure a day, and «Зарплата не
  /// пришла?» once the day passed without the income; without a half, neither.
  func testTheHalfOfTheMonthAndTheLateSalary() throws {
    let today = environment(.russian).today
    let free = snapshot(dataset(today: today), today: today).planning.freeMoney
    let names = { (parts: [FreeMoneyBlock.Part]) in parts.map(\.name) }
    XCTAssertFalse(names(FreeMoneyBlock.parts(of: free)).contains("half"))
    let half = PayHalf(
      start: today.adding(days: -5), nextIncomeDay: today.adding(days: 5),
      nextIncomeId: UUID(), late: false)
    let onTime = names(FreeMoneyBlock.parts(of: free, half: free, payHalf: half))
    XCTAssertTrue(onTime.contains("half"))
    XCTAssertFalse(onTime.contains("salaryLate"))
    let perDay = try XCTUnwrap(onTime.firstIndex(of: "perDay"))
    XCTAssertEqual(onTime.firstIndex(of: "half"), perDay + 1, "right under the figure a day")
    var late = half
    late.late = true
    XCTAssertTrue(
      names(FreeMoneyBlock.parts(of: free, half: free, payHalf: late)).contains("salaryLate"))
    // The half alone, without the free sum through its day, says nothing.
    XCTAssertFalse(names(FreeMoneyBlock.parts(of: free, payHalf: half)).contains("half"))

    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = environment(choice)
      for key in ["free.half", "free.salaryLate", "free.cardDue"] {
        XCTAssertNotEqual(environment.language(key, table: "Planning"), key, "\(choice) \(key)")
      }
      let text = environment.format(
        "free.half", table: "Planning", "25", environment.money.rounded(rub(18_400)),
        environment.money.rounded(rub(1_840)))
      XCTAssertTrue(text.contains(environment.money.rounded(rub(18_400))), text)
    }
  }

  /// A credit card out of the summary with a statement due by D is named with its day and sum;
  /// one due later, one with nothing to pay and one in the summary are not.
  func testTheCreditCardsOutOfTheSummaryAreNamed() {
    let today = environment(.russian).today
    let base = snapshot(dataset(today: today), today: today)
    let due = today.adding(days: 5)
    let named = replacing(base) {
      $0.creditCards = [
        card: CreditCardNow(toPayNoInterestE4: rub(12_000), payBy: due),
        main: CreditCardNow(toPayNoInterestE4: rub(3_000), payBy: due),
      ]
    }
    let cards = FreeMoneyBlock.cardsDue(named, until: today.adding(days: 10))
    XCTAssertEqual(cards.map(\.accountId), [card])
    XCTAssertEqual(cards.first?.amount, rub(12_000))
    XCTAssertEqual(cards.first?.name, "T-Card")
    XCTAssertEqual(cards.first?.due, due)
    XCTAssertTrue(FreeMoneyBlock.cardsDue(named, until: today.adding(days: 2)).isEmpty)
    let nothing = replacing(base) {
      $0.creditCards = [card: CreditCardNow(toPayNoInterestE4: .zero, payBy: due)]
    }
    XCTAssertTrue(FreeMoneyBlock.cardsDue(nothing, until: today.adding(days: 10)).isEmpty)
    let parts = FreeMoneyBlock.parts(of: named.planning.freeMoney, cards: cards).map(\.name)
    XCTAssertTrue(parts.contains("cardsDue"))
  }

  // MARK: - Self-employment in Planning

  /// The block shows only while self-employment is on, and its total is the tax to pay and
  /// its day.
  func testTheBlockOfSelfEmploymentShowsWhileItIsOn() throws {
    let order = PlanningBlocks.standard
    XCTAssertFalse(PlanningBlockText.shown(order, selfEmployed: false).contains(.selfEmployment))
    XCTAssertTrue(PlanningBlockText.shown(order, selfEmployed: true).contains(.selfEmployment))
    XCTAssertFalse(PlanningBlock.selfEmployment.hasShortList)

    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = environment(choice)
      let today = environment.today
      let on = snapshot(dataset(today: today, selfEmployed: true), today: today)
      let npd = try XCTUnwrap(on.planning.npd)
      let block = try XCTUnwrap(SelfEmploymentBlock.build(npd: npd, today: today))
      XCTAssertEqual(block.taxToPayE4, rub(4_800), "120,000 ₽ × 4 %")
      let total = try XCTUnwrap(
        PlanningBlockText.total(
          of: .selfEmployment, on, free: nil, adviceCount: nil, environment))
      XCTAssertTrue(total.contains(environment.money.rounded(rub(4_800))), total)
      XCTAssertNotEqual(
        PlanningBlockText.name(of: .selfEmployment, environment),
        PlanningBlockText.nameKey(of: .selfEmployment))
      let off = snapshot(dataset(today: today), today: today)
      XCTAssertNil(off.planning.npd)
      XCTAssertNil(
        PlanningBlockText.total(
          of: .selfEmployment, off, free: nil, adviceCount: nil, environment))
    }
  }

  /// «Налог НПД за октябрь ≈ X до 28 ноября»: the months over and unpaid, then the month under
  /// way — that one without «Заплатить…»; a category taxed at another rate leaves them as they
  /// are — its tax is paid by the quarter.
  func testTheTaxOfSelfEmploymentInThePayments() throws {
    let today = DateOnly(year: 2026, month: 10, day: 13)
    let year = NPDYear(year: 2026)
    let months = [
      NPDMonth(month: MonthKey(year: 2026, month: 7), toPayE4: rub(900), due: today, state: .paid),
      NPDMonth(month: MonthKey(year: 2026, month: 8), toPayE4: .zero, due: today, state: .carried),
      NPDMonth(
        month: MonthKey(year: 2026, month: 9), toPayE4: rub(4_800),
        due: DateOnly(year: 2026, month: 10, day: 28), state: .due),
      NPDMonth(
        month: MonthKey(year: 2026, month: 10), toPayE4: rub(1_200),
        due: DateOnly(year: 2026, month: 11, day: 28), state: .accruing),
    ]
    let npd = NPDState(months: months, year: year)
    let npdOnly = [CoreKit.Category(kind: .income, name: "НПД", tax: IncomeTax(rate: 4, npd: true))]
    let rows = NPDPaymentRows.rows(npd: npd, categories: npdOnly, today: today)
    XCTAssertEqual(rows.map(\.month.month), [9, 10])
    XCTAssertTrue(NPDPaymentRows.rows(npd: nil, categories: npdOnly, today: today).isEmpty)
    let mixed =
      npdOnly + [
        CoreKit.Category(kind: .income, name: "ИП", tax: IncomeTax(rate: 6, npd: false))
      ]
    XCTAssertEqual(
      NPDPaymentRows.rows(npd: npd, categories: mixed, today: today).map(\.month.month), [9, 10],
      "the tax of another rate is not in the months")

    let ru = environment(.russian)
    let due = NPDPaymentRows.text(rows[0], ru)
    XCTAssertTrue(due.hasPrefix("Налог НПД за сентябрь 2026"), due)
    XCTAssertTrue(due.contains(ru.money.rounded(rub(4_800))), due)
    XCTAssertTrue(due.contains(ru.dates.dayAndMonth(DateOnly(year: 2026, month: 10, day: 28))))
    XCTAssertTrue(NPDPaymentRows.text(rows[1], ru).contains("пока"))
    let en = environment(.english)
    XCTAssertTrue(NPDPaymentRows.text(rows[0], en).contains("September 2026"))
    for environment in [ru, en] {
      for key in ["scheduled.npd", "scheduled.npd.accruing", "scheduled.npd.symbol"] {
        XCTAssertNotEqual(environment.language(key, table: "Planning"), key)
      }
    }
  }

  /// «Налог УСН за III квартал 2026 ≈ X до 28 октября»: the quarters of a tax at another rate
  /// over and unpaid, then the quarter under way; a paid one or one with nothing to pay is not
  /// listed.
  func testTheTaxOfAnotherRateInThePaymentsByTheQuarter() throws {
    let quarters = [
      TaxQuarter(year: 2026, quarter: 2, toPayE4: rub(3_000), state: .paid),
      TaxQuarter(year: 2026, quarter: 3, toPayE4: rub(10_200), state: .due),
      TaxQuarter(year: 2026, quarter: 4, toPayE4: rub(1_800), state: .accruing),
    ]
    let npd = NPDState(year: NPDYear(year: 2026), quarters: quarters)
    let rows = NPDPaymentRows.quarterRows(npd: npd)
    XCTAssertEqual(rows.map(\.quarter), [3, 4])
    XCTAssertEqual(rows[0].due, DateOnly(year: 2026, month: 10, day: 28))
    XCTAssertTrue(NPDPaymentRows.quarterRows(npd: nil).isEmpty)
    XCTAssertTrue(
      NPDPaymentRows.quarterRows(
        npd: NPDState(
          year: NPDYear(year: 2026),
          quarters: [TaxQuarter(year: 2026, quarter: 3, toPayE4: .zero, state: .due)])
      ).isEmpty)

    let ru = environment(.russian)
    let due = NPDPaymentRows.text(rows[0], ru)
    XCTAssertTrue(due.hasPrefix("Налог УСН за III квартал 2026"), due)
    XCTAssertTrue(due.contains(ru.money.rounded(rub(10_200))), due)
    XCTAssertTrue(due.contains(ru.dates.dayAndMonth(DateOnly(year: 2026, month: 10, day: 28))))
    XCTAssertTrue(NPDPaymentRows.text(rows[1], ru).contains("пока"))
    let en = environment(.english)
    XCTAssertTrue(
      NPDPaymentRows.text(rows[0], en).contains("Q3 2026"), NPDPaymentRows.text(rows[0], en))
    for environment in [ru, en] {
      for key in ["scheduled.tax", "scheduled.tax.accruing"]
        + (1...4).map({ "scheduled.tax.quarter.\($0)" })
      {
        XCTAssertNotEqual(environment.language(key, table: "Planning"), key)
      }
      for key in ["tax.pay.title", "tax.pay.check"] {
        XCTAssertNotEqual(environment.language(key, table: "Allocation"), key)
      }
    }
  }

  /// The planning screen lays itself out with the block of self-employment and settles.
  func testThePlanningScreenWithSelfEmploymentSettles() throws {
    try TestEnvironment.requireScreen(width: 900)
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = environment(choice)
      let today = environment.today
      let deps = deps(
        environment, snapshot(dataset(today: today, selfEmployed: true), today: today))
      let layout = PlanningLayoutStore(defaults: try defaults())
      for width in [CGFloat(720), 900] {
        try assertSettles(
          PlanningView(layout: layout).appDependencies(deps), width: width,
          "\(choice) \(Int(width))")
      }
      try assertSettles(
        SelfEmploymentBlockView().appDependencies(deps), width: 380, "block \(choice)")
      try assertSettles(
        FreeMoneyBlock().appDependencies(deps), width: 380, "free \(choice)")
    }
  }

  // MARK: - The debt load

  /// High from 50 %, very high from 80 % — a word and a symbol, never a colour; the months
  /// newest first; every word in both languages.
  func testTheDebtLoadByMonth() {
    XCTAssertNil(DebtLoadHistoryView.level(nil))
    XCTAssertNil(DebtLoadHistoryView.level(4_999))
    XCTAssertEqual(DebtLoadHistoryView.level(5_000), .high)
    XCTAssertEqual(DebtLoadHistoryView.level(7_999), .high)
    XCTAssertEqual(DebtLoadHistoryView.level(8_000), .veryHigh)
    XCTAssertNotEqual(
      DebtLoadHistoryView.Level.high.symbol, DebtLoadHistoryView.Level.veryHigh.symbol)
    func load(_ bp: Int?) -> DebtLoad {
      DebtLoad(
        monthlyPaymentsRub: rub(10_000), incomeRub: rub(50_000), incomeSource: .history,
        loadBp: bp, withoutRate: [], withoutPayment: [],
        status: bp == nil ? .notEnoughData(reasonKey: DebtLoad.noIncomeKey) : .ready)
    }
    let history = [
      DebtLoadMonth(month: MonthKey(year: 2026, month: 8), load: load(3_000)),
      DebtLoadMonth(month: MonthKey(year: 2026, month: 9), load: load(nil)),
      DebtLoadMonth(month: MonthKey(year: 2026, month: 10), load: load(5_500)),
    ]
    let rows = DebtLoadHistoryView.rows(history)
    XCTAssertEqual(rows.map(\.month.month), [10, 9, 8])
    XCTAssertEqual(rows.map(\.loadBp), [5_500, nil, 3_000])
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = environment(choice)
      for key in DebtLoadHistoryView.keys {
        XCTAssertNotEqual(environment.language(key, table: "Planning"), key, "\(choice) \(key)")
      }
      let deps = AppDependencies(
        environment: environment, store: TransactionsStore(),
        compute: ComputeStore(calendar: .system))
      let view = NSHostingView(
        rootView: DebtLoadHistoryView(history: history).appDependencies(deps).frame(width: 340))
      view.layoutSubtreeIfNeeded()
      XCTAssertGreaterThan(view.fittingSize.height, 0)
    }
    XCTAssertTrue(
      environment(.russian).language("advice.load.thresholds", table: "Planning").contains("50"))
  }

  // MARK: - Goals and limits

  /// Without an account there is nothing to transfer to: the tick goes with it; an account in
  /// the archive stays offered to the goal that holds it.
  func testWhereTheMoneyOfAGoalIs() {
    var goal = Goal(name: "Trip", targetE4: rub(90_000))
    goal = GoalAccountFields.withAccount(goal, main)
    goal.transfersOnContribution = true
    XCTAssertEqual(goal.accountId, main)
    XCTAssertTrue(GoalAccountFields.withAccount(goal, card).transfersOnContribution)
    let cleared = GoalAccountFields.withAccount(goal, nil)
    XCTAssertNil(cleared.accountId)
    XCTAssertFalse(cleared.transfersOnContribution)
    let archived = PaymentMethod(name: "Old", archived: true)
    let live = PaymentMethod(name: "Live")
    XCTAssertEqual(GoalAccountFields.offered([archived, live], keeping: nil).map(\.name), ["Live"])
    XCTAssertEqual(
      GoalAccountFields.offered([archived, live], keeping: archived.id).map(\.name),
      ["Old", "Live"])
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = environment(choice)
      for key in GoalAccountFields.keys {
        XCTAssertNotEqual(environment.language(key, table: "Planning"), key, "\(choice) \(key)")
      }
    }
  }

  /// The form of a goal lays out with the account and the tick.
  func testTheFormOfAGoalLaysOut() throws {
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = environment(choice)
      let today = environment.today
      let deps = deps(environment, snapshot(dataset(today: today), today: today))
      try assertSettles(GoalForm(original: nil).appDependencies(deps), width: 460, "\(choice)")
    }
  }

  /// The category the tax of self-employment is paid in, and everything under it, take no
  /// limit: not offered, refused, never suggested.
  func testNoLimitOnTheTaxOfSelfEmployment() throws {
    let today = environment(.russian).today
    let taxes = CoreKit.Category(kind: .expense, name: "Налоги и сборы")
    let tax = CoreKit.Category(parentId: taxes.id, kind: .expense, name: "Налог самозанятого")
    let food = CoreKit.Category(kind: .expense, name: "Еда")
    var data = dataset(today: today)
    data.categories += [taxes, tax, food]
    data.selfEmployment = SelfEmploymentSettings(enabled: true, taxCategoryId: tax.id)
    let snapshot = snapshot(data, today: today)
    let limitless = LimitWrites.onScreen(snapshot)
    XCTAssertTrue(limitless.contains(tax.id))
    let tree = snapshot.ledger.tree
    XCTAssertFalse(LimitRules.offersLimit(on: tax.id, tree: tree, limitless: limitless))
    XCTAssertTrue(LimitRules.offersLimit(on: food.id, tree: tree, limitless: limitless))
    XCTAssertNotNil(
      LimitRules.validate(
        Budget(scope: .category, categoryId: tax.id, amountE4: rub(1_000)), tree: tree,
        existing: [], limitless: limitless))
    XCTAssertNil(
      LimitRules.validate(
        Budget(scope: .category, categoryId: food.id, amountE4: rub(1_000)), tree: tree,
        existing: [], limitless: limitless))
    XCTAssertFalse(LimitWrites.onScreen(nil).contains(tax.id))
  }

  // MARK: - The questions after the reminders

  /// The old debts first, then the offer of self-employment; one at a time, once a launch,
  /// never under the cover, nor in a set of synthetic data.
  func testTheQuestionsAfterTheReminders() {
    let item = DebtReviewItem(debtId: UUID(), fields: [.costs])
    func next(
      _ review: [DebtReviewItem] = [], offer: Bool = false, asked: Set<String> = [],
      waits: Bool = false, locked: Bool = false, suppressed: Bool = false, dataSet: Bool = false
    ) -> LaunchQuestion? {
      RemindersPresentation.nextQuestion(
        debtReview: review, offersSelfEmployment: offer, asked: asked, waits: waits,
        locked: locked, suppressed: suppressed, dataSet: dataSet)
    }
    XCTAssertNil(next())
    XCTAssertEqual(next([item], offer: true), .debtReview([item]))
    XCTAssertEqual(next([item], offer: true, asked: ["debtReview"]), .selfEmployment)
    XCTAssertNil(next([item], offer: true, asked: ["debtReview", "selfEmployment"]))
    XCTAssertEqual(next(offer: true), .selfEmployment)
    XCTAssertNil(next([item], waits: true))
    XCTAssertNil(next([item], locked: true))
    XCTAssertNil(next([item], suppressed: true))
    XCTAssertNil(next([item], offer: true, dataSet: true))
  }

  /// An income in a category named as self-employment — or under one — brings the offer once;
  /// on, already offered, or only spending there, it does not.
  func testTheOfferOfSelfEmployment() {
    XCTAssertTrue(SelfEmploymentOffer.isSelfEmployedName("Самозанятость"))
    XCTAssertTrue(SelfEmploymentOffer.isSelfEmployedName("Доход по ГПХ"))
    XCTAssertTrue(SelfEmploymentOffer.isSelfEmployedName("Self-employed"))
    XCTAssertFalse(SelfEmploymentOffer.isSelfEmployedName("Зарплата"))
    let parent = CoreKit.Category(kind: .income, name: "ГПХ")
    let child = CoreKit.Category(parentId: parent.id, kind: .income, name: "Заказчик")
    let salary = CoreKit.Category(kind: .income, name: "Зарплата")
    let today = environment(.russian).today
    var data = Dataset(
      entries: [operation(.income, 30_000, on: today, category: child.id)],
      categories: [parent, child, salary])
    let tree = CategoryTree(data.categories)
    XCTAssertTrue(SelfEmploymentOffer.offers(dataset: data, tree: tree))
    data.selfEmployment = SelfEmploymentSettings(offered: true)
    XCTAssertFalse(SelfEmploymentOffer.offers(dataset: data, tree: tree))
    data.selfEmployment = SelfEmploymentSettings(enabled: true)
    XCTAssertFalse(SelfEmploymentOffer.offers(dataset: data, tree: tree))
    data.selfEmployment = .standard
    data.entries = [operation(.income, 30_000, on: today, category: salary.id)]
    XCTAssertFalse(SelfEmploymentOffer.offers(dataset: data, tree: tree))
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = environment(choice)
      for key in SelfEmploymentOfferSheet.keys {
        XCTAssertNotEqual(environment.language(key, table: "Planning"), key, "\(choice) \(key)")
      }
      let deps = AppDependencies(
        environment: environment, store: TransactionsStore(),
        compute: ComputeStore(calendar: .system))
      let view = NSHostingView(rootView: SelfEmploymentOfferSheet().appDependencies(deps))
      view.layoutSubtreeIfNeeded()
      XCTAssertGreaterThan(view.fittingSize.height, 0)
    }
  }

  // MARK: - What this Mac remembers of the reminders

  /// «Готово» puts a reminder away by its key, per set of data; the credit history is done for
  /// the half of the year; its switch is one for the Mac.
  func testTheMarksOfTheRemindersOfDebts() throws {
    let defaults = try defaults()
    XCTAssertEqual(DebtReminderMarks.read(from: defaults, dataSet: nil), DebtReminderMarks())
    DebtReminderMarks.dismiss("insurance:A", in: defaults, dataSet: nil)
    DebtReminderMarks.dismiss("pledge:B:2026-10-20", in: defaults, dataSet: nil)
    DebtReminderMarks.dismiss("insurance:A", in: defaults, dataSet: nil)
    DebtReminderMarks.creditHistoryDone(
      HalfYear(year: 2026, second: true), in: defaults, dataSet: nil)
    var marks = DebtReminderMarks.read(from: defaults, dataSet: nil)
    XCTAssertEqual(marks.dismissed, ["insurance:A", "pledge:B:2026-10-20"])
    XCTAssertEqual(marks.creditHistoryDone, HalfYear(year: 2026, second: true))
    XCTAssertTrue(marks.creditHistoryEnabled)
    // A set of synthetic data keeps its own marks.
    let sample = DebtReminderMarks.read(from: defaults, dataSet: "sample")
    XCTAssertTrue(sample.dismissed.isEmpty)
    XCTAssertNil(sample.creditHistoryDone)
    defaults.set(false, forKey: DebtReminderMarks.creditHistoryEnabledKey)
    marks = DebtReminderMarks.read(from: defaults, dataSet: "sample")
    XCTAssertFalse(marks.creditHistoryEnabled)

    // What the marks hold, the reminders leave out.
    let today = DateOnly(year: 2026, month: 8, day: 3)
    let shown = DebtReminders.list(
      debts: [], costs: [], cards: [:], today: today, dismissed: [], creditHistoryEnabled: true,
      creditHistoryDone: nil)
    XCTAssertEqual(shown, [.creditHistory(half: HalfYear(year: 2026, second: true))])
    XCTAssertTrue(
      DebtReminders.list(
        debts: [], costs: [], cards: [:], today: today, dismissed: [],
        creditHistoryEnabled: true, creditHistoryDone: HalfYear(year: 2026, second: true)
      ).isEmpty)
  }

  /// The hint about burnout once a week: it stays for the launch it showed in, is not shown
  /// again that week after it, and «Не показывать» turns it off.
  func testTheHintAboutBurnoutOnceAWeek() throws {
    let defaults = try defaults()
    let today = DateOnly(year: 2026, month: 10, day: 13)
    XCTAssertTrue(BurnoutShowing.enabled(defaults))
    XCTAssertNil(BurnoutShowing.lastShownWeek(defaults, today: today))
    BurnoutShowing.shown(defaults, today: today)
    XCTAssertEqual(defaults.string(forKey: BurnoutShowing.lastShownKey), Burnout.weekKey(today))
    XCTAssertNil(BurnoutShowing.lastShownWeek(defaults, today: today), "it stays this launch")
    let signal = BurnoutCheck.signal(
      BurnoutSignal(lastWeekCount: 14, usualCount: 6, from: today.adding(days: -6), through: today))
    XCTAssertTrue(
      Burnout.shows(
        signal, enabled: true,
        lastShownWeek: BurnoutShowing.lastShownWeek(defaults, today: today), today: today))
    BurnoutShowing.shownThisLaunch = nil
    XCTAssertFalse(
      Burnout.shows(
        signal, enabled: true,
        lastShownWeek: BurnoutShowing.lastShownWeek(defaults, today: today), today: today),
      "the next launch of the same week")
    XCTAssertTrue(
      Burnout.shows(
        signal, enabled: true,
        lastShownWeek: BurnoutShowing.lastShownWeek(defaults, today: today.adding(days: 7)),
        today: today.adding(days: 7)))
    BurnoutShowing.turnOff(defaults)
    XCTAssertFalse(BurnoutShowing.enabled(defaults))
  }

  // MARK: - «Стоит посмотреть»

  private func notes(today: DateOnly) -> [WorthALookNote] {
    let debt = UUID()
    let month = NPDMonth(
      month: today.monthKey.previous, toPayE4: rub(4_800), due: today.adding(days: 2),
      state: .due)
    return [
      .debt(
        .prepayNotice(
          debtId: debt, fileBy: today, prepayOn: today.adding(days: 1), amountE4: rub(50_000))),
      .debt(.pledgeDue(debtId: debt, returnBy: today.adding(days: 3), overdue: false)),
      .debt(.pledgeDue(debtId: debt, returnBy: today.adding(days: -3), overdue: true)),
      .debt(.insuranceCooling(costId: UUID(), debtId: debt, until: today.adding(days: 20))),
      .debt(.creditHistory(half: HalfYear(containing: today))),
      .debt(
        .cardPayBy(
          accountId: card, due: today.adding(days: 4), fullE4: rub(12_000), minimumE4: rub(600))),
      .debt(.cardGraceMissed(accountId: card, statementDay: today, estimateE4: rub(310))),
      .npdDue(month),
      .salaryLate(
        PayHalf(
          start: today.adding(days: -20), nextIncomeDay: today.adding(days: -2),
          nextIncomeId: UUID(), late: true)),
      .allocate(incomeId: UUID(), leftE4: rub(70_000), currency: .rub),
      .monthRest(MonthRestOffer(month: today.monthKey.previous, amountE4: rub(9_000), target: nil)),
      .npdLimit(
        NPDYear(year: today.year, incomeRub: rub(2_200_000), leftRub: rub(200_000), shareBp: 9_166)),
      .npdLimit(
        NPDYear(
          year: today.year, incomeRub: rub(2_500_000), leftRub: .zero, shareBp: 10_416,
          exceeded: true)),
      .burnout(
        BurnoutSignal(
          lastWeekCount: 14, usualCount: 6, from: today.adding(days: -6), through: today)),
      .lowCopySpace(freeBytes: 500_000_000), .databaseProblems(count: 3),
    ]
  }

  /// Every line says what it is about in both languages: the names, the sums, the days; no key
  /// and no placeholder shows through; every action has its words.
  func testEveryLineOfWorthALookInBothLanguages() {
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = environment(choice)
      let today = environment.today
      for note in notes(today: today) {
        let text = WorthALookNoteText.text(
          note,
          debts: [:].merging(
            notes(today: today).compactMap { note -> (UUID, String)? in
              if case .debt(let reminder) = note, case .prepayNotice(let id, _, _, _) = reminder {
                return (id, "Loan")
              }
              return nil
            }, uniquingKeysWith: { first, _ in first }),
          accounts: [card: "T-Card"], environment)
        XCTAssertFalse(text.isEmpty, "\(note.id)")
        XCTAssertFalse(text.hasPrefix("look."), "\(choice) \(note.id): \(text)")
        XCTAssertFalse(text.contains("%@") || text.contains("%lld"), "\(note.id): \(text)")
        XCTAssertFalse(WorthALookNoteText.symbol(note).isEmpty)
        XCTAssertFalse(WorthALookNoteText.actions(note).isEmpty, "\(note.id)")
        switch note {
        case .debt(.cardPayBy):
          XCTAssertTrue(text.contains("T-Card"), text)
          XCTAssertTrue(text.contains(environment.money.rounded(rub(12_000))), text)
          XCTAssertTrue(text.contains(environment.money.rounded(rub(600))), text)
        case .allocate:
          XCTAssertTrue(text.contains(environment.money.rounded(rub(70_000))), text)
        case .npdDue:
          XCTAssertTrue(text.contains(environment.money.rounded(rub(4_800))), text)
        case .burnout:
          XCTAssertTrue(text.contains("14") && text.contains("6"), text)
        case .lowCopySpace:
          XCTAssertTrue(text.contains("500"), text)
        case .databaseProblems:
          XCTAssertTrue(text.contains("3"), text)
        default: break
        }
      }
      for key in WorthALookNoteText.keys {
        XCTAssertNotEqual(environment.language(key, table: "Overview"), key, "\(choice) \(key)")
      }
    }
    XCTAssertEqual(
      WorthALookNoteText.actions(.debt(.creditHistory(half: HalfYear(year: 2026, second: false)))),
      [.done, .stopCreditHistory])
  }

  /// With a line of 1.9 on the card, «ничего необычного» is not said; without one, it is.
  func testNothingUnusualOnlyOnAnEmptyCard() {
    let today = environment(.russian).today
    XCTAssertEqual(AnomaliesCard.lines([.nothingUnusual], notes: []), [.nothingUnusual])
    XCTAssertEqual(AnomaliesCard.lines([.nothingUnusual], notes: [notes(today: today)[0]]), [])
    XCTAssertEqual(AnomaliesCard.lines([.more(2)], notes: [notes(today: today)[0]]), [.more(2)])
  }

  /// The lines of the card come from the snapshot, less those settled on it.
  func testTheCardTakesTheLinesOfTheSnapshot() {
    let today = environment(.russian).today
    let base = snapshot(dataset(today: today), today: today)
    let reminder = DebtReminder.creditHistory(half: HalfYear(containing: today))
    let with = replacing(base) { $0.debtReminders = [reminder] }
    XCTAssertEqual(AnomaliesCard.notes(with, settled: []), [.debt(reminder)])
    XCTAssertTrue(AnomaliesCard.notes(with, settled: ["debt:\(reminder.id)"]).isEmpty)
    XCTAssertTrue(AnomaliesCard.notes(nil, settled: []).isEmpty)
  }

  /// Every line lays out with its buttons, in both languages.
  func testTheLinesLayOut() {
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = environment(choice)
      let today = environment.today
      let snapshot = snapshot(dataset(today: today), today: today)
      let deps = deps(environment, snapshot)
      for note in notes(today: today) {
        let view = NSHostingView(
          rootView: WorthALookNoteRow(
            note: note, snapshot: snapshot, settled: { _ in },
            open: { _ in }
          )
          .appDependencies(deps).frame(width: 320))
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.fittingSize.height, 0, "\(note.id)")
      }
    }
  }

  // MARK: - The tiles «Рассрочки» and «Самозанятость»

  /// «Рассрочки: 2 · ближайшее 2,500 ₽ 14 ноября»; with none, «Рассрочек нет».
  func testTheTileOfInstalments() {
    let debt = UUID()
    let due = DateOnly(year: 2026, month: 11, day: 14)
    let summary = InstalmentsSummary(
      totalRub: rub(34_000), count: 2,
      next: [UpcomingInstalment(debtId: debt, due: due, currency: .rub, amountE4: rub(2_500))])
    let ru = environment(.russian)
    let headline = InstalmentsTileContent.headline(summary, ru)
    XCTAssertTrue(headline.hasPrefix("2 рассрочки"), headline)
    XCTAssertTrue(headline.contains(ru.money.rounded(rub(2_500))), headline)
    XCTAssertTrue(headline.contains(ru.dates.dayAndMonth(due)), headline)
    XCTAssertTrue(
      InstalmentsTileContent.headline(InstalmentsSummary(count: 1), environment(.english))
        .hasPrefix("1 plan"))
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = environment(choice)
      for key in InstalmentsTileContent.keys {
        XCTAssertNotEqual(environment.language(key, table: "Overview"), key, "\(choice) \(key)")
      }
      let deps = AppDependencies(
        environment: environment, store: TransactionsStore(),
        compute: ComputeStore(calendar: .system))
      for shown in [summary, .empty] {
        let view = NSHostingView(
          rootView: InstalmentsTileContent(summary: shown, names: [debt: "Phone"])
            .appDependencies(deps).frame(width: 300))
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.fittingSize.height, 0)
      }
    }
  }

  /// Both tiles are added with «Изменить», have cards of their own instead of nothing, and their
  /// «Почему так» adds up.
  func testTheTilesAreAddedAndExplainThemselves() throws {
    let environment = environment(.russian)
    let today = environment.today
    let snapshot = snapshot(dataset(today: today, selfEmployed: true), today: today)
    let deps = deps(environment, snapshot)
    environment.overviewLayout = .standard
    for tile in [OverviewTile.installments, .selfEmployment] {
      XCTAssertFalse(environment.overviewLayout.shownTiles(in: .plan).contains(tile))
      XCTAssertTrue(OverviewTilesActions.show(environment, tile))
      XCTAssertTrue(environment.overviewLayout.shownTiles(in: .plan).contains(tile))
      let card = NSHostingView(
        rootView: OverviewCardView(tile: tile, actions: OperationActions())
          .appDependencies(deps).frame(width: 320))
      card.layoutSubtreeIfNeeded()
      XCTAssertGreaterThan(card.fittingSize.height, 40, "\(tile) has a card")
    }
    let npd = try XCTUnwrap(snapshot.planning.npd)
    let explained = TileExplanations.selfEmployment(npd, today: today)
    for section in explained.sections { XCTAssertNotEqual(section.addsUp, false) }
    let instalments = TileExplanations.installments(
      InstalmentsSummary(
        totalRub: rub(34_000), count: 2,
        next: [UpcomingInstalment(debtId: UUID(), due: today, currency: .rub, amountE4: rub(2_500))]
      ))
    for section in instalments.sections { XCTAssertNotEqual(section.addsUp, false) }
  }

  // MARK: - Windows

  private func assertSettles<V: View>(_ view: V, width: CGFloat, _ what: String) throws {
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: width, height: 700), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    windows.append(window)
    // dependencies: every caller hands them to its view with `.appDependencies`
    let hosting = NSHostingView(rootView: view.frame(width: width, height: 700))
    window.contentView = hosting
    window.orderFront(nil)
    settle(0.5)
    hosting.layoutSubtreeIfNeeded()
    let first = hosting.fittingSize
    settle(0.3)
    hosting.layoutSubtreeIfNeeded()
    XCTAssertEqual(hosting.fittingSize, first, "the size keeps changing: \(what)")
    XCTAssertFalse(hosting.needsLayout, "the screen asks for layout again: \(what)")
    XCTAssertEqual(window.frame.width, width, accuracy: 1, "the window grew: \(what)")
  }
}
