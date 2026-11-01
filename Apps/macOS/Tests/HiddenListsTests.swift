import AppCore
import XCTest

@testable import OhMyMoney

// Synthetic data only.

/// While the hidden accounts are covered, the lists of operations — a day of «Календарь», the
/// table and the search of «Операции», the lists of «Аналитика» — show nothing of theirs: no
/// operation paid from such an account or with a card of it, no line of the account, no name.
/// The figures keep all the money and say «часть скрыта». Revealed, everything is listed again.
final class HiddenListsTests: XCTestCase {
  private let food = CoreKit.Category(kind: .expense, name: "Food")
  private let salary = CoreKit.Category(kind: .income, name: "Salary")
  private let open = PaymentMethod(name: "Sber Main", isDefault: true)
  private let secret: PaymentMethod = {
    var account = PaymentMethod(name: "Secret Savings")
    account.hidden = true
    return account
  }()
  private let other: PaymentMethod = {
    var account = PaymentMethod(name: "Other Secret")
    account.hidden = true
    return account
  }()
  private lazy var secretCard = PaymentCard(accountId: secret.id, name: "Secret Black")

  private let today = DateOnly(year: 2026, month: 9, day: 19)
  private var september: MonthKey { today.monthKey }

  private func noon(_ day: DateOnly) -> Date {
    CalendarContext.utc.startOfDay(day).addingTimeInterval(12 * 3600)
  }

  private func spend(
    _ rubles: String, on day: DateOnly, account: UUID?, card: UUID? = nil, note: String? = nil
  ) -> TransactionEntry {
    let id = UUID()
    let amount = money(rubles)
    let when = noon(day)
    return TransactionEntry(
      transaction: Transaction(
        id: id, kind: .expense, occurredAt: when, amountE4: amount, note: note,
        paymentMethodId: account, createdAt: when, updatedAt: when, cardId: card),
      parts: [
        TransactionPart(
          transactionId: id, categoryId: food.id, quality: .neutral, qualitySource: .category,
          amountE4: amount)
      ])
  }

  private func transfer(_ from: UUID, _ to: UUID, on day: DateOnly) -> Transfer {
    Transfer(
      occurredAt: noon(day), fromAccountId: from, fromCurrency: .rub,
      fromAmountE4: money("50"), toAccountId: to, toCurrency: .rub, toAmountE4: money("50"))
  }

  private struct Books {
    var dataset: Dataset
    var openOp: TransactionEntry
    var hiddenOp: TransactionEntry
    var cardOp: TransactionEntry
  }

  /// One day with three purchases: one from the visible account, one from the hidden account,
  /// one with a card of the hidden account that names no account.
  private func books() -> Books {
    let openOp = spend("100", on: today, account: open.id, note: "Coffee")
    let hiddenOp = spend("300", on: today, account: secret.id, note: "Secret gift")
    let cardOp = spend("200", on: today, account: nil, card: secretCard.id, note: "Card buy")
    let dataset = Dataset(
      entries: [openOp, hiddenOp, cardOp], categories: [food, salary],
      paymentMethods: [open, secret, other],
      transfers: [
        transfer(open.id, secret.id, on: today), transfer(secret.id, other.id, on: today),
      ],
      cards: [secretCard])
    return Books(dataset: dataset, openOp: openOp, hiddenOp: hiddenOp, cardOp: cardOp)
  }

  private func snapshots(_ dataset: Dataset) -> (whole: DataSnapshot, covered: DataSnapshot) {
    let whole = DataSnapshot.build(
      dataset: dataset, calendar: .utc, today: today, context: SnapshotContext(),
      version: DataVersion(load: 0))
    return (whole, whole.presented(hiding: HiddenAccounts(accounts: dataset.paymentMethods)))
  }

  // MARK: What is hidden

  func testTheCoveredSnapshotHidesTheAccountsAndTheirCardsAndTheWholeOneNothing() {
    let books = books()
    let (whole, covered) = snapshots(books.dataset)
    let hidden = HiddenOperations(snapshot: covered)
    XCTAssertEqual(hidden.accounts.ids, [secret.id, other.id])
    XCTAssertEqual(hidden.cards, [secretCard.id])
    XCTAssertTrue(hidden.hides(books.hiddenOp))
    XCTAssertTrue(hidden.hides(books.cardOp), "a card of a hidden account hides its operation")
    XCTAssertFalse(hidden.hides(books.openOp))
    XCTAssertTrue(HiddenOperations(snapshot: whole).isEmpty)
  }

  // MARK: «Календарь»

