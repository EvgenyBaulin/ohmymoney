import CoreAccounting
import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation
import Testing

/// A handful of events around 19 September 2026 and the operations tied to them.
private struct EventsBook {
  static let today = EventsBook.day("2026-09-19")

  let food = EventsBook.id(1)
  let cafe = EventsBook.id(2)
  let groceries = EventsBook.id(3)
  let transport = EventsBook.id(10)
  let gifts = EventsBook.id(11)

  /// 15–25 September, budget 50 000: tickets bought in August, spending since the 15th.
  let trip = Event(
    id: EventsBook.id(101), name: "Trip", kind: .trip, startDate: EventsBook.day("2026-09-15"),
    endDate: EventsBook.day("2026-09-25"), budgetE4: EventsBook.money("50000"))
  /// 18–21 September, budget 5 000, 3 000 spent in its first two days.
  let festival = Event(
    id: EventsBook.id(102), name: "Festival", startDate: EventsBook.day("2026-09-18"),
    endDate: EventsBook.day("2026-09-21"), budgetE4: EventsBook.money("5000"))
  /// Today, without a budget.
  let guests = Event(
    id: EventsBook.id(103), name: "Guests", startDate: EventsBook.day("2026-09-19"),
    endDate: EventsBook.day("2026-09-19"))
  /// 1 September, budget 3 000, cost 3 500.
  let concert = Event(
    id: EventsBook.id(104), name: "Concert", startDate: EventsBook.day("2026-09-01"),
    endDate: EventsBook.day("2026-09-01"), budgetE4: EventsBook.money("3000"))
  /// Ended in May: out of every list.
  let springTrip = Event(
    id: EventsBook.id(105), name: "Spring trip", kind: .trip,
    startDate: EventsBook.day("2026-05-01"), endDate: EventsBook.day("2026-05-05"),
    budgetE4: EventsBook.money("10000"))
  /// A birthday every 10 October: 2024 cost 5 000, 2025 cost 7 000, 2026 is next, and 2027
  /// was already created by the yearly repeat.
  let birthday2024: Event
  let birthday2025: Event
  let birthday2026: Event
  let birthday2027: Event
  /// 28 September, budget 4 000 — later this month.
  let dinner = Event(
    id: EventsBook.id(110), name: "Dinner", startDate: EventsBook.day("2026-09-28"),
    endDate: EventsBook.day("2026-09-28"), budgetE4: EventsBook.money("4000"))
  /// 31 December – 1 January, budget 30 000, 1 000 already spent.
  let newYear = Event(
    id: EventsBook.id(111), name: "New Year", kind: .newYear,
    startDate: EventsBook.day("2026-12-31"), endDate: EventsBook.day("2027-01-01"),
    budgetE4: EventsBook.money("30000"))
  /// Archived: hidden everywhere.
  let archived = Event(
    id: EventsBook.id(112), name: "Archived", startDate: EventsBook.day("2026-10-01"),
    endDate: EventsBook.day("2026-10-01"), budgetE4: EventsBook.money("1000"), archived: true)
  /// June 2027, budget 100 000: beyond the 120 days.
  let farTrip = Event(
    id: EventsBook.id(113), name: "Far trip", kind: .trip,
    startDate: EventsBook.day("2027-06-01"), endDate: EventsBook.day("2027-06-10"),
    budgetE4: EventsBook.money("100000"))

  var entries: [TransactionEntry] = []
  private var next = 1_000

  init() {
    let series = Self.id(200)
    func birthday(_ number: Int, _ year: Int, archived: Bool) -> Event {
      let date = DateOnly(year: year, month: 10, day: 10)
      return Event(
        id: Self.id(number), name: "Birthday", kind: .birthday, startDate: date, endDate: date,
        recurringYearly: true, seriesId: series, archived: archived)
    }
    birthday2024 = birthday(106, 2024, archived: true)
    birthday2025 = birthday(107, 2025, archived: true)
    birthday2026 = birthday(108, 2026, archived: false)
    birthday2027 = birthday(109, 2027, archived: false)

    add("2026-08-20", "20000", category: transport, event: trip)
    add("2026-09-16", "3000", category: cafe, event: trip)
    add("2026-09-17", "2000", category: groceries, event: trip)
    add("2026-09-17", "1000", category: cafe, event: trip, reimbursable: true)
    add("2026-09-18", "500", kind: .refund, category: cafe, event: trip)
    add("2026-09-18", "700", category: nil, event: trip)
    add("2026-09-18", "1800", category: cafe, event: festival)
    add("2026-09-19", "1200", category: cafe, event: festival)
    add("2026-09-01", "3500", category: cafe, event: concert)
    add("2024-10-05", "5000", category: gifts, event: birthday2024)
    add("2025-10-01", "7000", category: gifts, event: birthday2025)
    add("2026-09-10", "1000", category: gifts, event: newYear)
    add("2026-09-12", "900", category: groceries, event: nil)
  }

