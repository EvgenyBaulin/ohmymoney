import CoreAccounting
import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CorePlanning

/// Events with budgets on random books: which ones the free sum holds money back for, what
/// they have spent, whether they run over, and the lists of the events block.
@Suite("Event budgets on random books")
struct EventBudgetPropertyTests {
  typealias Fx = CashFx

  static let seeds: [UInt64] = Array(1...30)

  struct Book {
    var fx = CashFx()
    var spentOn: [UUID: AmountE4] = [:]
    /// Spending of each event dated from its first day through today.
    var duringOn: [UUID: AmountE4] = [:]

    init(seed: UInt64) {
      var random = SeededRandom(seed: seed)
      for index in 0..<random.int(in: 1...6) {
        let id = CashFx.id(500 + index)
        let start = CashFx.today.adding(days: random.int(in: -90...200))
        let event = Event(
          id: id, name: "Event \(index)", startDate: start,
          endDate: start.adding(days: random.int(in: 0...14)),
          budgetE4: random.chance(1, outOf: 5)
            ? nil : AmountE4(whole: Int64(random.int(in: 1...60) * 1_000)),
          archived: random.chance(1, outOf: 10))
        fx.events.append(event)
        for _ in 0..<random.int(in: 0...5) {
          let day = start.adding(days: random.int(in: -10...14))
          guard day <= CashFx.today else { continue }
          let amount = AmountE4(whole: Int64(random.int(in: 1...15) * 1_000))
          fx.add(.expense, amount.decimal.description, at: CalendarContext.utc.noon(of: day))
          fx.entries[fx.entries.count - 1].parts[0].eventId = id
          spentOn[id, default: .zero] += amount
          if day >= start { duringOn[id, default: .zero] += amount }
        }
      }
    }
  }

  /// Under way today or ahead with a budget, archived ones aside, however far ahead: the
  /// events the free sum keeps the rest of the budget for, by start.
  @Test(arguments: seeds)
  func theEventsWithABudgetStillAhead(_ seed: UInt64) {
    let book = Book(seed: seed)
    let snapshot = book.fx.snapshot()
    let model = book.fx.events.filter {
      !$0.archived && $0.budgetE4 != nil && $0.endDate >= Fx.today
    }.sorted { ($0.startDate, $0.id.uuidString) < ($1.startDate, $1.id.uuidString) }
    #expect(snapshot.budgetedEvents.map(\.event.id) == model.map(\.id), "seed \(seed)")
  }

  /// What each event spent is every operation filed under it, whatever its date; over budget
  /// when that is more than the budget; running over when, under way, what was spent before it
  /// began plus the pace of its days so far would pass the budget by its last day.
  @Test(arguments: seeds)
  func spentOverAndPace(_ seed: UInt64) {
    let book = Book(seed: seed)
    let plans = EventPlanning.plans(ledger: book.fx.ledger, today: Fx.today)
    for plan in plans {
      let event = plan.event
      let spent = book.spentOn[event.id] ?? .zero
      #expect(plan.spent == spent, "seed \(seed)")
      #expect(plan.remaining == event.budgetE4.map { $0 - spent })
      #expect(plan.overBudget == (event.budgetE4.map { spent > $0 } ?? false))
      let underWay = event.startDate <= Fx.today && event.endDate >= Fx.today
      #expect(plan.isActive == underWay)
      var pacing = false
      if underWay, let budget = event.budgetE4 {
        let during = book.duringOn[event.id] ?? .zero
        let committed = spent - during
        let days = Decimal(event.startDate.days(to: event.endDate) + 1)
        let gone = Decimal(event.startDate.days(to: Fx.today) + 1)
        pacing = committed.decimal + during.decimal * days / gone > budget.decimal
      }
      #expect(plan.pacing == pacing, "seed \(seed)")
      // The target of an event without a series is its budget. What to put aside a month for
      // one not started yet: what is left of it over the months until it starts, at least one.
      #expect(plan.target == event.budgetE4, "seed \(seed)")
      if event.startDate > Fx.today, let target = event.budgetE4 {
        let months = max(1, PlainCalendar.months(from: Fx.today, to: event.startDate))
        let left = target - spent
        let expected =
          left.raw > 0 ? SubscriptionMath.rounded(left.decimal / Decimal(months)) : .zero
        #expect(plan.monthlySaving == expected, "seed \(seed)")
      } else {
        #expect(plan.monthlySaving == nil)
      }
    }
  }

