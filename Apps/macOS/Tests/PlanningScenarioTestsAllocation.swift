import AppCore
import XCTest

@testable import OhMyMoney

/// Allocating a salary by the owner's rules: which incomes count as «Заработок» (chosen, by
/// name in either language, under it, archived), a percent of the income after the tax, a
/// fixed sum in dollars at the rate of the day, what a sheet writes (a contribution and its
/// transfer once, nothing to the income's own account, nothing at zero), how much is already
/// allocated, the keys `alloc:`, the day the sheet looks to, a raise above the usual, and the
/// settings read back from their rows.
final class PlanningScenarioTestsAllocation: XCTestCase {
  private typealias S = PlanningScenario

  private let earnings = CoreKit.Category(kind: .income, name: "Заработок")
  private lazy var salary = CoreKit.Category(
    parentId: earnings.id, kind: .income, name: "Зарплата")
  private let gifts = CoreKit.Category(kind: .income, name: "Подарки")
  private let main = PaymentMethod(name: "Основной", kind: .card, isDefault: true)
  private let savings = PaymentMethod(name: "Накопительный", kind: .account, cushion: true)

  private var tree: CategoryTree { CategoryTree([earnings, salary, gifts]) }

  // MARK: What «Заработок» is

  func testTheTopCategoryNamedEarningsIsFoundInEitherLanguage() {
    let english = CoreKit.Category(kind: .income, name: " Earnings ")
    XCTAssertEqual(
      Allocation.earningsCategory(
        tree: CategoryTree([english]), categories: [english], settings: .standard),
      english.id)
    XCTAssertEqual(
      Allocation.earningsCategory(tree: tree, categories: [gifts, earnings], settings: .standard),
      earnings.id)
  }

  func testAnArchivedEarningsIsNotFound() {
    let archived = CoreKit.Category(kind: .income, name: "Заработок", archived: true)
    XCTAssertNil(
      Allocation.earningsCategory(
        tree: CategoryTree([archived]), categories: [archived], settings: .standard))
  }

  func testAnExpenseCategoryNamedEarningsIsNotIt() {
    let expense = CoreKit.Category(kind: .expense, name: "Заработок")
    XCTAssertNil(
      Allocation.earningsCategory(
        tree: CategoryTree([expense]), categories: [expense], settings: .standard))
  }

  func testTheChosenCategoryWinsOverTheName() {
    let chosen = AllocationSettings(earningsCategoryId: gifts.id)
    XCTAssertEqual(
      Allocation.earningsCategory(tree: tree, categories: [earnings, gifts], settings: chosen),
      gifts.id)
    XCTAssertTrue(Allocation.isEarnings(categoryId: gifts.id, tree: tree, settings: chosen))
    XCTAssertFalse(Allocation.isEarnings(categoryId: salary.id, tree: tree, settings: chosen))
  }

  func testAChosenCategoryThatIsGoneFallsBackToTheName() {
    let gone = AllocationSettings(earningsCategoryId: UUID())
    XCTAssertEqual(
      Allocation.earningsCategory(tree: tree, categories: [earnings], settings: gone),
      earnings.id)
  }

  func testASubcategoryOfEarningsIsEarnings() {
    XCTAssertTrue(Allocation.isEarnings(categoryId: salary.id, tree: tree, settings: .standard))
    XCTAssertFalse(Allocation.isEarnings(categoryId: gifts.id, tree: tree, settings: .standard))
    XCTAssertFalse(Allocation.isEarnings(categoryId: nil, tree: tree, settings: .standard))
  }

  // MARK: Which incomes are offered

  private func salaryOf(_ whole: Int64, _ day: String) -> TransactionEntry {
    S.entry(.income, S.rub(whole), on: day, category: salary.id, account: main.id)
  }

  func testASalaryIsOfferedAndAGiftIsNot() {
    XCTAssertTrue(
      Allocation.offers(entry: salaryOf(100_000, "2026-10-10"), tree: tree, settings: .standard))
    XCTAssertFalse(
      Allocation.offers(
        entry: S.entry(.income, S.rub(5_000), on: "2026-10-10", category: gifts.id),
        tree: tree, settings: .standard))
  }

  func testADeclinedOrDeletedSalaryIsNotOffered() {
    let entry = salaryOf(100_000, "2026-10-10")
    XCTAssertFalse(
      Allocation.offers(
        entry: entry, tree: tree, settings: AllocationSettings(declined: [entry.id])))
    var deleted = entry
    deleted.transaction.deletedAt = Date()
    XCTAssertFalse(Allocation.offers(entry: deleted, tree: tree, settings: .standard))
  }

