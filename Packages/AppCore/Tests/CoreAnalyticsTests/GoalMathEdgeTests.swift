import CoreAccounting
import CoreKit
import CorePlanning
import Foundation
import Testing

@testable import CoreAnalytics

/// The corners of counting a goal in its own currency: no rate at all, a row in tenge, and a row
/// that names one goal while filed under another's subcategory.
@Suite("Goals in their own currency: the corners")
struct GoalMathEdgeTests {
  static let kzt = CurrencyCode("KZT")
  let trip = id(21)
  let bike = id(22)
  var categories: [CoreKit.Category] {
    [
      CoreKit.Category(
        id: id(20), kind: .expense, name: "Goals", quality: .good, systemRole: .goals),
      CoreKit.Category(id: trip, parentId: id(20), kind: .expense, name: "Trip"),
      CoreKit.Category(id: bike, parentId: id(20), kind: .expense, name: "Bike"),
    ]
  }
  var tripGoal: Goal {
    Goal(
      id: id(600), name: "Trip", targetE4: money("2000"), monthlyPlanE4: money("300"),
      subcategoryId: trip, currency: .usd)
  }
  var bikeGoal: Goal {
    Goal(
      id: id(601), name: "Bike", targetE4: money("90000"), monthlyPlanE4: money("9000"),
      subcategoryId: bike)
  }
  let rates = DayRates(series: [
    CurrencyCode.usd: [DayRate(day: DateOnly(year: 2026, month: 3, day: 1), perUnit: 90)],
    kzt: [DayRate(day: DateOnly(year: 2026, month: 3, day: 1), perUnit: Decimal(18) / 100)],
  ])

  /// A contribution on `iso`, noon UTC.
  func contribution(
    _ number: Int, _ amount: String, _ currency: CurrencyCode = .rub, rub: String? = nil,
    category: UUID, goal: UUID? = nil, on iso: String = "2026-03-02",
    kind: TransactionKind = .expense
  ) -> TransactionEntry {
    let at = CalendarContext.utc.startOfDay(day(iso)).addingTimeInterval(43_200)
    let rubles = money(rub ?? amount)
    return TransactionEntry(
      transaction: Transaction(
        id: id(number), kind: kind, occurredAt: at, currency: currency, amountE4: money(amount),
        amountRubE4: rubles, createdAt: at, updatedAt: at),
      parts: [
        TransactionPart(
          id: id(number * 10), transactionId: id(number), categoryId: category,
          amountE4: money(amount), amountRubE4: rubles, goalId: goal)
      ])
  }

  func ledger(_ entries: [TransactionEntry], goals: [Goal]) -> Ledger {
    Ledger(
      dataset: Dataset(entries: entries, categories: categories, goals: goals), calendar: .utc)
  }

