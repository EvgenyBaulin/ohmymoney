import AppCore
import XCTest

@testable import OhMyMoney

// Synthetic data only.

/// While the hidden accounts are covered nothing on screen names them or lists what is theirs —
/// the days of Overview, «Стоит посмотреть», «Капитал» and the cushion, the plans of the calendar,
/// the ribbon and the blocks of Planning, the yearly expenses, «Почему так» of the balance
/// forecast, the goal form, a transfer of the day list — while every figure keeps their money and
/// says «часть скрыта». Revealed (the whole snapshot), everything is there again.
@MainActor
final class HiddenLeaksTests: XCTestCase {
  private let food = CoreKit.Category(kind: .expense, name: "Food")
  private let salary = CoreKit.Category(kind: .income, name: "Salary")
  private let open = PaymentMethod(name: "Sber Main", isDefault: true)
  private let secret: PaymentMethod = {
    var account = PaymentMethod(name: "Secret Savings")
    account.hidden = true
    account.cushion = true
    return account
  }()
  private let other: PaymentMethod = {
    var account = PaymentMethod(name: "Other Secret")
    account.hidden = true
    return account
  }()
  private lazy var secretCard = PaymentCard(accountId: secret.id, name: "Secret Black")

  private let today = DateOnly(year: 2026, month: 9, day: 19)

  private func rub(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }

  private func noon(_ day: DateOnly) -> Date {
    CalendarContext.utc.startOfDay(day).addingTimeInterval(12 * 3600)
  }

  private func spend(
    _ rubles: Int64, on day: DateOnly, account: UUID?, card: UUID? = nil, note: String? = nil
  ) -> TransactionEntry {
    let id = UUID()
    let when = noon(day)
    return TransactionEntry(
      transaction: Transaction(
        id: id, kind: .expense, occurredAt: when, amountE4: rub(rubles), note: note,
        paymentMethodId: account, createdAt: when, updatedAt: when, cardId: card),
      parts: [
        TransactionPart(
          transactionId: id, categoryId: food.id, quality: .neutral, qualitySource: .category,
          amountE4: rub(rubles))
      ])
  }

  private struct Books {
    var dataset: Dataset
    var openOp: TransactionEntry
    var hiddenOp: TransactionEntry
    var cardOp: TransactionEntry
    var openBill: ScheduledPayment
    var hiddenBill: ScheduledPayment
    var cardBill: ScheduledPayment
    var openIncome: ExpectedIncome
    var hiddenIncome: ExpectedIncome
  }

  /// Three purchases of today (visible account, hidden account, a card of the hidden account),
  /// counted balances of the visible and the hidden account, and plans of the next days on each.
  private func books() -> Books {
    let openOp = spend(100, on: today, account: open.id, note: "Coffee")
    let hiddenOp = spend(300, on: today, account: secret.id, note: "Secret insurance")
    let cardOp = spend(200, on: today, account: nil, card: secretCard.id, note: "Card buy")
    let soon = today.adding(days: 3)
    let openBill = ScheduledPayment(
      name: "Rent", amountE4: rub(1_000), paymentMethodId: open.id, day: soon.day, nextDate: soon)
    let hiddenBill = ScheduledPayment(
      name: "Secret loan", amountE4: rub(2_000), paymentMethodId: secret.id, day: soon.day,
      nextDate: soon)
    let cardBill = ScheduledPayment(
      name: "Secret club", amountE4: rub(500), day: soon.day, nextDate: soon,
      cardId: secretCard.id)
    let openIncome = ExpectedIncome(
      name: "Salary", totalE4: rub(50_000), dueDate: today.adding(days: 5),
      paymentMethodId: open.id)
    let hiddenIncome = ExpectedIncome(
      name: "Secret bonus", totalE4: rub(30_000), dueDate: today.adding(days: 5),
      paymentMethodId: secret.id)
    let counted = DateOnly(year: 2026, month: 9, day: 10)
    let reconciliation = Reconciliation(
      date: counted, reconciledAt: CalendarContext.utc.startOfDay(counted),
      actualTotalRubE4: .zero, kind: .accounts)
    var dataset = Dataset(
      entries: [openOp, hiddenOp, cardOp], categories: [food, salary],
      paymentMethods: [open, secret, other], cards: [secretCard])
    dataset.planning = PlanningBook(
      scheduled: [openBill, hiddenBill, cardBill], expected: [openIncome, hiddenIncome],
      reconciliations: [reconciliation],
      reconciledBalances: [open.id, secret.id].map {
        ReconciledBalance(
          reconciliationId: reconciliation.id, accountId: $0, currency: .rub,
          actualE4: rub(10_000))
      })
    return Books(
      dataset: dataset, openOp: openOp, hiddenOp: hiddenOp, cardOp: cardOp, openBill: openBill,
      hiddenBill: hiddenBill, cardBill: cardBill, openIncome: openIncome,
      hiddenIncome: hiddenIncome)
  }