  func testAnExpenseInEarningsIsNotOffered() {
    let expense = S.entry(.expense, S.rub(100), on: "2026-10-10", category: salary.id)
    XCTAssertFalse(Allocation.offers(entry: expense, tree: tree, settings: .standard))
  }

  private func ledger(
    _ entries: [TransactionEntry], transfers: [Transfer] = []
  )
    -> Ledger
  {
    Ledger(
      dataset: Dataset(
        entries: entries, categories: [earnings, salary, gifts], paymentMethods: [main, savings],
        transfers: transfers),
      calendar: S.calendar)
  }

  func testOfferedAreTheLastThirtyDaysNewestFirst() {
    let old = salaryOf(100_000, "2026-09-14")
    let inside = salaryOf(100_000, "2026-09-15")
    let latest = salaryOf(100_000, "2026-10-10")
    let offered = Allocation.offered(
      ledger: ledger([old, inside, latest]), today: S.day("2026-10-14"))
    XCTAssertEqual(offered, [latest.id, inside.id])
  }

  func testAFullyAllocatedSalaryIsNoLongerOffered() {
    let income = salaryOf(1_000, "2026-10-10")
    let moved = Transfer(
      occurredAt: income.transaction.occurredAt, fromAccountId: main.id, fromCurrency: .rub,
      fromAmountE4: S.rub(1_000), toAccountId: savings.id, toCurrency: .rub,
      toAmountE4: S.rub(1_000), externalId: Allocation.externalId(incomeId: income.id, uuid: UUID())
    )
    XCTAssertTrue(
      Allocation.offered(ledger: ledger([income], transfers: [moved]), today: S.day("2026-10-14"))
        .isEmpty)
  }

  func testAPartlyAllocatedSalaryIsStillOffered() {
    let income = salaryOf(1_000, "2026-10-10")
    let moved = Transfer(
      occurredAt: income.transaction.occurredAt, fromAccountId: main.id, fromCurrency: .rub,
      fromAmountE4: S.rub(999), toAccountId: savings.id, toCurrency: .rub,
      toAmountE4: S.rub(999), externalId: Allocation.externalId(incomeId: income.id, uuid: UUID()))
    XCTAssertEqual(
      Allocation.offered(ledger: ledger([income], transfers: [moved]), today: S.day("2026-10-14")),
      [income.id])
  }

  // MARK: Keys and what is allocated

  func testTheKeyNamesItsIncomeAndNothingElseReads() {
    let income = UUID()
    let key = Allocation.externalId(incomeId: income, uuid: UUID())
    XCTAssertTrue(key.hasPrefix("alloc:"))
    XCTAssertEqual(Allocation.income(ofKey: key), income)
    XCTAssertNil(Allocation.income(ofKey: "alloc:\(income.uuidString)"))
    XCTAssertNil(Allocation.income(ofKey: "alloc:nope:\(UUID().uuidString)"))
    XCTAssertNil(Allocation.income(ofKey: "sched:\(income.uuidString):x"))
    XCTAssertNil(Allocation.income(ofKey: nil))
  }

  func testAllocatedCountsContributionsLessRefundsAndOtherTransfersOnce() {
    let income = UUID()
    let key = Allocation.externalId(incomeId: income, uuid: UUID())
    let contribution = S.entry(
      .expense, S.rub(3_000), on: "2026-10-10", category: nil, externalId: key)
    let back = S.entry(
      .refund, S.rub(500), on: "2026-10-11", category: nil,
      externalId: Allocation.externalId(incomeId: income, uuid: UUID()))
    let carried = Transfer(
      occurredAt: Date(), fromAccountId: main.id, fromCurrency: .rub, fromAmountE4: S.rub(3_000),
      toAccountId: savings.id, toCurrency: .rub, toAmountE4: S.rub(3_000), externalId: key)
    let cushion = Transfer(
      occurredAt: Date(), fromAccountId: main.id, fromCurrency: .rub, fromAmountE4: S.rub(2_000),
      toAccountId: savings.id, toCurrency: .rub, toAmountE4: S.rub(2_000),
      externalId: Allocation.externalId(incomeId: income, uuid: UUID()))
    let total = Allocation.distributed(
      incomeId: income, entries: [contribution, back], transfers: [carried, cushion])
    XCTAssertEqual(total, S.rub(4_500))
  }

