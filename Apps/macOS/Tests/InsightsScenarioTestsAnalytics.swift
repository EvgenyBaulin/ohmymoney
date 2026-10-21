import AppCore
import XCTest

@testable import OhMyMoney

/// The sections of Analytics on books written by hand: Good vs Bad by month and its streaks of
/// days without bad spending, goals beside the rest, «За других» with returned, waiting, written
/// off and surplus money, «Для кого» by value and person, places with their receipts net of
/// refunds and their first visits, events with their budgets and last year's, accounts with
/// their turnover and cashback, income against spending, weeks, weekdays and the comparison
/// with the period before.
final class InsightsScenarioAnalyticsTests: XCTestCase {
  private func rub(_ value: Int64) -> AmountE4 { AmountE4(whole: value) }
  private let september = Period.month(MonthKey(year: 2026, month: 9))

  // MARK: - Good vs Bad

  /// Each month of the period has its own qualities; bad spending is by category.
  func testQualitiesByMonthAndBadByCategory() throws {
    var book = InsightsBook()
    book.add(.expense, rub(100), on: .d(8, 5), category: book.fun.id)
    book.add(.expense, rub(300), on: .d(9, 5), category: book.fun.id)
    book.add(.expense, rub(700), on: .d(9, 6), category: book.health.id)
    let period = Period.days(DayRange(.d(8, 1), .d(9, 30)))
    let report = QualityReport(ledger: book.ledger, period: period, today: .d(9, 30))
    XCTAssertEqual(report.months.map(\.month.month), [8, 9])
    let september = try XCTUnwrap(report.months.last).qualities
    XCTAssertEqual(september.map(\.amount), [rub(700), .zero, rub(300)])
    XCTAssertEqual(september.map(\.share), [7_000, nil, 3_000])
    XCTAssertEqual(report.badByCategory.map(\.amount), [rub(400)])
  }

  /// Goals beside the rest of my spending, each a share of the whole.
  func testGoalsBesideTheRest() {
    var book = InsightsBook()
    let goals = CoreKit.Category(kind: .expense, name: "Goals", quality: .good, systemRole: .goals)
    book.extra = [goals]
    book.add(.expense, rub(300), on: .d(9, 2), category: goals.id)
    book.add(.expense, rub(700), on: .d(9, 3))
    let report = QualityReport(ledger: book.ledger, period: september, today: .d(9, 30))
    XCTAssertEqual(report.goals, rub(300))
    XCTAssertEqual(report.rest, rub(700))
    XCTAssertEqual(report.goalsShare, 3_000)
    XCTAssertEqual(report.restShare, 7_000)
  }

  /// Days without bad spending: four before a bad day, five after it up to today.
  func testStreaksOfDaysWithoutBadSpending() {
    var book = InsightsBook()
    book.add(.expense, rub(10), on: .d(9, 1))
    book.add(.expense, rub(50), on: .d(9, 5), category: book.fun.id)
    let report = QualityReport(ledger: book.ledger, period: september, today: .d(9, 10))
    XCTAssertEqual(report.currentStreak, 5)
    XCTAssertEqual(report.bestStreak, 5)
    let today = QualityReport(ledger: book.ledger, period: september, today: .d(9, 5))
    XCTAssertEqual(today.currentStreak, 0)
    XCTAssertEqual(today.bestStreak, 4)
  }

  /// A bad purchase refunded in full spoils no day: all four days since the book began are
  /// clean. An empty book has no streak.
  func testARefundedBadDayIsNoBadDay() {
    var book = InsightsBook()
    let bad = book.add(.expense, rub(50), on: .d(9, 3), category: book.fun.id)
    book.add(.refund, rub(50), on: .d(9, 4), category: book.fun.id, refundOf: bad.parts[0].id)
    let report = QualityReport(ledger: book.ledger, period: september, today: .d(9, 6))
    XCTAssertEqual(report.currentStreak, 4)
    XCTAssertEqual(report.bestStreak, 4)
    let empty = QualityReport(ledger: InsightsBook().ledger, period: september, today: .d(9, 6))
    XCTAssertEqual(empty.currentStreak, 0)
    XCTAssertEqual(empty.bestStreak, 0)
  }

  // MARK: - For others