  private func snapshots(_ dataset: Dataset) -> (whole: DataSnapshot, covered: DataSnapshot) {
    let whole = DataSnapshot.build(
      dataset: dataset, calendar: .utc, today: today, context: SnapshotContext(),
      version: DataVersion(load: 0))
    return (whole, whole.presented(hiding: HiddenAccounts(accounts: dataset.paymentMethods)))
  }

  // MARK: 1. The days of Overview

  func testTheRecentDaysListNoHiddenOperationAndKeepTheirTotals() throws {
    let books = books()
    let (whole, covered) = snapshots(books.dataset)
    let all = try XCTUnwrap(whole.recentGroups.first { $0.day == today })
    let shown = try XCTUnwrap(covered.recentGroups.first { $0.day == today })

    XCTAssertEqual(
      Set(all.entries.map(\.id)), [books.openOp.id, books.hiddenOp.id, books.cardOp.id])
    XCTAssertFalse(all.partHidden)
    XCTAssertEqual(shown.entries.map(\.id), [books.openOp.id])
    XCTAssertEqual(shown.totals, all.totals, "the day keeps the money of the hidden account")
    XCTAssertTrue(shown.partHidden)
    XCTAssertTrue(whole.recentIds.isSuperset(of: [books.hiddenOp.id, books.cardOp.id]))
    XCTAssertFalse(covered.recentIds.contains(books.hiddenOp.id))
    XCTAssertFalse(covered.recentIds.contains(books.cardOp.id))
    XCTAssertTrue(covered.recentIds.contains(books.openOp.id))
  }

  // MARK: 2. «Стоит посмотреть»

  func testWorthALookListsNoAnomalyOfAHiddenOperation() {
    let books = books()
    let (whole, covered) = snapshots(books.dataset)
    let report = AnomalyReport(all: [
      Anomaly(
        rule: .largeExpense, subject: "a", day: today, amount: rub(300),
        transactionId: books.hiddenOp.id),
      Anomaly(
        rule: .possibleDuplicate, subject: "b", day: today, amount: rub(200),
        transactionId: books.cardOp.id),
      Anomaly(
        rule: .largeExpense, subject: "c", day: today, amount: rub(100),
        transactionId: books.openOp.id),
      Anomaly(
        rule: .categorySpike, subject: "d", day: today, amount: rub(600), categoryId: food.id),
    ])
    XCTAssertEqual(
      Set(AnomaliesCard.covering(report, shown: covered).all.map(\.subject)), ["c", "d"])
    XCTAssertEqual(AnomaliesCard.covering(report, shown: whole).all.count, 4)
    XCTAssertEqual(AnomaliesCard.covering(report, shown: nil).all.count, 4)
  }

