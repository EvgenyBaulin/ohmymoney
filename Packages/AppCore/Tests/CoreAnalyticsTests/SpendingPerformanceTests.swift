import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// How long the calculations of «Разбор трат» take on the large synthetic set (about 20 000
/// operations over two years), from a built ledger. Only `make bench` runs it, in release; the
/// target of each is 200 ms. The output carries times and counts only.
@Suite("Performance of the spending analysis", .serialized, .enabled(if: Bench.isOn))
struct SpendingPerformanceTests {
  static let ledger = Ledger(dataset: PerformanceTests.dataset, calendar: Synthetic.calendar)
  static let today = PerformanceTests.set.lastDay
  static let budget = Duration.milliseconds(200)

  @Test func comparisonOfTwoYears() {
    let year = Self.today.year
    let periods = ComparisonPeriods(
      current: DayRange(DateOnly(year: year, month: 1, day: 1), Self.today),
      baseline: DayRange(
        DateOnly(year: year - 1, month: 1, day: 1), DateOnly(year: year - 1, month: 12, day: 31)))
    var rows = 0
    let times = Bench.measure("comparison, two periods, by category") {
      rows = SpendingComparison(ledger: Self.ledger, periods: periods).rows.count
    }
    #expect(rows > 0)
    #expect(times.median < Self.budget)
  }

  @Test func heatmapOfTwoYears() {
    let range = DayRange(Self.today.adding(days: -730), Self.today)
    var total = AmountE4.zero
    let times = Bench.measure("hour heatmap, two years") {
      total = HourHeatmap(ledger: Self.ledger, range: range).total
    }
    #expect(total.raw > 0)
    #expect(times.median < Self.budget)
  }

  @Test func weekendPriceOfTwoYears() {
    let range = DayRange(Self.today.adding(days: -730), Self.today)
    var total = AmountE4.zero
    let times = Bench.measure("weekend price, two years") {
      total = WeekendPrice(ledger: Self.ledger, range: range).total
    }
    #expect(total.raw > 0)
    #expect(times.median < Self.budget)
  }

  @Test func usualDayLeaksHabitsAndPeople() {
    var found = 0
    let range = DayRange(Self.today.adding(days: -365), Self.today)
    let usual = Bench.measure("usual day") {
      found = UsualDay(ledger: Self.ledger, today: Self.today).overall.daysWithSpending
    }
    #expect(found > 0)
    #expect(usual.median < Self.budget)
    let leaks = Bench.measure("leaks") {
      found = SpendingLeaks(ledger: Self.ledger, today: Self.today).leaks.count
    }
    #expect(leaks.median < Self.budget)
    let habits = Bench.measure("habits") {
      found = PlaceHabits(ledger: Self.ledger, today: Self.today).habits.count
    }
    #expect(habits.median < Self.budget)
    let people = Bench.measure("spending on people, a year") {
      found = SpendingOnPeople(ledger: Self.ledger, range: range).people.count
    }
    #expect(people.median < Self.budget)
    let places = Bench.measure("favourite places, a year") {
      found = FavoritePlaces(ledger: Self.ledger, period: .days(range)).byVisits.count
    }
    #expect(places.median < Self.budget)
    let receipts = Bench.measure("average check history, two years") {
      found =
        ReceiptHistory(
          ledger: Self.ledger, range: DayRange(Self.today.adding(days: -730), Self.today)
        ).series.count
    }
    #expect(receipts.median < Self.budget)
    #expect(found >= 0)
  }
}