  private func chosenDay(_ snapshot: DataSnapshot) throws -> [TransactionsStore.DayGroup] {
    let calendar = CalendarScreen.calendar(
      of: snapshot, scope: .month, anchor: today, firstWeekday: 2)
    return CalendarScreen.groups(
      of: try XCTUnwrap(calendar.day(today)), in: snapshot, calendar: .utc)
  }

  func testADayOfTheCalendarListsNoHiddenOperationAndKeepsItsWholeFigure() throws {
    let books = books()
    let (whole, covered) = snapshots(books.dataset)
    let shown = try XCTUnwrap(try chosenDay(covered).first)
    let all = try XCTUnwrap(try chosenDay(whole).first)

    XCTAssertEqual(shown.entries.map(\.id), [books.openOp.id])
    XCTAssertEqual(shown.totals, all.totals, "the header keeps the money of the hidden account")
    XCTAssertTrue(shown.partHidden)
    XCTAssertEqual(
      Set(all.entries.map(\.id)), [books.openOp.id, books.hiddenOp.id, books.cardOp.id])
    XCTAssertFalse(all.partHidden)
  }

  func testTheMonthFigureOfTheCalendarSaysPartIsHiddenOnlyWhileCovered() {
    let books = books()
    let (whole, covered) = snapshots(books.dataset)
    let calendar = CalendarScreen.calendar(
      of: covered, scope: .month, anchor: today, firstWeekday: 2)
    XCTAssertTrue(CalendarScreen.partHidden(of: calendar, in: covered))
    XCTAssertFalse(CalendarScreen.partHidden(of: calendar, in: whole))
    XCTAssertEqual(
      calendar.spent,
      CalendarScreen.calendar(of: whole, scope: .month, anchor: today, firstWeekday: 2).spent,
      "the figure of the month is not lowered by hiding")
  }

  func testAMonthWithoutHiddenSpendingSaysNothing() {
    var dataset = books().dataset
    dataset.entries = [spend("100", on: today, account: open.id)]
    let (_, covered) = snapshots(dataset)
    let calendar = CalendarScreen.calendar(
      of: covered, scope: .month, anchor: today, firstWeekday: 2)
    XCTAssertFalse(CalendarScreen.partHidden(of: calendar, in: covered))
  }

  func testADayGroupDropsTransfersBetweenHiddenAccountsAndKeepsTheOneToAVisibleAccount() {
    let books = books()
    let hidden = HiddenOperations(snapshot: snapshots(books.dataset).covered)
    let groups = TransactionsStore.group(
      books.dataset.entries, calendar: .utc, transfers: books.dataset.transfers)
    let group = groups[0].covering(hidden)
    XCTAssertEqual(group.transfers.count, 1)
    XCTAssertEqual(group.transfers.first?.toAccountId, secret.id)
    XCTAssertEqual(
      HiddenAccounts(accounts: books.dataset.paymentMethods).caption(for: group.transfers[0]),
      .toHidden)
    XCTAssertTrue(group.partHidden)
    let same = groups[0].covering(.none)
    XCTAssertEqual(same.items.count, groups[0].items.count)
    XCTAssertFalse(same.partHidden)
  }

  // MARK: «Операции»

  func testTheTableAndTheSearchOfOperationsLeaveOutTheCardOfAHiddenAccount() {
    let books = books()
    let (_, covered) = snapshots(books.dataset)
    let hidden = HiddenOperations(snapshot: covered)
    var filter = EntryFilter.none
    filter.hiddenAccountIds = hidden.accounts.ids
    filter.hiddenCardIds = hidden.cards
    let listing = TransactionListing.build(matching: filter, in: covered.ledger)
    XCTAssertTrue(listing.visibleIds.contains(books.openOp.id))
    XCTAssertFalse(listing.visibleIds.contains(books.hiddenOp.id))
    XCTAssertFalse(listing.visibleIds.contains(books.cardOp.id))
    filter.text = "Card buy"
    XCTAssertTrue(TransactionListing.build(matching: filter, in: covered.ledger).visibleIds.isEmpty)
    filter.text = "Secret"
    let found = TransactionListing.build(matching: filter, in: covered.ledger)
    XCTAssertFalse(found.visibleIds.contains(books.hiddenOp.id))
    var revealed = EntryFilter.none
    revealed.text = "Card buy"
    XCTAssertEqual(
      TransactionListing.build(matching: revealed, in: covered.ledger).visibleIds,
      [books.cardOp.id])
  }

  // MARK: «Аналитика»

