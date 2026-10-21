import AppCore
import XCTest

@testable import OhMyMoney

/// «Почему так» of every tile of Overview on many different books — an empty one, a month of
/// income only, refunds outweighing a category, money waiting from others, and the synthetic
/// sample of different lengths, seeds and languages ending on the edges of months and years:
/// every sum of a breakdown adds up to its total, and the total is the figure the tile shows.
@MainActor
final class InsightsScenarioTilesTests: XCTestCase {
  private var environment: AppEnvironment!

  override func setUp() async throws {
    environment = AppEnvironment()
  }

  override func tearDown() async throws {
    environment = nil
  }

  private func rub(_ value: Int64) -> AmountE4 { AmountE4(whole: value) }

  private func snapshot(_ dataset: Dataset, today: DateOnly) -> DataSnapshot {
    DataSnapshot.build(
      dataset: dataset, calendar: .utc, today: today,
      context: SnapshotContext(rubPerUnit: [.usd: 95, .eur: 103]),
      version: DataVersion(load: 0), now: InsightsBook.noon(today))
  }

  private func sample(
    seed: UInt64, months: Int, endingOn today: DateOnly, language: String = "en"
  ) -> DataSnapshot {
    let set = SampleDataGenerator(seed: seed).generate(
      months: months, endingOn: today, calendar: .utc, language: language
    ).withEveryFeature(seed: seed, calendar: .utc, language: language)
    let dataset = Dataset(
      entries: set.entries, links: set.links, categories: set.categories, people: set.people,
      places: set.places, events: set.events, paymentMethods: set.paymentMethods,
      debts: set.debts, goals: set.goals, planning: set.planningBook,
      settings: AnalyticsSettings(cashbackCategoryId: set.cashbackCategoryId),
      transfers: set.transfers, accountGroups: set.accountGroups,
      accountSettings: AccountSettings(storedValues: set.settings), cards: set.cards,
      cashbackRules: set.cashbackRules, banks: set.banks, assets: set.assets,
      assetValuations: set.assetValuations,
      capitalSettings: CapitalSettings(storedValues: set.settings))
    return snapshot(dataset, today: today)
  }

  private func remainder(_ snapshot: DataSnapshot) -> MonthForecast.Remainder {
    MonthForecast.remainder(
      ledger: snapshot.ledger, today: snapshot.today,
      scheduledOperations: snapshot.planning.matches.operationIds)
  }

  /// What the forecast and the anomaly steps deliver for a snapshot, worked out once.
  private struct Steps {
    var remainder: MonthForecast.Remainder
    var anomalies: AnomalyReport
  }

  private func steps(_ snapshot: DataSnapshot) -> Steps {
    Steps(
      remainder: remainder(snapshot),
      anomalies: AnomalyRules.build(
        ledger: snapshot.ledger, events: snapshot.planning.events, today: snapshot.today))
  }

  private func explain(
    _ tile: OverviewTile, _ snapshot: DataSnapshot, _ steps: Steps? = nil, waiting: Bool = false
  ) -> TileExplanation {
    let delivered = waiting ? nil : (steps ?? self.steps(snapshot))
    return TileWhy.explanation(
      of: tile, snapshot: snapshot, remainder: delivered?.remainder,
      owed: delivered.map { _ in snapshot.owed.amount }, anomalies: delivered?.anomalies,
      rates: nil, environment: environment)
  }