  /// 9 000 ₽ put into a dollar goal while no dollar rate is known at all: the row is not
  /// guessed — `GoalMath` has no figure for it, the goal's status counts it as one row without a
  /// rate and saves nothing from it, and the plan still asks its 300 dollars. A row in dollars
  /// counts its own amount with no rate needed.
  @Test func aRowWithoutARateIsLeftOutAndSaidSo() throws {
    let rubles = contribution(1, "9000", category: trip)
    let dollars = contribution(2, "40", .usd, rub: "3600", category: trip)
    let book = ledger([rubles, dollars], goals: [tripGoal])
    let rubleRow = try #require(book.row(ofPart: id(10)))
    let dollarRow = try #require(book.row(ofPart: id(20)))
    #expect(GoalMath.contribution(of: rubleRow, to: tripGoal, rates: .empty) == nil)
    #expect(GoalMath.contribution(of: dollarRow, to: tripGoal, rates: .empty) == money("40"))
    let status = try #require(
      GoalRules.statuses(goals: [tripGoal], ledger: book, today: day("2026-03-20")).first)
    #expect(status.withoutRate == 1)
    #expect(status.saved == money("40"))
    #expect(
      GoalMath.planLeft(
        goals: [tripGoal], rows: book.rows, month: MonthKey(year: 2026, month: 3), rates: .empty)
        == [id(600): money("260")])
  }

  /// 50 000 tenge worth 9 000 ₽ put into the dollar goal count 9 000 ÷ 90 = 100 dollars. Put
  /// into a tenge goal they count as themselves, 50 000 tenge, and 900 ₽ put into the tenge goal
  /// count 900 ÷ 0.18 = 5 000 tenge — the rate of one tenge, whatever the bank quotes a hundred at.
  @Test func tengeCountsThroughRublesAtTheRateOfOneUnit() throws {
    let tenge = contribution(1, "50000", Self.kzt, rub: "9000", category: trip)
    let rubles = contribution(2, "900", category: trip)
    let book = ledger([tenge, rubles], goals: [tripGoal])
    let tengeRow = try #require(book.row(ofPart: id(10)))
    let rubleRow = try #require(book.row(ofPart: id(20)))
    #expect(GoalMath.contribution(of: tengeRow, to: tripGoal, rates: rates) == money("100"))
    let inTenge = Goal(
      id: id(600), name: "Trip", targetE4: money("2000"), subcategoryId: trip, currency: Self.kzt)
    #expect(GoalMath.contribution(of: tengeRow, to: inTenge, rates: rates) == money("50000"))
    #expect(GoalMath.contribution(of: rubleRow, to: inTenge, rates: rates) == money("5000"))
  }

  /// A row that names the trip goal while filed under the bike's subcategory is the trip's: the
  /// goal named is the owner's word, the category only a place to file it. The bike gets
  /// nothing from it — in `GoalMath` and in the goals' statuses alike —, and a withdrawal named
  /// the same way takes from the trip.
  @Test func theGoalNamedWinsOverTheCategory() throws {
    let put = contribution(1, "50", .usd, rub: "4500", category: bike, goal: id(600))
    let taken = contribution(
      2, "10", .usd, rub: "900", category: bike, goal: id(600), on: "2026-03-05", kind: .refund)
    let book = ledger([put, taken], goals: [tripGoal, bikeGoal])
    let row = try #require(book.row(ofPart: id(10)))
    let back = try #require(book.row(ofPart: id(20)))
    #expect(GoalMath.contribution(of: row, to: tripGoal, rates: rates) == money("50"))
    #expect(GoalMath.contribution(of: row, to: bikeGoal, rates: rates) == .zero)
    #expect(GoalMath.contribution(of: back, to: tripGoal, rates: rates) == money("-10"))
    #expect(GoalMath.contribution(of: back, to: bikeGoal, rates: rates) == .zero)
    let statuses = GoalRules.statuses(
      goals: [tripGoal, bikeGoal], ledger: book, today: day("2026-03-20"), rates: rates)
    #expect(statuses.map(\.saved) == [money("40"), .zero])
  }

  /// Income and money back never touch a goal, even one they name or are filed under.
  @Test func onlyContributionsAndWithdrawalsTouchAGoal() throws {
    let income = contribution(
      1, "100", .usd, rub: "9000", category: trip, goal: id(600), kind: .income)
    let back = contribution(
      2, "100", .usd, rub: "9000", category: trip, goal: id(600), kind: .reimbursement)
    let book = ledger([income, back], goals: [tripGoal])
    for row in book.rows {
      #expect(GoalMath.contribution(of: row, to: tripGoal, rates: rates) == .zero)
    }
  }

  /// 27 000 ₽ put into the bike in March on a plan of 9 000 from March: 18 000 of credit. April
  /// asks nothing, and May, with 9 000 of credit left, nothing either; June asks its 9 000.
  @Test func planLeftUsesTheCreditOfEarlierMonths() {
    var goal = bikeGoal
    goal.planStartMonth = MonthKey(year: 2026, month: 3)
    let book = ledger([contribution(1, "27000", category: bike, on: "2026-03-10")], goals: [goal])
    for (month, left) in [(4, nil), (5, nil), (6, money("9000"))] as [(Int, AmountE4?)] {
      let key = MonthKey(year: 2026, month: month)
      #expect(
        GoalMath.planLeft(goals: [goal], rows: book.rows, month: key, rates: rates)[goal.id]
          == left, "\(key)")
    }
    let may = GoalMath.planState(
      goal: goal, rows: book.rows, month: MonthKey(year: 2026, month: 5), rates: rates)
    #expect(may?.creditIn == money("9000"))
    #expect(may?.creditOut == .zero)
  }
}
