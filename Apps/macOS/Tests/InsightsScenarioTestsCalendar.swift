import AppCore
import XCTest

@testable import OhMyMoney

/// «Календарь трат» on books written by hand: months that start on a Monday or a Sunday, a
/// week over New Year, a leap February, the 90-day window and its 14-day threshold, the edges
/// of «дороже обычного», refunds counted on the purchase's day, money for others, days ahead,
/// plans in a currency without a rate, and a calendar shown in dollars.
final class InsightsScenarioCalendarTests: XCTestCase {
  private func rub(_ value: Int64) -> AmountE4 { AmountE4(whole: value) }

  private func calendar(
    _ book: InsightsBook, _ scope: CalendarScope = .month, anchor: DateOnly, today: DateOnly,
    firstWeekday: Int = 1, plans: [CalendarPlan] = [], currency: CurrencyCode = .rub,
    rates: [CurrencyCode: Decimal] = [:]
  ) -> SpendingCalendar {
    SpendingCalendar.build(
      ledger: book.ledger, scope: scope, anchor: anchor, today: today,
      firstWeekday: firstWeekday, plans: plans, currency: currency, rubPerUnit: rates)
  }

  private func plan(
    _ kind: CalendarPlan.Kind, _ name: String, _ amount: AmountE4, on day: DateOnly,
    currency: CurrencyCode = .rub
  ) -> CalendarPlan {
    CalendarPlan(
      kind: kind, sourceId: UUID(), day: day, name: name, amount: amount, currency: currency)
  }

  // MARK: - The grid

  /// February 2027 starts on a Monday and has 28 days: four whole weeks, no neighbours.
  func testAFebruaryStartingOnMondayIsFourWeeks() {
    let shown = calendar(InsightsBook(), anchor: .d(2, 10, 2027), today: .d(3, 5, 2027))
    XCTAssertEqual(shown.weeks.count, 4)
    XCTAssertEqual(shown.range, DayRange(.d(2, 1, 2027), .d(2, 28, 2027)))
    XCTAssertTrue(shown.weeks.joined().allSatisfy(\.inScope))
  }

  /// February 2026 starts on a Sunday: five weeks from Monday, four from Sunday.
  func testFebruaryIsFiveWeeksFromMondayAndFourFromSunday() {
    let monday = calendar(InsightsBook(), anchor: .d(2, 1), today: .d(3, 5))
    XCTAssertEqual(monday.range, DayRange(.d(1, 26), .d(3, 1)))
    XCTAssertEqual(monday.weeks.count, 5)
    XCTAssertEqual(monday.days.count, 28)
    let sunday = calendar(InsightsBook(), anchor: .d(2, 1), today: .d(3, 5), firstWeekday: 7)
    XCTAssertEqual(sunday.range, DayRange(.d(2, 1), .d(2, 28)))
    XCTAssertEqual(sunday.weekdays, [7, 1, 2, 3, 4, 5, 6])
  }

  /// A leap February has its 29th in scope.
  func testALeapFebruaryHasItsTwentyNinth() throws {
    let shown = calendar(InsightsBook(), anchor: .d(2, 29, 2028), today: .d(3, 1, 2028))
    XCTAssertEqual(shown.days.count, 29)
    XCTAssertEqual(shown.days.last?.day, .d(2, 29, 2028))
    XCTAssertTrue(try XCTUnwrap(shown.day(.d(3, 1, 2028))).isToday)
  }

  /// The week of New Year: Monday 28 December to Sunday 3 January, all of it in scope, and
  /// the spending of both years counted.
  func testAWeekOverNewYear() {
    var book = InsightsBook()
    book.add(.expense, rub(100), on: .d(12, 30))
    book.add(.expense, rub(250), on: .d(1, 2, 2027))
    let week = calendar(book, .week, anchor: .d(12, 31), today: .d(1, 5, 2027))
    XCTAssertEqual(week.range, DayRange(.d(12, 28), .d(1, 3, 2027)))
    XCTAssertTrue(week.days.allSatisfy(\.inScope))
    XCTAssertEqual(week.spent, rub(350))
  }

  /// A month counts only its own days; a neighbour's day shows its spending outside the sum.
  func testAMonthCountsOnlyItsOwnDays() throws {
    var book = InsightsBook()
    book.add(.expense, rub(70), on: .d(8, 31))
    book.add(.expense, rub(30), on: .d(9, 1))
    let shown = calendar(book, anchor: .d(9, 15), today: .d(9, 20))
    XCTAssertEqual(shown.spent, rub(30))
    let neighbour = try XCTUnwrap(shown.day(.d(8, 31)))
    XCTAssertFalse(neighbour.inScope)
    XCTAssertEqual(neighbour.spent, rub(70))
  }