  func testWorthALookSaysNothingOfAHiddenAccountOrItsOperations() {
    let books = books()
    let (whole, covered) = snapshots(books.dataset)
    let notes: [WorthALookNote] = [
      .debt(.cardOverLimit(accountId: secret.id, overE4: rub(10))),
      .debt(.cardPayBy(accountId: open.id, due: today, fullE4: rub(10), minimumE4: nil)),
      .bank(.limitNear(accountId: secret.id, kind: .cash, leftE4: rub(1), currency: .rub)),
      .bank(
        .cardExpiry(
          accountId: open.id, cardId: secretCard.id, expiresOn: today.monthKey, expired: false,
          attachedCount: 0)),
      .warranty(
        .returnEnds(transactionId: books.hiddenOp.id, title: "Secret", until: today, daysLeft: 1)
      ),
      .purchase(
        .regret(
          RegretQuestion(
            transactionId: books.cardOp.id, boughtOn: today, categoryId: food.id,
            amountRubE4: rub(200), note: "Card buy"))),
      .allocate(incomeId: books.hiddenOp.id, leftE4: rub(1), currency: .rub),
      .warranty(
        .returnEnds(transactionId: books.openOp.id, title: "Coffee", until: today, daysLeft: 1)),
      .lowCopySpace(freeBytes: 1),
    ]
    let hidden = HiddenOperations(snapshot: covered)
    let shown = WorthALookCover.covering(notes, hidden: hidden, ledger: covered.ledger)
    XCTAssertEqual(shown, [notes[1], notes[7], notes[8]])
    XCTAssertEqual(
      WorthALookCover.covering(
        notes, hidden: HiddenOperations(snapshot: whole), ledger: whole.ledger),
      notes)
  }

  func testTheInsuranceLimitOfABankWithOnlyHiddenAccountsIsNotSaid() {
    var books = books()
    let bank = Bank(name: "Secret Bank")
    let visibleBank = Bank(name: "Open Bank")
    books.dataset.paymentMethods = books.dataset.paymentMethods.map { account in
      var account = account
      account.bankId = account.id == open.id ? visibleBank.id : bank.id
      return account
    }
    let (_, covered) = snapshots(books.dataset)
    let hidden = HiddenOperations(snapshot: covered)
    let onlyHidden = WorthALookNote.bank(
      .insuranceOver(bankId: bank.id, name: "Secret Bank", totalRub: rub(2), limitRub: rub(1)))
    let visible = WorthALookNote.bank(
      .insuranceOver(bankId: visibleBank.id, name: "Open Bank", totalRub: rub(2), limitRub: rub(1)))
    XCTAssertTrue(WorthALookCover.hides(onlyHidden, hidden: hidden, ledger: covered.ledger))
    XCTAssertFalse(WorthALookCover.hides(visible, hidden: hidden, ledger: covered.ledger))
  }

  // MARK: 3. «Капитал» and the cushion

  func testCapitalNamesNoHiddenAccountAndKeepsItsTotals() throws {
    let books = books()
    let (whole, covered) = snapshots(books.dataset)
    let capital = whole.planning.capital
    let all = CapitalViewModel(capital: capital, hiding: whole.hiding)
    let shown = CapitalViewModel(capital: capital, hiding: covered.hiding)
    func names(_ model: CapitalViewModel) -> [String] {
      (model.haveGroups + model.oweGroups).flatMap(\.rows).map(\.line.name)
        + model.warnings.flatMap(\.names) + model.countedTwice
    }
    XCTAssertTrue(names(all).contains(secret.name))
    XCTAssertFalse(names(shown).contains(secret.name))
    XCTAssertFalse(names(shown).contains(other.name))
    XCTAssertTrue(names(shown).contains(open.name))
    XCTAssertEqual(shown.net, all.net)
    XCTAssertEqual(shown.have, all.have)
    let wholeAccounts = try XCTUnwrap(all.haveGroups.first { $0.kind == .accounts })
    let shownAccounts = try XCTUnwrap(shown.haveGroups.first { $0.kind == .accounts })
    XCTAssertEqual(shownAccounts.totalRub, wholeAccounts.totalRub, "the block keeps all the money")
    XCTAssertTrue(shownAccounts.partHidden)
    XCTAssertTrue(shown.partHidden)
    XCTAssertFalse(all.partHidden)
    XCTAssertTrue(CapitalViewModel.touchesHidden(capital, hiding: covered.hiding))
    XCTAssertFalse(CapitalViewModel.touchesHidden(capital, hiding: whole.hiding))
  }

