import AppCore
import XCTest

@testable import OhMyMoney

/// The tables of Analytics and Reports on books written by hand: categories with their
/// subcategories adding up to their parents, shares of each level reading exactly 100.00 %,
/// refunds counted in the purchase's month, money for others outside my spending until
/// written off, income by the month it is for, the monthly table of a year begun late, the
/// groupings by «for whom», place, event and account, and the CSV pandas reads.
final class InsightsScenarioReportsTests: XCTestCase {
  private func rub(_ value: Int64) -> AmountE4 { AmountE4(whole: value) }
  private let september = Period.month(MonthKey(year: 2026, month: 9))
  private let october = Period.month(MonthKey(year: 2026, month: 10))

  private func lowest(_ nodes: [BreakdownNode]) -> [BreakdownNode] {
    nodes.flatMap { $0.children.isEmpty ? [$0] : $0.children }
  }

  // MARK: - Category breakdown

  /// Money on «Food» itself and on «Cafe» under it: the parent is the sum of its children,
  /// «(no subcategory)» goes last under it, and the lowest level reads 100 %.
  func testAParentIsTheSumOfItsChildren() throws {
    var book = InsightsBook()
    book.add(.expense, rub(300), on: .d(9, 3), category: book.cafe.id)
    book.add(.expense, rub(500), on: .d(9, 4), category: book.food.id)
    book.add(.expense, rub(200), on: .d(9, 5), category: book.transport.id)
    let breakdown = CategoryBreakdown(ledger: book.ledger, period: september, kind: .expense)
    XCTAssertEqual(breakdown.total, rub(1_000))
    let food = try XCTUnwrap(breakdown.nodes.first)
    XCTAssertEqual(food.key, .category(book.food.id))
    XCTAssertEqual(food.amount, rub(800))
    XCTAssertEqual(food.children.map(\.key), [.category(book.cafe.id), .noSubcategory])
    XCTAssertEqual(food.share, 8_000)
    XCTAssertEqual(lowest(breakdown.nodes).compactMap(\.share).reduce(0, +), Shares.whole)
    XCTAssertEqual(food.children.map(\.share), [3_000, 5_000])
  }

  /// A refund of a September purchase made in October takes the money off September, in
  /// the purchase's category; October has nothing.
  func testARefundCountsInTheMonthOfThePurchase() {
    var book = InsightsBook()
    let purchase = book.add(.expense, rub(1_000), on: .d(9, 28), category: book.transport.id)
    book.add(
      .refund, rub(400), on: .d(10, 2), category: book.transport.id,
      refundOf: purchase.parts[0].id)
    let ledger = book.ledger
    XCTAssertEqual(
      CategoryBreakdown(ledger: ledger, period: september, kind: .expense).total, rub(600))
    XCTAssertTrue(CategoryBreakdown(ledger: ledger, period: october, kind: .expense).nodes.isEmpty)
    XCTAssertEqual(ledger.expenses(in: october.range), .zero)
  }

  /// A refund with no purchase is a refund of its own month and may outweigh its category:
  /// that line has no share, the total is still the sum.
  func testARefundWithoutAPurchaseCanMakeALineNegative() throws {
    var book = InsightsBook()
    book.add(.expense, rub(100), on: .d(9, 2), category: book.fun.id)
    book.add(.refund, rub(250), on: .d(9, 3), category: book.fun.id)
    book.add(.expense, rub(400), on: .d(9, 4), category: book.transport.id)
    let breakdown = CategoryBreakdown(ledger: book.ledger, period: september, kind: .expense)
    XCTAssertEqual(breakdown.total, rub(250))
    let fun = try XCTUnwrap(breakdown.nodes.first { $0.key == .category(book.fun.id) })
    XCTAssertEqual(fun.amount, rub(-150))
    XCTAssertNil(fun.share)
    XCTAssertEqual(breakdown.nodes.first?.share, Shares.whole)
  }