  /// Paid for Anna: what came back, what waits, what was written off; the person first, parts
  /// without one last.
  func testMoneyForOthersByPerson() throws {
    var book = InsightsBook()
    let anna = Person(name: "Anna")
    book.people = [anna]
    let part = book.add(
      .expense, rub(700), on: .d(9, 2), reimbursable: true, debtor: anna.id, status: .expected)
    let back = book.add(.reimbursement, rub(250), on: .d(9, 10))
    book.links = [
      ReimbursementLink(reimbursementTxId: back.id, partId: part.parts[0].id, amountE4: rub(250))
    ]
    book.add(
      .expense, rub(100), on: .d(9, 3), reimbursable: true, debtor: anna.id, status: .writtenOff)
    book.add(.expense, rub(40), on: .d(9, 4), reimbursable: true, status: .expected)
    let report = OthersReport(ledger: book.ledger, period: september)
    XCTAssertEqual(report.totals.paid, rub(840))
    XCTAssertEqual(report.totals.returned, rub(250))
    XCTAssertEqual(report.totals.waiting, rub(490))
    XCTAssertEqual(report.totals.writtenOff, rub(100))
    XCTAssertEqual(report.byPerson.map(\.personId), [anna.id, nil])
    XCTAssertEqual(try XCTUnwrap(report.byPerson.first).totals.waiting, rub(450))
  }

  /// A surplus — money back above the parts — is income in «Доплаты» and counted on its own.
  func testTheSurplusIsCountedFromItsCategory() {
    var book = InsightsBook()
    let surcharges = CoreKit.Category(kind: .income, name: "Surcharges", systemRole: .surcharges)
    book.extra = [surcharges]
    book.add(.income, rub(120), on: .d(9, 12), category: surcharges.id)
    book.add(.income, rub(5_000), on: .d(9, 12))
    XCTAssertEqual(OthersReport(ledger: book.ledger, period: september).surplus, rub(120))
  }

  // MARK: - For whom

  /// «Для кого»: values and the people named; money for no person is no person line; months.
  func testForWhomValuesPeopleAndMonths() {
    var book = InsightsBook()
    let mother = Person(name: "Mother", relation: .family)
    book.people = [mother]
    book.add(.expense, rub(500), on: .d(9, 2), forWhom: .family, person: mother.id)
    book.add(.expense, rub(200), on: .d(9, 3), forWhom: .family)
    book.add(.expense, rub(900), on: .d(9, 4))
    let report = ForWhomReport(ledger: book.ledger, period: september)
    XCTAssertEqual(report.values.map(\.key), [.forWhom(.me), .forWhom(.family)])
    XCTAssertEqual(report.values.map(\.amount), [rub(900), rub(700)])
    XCTAssertEqual(report.people.map(\.key), [.person(mother.id)])
    XCTAssertEqual(report.months.first?.amounts[.family], rub(700))
  }

  // MARK: - Places

  /// A place: my spending, distinct purchases, the average receipt net of refunds; a refund is
  /// no visit.
  func testAPlaceCountsVisitsAndReceiptsNetOfRefunds() throws {
    var book = InsightsBook()
    let shop = Place(name: "Shop")
    book.places = [shop]
    let first = book.add(.expense, rub(1_000), on: .d(9, 2), place: shop.id)
    book.add(.expense, rub(500), on: .d(9, 3), place: shop.id)
    book.add(.refund, rub(400), on: .d(9, 9), place: shop.id, refundOf: first.parts[0].id)
    let place = try XCTUnwrap(PlacesReport(ledger: book.ledger, period: september).places.first)
    XCTAssertEqual(place.purchases, 2)
    XCTAssertEqual(place.mySpending, rub(1_100))
    XCTAssertEqual(place.averageReceipt, rub(550))
    XCTAssertTrue(place.isNew)
  }

  /// A place first visited in August is not new in September; the new one is.
  func testOnlyAFirstVisitInThePeriodIsNew() {
    var book = InsightsBook()
    let old = Place(name: "Old")
    let new = Place(name: "New")
    book.places = [old, new]
    book.add(.expense, rub(10), on: .d(8, 30), place: old.id)
    book.add(.expense, rub(10), on: .d(9, 2), place: old.id)
    book.add(.expense, rub(10), on: .d(9, 3), place: new.id)
    let report = PlacesReport(ledger: book.ledger, period: september)
    XCTAssertEqual(report.newPlaces.map(\.placeId), [new.id])
  }

  /// By purchases: the place visited more often first, whatever it spent.
  func testPlacesByPurchases() {
    var book = InsightsBook()
    let often = Place(name: "Often")
    let dear = Place(name: "Dear")
    book.places = [often, dear]
    for day in 1...3 { book.add(.expense, rub(10), on: .d(9, day), place: often.id) }
    book.add(.expense, rub(9_000), on: .d(9, 4), place: dear.id)
    let report = PlacesReport(ledger: book.ledger, period: september)
    XCTAssertEqual(report.places.map(\.placeId), [dear.id, often.id])
    XCTAssertEqual(report.byPurchases.map(\.placeId), [often.id, dear.id])
  }