  /// Days ahead: no spending, but what is already written for them is listed.
  func testDaysAheadListWhatIsWrittenButSpendNothing() throws {
    var book = InsightsBook()
    let ahead = book.add(.expense, rub(500), on: .d(9, 25))
    let shown = calendar(book, anchor: .d(9, 1), today: .d(9, 20))
    let day = try XCTUnwrap(shown.day(.d(9, 25)))
    XCTAssertTrue(day.isFuture)
    XCTAssertNil(day.spent)
    XCTAssertEqual(day.transactionIds, [ahead.id])
    XCTAssertEqual(shown.spent, .zero)
    XCTAssertEqual(try XCTUnwrap(shown.day(.d(9, 19))).spent, .zero)
  }

  /// «‹» and «›»: a month goes to the 1st of the next, a week back over New Year.
  func testStepsFromTheThirtyFirstAndOverNewYear() {
    XCTAssertEqual(SpendingCalendar.step(.d(1, 31), scope: .month, by: 1), .d(2, 1))
    XCTAssertEqual(SpendingCalendar.step(.d(1, 31), scope: .month, by: -1), .d(12, 1, 2025))
    XCTAssertEqual(SpendingCalendar.step(.d(1, 3), scope: .week, by: -1), .d(12, 27, 2025))
    XCTAssertEqual(SpendingCalendar.step(.d(12, 15), scope: .month, by: 13), .d(1, 1, 2028))
  }

  /// The first weekday: Russian is Monday, others follow the Mac, a broken value is Monday.
  func testTheFirstWeekdayOfEachLanguage() {
    XCTAssertEqual(SpendingCalendar.firstWeekday(languageCode: "ru", systemFirstWeekday: 1), 1)
    XCTAssertEqual(SpendingCalendar.firstWeekday(languageCode: "en", systemFirstWeekday: 1), 7)
    XCTAssertEqual(SpendingCalendar.firstWeekday(languageCode: "en", systemFirstWeekday: 2), 1)
    XCTAssertEqual(SpendingCalendar.firstWeekday(languageCode: "en", systemFirstWeekday: 7), 6)
    XCTAssertEqual(SpendingCalendar.firstWeekday(languageCode: nil, systemFirstWeekday: 9), 1)
    XCTAssertEqual(SpendingCalendar.weekdays(startingWith: 0), [1, 2, 3, 4, 5, 6, 7])
    XCTAssertEqual(
      SpendingCalendar.weekStart(of: .d(9, 1), firstWeekday: 3), .d(8, 26))
  }

  // MARK: - The usual day

  /// Thirteen days with spending are too few to say what is usual; the fourteenth is enough.
  func testFourteenDaysOfHistoryAreTheThreshold() throws {
    var book = InsightsBook()
    for offset in 1...13 {
      book.add(.expense, rub(100), on: DateOnly.d(9, 20).adding(days: -offset))
    }
    book.add(.expense, rub(500), on: .d(9, 20))
    let few = calendar(book, .week, anchor: .d(9, 20), today: .d(9, 20))
    XCTAssertNil(try XCTUnwrap(few.day(.d(9, 20))).level)
    XCTAssertTrue(few.lowData)
    book.add(.expense, rub(100), on: .d(8, 1))
    let enough = calendar(book, .week, anchor: .d(9, 20), today: .d(9, 20))
    XCTAssertEqual(try XCTUnwrap(enough.day(.d(9, 20))).level, .muchHigher)
    XCTAssertEqual(enough.usual, rub(100))
  }

  /// A day more than 90 days back no longer says what is usual.
  func testTheWindowForgetsDaysOlderThanNinety() throws {
    var book = InsightsBook()
    for offset in 78...90 {
      book.add(.expense, rub(100), on: DateOnly.d(9, 20).adding(days: -offset))
    }
    book.add(.expense, rub(100), on: DateOnly.d(9, 20).adding(days: -91))
    book.add(.expense, rub(400), on: .d(9, 20))
    let shown = calendar(book, .week, anchor: .d(9, 20), today: .d(9, 20))
    XCTAssertNil(try XCTUnwrap(shown.day(.d(9, 20))).level)
    XCTAssertNil(shown.usual)
  }