  /// A part paid for somebody else is not my spending while it waits or after it came back;
  /// written off, it is.
  func testMoneyForOthersCountsOnlyWhenWrittenOff() {
    var book = InsightsBook()
    let anna = Person(name: "Anna")
    book.people = [anna]
    book.add(
      .expense, rub(700), on: .d(9, 2), reimbursable: true, debtor: anna.id, status: .expected)
    book.add(
      .expense, rub(300), on: .d(9, 3), reimbursable: true, debtor: anna.id, status: .returned)
    book.add(
      .expense, rub(90), on: .d(9, 4), reimbursable: true, debtor: anna.id, status: .writtenOff)
    XCTAssertEqual(book.ledger.expenses(in: september.range), rub(90))
  }

  /// Income for September that arrived on 31 August is September's in whole months, August's
  /// in a span of days.
  func testIncomeBelongsToItsMonthInWholeMonths() {
    var book = InsightsBook()
    book.add(
      .income, rub(50_000), on: .d(8, 31), periodMonth: MonthKey(year: 2026, month: 9))
    let ledger = book.ledger
    XCTAssertEqual(ledger.income(in: september), rub(50_000))
    XCTAssertEqual(ledger.income(in: .month(MonthKey(year: 2026, month: 8))), .zero)
    XCTAssertEqual(ledger.income(in: .days(DayRange(.d(8, 20), .d(8, 31)))), rub(50_000))
    XCTAssertEqual(
      CategoryBreakdown(ledger: ledger, period: september, kind: .income).total, rub(50_000))
  }

  /// A deleted operation is in no figure; a reimbursement is not income.
  func testDeletedOperationsAndReimbursementsAreNotCounted() {
    var book = InsightsBook()
    book.add(.expense, rub(999), on: .d(9, 5), deleted: true)
    book.add(.income, rub(999), on: .d(9, 5), deleted: true)
    book.add(.reimbursement, rub(500), on: .d(9, 6))
    let ledger = book.ledger
    XCTAssertEqual(ledger.expenses(in: september.range), .zero)
    XCTAssertEqual(ledger.income(in: september), .zero)
    XCTAssertFalse(
      ReportBuilder(ledger: ledger, today: .d(10, 1))
        .table(.periodTotal, period: september).hasData)
  }

  /// A purchase in dollars counts by its rubles.
  func testAForeignPurchaseCountsByItsRubles() {
    var book = InsightsBook()
    book.add(.expense, rub(10), on: .d(9, 7), currency: .usd, rub: AmountE4(raw: 9_512_500))
    XCTAssertEqual(book.ledger.expenses(in: september.range), AmountE4(raw: 9_512_500))
  }

  /// A split purchase puts each part in its own category.
  func testASplitPurchaseFallsIntoEachCategory() {
    var book = InsightsBook()
    book.split([(book.food.id, rub(120)), (book.health.id, rub(80))], on: .d(9, 9))
    let nodes = CategoryBreakdown(ledger: book.ledger, period: september, kind: .expense).nodes
    XCTAssertEqual(nodes.map(\.key), [.category(book.food.id), .category(book.health.id)])
    XCTAssertEqual(nodes.map(\.share), [6_000, 4_000])
  }

  // MARK: - Report tables

  /// Three equal categories: the share column reads 0.3334, 0.3333, 0.3333 and the total 1.
  func testTheShareColumnAddsUpToOne() throws {
    var book = InsightsBook()
    for category in [book.food.id, book.transport.id, book.fun.id] {
      book.add(.expense, rub(100), on: .d(9, 10), category: category)
    }
    let table = ReportBuilder(ledger: book.ledger, today: .d(10, 1))
      .table(.expensesByCategory, period: september)
    XCTAssertEqual(table.rows.map(\.share), [3_334, 3_333, 3_333])
    XCTAssertEqual(table.total.share, Shares.whole)
    let csv = try XCTUnwrap(
      String(data: ReportCSV.data(table) { _ in "x" }, encoding: .utf8))
    let shares = csv.split(separator: "\n").dropFirst().map { $0.split(separator: ",").last! }
    XCTAssertEqual(shares, ["0.3334", "0.3333", "0.3333", "1.0000"])
  }

