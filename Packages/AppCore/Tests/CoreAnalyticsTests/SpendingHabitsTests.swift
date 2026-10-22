import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// «Разбор трат», part 3: places, habits, people, leaks, what ate the limit, the price in hours
/// of work.
@Suite("Places, people and prices")
struct SpendingHabitsTests {
  private func day(_ month: Int, _ day: Int, year: Int = 2026) -> DateOnly {
    SpendKit.day(year, month, day)
  }
  private func money(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }
  private let today = SpendKit.day(2026, 10, 14)

  private func september() -> Period { .month(MonthKey(year: 2026, month: 9)) }

  // MARK: - Favourite places

  @Test func favouritePlacesAreCountedByVisitsAndByMoneyAndSayHowManyHaveNoPlace() throws {
    let often = Place(name: "Kiosk")
    let dear = Place(name: "Shop")
    let ledger = SpendKit.ledger(
      [
        try SpendKit.purchase(100, on: day(9, 2), place: often.id),
        try SpendKit.purchase(100, on: day(9, 3), place: often.id),
        try SpendKit.purchase(100, on: day(9, 4), place: often.id),
        try SpendKit.purchase(1_000, on: day(9, 5), place: dear.id),
        try SpendKit.purchase(700, on: day(9, 6)),
        try SpendKit.purchase(999, on: day(8, 6)),
      ], places: [often, dear])
    let favourites = FavoritePlaces(ledger: ledger, period: september())
    #expect(favourites.byVisits.map(\.placeId) == [often.id, dear.id])
    #expect(favourites.byAmount.map(\.placeId) == [dear.id, often.id])
    #expect(favourites.byAmount.count == 2)  // the operation without a place is in neither list
    #expect(favourites.operationsWithPlace == 4)
    #expect(favourites.operationsWithoutPlace == 1)
    #expect(favourites.withoutPlacePercent == 20)
    #expect(
      FavoritePlaces(ledger: SpendKit.ledger([]), period: september()).withoutPlacePercent
        == nil)
  }

  // MARK: - The average check, month by month

  @Test func aMonthWithOneVisitIsNotOnTheChart() throws {
    let place = Place(name: "Cafe")
    let single = Place(name: "Barber")
    var entries: [TransactionEntry] = []
    for (date, amount) in [
      (day(8, 3), 100), (day(8, 9), 300), (day(9, 4), 500), (day(10, 2), 90), (day(10, 5), 100),
      (day(10, 9), 110),
    ] {
      entries.append(try SpendKit.purchase(Int64(amount), on: date, place: place.id))
    }
    entries.append(try SpendKit.purchase(700, on: day(8, 12), place: single.id))
    entries.append(try SpendKit.purchase(800, on: day(9, 12), place: single.id))
    let history = ReceiptHistory(
      ledger: SpendKit.ledger(entries, places: [place, single]),
      range: DayRange(day(1, 1), day(10, 31)))
    let points = history.points(for: place.id)
    #expect(
      points.map(\.month) == [MonthKey(year: 2026, month: 8), MonthKey(year: 2026, month: 10)])
    #expect(points.map(\.average) == [money(200), money(100)])
    #expect(points.map(\.visits) == [2, 3])
    #expect(history.hasChart(for: place.id))
    #expect(!history.hasChart(for: single.id))
    #expect(history.points(for: UUID()).isEmpty)
  }

  // MARK: - Habits

  /// A visit `weeks` blocks of seven days before today, a day into the block.
  private func visit(week: Int, place: Place, amount: Int64 = 100) throws -> TransactionEntry {
    try SpendKit.purchase(amount, on: today.adding(days: -(7 * week + 1)), place: place.id)
  }

  @Test func sixOfEightWeeksIsAHabitFiveIsNot() throws {
    let habit = Place(name: "Coffee")
    let almost = Place(name: "Gym")
    var entries: [TransactionEntry] = []
    for week in [0, 1, 2, 3, 4, 7] { entries.append(try visit(week: week, place: habit)) }
    for week in 0..<5 { entries.append(try visit(week: week, place: almost)) }
    // Older than eight weeks does not count, however many.
    for week in 8..<20 { entries.append(try visit(week: week, place: almost)) }
    let habits = PlaceHabits(
      ledger: SpendKit.ledger(entries, places: [habit, almost]), today: today)
    #expect(habits.habits.map(\.placeId) == [habit.id])
    let found = try #require(habits.habits.first)
    #expect(found.weeksWithVisits == 6)
    #expect(found.weeklyAverage == money(75))  // 600 over eight weeks
    #expect(found.yearlyCost == money(3_900))  // 75 for 52 weeks
  }

  @Test func twoVisitsInOneWeekAreOneWeekWithAVisit() throws {
    let place = Place(name: "Coffee")
    var entries: [TransactionEntry] = []
    for week in 0..<5 {
      entries.append(try visit(week: week, place: place))
      entries.append(try visit(week: week, place: place))
    }
    let habits = PlaceHabits(ledger: SpendKit.ledger(entries, places: [place]), today: today)
    #expect(habits.habits.isEmpty)
  }

  // MARK: - People

  @Test func spendingOnPeopleIsThePartsForThemAndWhatWasWrittenOff() throws {
    let anya = Person(name: "Anya")
    let boris = Person(name: "Boris")
    let entries = [
      try SpendKit.purchase(300, on: day(9, 3), person: anya.id),
      try SpendKit.entry(
        500, at: SpendKit.moment(day(9, 4), 12, 30), person: boris.id, reimbursable: true,
        status: .expected),
      try SpendKit.entry(
        200, at: SpendKit.moment(day(9, 5), 12, 30), person: boris.id, reimbursable: true,
        status: .writtenOff),
      try SpendKit.purchase(900, on: day(9, 6)),
      try SpendKit.purchase(40, on: day(10, 6), person: anya.id),
    ]
    let ledger = SpendKit.ledger(entries, people: [anya, boris])
    let range = DayRange(day(9, 1), day(9, 30))
    let spending = SpendingOnPeople(ledger: ledger, range: range)
    #expect(spending.people.map(\.personId) == [anya.id, boris.id])
    #expect(spending.people.map(\.amount) == [money(300), money(200)])
    #expect(spending.total == money(500))
    let report = ForWhomReport(ledger: ledger, period: .days(range))
    #expect(report.people.map(\.key) == spending.people.map { .person($0.personId) })
    #expect(report.people.map(\.amount) == spending.people.map(\.amount))
  }

  // MARK: - Leaks

  private struct LeakBook {
    let coffee = Place(name: "Coffee")
    let bakery = Place(name: "Bakery")
    let shop = Place(name: "Shop")
    let cinema = Place(name: "Cinema")
    var entries: [TransactionEntry] = []
    var coffeeIds: [UUID] = []
    var places: [Place] { [coffee, bakery, shop, cinema] }

    init(today: DateOnly, scale: Int64 = 1, extras: Bool = false) throws {
      func add(_ amount: Int64, _ offset: Int, _ place: Place?) throws -> UUID {
        let entry = try SpendKit.purchase(
          amount * scale, on: today.adding(days: -offset), place: place?.id)
        entries.append(entry)
        return entry.id
      }
      for index in 1...22 { coffeeIds.append(try add(200, index, coffee)) }
      for index in 1...3 { _ = try add(150, 30 + index, bakery) }
      for index in 1...5 { _ = try add(5_000, 40 + index, shop) }
      for index in 1...4 { _ = try add(3_000, 50 + index, cinema) }
      if extras { for index in 1...6 { _ = try add(100, 60 + index, nil) } }
    }
  }

  @Test func smallAndOftenAreFoundInTheOwnersHistory() throws {
    let book = try LeakBook(today: today)
    let leaks = SpendingLeaks(
      ledger: SpendKit.ledger(book.entries, places: book.places), today: today)
    #expect(leaks.threshold == money(200))
    #expect(leaks.usualCount == 13)
    #expect(leaks.leaks.count == 1)
    let coffee = try #require(leaks.leaks.first)
    #expect(coffee.key == .place(book.coffee.id))
    #expect(coffee.count == 22)
    #expect(coffee.total == money(4_400))
    #expect(coffee.largest == money(200))
    // 4 400 in 90 days is 1 466.67 in 30.
    #expect(coffee.perMonth == AmountE4(raw: 14_666_667))
  }

  @Test func theThresholdsFollowTheHistoryNotAFixedSum() throws {
    let tenfold = try LeakBook(today: today, scale: 10)
    let leaks = SpendingLeaks(
      ledger: SpendKit.ledger(tenfold.entries, places: tenfold.places), today: today)
    #expect(leaks.threshold == money(2_000))
    #expect(leaks.leaks.map(\.key) == [.place(tenfold.coffee.id)])
    #expect(leaks.leaks.first?.largest == money(2_000))
  }

  @Test func purchasesWithoutAPlaceAreNotSeenAndOneOffsAreNotLeaks() throws {
    let book = try LeakBook(today: today, extras: true)
    let ledger = SpendKit.ledger(book.entries, places: book.places)
    let leaks = SpendingLeaks(ledger: ledger, today: today)
    #expect(leaks.leaks.map(\.key) == [.place(book.coffee.id)])
  }

  @Test func operationsMarkedOneOffAreNotCounted() throws {
    let book = try LeakBook(today: today)
    let ledger = SpendKit.ledger(book.entries, places: book.places)
    let marks = OneOffMarks(ids: Set(book.coffeeIds.prefix(2)))
    let trimmed = SpendingLeaks(ledger: ledger, today: today, oneOff: marks)
    #expect(trimmed.leaks.first?.count == 20)
    #expect(trimmed.leaks.first?.total == money(4_000))
  }

  @Test func withoutHistoryThereAreNoLeaks() throws {
    var entries: [TransactionEntry] = []
    let place = Place(name: "Coffee")
    for index in 1...19 {
      entries.append(try SpendKit.purchase(100, on: today.adding(days: -index), place: place.id))
    }
    let leaks = SpendingLeaks(ledger: SpendKit.ledger(entries, places: [place]), today: today)
    #expect(leaks.threshold == nil)
    #expect(leaks.leaks.isEmpty)
  }

  @Test func byCategoryTheSameRuleHolds() throws {
    var entries: [TransactionEntry] = []
    for index in 1...20 {
      entries.append(
        try SpendKit.purchase(100, on: today.adding(days: -index), category: SpendKit.taxi))
    }
    for index in 1...5 {
      entries.append(
        try SpendKit.purchase(100, on: today.adding(days: -60 - index), category: SpendKit.food))
    }
    for index in 1...4 {
      entries.append(
        try SpendKit.purchase(4_000, on: today.adding(days: -30 - index), category: SpendKit.fun))
    }
    let leaks = SpendingLeaks(
      ledger: SpendKit.ledger(entries), today: today, grouping: .category)
    #expect(leaks.leaks.map(\.key) == [.category(SpendKit.taxi.id)])
    #expect(leaks.leaks.first?.count == 20)
  }

  // MARK: - What ate the limit

  @Test func threeLargestPurchasesAndOneLineForTheRest() throws {
    let partId = UUID()
    let big = try SpendKit.entry(
      5_000, at: SpendKit.moment(day(9, 2), 12, 30), category: SpendKit.food, partId: partId)
    let refund = try SpendKit.entry(
      1_000, at: SpendKit.moment(day(9, 3), 12, 30), kind: .refund, category: SpendKit.food,
      refundOf: partId)
    let stray = try SpendKit.entry(
      500, at: SpendKit.moment(day(9, 4), 12, 30), kind: .refund, category: SpendKit.food)
    let second = try SpendKit.purchase(3_000, on: day(9, 5), category: SpendKit.food)
    let third = try SpendKit.purchase(2_000, on: day(9, 6), category: SpendKit.dairy)
    var entries = [big, refund, stray, second, third]
    for index in 0..<3 {
      entries.append(try SpendKit.purchase(400, on: day(9, 10 + index), category: SpendKit.food))
    }
    entries.append(try SpendKit.purchase(100, on: day(9, 7), category: SpendKit.taxi))
    entries.append(try SpendKit.purchase(9_000, on: day(10, 1), category: SpendKit.food))
    let ledger = SpendKit.ledger(entries)
    let eaten = LimitConsumption(
      ledger: ledger, categoryId: SpendKit.food.id, month: MonthKey(year: 2026, month: 9))
    #expect(eaten.largest.map(\.amount) == [money(4_000), money(3_000), money(2_000)])
    #expect(eaten.largest.map(\.transactionId) == [big.id, second.id, third.id])
    #expect(eaten.othersCount == 3)
    #expect(eaten.othersTotal == money(1_200))
    #expect(eaten.othersLargest == money(400))
    #expect(eaten.returns == money(-500))
    #expect(eaten.spent == money(9_700))
    #expect(
      AmountE4.sum(eaten.largest.map(\.amount)) + eaten.othersTotal + eaten.returns == eaten.spent)
    // What the category spent in the month by the ledger's own rule.
    let ledgerSum = AmountE4.sum(
      ledger.rows(in: DayRange(day(9, 1), day(9, 30)))
        .filter { $0.rootCategoryId == SpendKit.food.id }.map(\.contribution))
    #expect(eaten.spent == ledgerSum)
  }

  @Test func aMonthWithFewPurchasesHasNoOthers() throws {
    let ledger = SpendKit.ledger([
      try SpendKit.purchase(700, on: day(9, 2)), try SpendKit.purchase(300, on: day(9, 3)),
    ])
    let eaten = LimitConsumption(
      ledger: ledger, categoryId: SpendKit.food.id, month: MonthKey(year: 2026, month: 9))
    #expect(eaten.largest.count == 2)
    #expect(eaten.othersCount == 0)
    #expect(eaten.othersLargest == nil)
    #expect(eaten.othersTotal == .zero)
  }

  // MARK: - Price in hours of work

  private func salaryBook(first: DateOnly = SpendKit.day(2026, 1, 10)) throws -> Ledger {
    var entries = [try SpendKit.purchase(10, on: first)]
    for month in [7, 8, 9] {
      entries.append(
        try SpendKit.purchase(168_000, on: day(month, 5), category: SpendKit.salary).asIncome())
    }
    entries.append(
      try SpendKit.purchase(50_000, on: day(8, 20), category: SpendKit.gifts).asIncome())
    // Salary of the month in progress is not a whole month: it is not in the rate.
    entries.append(
      try SpendKit.purchase(999_999, on: day(10, 5), category: SpendKit.salary).asIncome())
    return SpendKit.ledger(entries)
  }

  @Test func theRateIsThreeWholeMonthsOfEarningsOverTheHours() throws {
    let ledger = try salaryBook()
    let settings = WorkHoursSettings(isEnabled: true)
    #expect(settings.hoursPerMonth == 168)
    let rate = try #require(
      WorkRate(
        ledger: ledger, today: today, settings: settings, earningsCategoryId: SpendKit.salary.id))
    #expect(rate.monthsCounted == 3)
    #expect(rate.monthlyEarnings == money(168_000))
    #expect(rate.hourly == money(1_000))
    #expect(rate.hours(for: money(14_000)) == 14)
    #expect(rate.wholeHours(for: money(14_000)) == 14)
    // Without a named category, all the income counts.
    let all = try #require(WorkRate(ledger: ledger, today: today, settings: settings))
    #expect(all.monthlyEarnings.raw > rate.monthlyEarnings.raw)
  }

  @Test func theOwnersHoursChangeTheResult() throws {
    let ledger = try salaryBook()
    let rate = try #require(
      WorkRate(
        ledger: ledger, today: today,
        settings: WorkHoursSettings(isEnabled: true, hoursPerMonth: 100),
        earningsCategoryId: SpendKit.salary.id))
    #expect(rate.hourly == money(1_680))
    #expect(rate.hours(for: money(14_000)) == Decimal(string: "8.3"))
    #expect(rate.wholeHours(for: money(14_000)) == 8)
  }

  @Test func switchedOffOrWithoutEarningsThereIsNoPriceInHours() throws {
    let ledger = try salaryBook()
    #expect(
      WorkRate(ledger: ledger, today: today, settings: WorkHoursSettings(isEnabled: false)) == nil)
    #expect(
      WorkRate(
        ledger: ledger, today: today,
        settings: WorkHoursSettings(isEnabled: true, hoursPerMonth: 0)) == nil)
    #expect(
      WorkRate(
        ledger: SpendKit.ledger([try SpendKit.purchase(10, on: day(1, 10))]), today: today,
        settings: WorkHoursSettings(isEnabled: true)) == nil)
    #expect(
      WorkRate(
        ledger: ledger, today: today, settings: WorkHoursSettings(isEnabled: true),
        earningsCategoryId: UUID()) == nil)
  }

  @Test func aMonthBeforeTheFirstOperationIsNotAMonthWithoutEarnings() throws {
    let ledger = SpendKit.ledger([
      try SpendKit.purchase(90_000, on: day(9, 5), category: SpendKit.salary).asIncome()
    ])
    let rate = try #require(
      WorkRate(ledger: ledger, today: today, settings: WorkHoursSettings(isEnabled: true)))
    #expect(rate.monthsCounted == 1)
    #expect(rate.monthlyEarnings == money(90_000))
  }
}

extension TransactionEntry {
  /// The same operation as an income (the test kit writes purchases).
  fileprivate func asIncome() -> TransactionEntry {
    var copy = self
    copy.transaction.kind = .income
    return copy
  }
}