  private func model(
    _ section: AnalyticsSection, _ snapshot: DataSnapshot, anomalies: AnomalyReport? = nil,
    forecast: ForecastInputs? = nil
  ) -> AnalyticsModel {
    AnalyticsBuilder.model(
      AnalyticsRequest(
        section: section, period: .month(september), today: today, forecast: forecast,
        anomalies: anomalies, hiding: HiddenOperations(snapshot: snapshot)),
      ledger: snapshot.ledger)
  }

  func testTheFiguresOfAnalyticsKeepTheHiddenMoneyAndSaySo() {
    let (whole, covered) = snapshots(books().dataset)
    let shown = model(.overview, covered)
    let all = model(.overview, whole)
    XCTAssertEqual(shown.overview?.categories.content, all.overview?.categories.content)
    XCTAssertEqual(
      shown.overview?.categories.content?.first?.value, 600, "all three purchases are counted")
    XCTAssertTrue(shown.partHidden)
    XCTAssertFalse(all.partHidden)
  }

  func testAnAnomalyOfAHiddenOperationIsNotListedWhileCovered() {
    let books = books()
    let (whole, covered) = snapshots(books.dataset)
    let ofHidden = Anomaly(
      rule: .largeExpense, subject: "a", day: today, amount: money("300"),
      transactionId: books.hiddenOp.id)
    let ofCard = Anomaly(
      rule: .possibleDuplicate, subject: "b", day: today, amount: money("200"),
      transactionId: books.cardOp.id, isHidden: true)
    let ofOpen = Anomaly(
      rule: .largeExpense, subject: "c", day: today, amount: money("100"),
      transactionId: books.openOp.id)
    let weekly = Anomaly(
      rule: .categorySpike, subject: "d", day: today, amount: money("600"), categoryId: food.id)
    let report = AnomalyReport(all: [ofHidden, ofCard, ofOpen, weekly])

    let shown = model(.anomalies, covered, anomalies: report)
    XCTAssertEqual(
      Set(shown.anomalies?.found.content?.map(\.subject) ?? []), ["c", "d"],
      "the anomalies of a category stay: they are figures")
    XCTAssertEqual(shown.anomalies?.hidden.map(\.subject), [])
    XCTAssertTrue(shown.partHidden)

    let all = model(.anomalies, whole, anomalies: report)
    XCTAssertEqual(Set(all.anomalies?.found.content?.map(\.subject) ?? []), ["a", "c", "d"])
    XCTAssertEqual(all.anomalies?.hidden.map(\.subject), ["b"])
  }

  func testOnlyHiddenAnomaliesLeaveNothingUnusualToSay() {
    let books = books()
    let (_, covered) = snapshots(books.dataset)
    let report = AnomalyReport(all: [
      Anomaly(
        rule: .largeExpense, subject: "a", day: today, amount: money("300"),
        transactionId: books.hiddenOp.id)
    ])
    XCTAssertEqual(
      model(.anomalies, covered, anomalies: report).anomalies?.found.reason, .noAnomalies)
  }

  func testThePaymentMethodsNameNoHiddenAccountWhileCovered() {
    let (whole, covered) = snapshots(books().dataset)
    func accounts(_ model: AnalyticsModel) -> Set<UUID> {
      let rows = model.paymentMethods?.table.content ?? []
      let bars = model.paymentMethods?.spending.content ?? []
      return Set(
        (rows.map(\.key) + bars.map(\.key)).compactMap {
          if case .paymentMethod(let id) = $0 { id } else { nil }
        })
    }
    let shown = model(.paymentMethods, covered)
    XCTAssertEqual(accounts(shown), [open.id])
    XCTAssertTrue(shown.partHidden)
    XCTAssertTrue(accounts(model(.paymentMethods, whole)).contains(secret.id))
  }

  func testTheCashbackChoicesOfferNoHiddenAccountOrCard() {
    let months = CashbackMonthsModel(
      choices: [.all, .account(open.id), .account(secret.id), .card(secretCard.id)],
      months: [.all: [], .account(open.id): [], .account(secret.id): [], .card(secretCard.id): []],
      cardAccounts: [secretCard.id: secret.id])
    let section = PaymentMethodsSectionModel(
      spending: .notEnoughData(.noSpending), table: .notEnoughData(.noPayments),
      cashbackMonths: .ready(months))
    let hidden = HiddenOperations(snapshot: snapshots(books().dataset).covered)
    let (covered, removed) = AnalyticsBuilder.covering(section, hidden: hidden)
    let kept = covered.cashbackMonths.content
    XCTAssertEqual(kept?.choices, [.all, .account(open.id)])
    XCTAssertEqual(Set(kept?.months.keys.map { $0 } ?? []), [.all, .account(open.id)])
    XCTAssertEqual(kept?.cardAccounts, [:])
    XCTAssertTrue(removed)
  }