  /// Every tile on this snapshot: its own tile, its own destination, every sum adding up, and
  /// the figures the cards read from the snapshot.
  private func assertWhole(
    _ snapshot: DataSnapshot, file: StaticString = #filePath, line: UInt = #line
  ) {
    let delivered = self.steps(snapshot)
    func explain(_ tile: OverviewTile, _ snapshot: DataSnapshot) -> TileExplanation {
      self.explain(tile, snapshot, delivered)
    }
    for tile in OverviewTile.allCases {
      let explanation = explain(tile, snapshot)
      XCTAssertEqual(explanation.tile, tile, file: file, line: line)
      XCTAssertEqual(explanation.destination, TileDestination.of(tile), file: file, line: line)
      for section in explanation.sections {
        XCTAssertNotEqual(section.addsUp, false, "\(tile)", file: file, line: line)
      }
    }
    let summary = snapshot.summary
    XCTAssertEqual(
      explain(.monthToDate, snapshot).figure, .money(summary.net, .rub), file: file, line: line)
    if snapshot.planning.debts.iOwe.isEmpty {
      XCTAssertEqual(
        explain(.iOwe, snapshot).state, .empty(TilePhrase("why.iOwe.none")), file: file,
        line: line)
    } else {
      XCTAssertEqual(
        explain(.iOwe, snapshot).figure, .money(snapshot.planning.debts.totalIOweRub, .rub),
        file: file, line: line)
    }
    let capital = snapshot.planning.capital
    if capital.breakdown.have.isEmpty && capital.breakdown.owe.isEmpty {
      XCTAssertEqual(
        explain(.capital, snapshot).state, .empty(TilePhrase("why.capital.none")), file: file,
        line: line)
    } else {
      XCTAssertEqual(
        explain(.capital, snapshot).figure, .money(capital.now.netRub, .rub), file: file,
        line: line)
    }
    if let main = snapshot.planning.freeMoney.main {
      XCTAssertEqual(
        explain(.freeMoney, snapshot).figure, .money(main, .rub), file: file, line: line)
    }
    let positive = summary.categories.filter { $0.amount.raw > 0 }.map(\.amount)
    if !summary.topCategories.isEmpty {
      XCTAssertEqual(
        explain(.topCategories, snapshot).figure, .money(AmountE4.sum(positive), .rub),
        file: file, line: line)
    }
    if snapshot.owed.count > 0 {
      XCTAssertEqual(
        explain(.owedToMe, snapshot).figure, .money(snapshot.owed.amount, .rub),
        file: file, line: line)
    }
    let forecast = MonthForecast(
      spent: summary.expenses.current, planned: snapshot.planning.planned.total,
      remainder: delivered.remainder)
    XCTAssertEqual(
      explain(.spendingForecast, snapshot).figure, .approximately(forecast.p50, .rub),
      file: file, line: line)
  }

  // MARK: - Books written by hand

  /// An empty book: no tile fails, the month is zero, the top and the qualities say there is
  /// no spending.
  func testAnEmptyBookExplainsEveryTile() {
    let snapshot = snapshot(Dataset(), today: .d(9, 14))
    assertWhole(snapshot)
    XCTAssertEqual(explain(.monthToDate, snapshot).figure, .money(.zero, .rub))
    XCTAssertEqual(
      explain(.topCategories, snapshot).state, .empty(TilePhrase("why.noSpending")))
    XCTAssertEqual(explain(.qualities, snapshot).state, .empty(TilePhrase("why.noSpending")))
  }

  /// An empty book on New Year's Day and on a leap day.
  func testAnEmptyBookOnTheEdgesOfTheYear() {
    assertWhole(snapshot(Dataset(), today: .d(1, 1)))
    assertWhole(snapshot(Dataset(), today: .d(2, 29, 2028)))
    assertWhole(snapshot(Dataset(), today: .d(12, 31)))
  }

  /// Before the steps deliver, the tiles that read them wait.
  func testTheTilesOfTheStepsWaitForThem() {
    let snapshot = snapshot(Dataset(), today: .d(9, 14))
    XCTAssertEqual(explain(.canSave, snapshot, waiting: true).state, .waiting)
    XCTAssertEqual(explain(.spendingForecast, snapshot, waiting: true).state, .waiting)
    XCTAssertEqual(explain(.monthToDate, snapshot, waiting: true).state, .ready)
  }

  /// The month: income, less spending, is the figure; the same days of August under it.
  func testTheMonthIsIncomeLessSpendingBesideAugust() throws {
    var book = InsightsBook()
    book.add(.income, rub(50_000), on: .d(9, 1))
    book.add(.expense, rub(1_200), on: .d(9, 3))
    book.add(.expense, rub(800), on: .d(9, 4), category: book.transport.id)
    book.add(.expense, rub(300), on: .d(8, 10))
    book.add(.expense, rub(999), on: .d(8, 20))
    let snapshot = snapshot(book.dataset, today: .d(9, 14))
    assertWhole(snapshot)
    let explanation = explain(.monthToDate, snapshot)
    let main = try XCTUnwrap(explanation.sections.first)
    XCTAssertEqual(main.rows.map(\.value), [.money(rub(50_000), .rub), .money(rub(2_000), .rub)])
    XCTAssertEqual(main.rows.map(\.role), [.plus, .minus])
    XCTAssertEqual(explanation.figure, .money(rub(48_000), .rub))
    XCTAssertEqual(explanation.sections[1].rows.map(\.value)[1], .money(rub(300), .rub))
  }

