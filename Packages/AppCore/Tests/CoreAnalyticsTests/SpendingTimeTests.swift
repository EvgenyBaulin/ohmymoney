import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// «Разбор трат», part 2: the weekend, the usual day, the hours of the day.
@Suite("The time of spending")
struct SpendingTimeTests {
  private func day(_ month: Int, _ day: Int) -> DateOnly { SpendKit.day(2026, month, day) }
  private func money(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }

  // 2026-10-09 is a Friday, 10 Saturday, 11 Sunday, 12 Monday.
  private let friday = SpendKit.day(2026, 10, 9)

  // MARK: - The window

  @Test func theDefaultWeekendIsFridayEveningThroughSunday() {
    let window = WeekendWindow.standard
    #expect(window.contains(weekday: 5, minuteOfDay: 19 * 60))
    #expect(window.contains(weekday: 5, minuteOfDay: 18 * 60))
    #expect(!window.contains(weekday: 5, minuteOfDay: 17 * 60 + 59))
    #expect(window.contains(weekday: 7, minuteOfDay: 23 * 60 + 59))
    #expect(!window.contains(weekday: 1, minuteOfDay: 0))
    #expect(window.contains(weekday: 6, minuteOfDay: 0))
    #expect(!window.coversWholeDay(weekday: 5))
    #expect(window.coversWholeDay(weekday: 6))
    #expect(window.coversWholeDay(weekday: 7))
    #expect(!window.coversWholeDay(weekday: 1))
  }

  @Test func aWindowMayRunOverTheEndOfTheWeek() {
    let window = WeekendWindow(
      startWeekday: 4, start: TimeOfDay(hour: 20, minute: 0), endWeekday: 1,
      end: TimeOfDay(hour: 6, minute: 0))
    #expect(window.contains(weekday: 4, minuteOfDay: 20 * 60))
    #expect(!window.contains(weekday: 4, minuteOfDay: 19 * 60))
    #expect(window.contains(weekday: 7, minuteOfDay: 12 * 60))
    #expect(window.contains(weekday: 1, minuteOfDay: 5 * 60 + 59))
    #expect(window.contains(weekday: 1, minuteOfDay: 6 * 60))
    #expect(!window.contains(weekday: 1, minuteOfDay: 6 * 60 + 1))
    #expect(!window.contains(weekday: 2, minuteOfDay: 0))
    #expect(window.coversWholeDay(weekday: 5))
    #expect(window.coversWholeDay(weekday: 6))
    #expect(!window.coversWholeDay(weekday: 4))
    #expect(!window.coversWholeDay(weekday: 1))
  }

  @Test func otherDaysAndBoundsAreKeptAsText() throws {
    #expect(WeekendWindow.standard.storedValue == "5@18:00-7@23:59")
    let custom = try #require(WeekendWindow(storedValue: "4@20:00-1@06:30"))
    #expect(custom.startWeekday == 4)
    #expect(custom.end == TimeOfDay(hour: 6, minute: 30))
    #expect(WeekendWindow(storedValue: custom.storedValue) == custom)
    #expect(WeekendWindow(storedValue: "") == nil)
    #expect(WeekendWindow(storedValue: "9@18:00-7@23:59") == nil)
    #expect(WeekendWindow(storedValue: "5@25:00-7@23:59") == nil)
    #expect(WeekendWindow(storedValue: "5-7") == nil)
  }

  // MARK: - The price of the weekend

  private func weekendBook() throws -> [TransactionEntry] {
    [
      try SpendKit.entry(500, at: SpendKit.moment(friday, 19)),  // Friday 19:00
      try SpendKit.entry(200, at: SpendKit.moment(friday, 17)),  // Friday 17:00
      try SpendKit.entry(300, at: SpendKit.noon(day(10, 10))),  // Saturday, no time
      try SpendKit.entry(90, at: SpendKit.noon(friday)),  // Friday, no time
      try SpendKit.entry(70, at: SpendKit.moment(day(10, 12), 10)),  // Monday 10:00
      try SpendKit.entry(1_000, at: SpendKit.moment(day(9, 5), 12, 30)),  // September, Saturday
    ]
  }

  @Test func theWeekendIsCountedByTheClockAndAnUntimedDayIsNotGuessed() throws {
    let ledger = SpendKit.ledger(try weekendBook())
    let price = WeekendPrice(
      ledger: ledger, range: DayRange(day(10, 1), day(10, 31)), window: .standard)
    #expect(price.weekend == money(800))  // Fri 19:00 + Saturday without a time
    #expect(price.weekdays == money(360))  // Fri 17:00 + Friday without a time + Monday
    #expect(price.weekendShare == 6_897)
    #expect(price.total == money(1_160))
  }

