import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// The money of goals in their own currencies, on random contributions and withdrawals, against
/// a model: a row in the goal's currency counts its own amount, a ruble goal counts rubles, any
/// other row counts its rubles at the rate of its own day; a contribution adds, a withdrawal
/// takes off; the plan of a month asks what is left of it, never more than the plan, never more
/// than the goal still needs.
@Suite("Goals in their own currency, against a model")
struct GoalMathPropertyTests {
  let trip = id(21)
  let bike = id(22)
  var categories: [CoreKit.Category] {
    [
      CoreKit.Category(
        id: id(20), kind: .expense, name: "Goals", quality: .good, systemRole: .goals),
      CoreKit.Category(id: trip, parentId: id(20), kind: .expense, name: "Trip"),
      CoreKit.Category(id: bike, parentId: id(20), kind: .expense, name: "Bike"),
      CoreKit.Category(id: id(10), kind: .expense, name: "Groceries"),
    ]
  }

  struct Case {
    var goals: [Goal]
    var entries: [TransactionEntry]
    var rates: DayRates
    var perUnit: [DateOnly: Decimal]
  }

  func randomCase(seed: UInt64) -> Case {
    var dice = MoneyDice(seed: seed)
    let start = DateOnly(year: 2026, month: 1, day: 1)
    var perUnit: [DateOnly: Decimal] = [:]
    var series: [DayRate] = []
    for offset in stride(from: 0, to: 120, by: 7) {
      let day = start.adding(days: offset)
      let rate = Decimal(dice.int(700_000...1_109_999)) / 10_000
      series.append(DayRate(day: day, perUnit: rate))
      for inner in 0..<7 { perUnit[day.adding(days: inner)] = rate }
    }
    let goals = [
      Goal(
        id: id(600), name: "Trip", targetE4: AmountE4(whole: Int64(dice.int(500...3000))),
        monthlyPlanE4: AmountE4(whole: Int64(dice.int(50...400))), subcategoryId: trip,
        currency: .usd),
      Goal(
        id: id(601), name: "Bike", targetE4: AmountE4(whole: Int64(dice.int(20_000...90_000))),
        monthlyPlanE4: AmountE4(whole: Int64(dice.int(1000...9000))), subcategoryId: bike),
    ]
    var entries: [TransactionEntry] = []
    for number in 1...dice.int(5...40) {
      let day = start.adding(days: dice.below(118))
      let at = CalendarContext.utc.startOfDay(day).addingTimeInterval(43_200)
      let inDollars = dice.chance(30)
      let amount = inDollars ? dice.amount(upTo: 300) : dice.amount(upTo: 20_000)
      let rub =
        inDollars
        ? (try? AmountE4(decimal: amount.decimal * (perUnit[day] ?? 90))) ?? amount : amount
      let byGoalId = dice.chance(30)
      let category = dice.pick([trip, bike, id(10)])
      let goalId: UUID? =
        byGoalId && category != id(10) ? (category == trip ? id(600) : id(601)) : nil
      entries.append(
        TransactionEntry(
          transaction: Transaction(
            id: id(number), kind: dice.chance(20) ? .refund : .expense, occurredAt: at,
            currency: inDollars ? .usd : .rub, amountE4: amount, amountRubE4: rub,
            createdAt: at, updatedAt: at),
          parts: [
            TransactionPart(
              id: id(number * 10), transactionId: id(number), categoryId: category,
              amountE4: amount, amountRubE4: rub, goalId: goalId)
          ]))
    }
    return Case(
      goals: goals, entries: entries, rates: DayRates(series: [.usd: series]), perUnit: perUnit)
  }

  /// What the model says a row adds to a goal.
  func modelAmount(
    _ entry: TransactionEntry, to goal: Goal, perUnit: [DateOnly: Decimal]
  ) -> AmountE4 {
    let part = entry.parts[0]
    let belongs =
      part.goalId == goal.id || (part.goalId == nil && part.categoryId == goal.subcategoryId)
    guard belongs else { return .zero }
    let value: AmountE4
    if goal.currency == .rub {
      value = part.amountRubE4
    } else if entry.transaction.currency == goal.currency {
      value = part.amountE4
    } else {
      let day = CalendarContext.utc.day(of: entry.transaction.occurredAt)
      value = (try? AmountE4(decimal: part.amountRubE4.decimal / (perUnit[day] ?? 1))) ?? .zero
    }
    return entry.transaction.kind == .refund ? -value : value
  }

  @Test(arguments: Array(1...60) as [UInt64])
  func eachGoalCountsItsOwnMoney(seed: UInt64) {
    let random = randomCase(seed: seed)
    let ledger = Ledger(
      dataset: Dataset(entries: random.entries, categories: categories, goals: random.goals),
      calendar: .utc)
    for goal in random.goals {
      let counted = AmountE4.sum(
        ledger.rows.compactMap { GoalMath.contribution(of: $0, to: goal, rates: random.rates) })
      let model = AmountE4.sum(
        random.entries.map { modelAmount($0, to: goal, perUnit: random.perUnit) })
      #expect(counted == model, "seed \(seed), \(goal.name)")

      // What each month put into the goal, and the month of the first money: the plan counts
      // from there, what went in above it is credit for the months after.
      var byMonth: [MonthKey: AmountE4] = [:]
      for entry in random.entries {
        let amount = modelAmount(entry, to: goal, perUnit: random.perUnit)
        guard !amount.isZero else { continue }
        byMonth[
          CalendarContext.utc.day(of: entry.transaction.occurredAt).monthKey, default: .zero] +=
          amount
      }
      for monthIndex in 0..<4 {
        let month = MonthKey(year: 2026, month: 1 + monthIndex)
        let thisMonth = byMonth[month] ?? .zero
        let plan = goal.monthlyPlanE4 ?? .zero
        var credit = AmountE4.zero
        if let first = byMonth.keys.min(), first < month {
          for earlier in MonthKey.range(first, through: month.previous) {
            credit = max(.zero, credit + (byMonth[earlier] ?? .zero) - plan)
          }
        }
        let expected = min(
          max(.zero, plan - credit - thisMonth), plan, max(.zero, goal.targetE4 - model))
        let left = GoalMath.planLeft(
          goals: [goal], rows: ledger.rows, month: month, rates: random.rates)
        #expect(left[goal.id] ?? .zero == expected, "seed \(seed), \(goal.name), \(month)")
        #expect((left[goal.id] ?? .zero) <= plan, "seed \(seed)")
      }
    }
  }
}