  // MARK: - Events

  /// An event of the period without spending is shown; one with only a refund in the period is
  /// not.
  func testEventsOfThePeriod() {
    var book = InsightsBook()
    let quiet = Event(name: "Quiet", startDate: .d(9, 20), endDate: .d(9, 21))
    let summer = Event(name: "Summer", startDate: .d(8, 1), endDate: .d(8, 10))
    book.events = [quiet, summer]
    let purchase = book.add(.expense, rub(800), on: .d(8, 5), event: summer.id)
    book.add(
      .refund, rub(100), on: .d(9, 5), event: summer.id, refundOf: purchase.parts[0].id)
    let report = EventsReport(ledger: book.ledger, period: september)
    XCTAssertEqual(report.events.map(\.eventId), [quiet.id])
    XCTAssertEqual(report.events.first?.total, .zero)
  }

  /// An event's budget left, and the same event a year before by its series.
  func testAnEventBesideItsBudgetAndLastYear() throws {
    var book = InsightsBook()
    let series = UUID()
    let now = Event(
      name: "Birthday", startDate: .d(9, 10), endDate: .d(9, 10), budgetE4: rub(5_000),
      recurringYearly: true, seriesId: series)
    let before = Event(
      name: "Birthday", startDate: .d(9, 10, 2025), endDate: .d(9, 10, 2025),
      recurringYearly: true, seriesId: series)
    book.events = [now, before]
    book.add(.expense, rub(3_200), on: .d(9, 10), event: now.id)
    book.add(.expense, rub(4_100), on: .d(9, 10, 2025), event: before.id)
    let item = try XCTUnwrap(EventsReport(ledger: book.ledger, period: september).events.first)
    XCTAssertEqual(item.total, rub(3_200))
    XCTAssertEqual(item.budgetLeft, rub(1_800))
    XCTAssertEqual(item.lastYearEventId, before.id)
    XCTAssertEqual(item.lastYearTotal, rub(4_100))
  }

  // MARK: - Accounts

  /// An account: my spending, its turnover net of refunds, the cashback it received; no account
  /// last.
  func testAccountsWithTurnoverAndCashback() throws {
    var book = InsightsBook()
    let cashback = CoreKit.Category(kind: .income, name: "Cashback")
    book.extra = [cashback]
    let card = UUID()
    let purchase = book.add(.expense, rub(2_000), on: .d(9, 2), account: card)
    book.add(.refund, rub(500), on: .d(9, 3), account: card, refundOf: purchase.parts[0].id)
    book.add(.income, rub(30), on: .d(9, 25), category: cashback.id, account: card)
    book.add(.expense, rub(99_000), on: .d(9, 4))
    var dataset = book.dataset
    dataset.settings = AnalyticsSettings(cashbackCategoryId: cashback.id)
    let ledger = Ledger(dataset: dataset, calendar: .utc)
    let report = PaymentMethodsReport(ledger: ledger, period: september)
    XCTAssertEqual(report.methods.map(\.key), [.paymentMethod(card), .noPaymentMethod])
    let method = try XCTUnwrap(report.methods.first)
    XCTAssertEqual(method.mySpending, rub(1_500))
    XCTAssertEqual(method.turnover, rub(1_500))
    XCTAssertEqual(method.cashback, rub(30))
    XCTAssertEqual(method.cashbackShare, 200)
    XCTAssertEqual(report.cashback, rub(30))
  }

  // MARK: - Series

  /// Income against spending by month; a span of days takes income by date.
  func testIncomeAgainstSpendingByMonth() {
    var book = InsightsBook()
    book.add(.income, rub(1_000), on: .d(8, 31), periodMonth: MonthKey(year: 2026, month: 9))
    book.add(.expense, rub(300), on: .d(9, 3))
    let whole = IncomeVsExpense(
      ledger: book.ledger, period: .days(DayRange(.d(8, 1), .d(9, 30))))
    XCTAssertEqual(whole.months.map(\.income), [.zero, rub(1_000)])
    XCTAssertEqual(whole.months.last?.net, rub(700))
    let cut = IncomeVsExpense(ledger: book.ledger, period: .days(DayRange(.d(8, 15), .d(9, 30))))
    XCTAssertEqual(cut.months.map(\.income), [rub(1_000), .zero])
    XCTAssertEqual(cut.income, rub(1_000))
  }

