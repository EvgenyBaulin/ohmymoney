import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// Goals in a currency of their own: progress in the goal's currency, a contribution in
/// another currency at the rate of its own day, rubles only at today's rate.
@Suite("Goals in a currency: progress, plans and rubles")
struct GoalCurrencyTests: SavingsFixtures {
  let today = DateOnly(year: 2026, month: 9, day: 19)
  let kzt = CurrencyCode("KZT")

  /// Rates as the Bank of Russia quotes them, turned into rubles for one unit the way the app
  /// builds its `DayRates`.
  func dayRates(_ rates: [Rate]) -> DayRates {
    var series: [CurrencyCode: [DayRate]] = [:]
    for rate in rates {
      series[rate.currency, default: []].append(DayRate(day: rate.date, perUnit: rate.perUnit))
    }
    return DayRates(series: series)
  }

  func goal(
    _ currency: CurrencyCode, target: String = "100000", plan: String? = nil,
    book: SavingsBook, date: String? = nil
  ) -> Goal {
    Goal(
      id: uid(700), name: "Trip", targetE4: rub(target), targetDate: date.map(self.date),
      monthlyPlanE4: plan.map(rub), subcategoryId: book.carSubcategory, currency: currency)
  }

  func status(
    _ goal: Goal, _ book: SavingsBook, rates: DayRates, rubPerUnit: [CurrencyCode: Decimal] = [:],
    canSave: AmountE4? = nil
  ) throws -> GoalStatus {
    var book = book
    book.goals = [goal]
    let statuses = GoalRules.statuses(
      goals: [goal], ledger: book.ledger, today: today, canSaveP50: canSave, rates: rates,
      rubPerUnit: rubPerUnit)
    return try #require(statuses.first)
  }

  /// The bank quotes 100 tenge at 18.5 ₽: one tenge is 0.185 ₽. 1 000 ₽ put into a tenge goal
  /// are 1 000 ÷ 0.185 = 5 405.4054 ₸ — not 1 000 ÷ 18.5 = 54.05 ₸, which the rate as quoted
  /// would give. Tenge put in count as they are.
  @Test func aTengeRateUsesItsNominal() throws {
    var book = SavingsBook()
    let goal = goal(kzt, book: book)
    book.contribute("2026-09-05", "1000", goal: goal.id)
    book.add(
      .expense, "2026-09-06", "20000", category: book.carSubcategory, goal: goal.id,
      currency: kzt, rubles: "3700")
    let rates = dayRates([
      Rate(
        date: date("2026-09-01"), currency: kzt, rubPerUnit: Decimal(string: "18.5")!,
        nominal: 100)
    ])

    let status = try status(goal, book, rates: rates, rubPerUnit: [kzt: Decimal(string: "0.2")!])
    #expect(status.currency == kzt)
    #expect(status.saved == rub("25405.4054"))
    #expect(status.contributedThisMonth == rub("25405.4054"))
    #expect(status.remaining == rub("74594.5946"))
    #expect(status.withoutRate == 0)
    // Shown in rubles at today's rate, 0.2 ₽ a tenge.
    #expect(status.savedRubToday == rub("5081.0811"))

    let row = try #require(book.ledger.rows.first { $0.currency == .rub })
    #expect(GoalMath.contribution(of: row, to: goal, rates: rates) == rub("5405.4054"))
    #expect(GoalRules.contribution(of: row, to: goal, rates: rates) == rub("5405.4054"))
  }

  /// 9 000 ₽ in August at 90 ₽ and 9 500 ₽ in September at 95 ₽ are 100 $ each: the rate of
  /// the day the money went in, whatever the rate is now. A withdrawal comes off the same
  /// way, and dollars put in count as dollars.
  @Test func aContributionCountsAtTheRateOfItsOwnDay() throws {
    var book = SavingsBook()
    let goal = goal(.usd, target: "1000", book: book)
    book.contribute("2026-08-10", "9000", goal: goal.id)
    book.contribute("2026-09-05", "9500", goal: goal.id)
    book.add(
      .expense, "2026-09-07", "50", category: book.carSubcategory, goal: goal.id,
      currency: .usd, rubles: "4800")
    book.withdraw("2026-09-10", "1900", goal: goal.id)
    let rates = DayRates(series: [
      .usd: [
        DayRate(day: date("2026-08-10"), perUnit: 90),
        DayRate(day: date("2026-09-01"), perUnit: 95),
      ]
    ])

    let status = try status(goal, book, rates: rates, rubPerUnit: [.usd: 100])
    // 100 + 100 + 50 − 20.
    #expect(status.saved == rub("230"))
    #expect(status.contributedThisMonth == rub("130"))
    #expect(status.remaining == rub("770"))
    #expect(status.progressBp == 2_300)
    #expect(status.savedRubToday == rub("23000"))
    #expect(status.rubles(rub("770")) == rub("77000"))

    // A later rate changes nothing counted before it.
    let moved = DayRates(series: [
      .usd: [
        DayRate(day: date("2026-08-10"), perUnit: 90),
        DayRate(day: date("2026-09-01"), perUnit: 95),
        DayRate(day: date("2026-09-15"), perUnit: 120),
      ]
    ])
    let later = try self.status(goal, book, rates: moved, rubPerUnit: [.usd: 120])
    #expect(later.saved == rub("230"))
  }

