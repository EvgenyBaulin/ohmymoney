import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("The goal reserve: what the goals' plans still ask this month")
struct FreeToSpendTests: SavingsFixtures {
  let today = DateOnly(year: 2026, month: 9, day: 19)

  /// Car: plan 10 000, 4 000 in. Flat: plan 5 000, 7 000 in — nothing left. Trip: plan
  /// 3 000, 3 000 in and 1 000 taken back. Boat: no plan. Old: archived. Reserve: 6 000 +
  /// 1 000 = 7 000 — the same figure the forecast plans for the goals.
  @Test func theGoalReserveIsWhatThePlansStillAsk() {
    var book = SavingsBook()
    let car = Goal(
      id: uid(500), name: "Car", targetE4: rub("100000"), monthlyPlanE4: rub("10000"),
      subcategoryId: book.carSubcategory)
    let flat = Goal(
      id: uid(501), name: "Flat", targetE4: rub("100000"), monthlyPlanE4: rub("5000"))
    let trip = Goal(
      id: uid(502), name: "Trip", targetE4: rub("100000"), monthlyPlanE4: rub("3000"))
    let boat = Goal(id: uid(503), name: "Boat", targetE4: rub("100000"))
    let old = Goal(
      id: uid(504), name: "Old", targetE4: rub("100000"), monthlyPlanE4: rub("9000"),
      archived: true)
    // Filed under the Car subcategory without a goal: still the car's.
    book.contribute("2026-09-02", "4000", goal: nil)
    // Last month's contribution does not reduce this month's plan.
    book.contribute("2026-08-30", "10000", goal: car.id)
    book.contribute("2026-09-03", "7000", goal: flat.id, category: book.goalsRoot)
    book.contribute("2026-09-04", "3000", goal: trip.id, category: book.goalsRoot)
    book.withdraw("2026-09-05", "1000", goal: trip.id, category: book.goalsRoot)
    let goals = [car, flat, trip, boat, old]
    book.goals = goals
    let ledger = book.ledger

    let reserve = goalReserve(ledger)
    #expect(reserve == rub("7000"))
    #expect(reserve == PlannedPayments(ledger: ledger, today: today).goals)
  }

  /// The goal reserve of the planning snapshot.
  func goalReserve(_ ledger: Ledger) -> AmountE4 {
    PlanningSnapshot.build(
      ledger: ledger, today: today, now: Date(timeIntervalSince1970: 1_790_000_000),
      rubPerUnit: [:]
    ).goalReserve
  }

  /// «Несделанный плановый взнос этого месяца» is never more than the plan: with
  /// a plan of 3 000 that starts in September and 5 000 taken out of the savings of earlier
  /// months, the reserve is the 3 000 still to put in, not 8 000 — putting the 5 000 back is no
  /// plan of this month. Taking back part of this month's own contribution still unmakes that
  /// part.
  @Test(arguments: [
    (["-5000"], "3000"),
    (["2000", "-5000"], "3000"),
    (["3000", "-1000"], "1000"),
    (["1000"], "2000"),
  ])
  func theGoalReserveIsNeverMoreThanThePlan(moves: [String], reserve: String) {
    var book = SavingsBook()
    let trip = Goal(
      id: uid(502), name: "Trip", targetE4: rub("100000"), monthlyPlanE4: rub("3000"),
      planStartMonth: MonthKey(year: 2026, month: 9))
    book.contribute("2026-08-10", "20000", goal: trip.id, category: book.goalsRoot)
    for (index, move) in moves.enumerated() {
      let day = "2026-09-0\(index + 2)"
      if move.hasPrefix("-") {
        book.withdraw(day, String(move.dropFirst()), goal: trip.id, category: book.goalsRoot)
      } else {
        book.contribute(day, move, goal: trip.id, category: book.goalsRoot)
      }
    }
    book.goals = [trip]
    let ledger = book.ledger
    let expected = rub(reserve)
    #expect(goalReserve(ledger) == expected)
    #expect(
      PlannedMonth.build(ledger: ledger, book: .empty, today: today).goals == expected)
    #expect(PlannedPayments(ledger: ledger, today: today).goals == expected)
  }
}