  /// A trip of 15–24 September (ten days) with a budget of 12 000: 2 000 paid on the 10th for
  /// the tickets, 5 500 spent in its first five days. At that pace it ends at 2 000 + 5 500 ×
  /// 10 ÷ 5 = 13 000 — over the budget, though only 7 500 is spent. With 5 000 spent it ends at
  /// exactly 12 000, which is not over.
  @Test func aTripRunningOverItsBudget() {
    var fx = Fx()
    fx.events = [
      Event(
        id: Fx.id(551), name: "Trip", startDate: Fx.day("2026-09-15"),
        endDate: Fx.day("2026-09-24"), budgetE4: Fx.money("12000"))
    ]
    for (day, amount) in [("2026-09-10", "2000"), ("2026-09-15", "3000"), ("2026-09-18", "2500")] {
      fx.add(.expense, amount, at: Fx.at(day, 12))
      fx.entries[fx.entries.count - 1].parts[0].eventId = Fx.id(551)
    }
    let plan = EventPlanning.plans(ledger: fx.ledger, today: Fx.today).first
    #expect(plan?.spent == Fx.money("7500"))
    #expect(plan?.remaining == Fx.money("4500"))
    #expect(plan?.overBudget == false)
    #expect(plan?.pacing == true)
    #expect(plan?.monthlySaving == nil)

    fx.entries[fx.entries.count - 1].transaction.amountE4 = Fx.money("2000")
    fx.entries[fx.entries.count - 1].transaction.amountRubE4 = Fx.money("2000")
    fx.entries[fx.entries.count - 1].parts[0].amountE4 = Fx.money("2000")
    fx.entries[fx.entries.count - 1].parts[0].amountRubE4 = Fx.money("2000")
    let even = EventPlanning.plans(ledger: fx.ledger, today: Fx.today).first
    #expect(even?.spent == Fx.money("7000"))
    #expect(even?.pacing == false)
  }

  /// A holiday of 10 January with a budget of 40 000 and 4 000 of it paid ahead: four months
  /// from September to January, 9 000 to put aside a month. One this month — 25 September —
  /// asks for the whole rest at once.
  @Test func whatToPutAsideForAnEventAhead() {
    var fx = Fx()
    fx.events = [
      Event(
        id: Fx.id(552), name: "Holiday", startDate: Fx.day("2027-01-10"),
        endDate: Fx.day("2027-01-20"), budgetE4: Fx.money("40000")),
      Event(
        id: Fx.id(553), name: "Concert", startDate: Fx.day("2026-09-25"),
        endDate: Fx.day("2026-09-25"), budgetE4: Fx.money("5000")),
    ]
    fx.add(.expense, "4000", at: Fx.at("2026-09-01", 12))
    fx.entries[fx.entries.count - 1].parts[0].eventId = Fx.id(552)
    let plans = Dictionary(
      uniqueKeysWithValues: EventPlanning.plans(ledger: fx.ledger, today: Fx.today).map {
        ($0.event.name, $0)
      })
    #expect(plans["Holiday"]?.monthsUntilStart == 4)
    #expect(plans["Holiday"]?.monthlySaving == Fx.money("9000"))
    #expect(plans["Concert"]?.monthsUntilStart == 0)
    #expect(plans["Concert"]?.monthlySaving == Fx.money("5000"))
    #expect(plans["Concert"]?.daysUntilStart == 6)
  }

  /// The events block: under way today; starting within 120 days; with a budget and under
  /// way, ended within 30 days or starting within 120 — archived ones in none.
  @Test(arguments: seeds)
  func theListsOfTheBlock(_ seed: UInt64) {
    let book = Book(seed: seed)
    let lists = book.fx.snapshot().events
    let live = book.fx.events.filter { !$0.archived }
    let underWay = Set(live.filter { $0.covers(Fx.today) }.map(\.id))
    let soon = Set(
      live.filter { $0.startDate > Fx.today && $0.startDate <= Fx.today.adding(days: 120) }.map(
        \.id))
    let ended = Set(
      live.filter { $0.endDate < Fx.today && $0.endDate >= Fx.today.adding(days: -30) }.map(\.id))
    let budgeted = Set(live.filter { $0.budgetE4 != nil }.map(\.id))
    #expect(Set(lists.active.map(\.event.id)) == underWay, "seed \(seed)")
    #expect(Set(lists.upcoming.map(\.event.id)) == soon, "seed \(seed)")
    #expect(
      Set(lists.withBudget.map(\.event.id))
        == budgeted.intersection(underWay.union(soon).union(ended)),
      "seed \(seed)")
  }

  /// The same event next year: the same day a year later — 29 February on 28 February — for as
  /// many days.
  @Test func theSameEventNextYear() {
    let leap = EventPlanning.nextYear(of: DayRange(Fx.day("2028-02-29"), Fx.day("2028-03-09")))
    #expect(leap == DayRange(Fx.day("2029-02-28"), Fx.day("2029-03-09")))
    let plain = EventPlanning.nextYear(of: DayRange(Fx.day("2026-12-30"), Fx.day("2027-01-02")))
    #expect(plain == DayRange(Fx.day("2027-12-30"), Fx.day("2028-01-02")))
  }
}