  /// The two-level table writes each parent right before its children and the total last.
  func testTheCSVWritesParentsBeforeTheirChildren() throws {
    var book = InsightsBook()
    book.add(.expense, rub(300), on: .d(9, 3), category: book.cafe.id)
    book.add(.expense, AmountE4(raw: 1_002_500), on: .d(9, 4), category: book.food.id)
    let table = ReportBuilder(ledger: book.ledger, today: .d(10, 1))
      .table(.expensesByCategoryAndSubcategory, period: september)
    let csv = try XCTUnwrap(
      String(
        data: ReportCSV.data(table) { "\($0)".components(separatedBy: ":")[0] },
        encoding: .utf8))
    let lines = csv.split(separator: "\n").map(String.init)
    XCTAssertEqual(lines[0], "row_type,name,amount_rub,amount_rub_exact,share")
    XCTAssertEqual(lines.count, 5)
    XCTAssertTrue(lines[1].hasPrefix("subtotal,category,400,400.2500,"))
    XCTAssertTrue(lines[2].hasPrefix("item,category,300,300.0000,"))
    XCTAssertTrue(lines[3].hasPrefix("item,no-subcategory,100,100.2500,"))
    XCTAssertEqual(lines[4], "total,Total,400,400.2500,1.0000")
    XCTAssertFalse(csv.hasPrefix("\u{FEFF}"))
  }

  /// Exact amounts: four decimals, a minus for refunds, no grouping.
  func testExactAmountsHaveFourDecimals() {
    XCTAssertEqual(ReportCSV.exact(AmountE4(raw: -2_500)), "-0.2500")
    XCTAssertEqual(ReportCSV.exact(AmountE4(raw: 12_345_000)), "1234.5000")
    XCTAssertEqual(ReportCSV.exact(.zero), "0.0000")
    XCTAssertEqual(ReportCSV.exact(AmountE4(raw: 1)), "0.0001")
    XCTAssertEqual(ReportCSV.share(nil), "")
    XCTAssertEqual(ReportCSV.share(7), "0.0007")
  }

  /// The period total: income less expenses, and «not enough data» on an empty period.
  func testThePeriodTotalIsIncomeLessExpenses() {
    var book = InsightsBook()
    book.add(.income, rub(1_000), on: .d(9, 1))
    book.add(.expense, rub(1_250), on: .d(9, 2))
    let table = ReportBuilder(ledger: book.ledger, today: .d(10, 1))
      .table(.periodTotal, period: september)
    XCTAssertEqual(table.rows.map(\.amount), [rub(1_000), rub(1_250)])
    XCTAssertEqual(table.total.amount, rub(-250))
    XCTAssertTrue(table.hasData)
    XCTAssertFalse(table.hasShares)
    let empty = ReportBuilder(ledger: book.ledger, today: .d(10, 1))
      .table(.periodTotal, period: october)
    XCTAssertFalse(empty.hasData)
  }