  /// The usual day of an even count is the mean of the two middle days.
  func testTheUsualDayOfAnEvenCount() {
    var book = InsightsBook()
    for offset in 1...14 {
      book.add(.expense, rub(Int64(offset * 10)), on: DateOnly.d(9, 20).adding(days: -offset))
    }
    let shown = calendar(book, .week, anchor: .d(9, 20), today: .d(9, 20))
    XCTAssertEqual(shown.usual, rub(75))
  }

  /// One and a half times usual is «дороже обычного», three times «намного дороже», just
  /// under stays usual; a usual day of zero never marks a day.
  func testTheEdgesOfTheLevels() {
    XCTAssertEqual(SpendingCalendar.level(spent: rub(150), usual: rub(100)), .higher)
    XCTAssertEqual(
      SpendingCalendar.level(spent: AmountE4(raw: 1_499_999), usual: rub(100)), .usual)
    XCTAssertEqual(SpendingCalendar.level(spent: rub(300), usual: rub(100)), .muchHigher)
    XCTAssertEqual(
      SpendingCalendar.level(spent: AmountE4(raw: 2_999_999), usual: rub(100)), .higher)
    XCTAssertEqual(SpendingCalendar.level(spent: rub(300), usual: .zero), .usual)
    XCTAssertLessThan(SpendingLevel.usual, SpendingLevel.muchHigher)
  }

  /// An empty book: zero everywhere in the past, no usual day, no complaint of little data.
  func testAnEmptyBookIsQuiet() {
    let shown = calendar(InsightsBook(), anchor: .d(9, 1), today: .d(9, 14))
    XCTAssertEqual(shown.spent, .zero)
    XCTAssertNil(shown.usual)
    XCTAssertFalse(shown.lowData)
    XCTAssertTrue(shown.days.allSatisfy { $0.level == nil && $0.transactionIds.isEmpty })
  }

  // MARK: - What a day is

  /// A refund made a week later takes the money off the purchase's day; the refund is still
  /// listed on its own day.
  func testARefundCountsOnThePurchasesDay() throws {
    var book = InsightsBook()
    let purchase = book.add(.expense, rub(1_000), on: .d(9, 3))
    let refund = book.add(.refund, rub(400), on: .d(9, 10), refundOf: purchase.parts[0].id)
    let shown = calendar(book, anchor: .d(9, 1), today: .d(9, 20))
    XCTAssertEqual(try XCTUnwrap(shown.day(.d(9, 3))).spent, rub(600))
    let day = try XCTUnwrap(shown.day(.d(9, 10)))
    XCTAssertEqual(day.spent, .zero)
    XCTAssertEqual(day.transactionIds, [refund.id])
    XCTAssertEqual(shown.spent, rub(600))
  }

  /// Income is no spending, but its day lists it.
  func testIncomeIsListedButIsNoSpending() throws {
    var book = InsightsBook()
    let income = book.add(.income, rub(50_000), on: .d(9, 5))
    let shown = calendar(book, anchor: .d(9, 1), today: .d(9, 20))
    let day = try XCTUnwrap(shown.day(.d(9, 5)))
    XCTAssertEqual(day.spent, .zero)
    XCTAssertEqual(day.transactionIds, [income.id])
  }

  /// A part paid for somebody else is no spending until written off.
  func testMoneyForOthersIsNoSpendingUntilWrittenOff() throws {
    var book = InsightsBook()
    let anna = Person(name: "Anna")
    book.people = [anna]
    book.add(.expense, rub(300), on: .d(9, 6), reimbursable: true, debtor: anna.id)
    book.add(
      .expense, rub(40), on: .d(9, 7), reimbursable: true, debtor: anna.id, status: .writtenOff)
    let shown = calendar(book, anchor: .d(9, 1), today: .d(9, 20))
    XCTAssertEqual(try XCTUnwrap(shown.day(.d(9, 6))).spent, .zero)
    XCTAssertEqual(try XCTUnwrap(shown.day(.d(9, 7))).spent, rub(40))
  }

  /// A deleted operation is not on its day at all.
  func testADeletedOperationIsNotOnItsDay() throws {
    var book = InsightsBook()
    book.add(.expense, rub(800), on: .d(9, 8), deleted: true)
    let day = try XCTUnwrap(calendar(book, anchor: .d(9, 1), today: .d(9, 20)).day(.d(9, 8)))
    XCTAssertEqual(day.spent, .zero)
    XCTAssertTrue(day.transactionIds.isEmpty)
  }