  func testABlockOfOnlyHiddenAccountsIsDroppedAndTheSummaryBlockKept() {
    let hiding = HiddenAccounts(ids: [secret.id])
    func line(_ id: UUID, _ group: CapitalLine.Group) -> CapitalLine {
      CapitalLine(
        source: .account(id), group: group, name: id == secret.id ? secret.name : open.name,
        currency: .rub, amount: rub(10), amountRub: rub(10))
    }
    let groups = CapitalViewModel.groups(
      [line(secret.id, .accounts), line(secret.id, .deposits), line(open.id, .deposits)],
      order: CapitalViewModel.haveOrder, groupNames: [:])
    let (covered, removed) = CapitalViewModel.covering(groups, hiding: hiding)
    XCTAssertTrue(removed)
    XCTAssertEqual(covered.map(\.kind), [.accounts, .deposits])
    XCTAssertEqual(covered[0].rows.count, 0)
    XCTAssertEqual(covered[0].totalRub, rub(10))
    XCTAssertEqual(covered[1].rows.map(\.line.name), [open.name])
    XCTAssertEqual(covered[1].totalRub, rub(20))
    XCTAssertTrue(covered.allSatisfy(\.partHidden))

    let onlyHidden = CapitalViewModel.groups(
      [line(secret.id, .deposits)], order: CapitalViewModel.haveOrder, groupNames: [:])
    XCTAssertTrue(CapitalViewModel.covering(onlyHidden, hiding: hiding).groups.isEmpty)
  }

  func testTheCushionSaysPartIsHiddenAndNamesNoHiddenBalance() {
    let (whole, covered) = snapshots(books().dataset)
    let status = whole.planning.cushion
    XCTAssertTrue(status.accounts.contains(secret.id))
    XCTAssertTrue(CushionText.touchesHidden(status, hiding: covered.hiding))
    XCTAssertFalse(CushionText.touchesHidden(status, hiding: whole.hiding))
    XCTAssertFalse(CushionText.touchesHidden(status, hiding: nil))
    let keys = [
      BalanceKey(accountId: secret.id, currency: .rub),
      BalanceKey(accountId: open.id, currency: .rub),
    ]
    XCTAssertEqual(
      CushionText.unanchored(keys, hiding: covered.hiding).map(\.accountId), [open.id])
    XCTAssertEqual(CushionText.unanchored(keys, hiding: whole.hiding).count, 2)
  }

  // MARK: 4. Plans

  func testTheCalendarListsNoPlanOfAHiddenAccountAndKeepsTheDaySums() throws {
    let books = books()
    let (whole, covered) = snapshots(books.dataset)
    func day(_ snapshot: DataSnapshot, shown: DataSnapshot? = nil) throws -> SpendingCalendarDay {
      let calendar = CalendarScreen.calendar(
        of: snapshot, scope: .month, anchor: today, firstWeekday: 2, shown: shown)
      return try XCTUnwrap(calendar.day(today.adding(days: 3)))
    }
    let all = try day(whole)
    let shown = try day(covered)
    XCTAssertEqual(
      Set(all.plans.map(\.sourceId)), [books.openBill.id, books.hiddenBill.id, books.cardBill.id])
    XCTAssertEqual(shown.plans.map(\.sourceId), [books.openBill.id])
    XCTAssertEqual(shown.plannedOut, all.plannedOut, "the sum of the day keeps all the plans")
    XCTAssertEqual(try day(whole, shown: covered).plans.map(\.sourceId), [books.openBill.id])
    let income = try XCTUnwrap(
      CalendarScreen.calendar(of: covered, scope: .month, anchor: today, firstWeekday: 2)
        .day(today.adding(days: 5)))
    XCTAssertEqual(income.plans.map(\.sourceId), [books.openIncome.id])
  }