  /// A year begun in September, seen on 14 October: months to come are dashes, October is
  /// not over, the average runs over September alone.
  func testTheMonthlyTableOfAYearBegunLate() throws {
    var book = InsightsBook()
    book.add(.expense, rub(900), on: .d(9, 10))
    book.add(.income, rub(3_000), on: .d(9, 25))
    book.add(.expense, rub(100), on: .d(10, 3))
    let table = ReportBuilder(ledger: book.ledger, today: .d(10, 14))
      .table(.monthly, period: .year(2026))
    XCTAssertEqual(table.rows.count, 12)
    XCTAssertEqual(table.rows[10].values, [nil, nil, nil])
    XCTAssertEqual(table.rows[0].values, [.zero, .zero, .zero])
    XCTAssertTrue(table.rows[9].isIncomplete)
    XCTAssertFalse(table.rows[8].isIncomplete)
    XCTAssertEqual(table.averageMonths, [MonthKey(year: 2026, month: 9)])
    let average = try XCTUnwrap(table.average)
    XCTAssertEqual(average.values, [rub(900), rub(3_000), rub(2_100)])
    XCTAssertEqual(table.total.values, [rub(1_000), rub(3_000), rub(2_000)])
    XCTAssertEqual(
      ReportCSV.columns(for: table),
      [
        "row_type", "name", "expenses_rub", "expenses_rub_exact", "income_rub", "income_rub_exact",
        "net_rub", "net_rub_exact",
      ])
  }

  /// An advance booked for December shows its figures as not over, and «Итого» counts it.
  func testAMonthBookedAheadCountsInTheTotal() {
    var book = InsightsBook()
    book.add(.income, rub(5_000), on: .d(10, 1), periodMonth: MonthKey(year: 2026, month: 12))
    let table = ReportBuilder(ledger: book.ledger, today: .d(10, 14))
      .table(.monthly, period: .year(2026))
    XCTAssertEqual(table.rows[11].values, [.zero, rub(5_000), rub(5_000)])
    XCTAssertTrue(table.rows[11].isIncomplete)
    XCTAssertEqual(table.rows[10].values, [nil, nil, nil])
    XCTAssertEqual(table.total.values[1], rub(5_000))
  }

  /// A past year is all complete: the average runs from its first month with money to
  /// December, a month without money counting as zero.
  func testAPastYearAveragesThroughDecember() throws {
    var book = InsightsBook()
    book.add(.expense, rub(1_100), on: .d(11, 5, 2025))
    let table = ReportBuilder(ledger: book.ledger, today: .d(10, 14))
      .table(.monthly, period: .year(2025))
    XCTAssertEqual(table.averageMonths.count, 2)
    XCTAssertEqual(try XCTUnwrap(table.average).values[0], rub(550))
    XCTAssertTrue(table.rows.allSatisfy { !$0.isIncomplete })
  }

  /// The average of an odd amount is rounded once to a stored unit.
  func testTheAverageIsRoundedOnce() throws {
    var book = InsightsBook()
    book.add(.expense, rub(100), on: .d(1, 5, 2025))
    let table = ReportBuilder(ledger: book.ledger, today: .d(10, 14))
      .table(.monthly, period: .year(2025))
    XCTAssertEqual(table.averageMonths.count, 12)
    XCTAssertEqual(try XCTUnwrap(table.average).values[0], AmountE4(raw: 83_333))
  }

  /// A year with nothing in it has no data and no average.
  func testAnEmptyYearHasNoDataAndNoAverage() {
    let table = ReportBuilder(ledger: InsightsBook().ledger, today: .d(10, 14))
      .table(.monthly, period: .year(2026))
    XCTAssertFalse(table.hasData)
    XCTAssertNil(table.average)
  }

  // MARK: - Groupings

  /// By «for whom»: people under their value; money that names no person is the value's own
  /// line, last under it.
  func testForWhomPutsPeopleUnderTheirValue() throws {
    var book = InsightsBook()
    let mother = Person(name: "Mother", relation: .family)
    book.people = [mother]
    book.add(.expense, rub(600), on: .d(9, 3), forWhom: .family, person: mother.id)
    book.add(.expense, rub(100), on: .d(9, 4), forWhom: .family)
    book.add(.expense, rub(300), on: .d(9, 5))
    let table = ReportBuilder(ledger: book.ledger, today: .d(10, 1))
      .table(.expensesByCategoryAndSubcategory, period: september, grouping: .forWhom)
    let family = try XCTUnwrap(table.rows.first)
    XCTAssertEqual(family.key, .forWhom(.family))
    XCTAssertEqual(family.amount, rub(700))
    XCTAssertEqual(family.children.map(\.key), [.person(mother.id), .forWhom(.family)])
    XCTAssertEqual(table.rows.last?.key, .forWhom(.me))
    XCTAssertTrue(table.rows.last?.children.isEmpty ?? false)
  }