  func testTheBalancesAtTheEndOfTheMonthListNoHiddenAccountAndKeepTheTotal() throws {
    var dataset = books().dataset
    let reconciliation = Reconciliation(
      date: DateOnly(year: 2026, month: 9, day: 10),
      reconciledAt: CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 10)),
      actualTotalRubE4: .zero, kind: .accounts)
    dataset.planning = PlanningBook(
      reconciliations: [reconciliation],
      reconciledBalances: [open.id, secret.id].map {
        ReconciledBalance(
          reconciliationId: reconciliation.id, accountId: $0, currency: .rub,
          actualE4: money("10000"))
      })
    let (whole, covered) = snapshots(dataset)
    let remainder = MonthForecast.Remainder(
      p10: money("100"), middle: money("200"), p90: money("400"), lowData: false,
      computedFor: today, daysLeft: 11, windowDays: 90)
    let inputs = ForecastInputs(planned: .zero, remainder: remainder, accounts: whole.accountPlan)
    let all = try XCTUnwrap(model(.forecast, whole, forecast: inputs).forecast?.accounts.content)
    let shownModel = model(.forecast, covered, forecast: inputs)
    let shown = try XCTUnwrap(shownModel.forecast?.accounts.content)

    XCTAssertTrue(all.sections.flatMap(\.lines).contains { $0.key.accountId == secret.id })
    XCTAssertFalse(shown.sections.flatMap(\.lines).contains { $0.key.accountId == secret.id })
    XCTAssertFalse(shown.unanchored.contains { $0.accountId == secret.id })
    XCTAssertEqual(shown.inSummaryTotalRub, all.inSummaryTotalRub, "the total keeps all the money")
    XCTAssertTrue(shownModel.partHidden)
  }

  @MainActor
  func testAModelMadeWhileRevealedIsNotShownOnceCovered() {
    let (whole, covered) = snapshots(books().dataset)
    let revealedModel = model(.overview, whole)
    var wanted = revealedModel.request
    wanted.hiding = HiddenOperations(snapshot: covered)
    let state = AnalyticsStore.state(
      for: wanted, data: BlockState<Int>.ready(1, at: Date()), forecast: nil,
      model: revealedModel, at: Date())
    XCTAssertEqual(state.value == nil, true, "a model of the shown accounts waits for a new one")
    let same = AnalyticsStore.state(
      for: revealedModel.request, data: BlockState<Int>.ready(1, at: Date()), forecast: nil,
      model: revealedModel, at: Date())
    XCTAssertNotNil(same.value)
  }

  func testTheLargestPurchasesNameNoHiddenOperationAndCountItWithTheOthers() {
    let books = books()
    let (_, covered) = snapshots(books.dataset)
    let whole = LimitConsumption(ledger: covered.ledger, categoryId: food.id, month: september)
    XCTAssertEqual(whole.largest.count, 3)
    let (shown, partHidden) = whole.covering(
      HiddenOperations(snapshot: covered), in: covered.ledger)
    XCTAssertEqual(shown.largest.map(\.transactionId), [books.openOp.id])
    XCTAssertEqual(shown.spent, whole.spent, "what was spent is the whole figure")
    XCTAssertEqual(shown.othersCount, whole.othersCount + 2)
    XCTAssertEqual(shown.othersTotal, whole.othersTotal + money("500"))
    XCTAssertEqual(shown.othersLargest, money("300"))
    XCTAssertTrue(partHidden)
    let (same, none) = whole.covering(.none, in: covered.ledger)
    XCTAssertEqual(same, whole)
    XCTAssertFalse(none)
  }

  func testPlacesFromDescriptionsNeitherOfferNorWriteHiddenOperations() {
    let place = Place(name: "Coffee")
    let books = books()
    var entries = books.dataset.entries
    entries.append(spend("50", on: today, account: secret.id, note: "Coffee"))
    let hidden = HiddenOperations(snapshot: snapshots(books.dataset).covered)
    let plan = PlaceFromNotePlan.build(entries: entries, places: [place], hiding: hidden)
    XCTAssertEqual(plan.proposals.first?.ids, [books.openOp.id])
    let all = PlaceFromNotePlan.build(entries: entries, places: [place])
    XCTAssertEqual(all.proposals.first?.ids.count, 2)
  }
}