  /// No rate of the goal's currency at all: the ruble contribution is left out and counted,
  /// the dollars still count, and nothing is shown in rubles without today's rate.
  @Test func aRowWithoutAnyRateIsLeftOutAndSaidSo() throws {
    var book = SavingsBook()
    let goal = goal(.usd, target: "1000", book: book)
    book.contribute("2026-09-05", "9500", goal: goal.id)
    book.add(
      .expense, "2026-09-07", "50", category: book.carSubcategory, goal: goal.id,
      currency: .usd, rubles: "4800")

    let status = try status(goal, book, rates: .empty)
    #expect(status.saved == rub("50"))
    #expect(status.withoutRate == 1)
    #expect(status.savedRubToday == nil)
    #expect(status.rubles(rub("1")) == nil)
  }

  /// A ruble goal counts rubles as it always did — a contribution in dollars by its rubles —
  /// and needs no rate for anything.
  @Test func aRubleGoalIsAsBefore() throws {
    var book = SavingsBook()
    let goal = goal(.rub, book: book)
    book.contribute("2026-09-05", "1000", goal: goal.id)
    book.add(
      .expense, "2026-09-07", "50", category: book.carSubcategory, goal: goal.id,
      currency: .usd, rubles: "4800")

    let status = try status(goal, book, rates: .empty)
    #expect(status.saved == rub("5800"))
    #expect(status.savedRubToday == rub("5800"))
    #expect(status.rubPerUnit == 1)
    #expect(status.withoutRate == 0)
    let dollars = try #require(book.ledger.rows.first { $0.currency == .usd })
    #expect(GoalMath.contribution(of: dollars, to: goal, rates: .empty) == rub("4800"))
  }

  /// «Can save» is in rubles: the goal's 100 $ a month is 9 500 ₽ at today's 95 ₽.
  @Test func canSaveIsComparedInRublesAtTodaysRate() throws {
    let book = SavingsBook()
    let goal = goal(.usd, target: "400", book: book, date: "2026-12-31")
    let rates = DayRates(series: [.usd: [DayRate(day: date("2026-09-01"), perUnit: 95)]])

    let short = try status(goal, book, rates: rates, rubPerUnit: [.usd: 95], canSave: rub("9000"))
    #expect(short.neededMonthly == rub("100"))
    #expect(short.coveredByCanSave == false)
    let enough = try status(
      goal, book, rates: rates, rubPerUnit: [.usd: 95], canSave: rub("9500"))
    #expect(enough.coveredByCanSave == true)
    let unknown = try status(goal, book, rates: rates, canSave: rub("1000000"))
    #expect(unknown.coveredByCanSave == nil)
  }

  /// The plan of a dollar goal asks dollars: 100 $ a month, 40 $ in already (3 800 ₽ at
  /// 95 ₽), 60 $ left. The planned month shows them in dollars with 5 700 ₽ as my share at
  /// today's 95 ₽, and the forecast adds the same rubles; without today's rate both leave the
  /// goal out and say so.
  @Test func thePlanOfAGoalIsInItsCurrencyAndItsRublesAgree() throws {
    var book = SavingsBook()
    let goal = goal(.usd, target: "1000", plan: "100", book: book)
    book.goals = [goal]
    book.contribute("2026-09-05", "3800", goal: goal.id)
    let rates = DayRates(series: [.usd: [DayRate(day: date("2026-09-01"), perUnit: 95)]])
    let ledger = book.ledger

    #expect(
      GoalRules.planStillDue(goals: [goal], ledger: ledger, today: today, rates: rates)
        == [goal.id: rub("60")])

    let month = PlannedMonth.build(
      ledger: ledger, book: .empty, today: today, rubPerUnit: [.usd: 95], dayRates: rates)
    let item = try #require(month.items.first { $0.kind == .goal })
    #expect(item.currency == .usd)
    #expect(item.amount == rub("60"))
    #expect(item.myShareRub == rub("5700"))
    #expect(month.goals == rub("5700"))
    #expect(month.byCategory[book.carSubcategory] == rub("5700"))
    let forecast = PlannedPayments(
      ledger: ledger, today: today, rubPerUnit: [.usd: 95], dayRates: rates)
    #expect(forecast.goals == month.goals)
    #expect(forecast.goalsWithoutRate.isEmpty)

    let snapshot = PlanningSnapshot.build(
      ledger: ledger, today: today, now: noon("2026-09-19"), rubPerUnit: [.usd: 95],
      dayRates: rates)
    #expect(snapshot.goalReserve == rub("5700"))
    #expect(snapshot.goals.first?.saved == rub("40"))
    #expect(snapshot.dayRates == rates)

    let noRate = PlannedMonth.build(ledger: ledger, book: .empty, today: today, dayRates: rates)
    #expect(noRate.goals == .zero)
    #expect(noRate.withoutRate == [goal.id])
    #expect(noRate.items.first { $0.kind == .goal }?.myShareRub == nil)
    let forecastNoRate = PlannedPayments(ledger: ledger, today: today, dayRates: rates)
    #expect(forecastNoRate.goals == .zero)
    #expect(forecastNoRate.goalsWithoutRate == [goal.id])
  }

  /// A contribution to a dollar goal can be written in dollars; rubles stay the default.
  @Test func aContributionCanBeWrittenInTheGoalsCurrency() {
    let book = SavingsBook()
    let goal = goal(.usd, book: book)
    let dollars = GoalRules.contributionDraft(
      goal: goal, subcategoryId: book.carSubcategory, amount: rub("50"),
      occurredAt: noon("2026-09-05"), currency: .usd)
    #expect(dollars.currency == .usd)
    let rubles = GoalRules.withdrawalDraft(
      goal: goal, subcategoryId: book.carSubcategory, amount: rub("50"),
      occurredAt: noon("2026-09-05"))
    #expect(rubles.currency == .rub)
  }
}