  @Test func theWeekendMovesMonthByMonth() throws {
    let ledger = SpendKit.ledger(try weekendBook())
    let price = WeekendPrice(ledger: ledger, range: DayRange(day(9, 1), day(10, 31)))
    #expect(
      price.months.map(\.month) == [
        MonthKey(year: 2026, month: 9), MonthKey(year: 2026, month: 10),
      ])
    #expect(price.months[0].weekend == money(1_000))
    #expect(price.months[0].weekdays == money(0))
    #expect(price.months[1].weekend == money(800))
    #expect(price.weekend == money(1_800))
  }

  @Test func otherWindowsGiveOtherPrices() throws {
    let ledger = SpendKit.ledger(try weekendBook())
    let thursday = WeekendWindow(
      startWeekday: 5, start: TimeOfDay(hour: 0, minute: 0), endWeekday: 7,
      end: TimeOfDay(hour: 23, minute: 59))
    let price = WeekendPrice(
      ledger: ledger, range: DayRange(day(10, 1), day(10, 31)), window: thursday)
    // The whole Friday is weekend now, with and without a time.
    #expect(price.weekend == money(500 + 200 + 300 + 90))
    #expect(price.weekdays == money(70))
  }

  @Test func oneOffIsInTheTotalUnlessAskedOtherwise() throws {
    let book = try weekendBook()
    let ledger = SpendKit.ledger(book)
    let marks = OneOffMarks(ids: [book[0].id])
    let range = DayRange(day(10, 1), day(10, 31))
    #expect(WeekendPrice(ledger: ledger, range: range, oneOff: marks).weekend == money(800))
    #expect(
      WeekendPrice(ledger: ledger, range: range, oneOff: marks, excludingOneOff: true).weekend
        == money(300))
  }

  /// 19:00 on a Friday in Bangkok is 15:00 in Moscow: the zone the operation was recorded in
  /// decides, and an operation without a zone is read in the zone the app was told to.
  @Test func anOperationIsReadInItsOwnZoneAndTheOldOnesInTheFallback() throws {
    let instant = SpendKit.moment(friday, 19, in: SpendKit.bangkok)
    let recorded = try SpendKit.entry(100, at: instant, zone: "Asia/Bangkok")
    let old = try SpendKit.entry(10, at: instant)
    let ledger = SpendKit.ledger([recorded, old])
    let range = DayRange(day(10, 1), day(10, 31))
    let inMoscow = WeekendPrice(ledger: ledger, range: range)
    #expect(inMoscow.weekend == money(100))
    #expect(inMoscow.weekdays == money(10))
    let inBangkok = WeekendPrice(
      ledger: ledger, range: range, clock: OperationClock(unrecordedZone: SpendKit.bangkok))
    #expect(inBangkok.weekend == money(110))
  }

  // MARK: - The usual day

  /// `today` is a Wednesday, 14 October 2026.
  private let today = SpendKit.day(2026, 10, 14)

  private func daysBefore(today: DateOnly, where include: (DateOnly) -> Bool) -> [DateOnly] {
    (1...UsualDay.window).map { today.adding(days: -$0) }.filter(include)
  }

  @Test func theUsualDayIsToldApartForWeekdaysAndWeekends() throws {
    var entries: [TransactionEntry] = []
    for date in daysBefore(today: today, where: { (1...4).contains($0.weekday) }) {
      entries.append(try SpendKit.purchase(1_000, on: date))
    }
    for date in daysBefore(today: today, where: { $0.weekday >= 6 }) {
      entries.append(try SpendKit.purchase(3_000, on: date))
    }
    let ledger = SpendKit.ledger(entries)
    let usual = UsualDay(ledger: ledger, today: today)
    #expect(usual.weekdays.amount == money(1_000))
    #expect(usual.weekends.amount == money(3_000))
    // Most days with spending are weekdays, so the median of them all is a weekday's.
    #expect(usual.overall.amount == money(1_000))
  }

  @Test func theOverallUsualDayIsTheRuleOfTheCalendar() throws {
    var entries: [TransactionEntry] = []
    for (index, date) in daysBefore(today: today, where: { _ in true }).enumerated()
    where index % 2 == 0 {
      entries.append(try SpendKit.purchase(Int64(500 + index * 37), on: date))
    }
    let ledger = SpendKit.ledger(entries)
    let calendar = SpendingCalendar.build(
      ledger: ledger, scope: .month, anchor: today, today: today, firstWeekday: 1)
    let usual = UsualDay(ledger: ledger, today: today)
    #expect(usual.overall.amount != nil)
    #expect(usual.overall.amount == calendar.usual)
  }

  @Test func oneOffChangesTheMedianButNotTheTotals() throws {
    let weekdays = daysBefore(today: today, where: { (1...5).contains($0.weekday) })
    var entries: [TransactionEntry] = []
    var marked: Set<UUID> = []
    for (index, date) in weekdays.enumerated() {
      let ordinary = index < 14
      let entry = try SpendKit.purchase(ordinary ? 1_000 : 9_000, on: date)
      if !ordinary { marked.insert(entry.id) }
      entries.append(entry)
    }
    let ledger = SpendKit.ledger(entries)
    let without = UsualDay(ledger: ledger, today: today, oneOff: OneOffMarks(ids: marked))
    let with = UsualDay(ledger: ledger, today: today)
    #expect(without.weekdays.amount == money(1_000))
    #expect(with.weekdays.amount == money(9_000))
    // The month's total is the same whatever is marked: it keeps every purchase.
    #expect(
      ledger.expenses(in: DayRange(today.adding(days: -90), today))
        == AmountE4.sum(entries.map(\.transaction.amountRubE4)))
  }

  @Test func fewerThanFourteenDaysSayThereIsTooLittleData() throws {
    var entries: [TransactionEntry] = []
    for date in daysBefore(today: today, where: { $0.weekday == 1 }).prefix(13) {
      entries.append(try SpendKit.purchase(1_000, on: date))
    }
    let usual = UsualDay(ledger: SpendKit.ledger(entries), today: today)
    #expect(usual.weekdays.isLowData)
    #expect(usual.weekdays.daysWithSpending == 13)
    #expect(usual.weekends.isLowData)
    #expect(usual.weekends.daysWithSpending == 0)
  }

  // MARK: - The hours of the day

  @Test func aCoffeeAtNineInTheTripZoneIsInHourNine() throws {
    // Thursday 2026-10-08, 09:00 in Singapore (+8) is 04:00 in Moscow.
    let thursday = day(10, 8)
    let instant = SpendKit.moment(thursday, 9, in: SpendKit.singapore)
    let ledger = SpendKit.ledger([
      try SpendKit.entry(250, at: instant, zone: "Asia/Singapore"),
      try SpendKit.entry(40, at: instant),  // recorded without a zone: Moscow's clock
    ])
    let map = HourHeatmap(ledger: ledger, range: DayRange(day(10, 1), day(10, 31)))
    #expect(map.amount(weekday: 4, hour: 9) == money(250))
    #expect(map.amount(weekday: 4, hour: 4) == money(40))
    #expect(map.count(weekday: 4, hour: 9) == 1)
    #expect(map.total == money(290))
    #expect(map.maximum == money(250))
    // The old operation is read where the app was told to: here, in Singapore.
    let there = HourHeatmap(
      ledger: ledger, range: DayRange(day(10, 1), day(10, 31)),
      clock: OperationClock(unrecordedZone: SpendKit.singapore))
    #expect(there.amount(weekday: 4, hour: 9) == money(290))
  }

  @Test func anOperationWithoutATimeIsInNoCell() throws {
    let ledger = SpendKit.ledger([
      try SpendKit.entry(100, at: SpendKit.noon(friday)),
      try SpendKit.entry(60, at: SpendKit.moment(friday, 12, 30)),
      try SpendKit.entry(25, at: SpendKit.moment(friday, 12, 45)),
    ])
    let map = HourHeatmap(ledger: ledger, range: DayRange(day(10, 1), day(10, 31)))
    #expect(map.withoutTime == 1)
    #expect(map.amount(weekday: 5, hour: 12) == money(85))
    #expect(map.count(weekday: 5, hour: 12) == 2)
    #expect(map.total == money(85))
  }

  @Test func theHeatmapShowsHabitsSoOneOffAndRefundsAreNotIn() throws {
    let big = try SpendKit.entry(9_000, at: SpendKit.moment(friday, 15))
    let small = try SpendKit.entry(100, at: SpendKit.moment(friday, 15))
    let refund = try SpendKit.entry(
      30, at: SpendKit.moment(friday, 3), kind: .refund)
    let ledger = SpendKit.ledger([big, small, refund])
    let map = HourHeatmap(
      ledger: ledger, range: DayRange(day(10, 1), day(10, 31)),
      oneOff: OneOffMarks(ids: [big.id]))
    #expect(map.amount(weekday: 5, hour: 15) == money(100))
    #expect(map.amount(weekday: 5, hour: 3) == money(0))
    #expect(map.cells.allSatisfy { $0.allSatisfy { $0.raw >= 0 } })
  }
}