  /// By place: «no place» goes last even when it is the largest line.
  func testNoPlaceGoesLastEvenWhenLargest() {
    var book = InsightsBook()
    let shop = Place(name: "Shop")
    book.places = [shop]
    book.add(.expense, rub(50), on: .d(9, 3), place: shop.id)
    book.add(.expense, rub(5_000), on: .d(9, 4))
    let table = ReportBuilder(ledger: book.ledger, today: .d(10, 1))
      .table(.expensesByCategory, period: september, grouping: .place)
    XCTAssertEqual(table.rows.map(\.key), [.place(shop.id), .noPlace])
    XCTAssertEqual(table.rows.compactMap(\.share).reduce(0, +), Shares.whole)
  }

  /// By event: the categories under each event are top-level ones, a subcategory folded in.
  func testAnEventHoldsTopLevelCategories() throws {
    var book = InsightsBook()
    let trip = Event(name: "Trip", startDate: .d(9, 1), endDate: .d(9, 10))
    book.events = [trip]
    book.add(.expense, rub(200), on: .d(9, 2), category: book.cafe.id, event: trip.id)
    book.add(.expense, rub(300), on: .d(9, 3), category: book.transport.id, event: trip.id)
    let table = ReportBuilder(ledger: book.ledger, today: .d(10, 1))
      .table(.expensesByCategoryAndSubcategory, period: september, grouping: .event)
    let event = try XCTUnwrap(table.rows.first)
    XCTAssertEqual(event.key, .event(trip.id))
    XCTAssertEqual(
      event.children.map(\.key), [.category(book.transport.id), .category(book.food.id)])
  }

  /// By account: an operation without one is «no account», last.
  func testByAccountWithAndWithout() {
    var book = InsightsBook()
    let card = UUID()
    book.add(.expense, rub(10), on: .d(9, 3), account: card)
    book.add(.expense, rub(20), on: .d(9, 3))
    let table = ReportBuilder(ledger: book.ledger, today: .d(10, 1))
      .table(.expensesByCategory, period: september, grouping: .paymentMethod)
    XCTAssertEqual(table.rows.map(\.key), [.paymentMethod(card), .noPaymentMethod])
  }

  /// Income by category ignores the grouping: it is always by category.
  func testIncomeIsAlwaysByCategory() {
    var book = InsightsBook()
    book.add(.income, rub(100), on: .d(9, 3), category: book.gifts.id)
    book.add(.income, rub(300), on: .d(9, 3))
    let table = ReportBuilder(ledger: book.ledger, today: .d(10, 1))
      .table(.incomeByCategory, period: september, grouping: .place)
    XCTAssertEqual(table.grouping, .category)
    XCTAssertEqual(table.rows.map(\.key), [.category(book.salary.id), .category(book.gifts.id)])
    XCTAssertEqual(table.rows.map(\.share), [7_500, 2_500])
  }

  /// Equal lines are ordered by their keys, so two builds of a table are the same table.
  func testEqualLinesHaveAStableOrder() {
    var book = InsightsBook()
    for category in [book.health.id, book.fun.id, book.transport.id] {
      book.add(.expense, rub(10), on: .d(9, 3), category: category)
    }
    let builder = ReportBuilder(ledger: book.ledger, today: .d(10, 1))
    let first = builder.table(.expensesByCategory, period: september)
    let second = ReportBuilder(ledger: book.ledger, today: .d(10, 1))
      .table(.expensesByCategory, period: september)
    XCTAssertEqual(first, second)
    let keys = first.rows.map { "\($0.key)" }
    XCTAssertEqual(keys, keys.sorted())
  }
}