  var events: [Event] {
    [
      trip, festival, guests, concert, springTrip, birthday2024, birthday2025, birthday2026,
      birthday2027, dinner, newYear, archived, farTrip,
    ]
  }

  var ledger: Ledger {
    let categories = [
      CoreKit.Category(id: food, kind: .expense, name: "Food", quality: .neutral),
      CoreKit.Category(id: cafe, parentId: food, kind: .expense, name: "Cafe"),
      CoreKit.Category(id: groceries, parentId: food, kind: .expense, name: "Groceries"),
      CoreKit.Category(id: transport, kind: .expense, name: "Transport", quality: .neutral),
      CoreKit.Category(id: gifts, kind: .expense, name: "Gifts", quality: .good),
    ]
    return Ledger(
      dataset: Dataset(entries: entries, categories: categories, events: events), calendar: .utc)
  }

  static func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number)) ?? UUID()
  }

  static func money(_ text: String) -> AmountE4 {
    amountLiteral(text)
  }

  static func day(_ iso: String) -> DateOnly {
    DateOnly(iso: iso) ?? DateOnly(year: 1970, month: 1, day: 1)
  }

  private mutating func add(
    _ iso: String, _ amount: String, kind: TransactionKind = .expense, category: UUID?,
    event: Event?, reimbursable: Bool = false
  ) {
    next += 1
    let transactionId = Self.id(next)
    let when = CalendarContext.utc.startOfDay(Self.day(iso)).addingTimeInterval(12 * 3600)
    let part = TransactionPart(
      id: Self.id(next + 500_000), transactionId: transactionId, categoryId: category,
      quality: .neutral, qualitySource: .manual, amountE4: Self.money(amount),
      forWhom: reimbursable ? .friends : .me, reimbursable: reimbursable,
      reimbursementStatus: reimbursable ? .expected : nil, eventId: event?.id)
    entries.append(
      TransactionEntry(
        transaction: Transaction(
          id: transactionId, kind: kind, occurredAt: when, amountE4: Self.money(amount),
          createdAt: when, updatedAt: when),
        parts: [part]))
  }
}

@Suite("Events planning: spent, budget, last time, monthly saving, lists")
struct EventsPlanningTests {
  private let book = EventsBook()
  private func money(_ text: String) -> AmountE4 { EventsBook.money(text) }

  private var planning: EventsPlanning {
    EventPlanning.build(ledger: book.ledger, today: EventsBook.today)
  }

  private func plan(_ event: Event) -> EventPlan? {
    EventPlanning.plans(ledger: book.ledger, today: EventsBook.today)
      .first { $0.event.id == event.id }
  }