  func testTheRibbonShowsNoPlanOfAHiddenAccountAndKeepsItsSums() {
    let books = books()
    let (whole, covered) = snapshots(books.dataset)
    let all = PlanningView.ribbon(of: whole)
    let shown = PlanningView.ribbon(of: whole, shown: covered)
    XCTAssertEqual(
      Set(all.days.flatMap(\.payments).map(\.sourceId)),
      [books.openBill.id, books.hiddenBill.id, books.cardBill.id])
    XCTAssertEqual(shown.days.flatMap(\.payments).map(\.sourceId), [books.openBill.id])
    XCTAssertEqual(shown.days.flatMap(\.incomes).map(\.sourceId), [books.openIncome.id])
    XCTAssertEqual(shown.paymentsRub, all.paymentsRub)
    XCTAssertEqual(shown.incomesRub, all.incomesRub)
    XCTAssertEqual(PlanningView.ribbon(of: covered).days, shown.days)
  }

  func testTheBlocksOfPlanningListNoPlanOfAHiddenAccount() {
    let books = books()
    let (whole, covered) = snapshots(books.dataset)
    let hidden = HiddenPlans(snapshot: covered)
    XCTAssertEqual(hidden.scheduled, [books.hiddenBill.id, books.cardBill.id])
    XCTAssertEqual(hidden.expected, [books.hiddenIncome.id])
    XCTAssertTrue(HiddenPlans(snapshot: whole).isEmpty)

    let planning = whole.planning
    XCTAssertEqual(
      ScheduledBlock.listed(planning.scheduled, hiding: hidden).map(\.payment.id),
      [books.openBill.id])
    XCTAssertEqual(ScheduledBlock.listed(planning.scheduled, hiding: .none).count, 3)
    XCTAssertEqual(
      ExpectedIncomeBlock.listed(planning.expected, hiding: hidden).map(\.id),
      [books.openIncome.id])
    XCTAssertFalse(
      UpcomingPaymentsCard.listed(planning.upcoming, hiding: hidden).contains {
        $0.id == books.hiddenBill.id || $0.id == books.cardBill.id
      })
    XCTAssertTrue(
      UpcomingPaymentsCard.listed(planning.upcoming, hiding: hidden).contains {
        $0.id == books.openBill.id
      })

    let funding = [
      FundingLine(
        paymentMethodId: secret.id, currency: .rub, due: rub(1), paid: .zero, remaining: rub(1),
        withoutRate: false),
      FundingLine(
        paymentMethodId: open.id, currency: .rub, due: rub(1), paid: .zero, remaining: rub(1),
        withoutRate: false),
    ]
    XCTAssertEqual(
      ScheduledBlock.funding(funding, hiding: covered.hiding).map(\.paymentMethodId), [open.id])
  }

  // MARK: 5. The page of the year

  func testTheYearSaysNothingFromTheDescriptionsOfHiddenOperations() {
    let books = books()
    let (whole, covered) = snapshots(books.dataset)
    let all = YearPlanInputs.yearlyRecords(whole.ledger, hidden: HiddenOperations(snapshot: whole))
    let shown = YearPlanInputs.yearlyRecords(
      covered.ledger, hidden: HiddenOperations(snapshot: covered))
    XCTAssertTrue(all.contains { $0.title == "Secret insurance" })
    XCTAssertEqual(shown.map(\.title), ["Coffee"])
    XCTAssertNotEqual(
      YearPlanInputs.hidingKey(whole), YearPlanInputs.hidingKey(covered),
      "the cache tells the covered page from the revealed one")
  }

  // MARK: 6. «Почему так» of «Прогноз остатка»