  /// Seven categories: five shown, the other two in one line, the shares of the lines a whole.
  func testTheTopFoldsTheRestIntoOneLine() throws {
    var book = InsightsBook()
    let more = (1...3).map { CoreKit.Category(kind: .expense, name: "Extra \($0)") }
    book.extra = more
    let ids = [book.food.id, book.transport.id, book.fun.id, book.health.id] + more.map(\.id)
    for (index, id) in ids.enumerated() {
      book.add(.expense, rub(Int64(100 * (index + 1))), on: .d(9, 5), category: id)
    }
    let snapshot = snapshot(book.dataset, today: .d(9, 14))
    assertWhole(snapshot)
    let section = try XCTUnwrap(explain(.topCategories, snapshot).sections.first)
    XCTAssertEqual(section.rows.count, 6)
    XCTAssertEqual(section.rows.last?.label.key, "why.top.rest")
    XCTAssertEqual(section.rows.last?.value, .money(rub(300), .rub))
    XCTAssertEqual(section.rows.compactMap(\.share).reduce(0, +), Shares.whole)
    XCTAssertEqual(section.total?.value, .money(rub(2_800), .rub))
  }

  /// A category its refunds outweighed is a line of its own outside the sum.
  func testARefundedCategoryStandsOutsideTheSum() throws {
    var book = InsightsBook()
    let more = (1...5).map { CoreKit.Category(kind: .expense, name: "More \($0)") }
    book.extra = more
    for (index, category) in more.enumerated() {
      book.add(.expense, rub(Int64(1_000 + index)), on: .d(9, 2), category: category.id)
    }
    book.add(.expense, rub(100), on: .d(9, 3), category: book.fun.id)
    book.add(.refund, rub(400), on: .d(9, 4), category: book.fun.id)
    let snapshot = snapshot(book.dataset, today: .d(9, 14))
    assertWhole(snapshot)
    let section = try XCTUnwrap(explain(.topCategories, snapshot).sections.first)
    let refunded = try XCTUnwrap(section.rows.first { $0.label.key == "why.top.refunded" })
    XCTAssertEqual(refunded.value, .money(rub(-300), .rub))
    XCTAssertEqual(refunded.role, .detail)
    XCTAssertEqual(section.total?.value, .money(rub(5_010), .rub))
  }

  /// Good, neutral and bad spending share the money spent; bad spending beside August's.
  func testQualitiesShareTheMoneyAndBadMoves() throws {
    var book = InsightsBook()
    book.add(.expense, rub(600), on: .d(9, 2), category: book.health.id)
    book.add(.expense, rub(300), on: .d(9, 3))
    book.add(.expense, rub(100), on: .d(9, 4), category: book.fun.id)
    book.add(.expense, rub(250), on: .d(8, 4), category: book.fun.id)
    let snapshot = snapshot(book.dataset, today: .d(9, 14))
    assertWhole(snapshot)
    let explanation = explain(.qualities, snapshot)
    let shares = explanation.sections[0].rows.map(\.share)
    XCTAssertEqual(shares, [6_000, 3_000, 1_000])
    XCTAssertEqual(explanation.figure, .money(rub(1_000), .rub))
    XCTAssertEqual(explanation.sections[1].rows.last?.value, .change(rub(-150), .rub))
  }

  /// A month of only income: the top says nothing was spent, the month is all income.
  func testAMonthOfOnlyIncome() {
    var book = InsightsBook()
    book.add(.income, rub(10_000), on: .d(9, 2))
    book.add(.income, rub(500), on: .d(9, 3), category: book.gifts.id)
    let snapshot = snapshot(book.dataset, today: .d(9, 14))
    assertWhole(snapshot)
    XCTAssertEqual(explain(.monthToDate, snapshot).figure, .money(rub(10_500), .rub))
    XCTAssertEqual(
      explain(.topCategories, snapshot).state, .empty(TilePhrase("why.noSpending")))
  }