  /// The trip: tickets 20 000, cafe 3 000, groceries 2 000, 500 of the cafe taken back, 700
  /// without a category, and 1 000 paid for a friend that is not mine — 25 200, of a budget
  /// of 50 000. By category: Transport 20 000, Food 4 500, none 700.
  @Test func spentRemainingAndCategoriesOfAnEventUnderWay() throws {
    let trip = try #require(plan(book.trip))
    #expect(trip.spent == money("25200"))
    #expect(trip.budget == money("50000"))
    #expect(trip.remaining == money("24800"))
    #expect(
      trip.byCategory == [
        EventPlan.CategoryAmount(categoryId: book.transport, amount: money("20000")),
        EventPlan.CategoryAmount(categoryId: book.food, amount: money("4500")),
        EventPlan.CategoryAmount(categoryId: nil, amount: money("700")),
      ])
    #expect(trip.isActive)
    #expect(trip.daysUntilStart == 0)
    #expect(trip.monthsUntilStart == 0)
    #expect(trip.monthlySaving == nil)
    #expect(!trip.overBudget)
  }

  /// The same figure as the Events section of Analytics.
  @Test func spentIsTheFigureOfAnalytics() throws {
    let report = EventsReport(ledger: book.ledger, period: .month(MonthKey(year: 2026, month: 9)))
    for event in [book.trip, book.festival, book.concert] {
      let item = try #require(report.events.first { $0.eventId == event.id })
      #expect(plan(event)?.spent == item.total)
    }
  }

  /// The trip's tickets were bought before it: they are committed, not a pace. Of the
  /// 5 200 spent over its first 5 days of 11, the pace gives 11 440, and 20 000 + 11 440 =
  /// 31 440 stays under 50 000 (stretching all 25 200 would give 55 440). The festival spent
  /// 3 000 in 2 of its 4 days: 6 000 by its end, over its 5 000 — pacing, not yet over.
  @Test func pacingExtrapolatesOnlyWhatWasSpentDuringTheEvent() throws {
    let trip = try #require(plan(book.trip))
    #expect(!trip.pacing)
    let festival = try #require(plan(book.festival))
    #expect(festival.spent == money("3000"))
    #expect(festival.remaining == money("2000"))
    #expect(festival.pacing)
    #expect(!festival.overBudget)
  }

  /// The concert cost 3 500 of 3 000.
  @Test func anEventOverItsBudget() throws {
    let concert = try #require(plan(book.concert))
    #expect(concert.overBudget)
    #expect(concert.remaining == money("-500"))
    #expect(!concert.isActive)
    #expect(!concert.pacing)
  }

  /// This year's birthday has no budget: its target is what the 2025 one cost, 7 000 — the
  /// latest earlier event of the series, not 2024's and not the 2027 one created ahead. It
  /// starts in October, one month away: 7 000 a month.
  @Test func lastTimeComesFromTheSeries() throws {
    let birthday = try #require(plan(book.birthday2026))
    #expect(birthday.lastTimeEventId == book.birthday2025.id)
    #expect(birthday.lastTimeTotal == money("7000"))
    #expect(birthday.target == money("7000"))
    #expect(birthday.daysUntilStart == 21)
    #expect(birthday.monthsUntilStart == 1)
    #expect(birthday.monthlySaving == money("7000"))
    let first = try #require(plan(book.birthday2024))
    #expect(first.lastTimeTotal == nil)
    #expect(first.target == nil)
    let next = try #require(plan(book.birthday2027))
    #expect(next.lastTimeEventId == book.birthday2026.id)
    #expect(next.lastTimeTotal == .zero)
  }

  /// New Year: 30 000 budget, 1 000 already spent, three months to put aside (September,
  /// October, November): 29 000 ÷ 3 = 9 666.6667. A dinner later this month takes its whole
  /// budget now. The far trip is 9 months away: 100 000 ÷ 9 = 11 111.1111.
  @Test func monthlySavingSpreadsWhatIsLeftOverTheMonthsBeforeTheStart() throws {
    let newYear = try #require(plan(book.newYear))
    #expect(newYear.daysUntilStart == 103)
    #expect(newYear.monthsUntilStart == 3)
    #expect(newYear.target == money("30000"))
    #expect(newYear.monthlySaving == money("9666.6667"))
    let dinner = try #require(plan(book.dinner))
    #expect(dinner.monthsUntilStart == 0)
    #expect(dinner.monthlySaving == money("4000"))
    let far = try #require(plan(book.farTrip))
    #expect(far.monthsUntilStart == 9)
    #expect(far.monthlySaving == money("11111.1111"))
  }

  /// Under way: the trip, the festival and the guests, by start. Upcoming within 120 days:
  /// the dinner, the birthday and New Year, soonest first — not the far trip, not the
  /// archived event. With a budget: the concert (ended 18 days ago), the trip, the festival,
  /// the dinner and New Year — not the spring trip, ended in May.
  @Test func theListsOfThePlanningBlock() {
    let result = planning
    #expect(result.active.map(\.event.id) == [book.trip.id, book.festival.id, book.guests.id])
    #expect(
      result.upcoming.map(\.event.id) == [book.dinner.id, book.birthday2026.id, book.newYear.id])
    #expect(
      result.withBudget.map(\.event.id) == [
        book.concert.id, book.trip.id, book.festival.id, book.dinner.id, book.newYear.id,
      ])
  }

  @Test func noEventsNoLists() {
    let ledger = Ledger(dataset: Dataset(), calendar: .utc)
    #expect(EventPlanning.build(ledger: ledger, today: EventsBook.today) == .empty)
  }
}