  func testAnotherIncomesAllocationIsNotThisOnes() {
    let contribution = S.entry(
      .expense, S.rub(3_000), on: "2026-10-10", category: nil,
      externalId: Allocation.externalId(incomeId: UUID(), uuid: UUID()))
    XCTAssertEqual(
      Allocation.distributed(incomeId: UUID(), entries: [contribution], transfers: []), .zero)
  }

  func testADeletedContributionIsNotAllocated() {
    let income = UUID()
    var contribution = S.entry(
      .expense, S.rub(3_000), on: "2026-10-10", category: nil,
      externalId: Allocation.externalId(incomeId: income, uuid: UUID()))
    contribution.transaction.deletedAt = Date()
    XCTAssertEqual(
      Allocation.distributed(incomeId: income, entries: [contribution], transfers: []), .zero)
    XCTAssertTrue(
      Allocation.linked(incomeId: income, entries: [contribution], transfers: []).contributions
        .isEmpty)
  }

  // MARK: What a rule takes

  func testAPercentTakesItsShareOfTheBaseToTheKopeck() {
    let rule = AllocationRule(
      target: .account(savings.id), amount: .percent(Decimal(string: "12.5")!))
    XCTAssertEqual(
      Allocation.amount(
        of: rule, base: S.kop(333_333), incomeCurrency: .rub, day: S.day("2026-10-10"),
        dayRates: .empty),
      S.kop(41_667))
  }

  func testAFixedSumInTheIncomesCurrencyIsTakenAsIs() {
    let rule = AllocationRule(target: .account(savings.id), amount: .fixed(S.rub(5_000), .rub))
    XCTAssertEqual(
      Allocation.amount(
        of: rule, base: S.rub(1), incomeCurrency: .rub, day: S.day("2026-10-10"),
        dayRates: .empty),
      S.rub(5_000))
  }

  func testAFixedSumInDollarsCountsAtTheRateOfTheDay() {
    let rule = AllocationRule(target: .account(savings.id), amount: .fixed(S.rub(100), .usd))
    let rates = DayRates(series: [.usd: [DayRate(day: S.day("2026-10-01"), perUnit: 90)]])
    XCTAssertEqual(
      Allocation.amount(
        of: rule, base: S.rub(1), incomeCurrency: .rub, day: S.day("2026-10-10"),
        dayRates: rates),
      S.rub(9_000))
    XCTAssertNil(
      Allocation.amount(
        of: rule, base: S.rub(1), incomeCurrency: .rub, day: S.day("2026-10-10"),
        dayRates: .empty))
  }

  func testARubleSumOnADollarIncomeIsInDollars() {
    let rule = AllocationRule(target: .account(savings.id), amount: .fixed(S.rub(9_000), .rub))
    let rates = DayRates(series: [.usd: [DayRate(day: S.day("2026-10-01"), perUnit: 90)]])
    XCTAssertEqual(
      Allocation.amount(
        of: rule, base: S.rub(1_000), incomeCurrency: .usd, day: S.day("2026-10-10"),
        dayRates: rates),
      S.rub(100))
  }

  // MARK: Writing a sheet

  private func sheet(_ income: TransactionEntry, lines: [AllocationLine]) -> AllocationSheet {
    AllocationSheet(
      incomeId: income.id, currency: income.transaction.currency,
      incomeE4: income.transaction.amountE4, baseE4: income.transaction.amountE4, lines: lines,
      until: S.day("2026-10-31"), unallocatedE4: income.transaction.amountE4)
  }

  func testAGoalLineWritesOneContributionAndItsTransferWithTheSameKey() throws {
    let income = salaryOf(100_000, "2026-10-10")
    let goalsCategory = UUID()
    let trip = Goal(
      name: "Отпуск", targetE4: S.rub(200_000), subcategoryId: goalsCategory,
      accountId: savings.id, transfersOnContribution: true)
    let line = AllocationLine(
      id: "goal", kind: .goal(trip.id), suggestedE4: S.rub(10_000), targetCurrency: .rub,
      transferTo: savings.id)
    let written = Allocation.write(
      sheet: sheet(income, lines: [line]), chosen: ["goal": S.rub(10_000)], income: income,
      goals: [trip], ids: { UUID() })
    let contribution = try XCTUnwrap(written.contributions.first)
    XCTAssertEqual(written.contributions.count, 1)
    XCTAssertEqual(contribution.parts.first?.goalId, trip.id)
    XCTAssertEqual(contribution.parts.first?.categoryId, goalsCategory)
    XCTAssertEqual(contribution.parts.first?.quality, .good)
    XCTAssertEqual(contribution.transaction.paymentMethodId, main.id)
    XCTAssertEqual(
      contribution.transaction.occurredAt, income.transaction.occurredAt.addingTimeInterval(1))
    XCTAssertEqual(written.transfers.count, 1)
    XCTAssertEqual(written.transfers.first?.externalId, contribution.transaction.externalId)
    XCTAssertTrue(written.goals.isEmpty)
    // The money is allocated once, not twice.
    XCTAssertEqual(
      Allocation.distributed(
        incomeId: income.id, entries: written.contributions, transfers: written.transfers),
      S.rub(10_000))
  }