  func testTheBalanceForecastBreakdownAddsUpToTheTileAndNamesNoHiddenAccount() throws {
    let (whole, covered) = snapshots(books().dataset)
    let remainder = MonthForecast.Remainder(
      p10: rub(100), middle: rub(200), p90: rub(400), lowData: false, computedFor: today,
      daysLeft: 11, windowDays: 90)
    let tile = BalanceForecastModel(
      forecast: whole.accountPlan.forecast(remainder: remainder),
      accountIds: BalanceForecastCard.summaryAccountIds(of: whole, locale: Locale(identifier: "en"))
    )
    let all = TileWhy.balanceForecast(
      whole: whole, shown: whole, remainder: remainder, locale: Locale(identifier: "en"))
    let shown = TileWhy.balanceForecast(
      whole: whole, shown: covered, remainder: remainder, locale: Locale(identifier: "en"))

    func texts(_ explanation: TileExplanation) -> [String] {
      explanation.sections.flatMap(\.rows).flatMap(\.label.arguments).compactMap {
        if case .text(let text) = $0 { text } else { nil }
      }
    }
    XCTAssertTrue(texts(all).contains(secret.name))
    XCTAssertFalse(texts(shown).contains(secret.name))
    XCTAssertTrue(texts(shown).contains(open.name))
    XCTAssertEqual(shown.figure, all.figure, "the total is the tile's figure")
    XCTAssertEqual(shown.figure, .approximately(try XCTUnwrap(tile.totals.first).middle, .rub))
    let folded = try XCTUnwrap(shown.sections.first?.rows.last)
    XCTAssertEqual(folded.label.key, "privacy.partHidden")
    XCTAssertNil(folded.value, "the folded line says no amount")
    XCTAssertFalse(all.sections.flatMap(\.rows).contains { $0.label.key == "privacy.partHidden" })
  }

  func testWhyOfThePlanTilesAndTheLastRecordNamesNothingHiddenAndKeepsTheFigure() throws {
    let books = books()
    let (whole, covered) = snapshots(books.dataset)
    let environment = AppEnvironment()
    func why(_ tile: OverviewTile, _ snapshot: DataSnapshot) -> TileExplanation {
      TileWhy.explanation(
        of: tile, snapshot: snapshot, remainder: nil, owed: nil, anomalies: nil, rates: nil,
        environment: environment)
    }
    func texts(_ explanation: TileExplanation) -> [String] {
      explanation.sections.flatMap(\.rows).flatMap(\.label.arguments).compactMap {
        if case .text(let text) = $0 { text } else { nil }
      }
    }
    func folded(_ explanation: TileExplanation) -> Bool {
      explanation.sections.flatMap(\.rows).contains {
        $0.label.key == "privacy.partHidden" && $0.value == nil
      }
    }

    let upcomingAll = why(.upcoming, whole)
    let upcoming = why(.upcoming, covered)
    XCTAssertTrue(texts(upcomingAll).contains(books.hiddenBill.name))
    XCTAssertFalse(texts(upcoming).contains(books.hiddenBill.name))
    XCTAssertFalse(texts(upcoming).contains(books.cardBill.name))
    XCTAssertTrue(texts(upcoming).contains(books.openBill.name))
    XCTAssertTrue(folded(upcoming))

    let expectedAll = why(.expectedIncome, whole)
    let expected = why(.expectedIncome, covered)
    XCTAssertTrue(texts(expectedAll).contains(books.hiddenIncome.name))
    XCTAssertFalse(texts(expected).contains(books.hiddenIncome.name))
    XCTAssertTrue(texts(expected).contains(books.openIncome.name))
    XCTAssertEqual(expected.figure, expectedAll.figure, "the total is the tile's figure")
    XCTAssertTrue(folded(expected))

    let recordAll = why(.lastRecord, whole)
    let record = why(.lastRecord, covered)
    XCTAssertTrue(texts(recordAll).contains("Card buy"))
    XCTAssertFalse(texts(record).contains("Card buy"))
    XCTAssertTrue(folded(record))
    XCTAssertFalse(folded(recordAll))
  }