  /// Income sources: top-level categories with their shares of the income.
  func testIncomeSourcesShareTheIncome() {
    var book = InsightsBook()
    book.add(.income, rub(900), on: .d(9, 2))
    book.add(.income, rub(100), on: .d(9, 3), category: book.gifts.id)
    let sources = IncomeSources(ledger: book.ledger, period: september)
    XCTAssertEqual(sources.total, rub(1_000))
    XCTAssertEqual(sources.sources.map(\.share), [9_000, 1_000])
    XCTAssertTrue(sources.sources.allSatisfy(\.children.isEmpty))
  }

  /// Weeks start on the Monday before the period; days are every day of it.
  func testWeeksStartOnMondayAndDaysCoverThePeriod() {
    var book = InsightsBook()
    book.add(.expense, rub(70), on: .d(9, 1))
    let weeks = TimeSeries(ledger: book.ledger, period: september, step: .week, today: .d(9, 30))
    XCTAssertEqual(weeks.points.first?.start, .d(8, 31))
    XCTAssertEqual(weeks.points.count, 5)
    XCTAssertEqual(weeks.total, rub(70))
    let days = TimeSeries(ledger: book.ledger, period: september, step: .day, today: .d(9, 30))
    XCTAssertEqual(days.points.count, 30)
    XCTAssertEqual(days.average, AmountE4(raw: 23_333))
  }

  /// The average of a month series counts only the months begun since the book began.
  func testTheAverageCountsOnlyMonthsSinceTheBookBegan() {
    var book = InsightsBook()
    book.add(.expense, rub(600), on: .d(8, 10))
    book.add(.expense, rub(400), on: .d(9, 10))
    let series = TimeSeries(
      ledger: book.ledger, period: .year(2026), step: .month, today: .d(9, 20))
    XCTAssertEqual(series.points.count, 12)
    XCTAssertEqual(series.total, rub(1_000))
    XCTAssertEqual(series.average, rub(500))
  }

  /// August's salary paid in September in a book begun in September is August's: its month is
  /// counted in the average of income.
  func testAnIncomeForTheMonthBeforeTheBookCountsInTheAverage() {
    var book = InsightsBook()
    book.add(.income, rub(3_000), on: .d(9, 3), periodMonth: MonthKey(year: 2026, month: 8))
    book.add(.income, rub(1_000), on: .d(9, 4))
    let series = TimeSeries(
      ledger: book.ledger, period: .year(2026), step: .month, measure: .income, today: .d(9, 20))
    XCTAssertEqual(series.total, rub(4_000))
    XCTAssertEqual(series.average, rub(2_000))
  }

  /// Weekdays: how often each one occurred since the book began, and its average.
  func testWeekdaysCountTheirOccurrences() throws {
    var book = InsightsBook()
    book.add(.expense, rub(300), on: .d(9, 1))
    book.add(.expense, rub(100), on: .d(9, 8))
    let profile = WeekdayProfile(ledger: book.ledger, period: september, today: .d(9, 14))
    XCTAssertEqual(profile.interval, DayRange(.d(9, 1), .d(9, 14)))
    let tuesday = try XCTUnwrap(profile.days.first { $0.weekday == 2 })
    XCTAssertEqual(tuesday.occurrences, 2)
    XCTAssertEqual(tuesday.total, rub(400))
    XCTAssertEqual(tuesday.average, rub(200))
    XCTAssertEqual(profile.days.map(\.occurrences).reduce(0, +), 14)
  }

  /// The comparison: an unfinished month against the same days before, running totals as long
  /// as their spans; a finished one against the whole month before.
  func testTheComparisonWithThePeriodBefore() {
    var book = InsightsBook()
    book.add(.expense, rub(100), on: .d(8, 5))
    book.add(.expense, rub(50), on: .d(8, 25))
    book.add(.expense, rub(80), on: .d(9, 5))
    let open = PeriodComparison(ledger: book.ledger, period: september, today: .d(9, 10))
    XCTAssertFalse(open.isComplete)
    XCTAssertEqual(open.expenses, Change(current: rub(80), previous: rub(100)))
    XCTAssertEqual(open.currentCumulative.count, 10)
    XCTAssertEqual(open.previousCumulative.last, rub(100))
    let done = PeriodComparison(ledger: book.ledger, period: september, today: .d(10, 2))
    XCTAssertTrue(done.isComplete)
    XCTAssertEqual(done.expenses.previous, rub(150))
    XCTAssertEqual(done.previousCumulative.count, 31)
  }
}