  func testAGoalLineWithoutATransferTurnsTheGoalsSwitchOff() {
    let income = salaryOf(100_000, "2026-10-10")
    let trip = Goal(
      name: "Отпуск", targetE4: S.rub(200_000), accountId: savings.id,
      transfersOnContribution: true)
    let line = AllocationLine(
      id: "goal", kind: .goal(trip.id), suggestedE4: S.rub(10_000), targetCurrency: .rub)
    let written = Allocation.write(
      sheet: sheet(income, lines: [line]), chosen: ["goal": S.rub(10_000)], income: income,
      goals: [trip], ids: { UUID() })
    XCTAssertTrue(written.transfers.isEmpty)
    XCTAssertEqual(written.goals.map(\.transfersOnContribution), [false])
  }

  func testLinesAtZeroOrNotChosenWriteNothing() {
    let income = salaryOf(100_000, "2026-10-10")
    let lines = [
      AllocationLine(
        id: "a", kind: .account(savings.id), suggestedE4: S.rub(1), targetCurrency: .rub),
      AllocationLine(
        id: "b", kind: .cushion(savings.id), suggestedE4: S.rub(1), targetCurrency: .rub),
    ]
    let written = Allocation.write(
      sheet: sheet(income, lines: lines), chosen: ["a": .zero], income: income, goals: [],
      ids: { UUID() })
    XCTAssertEqual(written, .empty)
  }

  func testNoTransferToTheIncomesOwnAccount() {
    let income = salaryOf(100_000, "2026-10-10")
    let line = AllocationLine(
      id: "a", kind: .account(main.id), suggestedE4: S.rub(1), targetCurrency: .rub)
    let written = Allocation.write(
      sheet: sheet(income, lines: [line]), chosen: ["a": S.rub(5_000)], income: income,
      goals: [], ids: { UUID() })
    XCTAssertTrue(written.transfers.isEmpty)
  }

  func testACushionWithoutAnAccountAndATaxKeptNowhereOnlyShow() {
    let income = salaryOf(100_000, "2026-10-10")
    let lines = [
      AllocationLine(id: "c", kind: .cushion(nil), suggestedE4: .zero, targetCurrency: .rub),
      AllocationLine(id: "t", kind: .tax(nil), suggestedE4: S.rub(4_000), targetCurrency: .rub),
    ]
    let written = Allocation.write(
      sheet: sheet(income, lines: lines), chosen: ["c": S.rub(1), "t": S.rub(4_000)],
      income: income, goals: [], ids: { UUID() })
    XCTAssertEqual(written, .empty)
  }

  func testAnIncomeWithoutAnAccountMovesNothing() {
    let income = S.entry(.income, S.rub(100_000), on: "2026-10-10", category: salary.id)
    let line = AllocationLine(
      id: "a", kind: .account(savings.id), suggestedE4: S.rub(1), targetCurrency: .rub)
    let written = Allocation.write(
      sheet: sheet(income, lines: [line]), chosen: ["a": S.rub(5_000)], income: income,
      goals: [], ids: { UUID() })
    XCTAssertTrue(written.transfers.isEmpty)
  }

  func testATransferOfADollarIncomeToARubleAccountGoesInRublesAtItsRate() throws {
    let income = S.entry(
      .income, S.rub(1_000), on: "2026-10-10", category: salary.id, currency: .usd,
      rubles: S.rub(90_000), account: main.id)
    let line = AllocationLine(
      id: "a", kind: .account(savings.id), suggestedE4: S.rub(1), targetCurrency: .rub)
    let written = Allocation.write(
      sheet: sheet(income, lines: [line]), chosen: ["a": S.rub(100)], income: income,
      goals: [], ids: { UUID() })
    let transfer = try XCTUnwrap(written.transfers.first)
    XCTAssertEqual(transfer.fromCurrency, .usd)
    XCTAssertEqual(transfer.fromAmountE4, S.rub(100))
    XCTAssertEqual(transfer.toCurrency, .rub)
    XCTAssertEqual(transfer.toAmountE4, S.rub(9_000))
  }