  func testCapitalNamesNoBankThatHoldsOnlyHiddenAccounts() {
    let secretBank = UUID()
    let openBank = UUID()
    var hiddenAccount = secret
    hiddenAccount.bankId = secretBank
    var visible = open
    visible.bankId = openBank
    let accounts = [visible, hiddenAccount]
    let banks = [secretBank, openBank].map {
      BankInsurance(
        bankId: $0, name: "Bank", accountIds: [], totalRub: rub(2_000_000),
        limitRub: rub(1_400_000), on: today)
    }
    XCTAssertEqual(
      CapitalInsuranceSection.shown(banks, accounts: accounts, hiding: HiddenAccounts(ids: [secret.id]))
        .map(\.bankId), [openBank])
    XCTAssertEqual(
      CapitalInsuranceSection.shown(banks, accounts: accounts, hiding: HiddenAccounts(ids: [UUID]()))
        .count, 2)
  }

  // MARK: Subscriptions, the year, the currency gain

  func testTheSubscriptionNoticesNameNoPaymentOfAHiddenAccount() {
    var books = books()
    let tomorrow = today.adding(days: 1)
    let secretTrial = ScheduledPayment(
      name: "Secret stream", kind: .subscription, amountE4: rub(399), paymentMethodId: secret.id,
      day: tomorrow.day, nextDate: tomorrow, trialEnd: tomorrow)
    let openTrial = ScheduledPayment(
      name: "Music", kind: .subscription, amountE4: rub(199), paymentMethodId: open.id,
      day: tomorrow.day, nextDate: tomorrow, trialEnd: tomorrow)
    books.dataset.planning.scheduled += [secretTrial, openTrial]
    let (whole, covered) = snapshots(books.dataset)
    let notices = SubscriptionWatch.notices(
      book: whole.dataset.planning, subscriptions: whole.dataset.subscriptions, today: today)
    XCTAssertEqual(Set(notices.map(\.paymentId)), [secretTrial.id, openTrial.id])
    XCTAssertEqual(
      SubscriptionNoticeRows.visible(
        notices, dismissed: [], hiding: HiddenPlans(snapshot: covered)
      ).map(\.paymentId), [openTrial.id])
    XCTAssertEqual(
      SubscriptionNoticeRows.visible(notices, dismissed: [], hiding: HiddenPlans(snapshot: whole))
        .count, 2)
  }

  func testTheYearNamesNoPlanOfAHiddenAccountAndKeepsTheCellFigure() throws {
    let books = books()
    let (whole, covered) = snapshots(books.dataset)
    let plan = YearPlanInputs.plan(covered, window: .rolling(from: today.monthKey))
    let payments = try XCTUnwrap(plan.cell(.payments, today.monthKey))
    let incomes = try XCTUnwrap(plan.cell(.income, today.monthKey))
    XCTAssertTrue(payments.items.contains { $0.sourceId == books.hiddenBill.id })
    let hidden = HiddenPlans(snapshot: covered)
    let shownPayments = YearGridCard.listed(payments.items, hiding: hidden)
    XCTAssertFalse(shownPayments.contains { $0.title == books.hiddenBill.name })
    XCTAssertFalse(shownPayments.contains { $0.title == books.cardBill.name })
    XCTAssertTrue(shownPayments.contains { $0.title == books.openBill.name })
    XCTAssertFalse(
      YearGridCard.listed(incomes.items, hiding: hidden).contains {
        $0.sourceId == books.hiddenIncome.id
      })
    XCTAssertEqual(
      payments.total,
      try XCTUnwrap(
        YearPlanInputs.plan(whole, window: .rolling(from: today.monthKey))
          .cell(.payments, today.monthKey)
      ).total, "the figure of the cell keeps the hidden payments")
    XCTAssertEqual(YearGridCard.listed(payments.items, hiding: .none), payments.items)
  }