  /// Income for September that came on 31 August counts in September's month to date.
  func testAnAdvanceForTheMonthCountsInIt() {
    var book = InsightsBook()
    book.add(.income, rub(30_000), on: .d(8, 31), periodMonth: MonthKey(year: 2026, month: 9))
    let snapshot = snapshot(book.dataset, today: .d(9, 1))
    assertWhole(snapshot)
    XCTAssertEqual(explain(.monthToDate, snapshot).figure, .money(rub(30_000), .rub))
  }

  /// Money waiting from others: the tile's figure is what is still owed.
  func testOwedToMeIsWhatIsStillWaited() {
    var book = InsightsBook()
    let anna = Person(name: "Anna")
    book.people = [anna]
    book.add(
      .expense, rub(700), on: .d(9, 2), reimbursable: true, debtor: anna.id, status: .expected)
    book.add(
      .expense, rub(200), on: .d(9, 3), reimbursable: true, debtor: anna.id, status: .returned)
    let snapshot = snapshot(book.dataset, today: .d(9, 14))
    XCTAssertEqual(snapshot.owed.amount, rub(700))
    XCTAssertEqual(snapshot.owed.count, 1)
    assertWhole(snapshot)
    XCTAssertEqual(snapshot.summary.expenses.current, .zero)
  }

  /// A purchase in dollars counts in the month by its rubles.
  func testAForeignPurchaseCountsByItsRubles() {
    var book = InsightsBook()
    book.add(.expense, rub(20), on: .d(9, 2), currency: .usd, rub: rub(1_900))
    let snapshot = snapshot(book.dataset, today: .d(9, 14))
    assertWhole(snapshot)
    XCTAssertEqual(explain(.monthToDate, snapshot).figure, .money(rub(-1_900), .rub))
  }

  /// On the 31st, the month before is clipped to its last day.
  func testOnTheThirtyFirstAugustIsWhole() {
    var book = InsightsBook()
    book.add(.expense, rub(100), on: .d(9, 30))
    book.add(.expense, rub(40), on: .d(8, 31))
    let snapshot = snapshot(book.dataset, today: .d(10, 31))
    assertWhole(snapshot)
    XCTAssertEqual(snapshot.summary.previousSpan, DayRange(.d(9, 1), .d(9, 30)))
    XCTAssertEqual(snapshot.summary.expenses.previous, rub(100))
  }

  /// Deleted operations are in no tile.
  func testDeletedOperationsAreInNoTile() {
    var book = InsightsBook()
    book.add(.expense, rub(5_000), on: .d(9, 2), deleted: true)
    let snapshot = snapshot(book.dataset, today: .d(9, 14))
    assertWhole(snapshot)
    XCTAssertEqual(explain(.monthToDate, snapshot).figure, .money(.zero, .rub))
  }

  // MARK: - The sample

  func testTheSampleOfOneMonth() {
    assertWhole(sample(seed: 11, months: 1, endingOn: .d(9, 14)))
  }

  func testTheSampleOfThreeMonthsEndingOnTheLastDayOfAMonth() {
    assertWhole(sample(seed: 12, months: 3, endingOn: .d(9, 30)))
  }

  func testTheSampleEndingOnTheFirstDayOfAMonth() {
    assertWhole(sample(seed: 13, months: 4, endingOn: .d(10, 1)))
  }

  func testTheSampleEndingOnNewYearsEve() {
    assertWhole(sample(seed: 14, months: 6, endingOn: .d(12, 31)))
  }

  func testTheSampleEndingOnNewYearsDay() {
    assertWhole(sample(seed: 15, months: 6, endingOn: .d(1, 1, 2027)))
  }

  func testTheSampleEndingOnALeapDay() {
    assertWhole(sample(seed: 16, months: 5, endingOn: .d(2, 29, 2028)))
  }

  func testTheSampleOfNineMonths() {
    assertWhole(sample(seed: 17, months: 9, endingOn: .d(8, 15)))
  }

  func testTheSampleInRussian() {
    assertWhole(sample(seed: 18, months: 6, endingOn: .d(3, 31), language: "ru"))
  }

  func testAnotherSeedOfTheSample() {
    assertWhole(sample(seed: 404, months: 6, endingOn: .d(6, 15)))
  }

  /// The sample, its tiles seen as on the last day of a short month and on the next day.
  func testTheSampleAcrossTheEndOfFebruary() {
    assertWhole(sample(seed: 19, months: 3, endingOn: .d(2, 28)))
    assertWhole(sample(seed: 19, months: 3, endingOn: .d(3, 1)))
  }
}