  // MARK: The day the sheet looks to

  func testWithoutExpectationsTheSheetLooksToTheEndOfTheMonth() {
    XCTAssertEqual(
      Allocation.until(today: S.day("2028-02-10"), expected: [], links: []),
      S.day("2028-02-29"))
  }

  func testTheNextExpectedSalaryIsTheDay() {
    let advance = ExpectedIncome(
      name: "Аванс", kind: .recurring, totalE4: S.rub(50_000), dueDate: S.day("2026-10-25"),
      freq: .monthly, day: 25)
    XCTAssertEqual(
      Allocation.until(today: S.day("2026-10-14"), expected: [advance], links: []),
      S.day("2026-10-25"))
  }

  func testALinkedOneOffIsDoneAndAClosedOneIsIgnored() {
    let bonus = ExpectedIncome(
      name: "Премия", kind: .oneOff, totalE4: S.rub(50_000), dueDate: S.day("2026-10-20"))
    var closed = ExpectedIncome(
      name: "Гонорар", kind: .oneOff, totalE4: S.rub(10_000), dueDate: S.day("2026-10-18"))
    closed.closed = true
    let link = ExpectedIncomeLink(expectedIncomeId: bonus.id, transactionId: UUID())
    XCTAssertEqual(
      Allocation.until(today: S.day("2026-10-14"), expected: [bonus, closed], links: [link]),
      S.day("2026-10-31"))
  }

  // MARK: A raise

  private func raiseOf(_ amounts: [Int64], latest: Int64) -> AllocationRaise? {
    let earlier = amounts.enumerated().map { index, amount in
      salaryOf(amount, "2026-0\(index + 6)-10")
    }
    let income = salaryOf(latest, "2026-10-10")
    return AllocationRaise.detect(
      income: income, ledger: ledger(earlier + [income]), links: [])
  }

  func testASalaryAboveTheUsualIsARaise() throws {
    let raise = try XCTUnwrap(raiseOf([100_000, 90_000, 110_000], latest: 120_000))
    XCTAssertEqual(raise.usualE4, S.rub(100_000))
    XCTAssertEqual(raise.differenceE4, S.rub(20_000))
  }

  func testTwoEarlierSalariesAreNotEnoughForAUsual() {
    XCTAssertNil(raiseOf([100_000, 100_000], latest: 200_000))
  }

  func testFivePercentOrLessIsNotARaise() {
    XCTAssertNil(raiseOf([100_000, 100_000, 100_000], latest: 105_000))
    XCTAssertNotNil(raiseOf([100_000, 100_000, 100_000], latest: 105_001))
  }

  func testASmallRaiseBelowThreeThousandRublesIsNotOne() {
    XCTAssertNil(raiseOf([20_000, 20_000, 20_000], latest: 22_000))
  }

  func testOnlyTheLastThreeMakeTheUsual() throws {
    // June 10,000 is older than the three before October and plays no part.
    let earlier = [10_000, 100_000, 100_000, 100_000].enumerated().map { index, amount in
      salaryOf(Int64(amount), "2026-0\(index + 6)-10")
    }
    let income = salaryOf(110_000, "2026-10-10")
    let raise = try XCTUnwrap(
      AllocationRaise.detect(income: income, ledger: ledger(earlier + [income]), links: []))
    XCTAssertEqual(raise.usualE4, S.rub(100_000))
  }

  // MARK: Settings rows

  func testAllocationSettingsReadBackFromTheirRows() {
    let written = AllocationSettings(
      earningsCategoryId: earnings.id, cushionAccountId: savings.id,
      monthRestTarget: .goal(UUID()), monthRestDone: MonthKey(iso: "2026-12"),
      declined: [UUID(), UUID()])
    XCTAssertEqual(
      AllocationSettings(storedValues: written.storedValues.compactMapValues { $0 }), written)
  }

  func testMonthRestTargetsReadOnlyWhatTheyWrite() {
    XCTAssertEqual(MonthRestTarget(storedValue: " cushion "), .cushion)
    XCTAssertNil(MonthRestTarget(storedValue: "goal:nope"))
    XCTAssertNil(MonthRestTarget(storedValue: "account"))
    let read = AllocationSettings(storedValues: [
      AllocationSettings.monthRestDoneKey: "2026-1",
      AllocationSettings.declinedKey: "bad, \(main.id.uuidString)",
    ])
    XCTAssertNil(read.monthRestDone)
    XCTAssertEqual(read.declined, [main.id])
  }
}