  func testTheCurrencyGainSaysPartIsHiddenWhenAHiddenAccountHoldsForeignMoney() {
    let inputs = [
      CurrencyGain.Input(
        key: BalanceKey(accountId: secret.id, currency: .usd), balanceAtStart: nil,
        balanceAtEnd: nil, flows: []),
      CurrencyGain.Input(
        key: BalanceKey(accountId: open.id, currency: .usd), balanceAtStart: nil,
        balanceAtEnd: nil, flows: []),
    ]
    let gain = CurrencyGain(
      inputs: inputs, rates: .empty, from: today.monthKey.firstDay, to: today)
    XCTAssertTrue(CurrencyGainSection.touchesHidden(gain, hiding: HiddenAccounts(ids: [secret.id])))
    XCTAssertFalse(CurrencyGainSection.touchesHidden(gain, hiding: HiddenAccounts(ids: [UUID]())))
    let visibleOnly = CurrencyGain(
      inputs: [inputs[1]], rates: .empty, from: today.monthKey.firstDay, to: today)
    XCTAssertFalse(
      CurrencyGainSection.touchesHidden(visibleOnly, hiding: HiddenAccounts(ids: [secret.id])))
  }

  func testTheFormsOfAPaymentSayTheMainAccountIsHiddenWithoutNamingIt() {
    var hiddenMain = secret
    hiddenMain.isDefault = true
    var plain = open
    plain.isDefault = false
    let accounts = [plain, hiddenMain]
    let environment = AppEnvironment()
    environment.language.choice = .russian
    XCTAssertEqual(
      AccountPicker.noneTitle(
        accounts: accounts, hiding: HiddenAccounts(accounts: accounts), environment),
      "Основной счёт (скрыт)")
    XCTAssertNil(
      AccountPicker.noneTitle(accounts: accounts, hiding: HiddenAccounts(ids: [UUID]()), environment))
    XCTAssertNil(
      AccountPicker.noneTitle(
        accounts: [open, secret], hiding: HiddenAccounts(accounts: [open, secret]), environment))
    // The form of an expected income says «as last time, else the main one» for no pick and
    // never lists the hidden main account.
    let options = ExpectedIncomeAccounts.options(
      accounts, hiding: HiddenAccounts(accounts: accounts), selection: nil, auto: "auto",
      locale: Locale(identifier: "en"))
    XCTAssertEqual(options.first, ExpectedIncomeAccounts.Option(id: nil, title: "auto"))
    XCTAssertFalse(options.contains { $0.title == secret.name })
  }

  // MARK: 7. The goal form

  func testTheGoalFormSaysTheMainAccountIsHiddenWithoutNamingIt() {
    var hiddenMain = secret
    hiddenMain.isDefault = true
    var plain = open
    plain.isDefault = false
    let accounts = [plain, hiddenMain]
    XCTAssertTrue(
      GoalMoveForm.hidesMain(accounts, hiding: HiddenAccounts(accounts: accounts)))
    XCTAssertFalse(GoalMoveForm.hidesMain(accounts, hiding: HiddenAccounts(ids: [UUID]())))
    XCTAssertFalse(
      GoalMoveForm.hidesMain([open, secret], hiding: HiddenAccounts(accounts: [open, secret])))
    for (choice, text) in [
      (AppLanguage.Choice.russian, "Основной счёт (скрыт)"),
      (.english, "Main account (hidden)"),
    ] {
      let environment = AppEnvironment()
      environment.language.choice = choice
      XCTAssertEqual(environment.language("form.method.mainHidden", table: "Planning"), text)
    }
  }

  // MARK: 8. A transfer of the day list

  func testTheDayListTellsTransfersByTheSnapshotOnScreen() {
    let (whole, covered) = snapshots(books().dataset)
    let hiding = DayListHiding.accounts(of: covered)
    XCTAssertEqual(hiding.ids, [secret.id, other.id])
    XCTAssertTrue(DayListHiding.accounts(of: whole).isEmpty)
    XCTAssertTrue(DayListHiding.accounts(of: nil).isEmpty)
    let transfer = Transfer(
      occurredAt: noon(today), fromAccountId: open.id, fromCurrency: .rub,
      fromAmountE4: rub(50), toAccountId: secret.id, toCurrency: .rub, toAmountE4: rub(50))
    let names = [open.id: open.name, secret.id: secret.name]
    let text = TransferRowText(transfer, names: names, hiding: hiding)
    XCTAssertEqual(text.caption, .toHidden)
    XCTAssertFalse(text.title(language: AppEnvironment().language).contains(secret.name))
  }
}