  /// A split purchase is listed once on its day.
  func testASplitPurchaseIsListedOnce() throws {
    var book = InsightsBook()
    let split = book.split([(book.food.id, rub(10)), (book.fun.id, rub(20))], on: .d(9, 9))
    let day = try XCTUnwrap(calendar(book, anchor: .d(9, 1), today: .d(9, 20)).day(.d(9, 9)))
    XCTAssertEqual(day.transactionIds, [split.id])
    XCTAssertEqual(day.spent, rub(30))
  }

  // MARK: - Plans and currencies

  /// Payments first, then incomes, each by name; past plans are not shown.
  func testPlansGoPaymentsFirstAndOnlyAhead() throws {
    let plans = [
      plan(.income, "Salary", rub(1_000), on: .d(9, 25)),
      plan(.payment, "Rent", rub(300), on: .d(9, 25)),
      plan(.payment, "Internet", rub(20), on: .d(9, 25)),
      plan(.payment, "Old", rub(5), on: .d(9, 10)),
    ]
    let shown = calendar(InsightsBook(), anchor: .d(9, 1), today: .d(9, 20), plans: plans)
    let day = try XCTUnwrap(shown.day(.d(9, 25)))
    XCTAssertEqual(day.plans.map(\.name), ["Internet", "Rent", "Salary"])
    XCTAssertEqual(day.plannedOut, rub(320))
    XCTAssertEqual(day.plannedIn, rub(1_000))
    XCTAssertTrue(try XCTUnwrap(shown.day(.d(9, 10))).plans.isEmpty)
  }

  /// A plan in a currency without a rate is left out of the sum and flagged, never guessed.
  func testAPlanWithoutARateIsFlaggedAndLeftOut() throws {
    let plans = [
      plan(.payment, "Hosting", rub(10), on: .d(9, 22), currency: .eur),
      plan(.payment, "Phone", rub(500), on: .d(9, 22)),
      plan(.income, "Fee", rub(7), on: .d(9, 23), currency: .eur),
    ]
    let shown = calendar(InsightsBook(), anchor: .d(9, 1), today: .d(9, 20), plans: plans)
    let mixed = try XCTUnwrap(shown.day(.d(9, 22)))
    XCTAssertEqual(mixed.plannedOut, rub(500))
    XCTAssertTrue(mixed.plansWithoutRate)
    let only = try XCTUnwrap(shown.day(.d(9, 23)))
    XCTAssertNil(only.plannedIn)
    XCTAssertTrue(only.plansWithoutRate)
  }

  /// In dollars: rubles at today's rate, rounded once to whole dollars.
  func testACalendarInDollarsRoundsOnce() throws {
    var book = InsightsBook()
    book.add(.expense, rub(1_000), on: .d(9, 3))
    book.add(.expense, rub(1_000), on: .d(9, 4))
    let shown = calendar(
      book, anchor: .d(9, 1), today: .d(9, 20), currency: .usd, rates: [.usd: 95])
    XCTAssertEqual(shown.currency, .usd)
    XCTAssertEqual(try XCTUnwrap(shown.day(.d(9, 3))).spent, rub(11))
    XCTAssertEqual(shown.spent, rub(21))
  }

  /// A currency without a rate shows the calendar in rubles.
  func testACurrencyWithoutARateFallsBackToRubles() {
    var book = InsightsBook()
    book.add(.expense, rub(1_234), on: .d(9, 3))
    let shown = calendar(book, anchor: .d(9, 1), today: .d(9, 20), currency: .usd, rates: [:])
    XCTAssertEqual(shown.currency, .rub)
    XCTAssertEqual(shown.spent, rub(1_234))
    let zero = calendar(
      book, anchor: .d(9, 1), today: .d(9, 20), currency: .usd,
      rates: [.usd: 0])
    XCTAssertEqual(zero.currency, .rub)
  }

  /// A purchase in dollars is on its day by its rubles, rounded once to the ruble: 950.4999
  /// is 950, never 951.
  func testAForeignPurchaseIsOnItsDayByItsRubles() throws {
    var book = InsightsBook()
    book.add(.expense, rub(10), on: .d(9, 3), currency: .usd, rub: AmountE4(raw: 9_504_999))
    let day = try XCTUnwrap(calendar(book, anchor: .d(9, 1), today: .d(9, 20)).day(.d(9, 3)))
    XCTAssertEqual(day.spent, rub(950))
  }
}
