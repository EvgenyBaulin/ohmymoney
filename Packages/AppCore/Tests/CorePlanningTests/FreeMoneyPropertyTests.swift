import CoreAccounting
import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CorePlanning

/// The free sum on random books: the money now is the counts plus what moved since, at
/// today's rates; the groups left out of the summary never touch it; a contribution to a goal
/// changes neither figure; the day D stays within a year.
@Suite("The free sum: random books against plain rules")
struct FreeMoneyPropertyTests {
  typealias Fx = CashFx
  typealias Scenario = ReconciliationPropertyTests.Scenario

  static let seeds: [UInt64] = Array(1...20)
  static let inSummary = [
    ReconciliationPropertyTests.mainRub, ReconciliationPropertyTests.cardRub,
    ReconciliationPropertyTests.cardUsd,
  ]

  // MARK: - The money now

  /// Main = Σ over the balances of the summary of (count + what moved after it, up to now),
  /// each converted at today's rate and rounded on its own; Kazakhstan is its own total, not
  /// in it; nothing is waiting to be counted.
  @Test(arguments: seeds)
  func theMoneyNowIsTheCountsPlusWhatMovedAtTodaysRates(_ seed: UInt64) {
    let scenario = Scenario(seed: seed)
    let free = scenario.fx.snapshot().freeMoney
    let rates = scenario.fx.rubPerUnit
    let model = AmountE4.sum(
      Self.inSummary.compactMap { key in
        SubscriptionMath.rubles(
          scenario.expected(key, at: Fx.now), in: key.currency, rubPerUnit: rates)
      })
    #expect(free.state == .ready)
    #expect(free.main == model, "seed \(seed)")
    let kazakhstan = SubscriptionMath.rubles(
      scenario.expected(ReconciliationPropertyTests.freedomKzt, at: Fx.now), in: Fx.tenge,
      rubPerUnit: rates)
    #expect(free.excluded.map(\.group.id) == [Fx.kazakhstan])
    #expect(free.excluded.first?.totalRub == kazakhstan, "seed \(seed)")
    #expect(free.unanchored.isEmpty)
    #expect(free.mainWithoutRate.isEmpty)
  }

  /// Whatever happens on the accounts of a group left out of the summary — spending, income,
  /// money moved between them — the money now does not move, and neither does the grey line.
  @Test(arguments: seeds)
  func aGroupLeftOutNeverTouchesTheFreeSum(_ seed: UInt64) {
    var random = SeededRandom(seed: seed)
    var fx = Scenario(seed: seed).fx
    let before = fx.snapshot().freeMoney
    for _ in 0..<random.int(in: 1...10) {
      let at = Fx.at("2026-09-19", 14).addingTimeInterval(TimeInterval(random.int(in: 0...3_000)))
      let amount = AmountE4(raw: Int64(random.int(in: 1...5_000_000)) * 100).decimal.description
      if random.chance(1, outOf: 2) {
        fx.add(.expense, amount, at: at, currency: Fx.tenge, account: Fx.freedom)
      } else {
        fx.add(
          .income, amount, at: at, currency: Fx.tenge, account: Fx.freedom, category: Fx.salary)
      }
    }
    let after = fx.snapshot().freeMoney
    #expect(after.main == before.main, "seed \(seed)")
    #expect(after.grey == before.grey, "seed \(seed)")
    #expect(after.excluded.first?.totalRub != before.excluded.first?.totalRub)
  }

  /// Money moved between two ruble balances of the summary changes nothing; sent to the group
  /// left out, it leaves the summary by what was sent; received from it, it comes in by what
  /// was received.
  @Test(arguments: seeds)
  func transfersMoveTheMoneyNowOnlyAcrossTheSummary(_ seed: UInt64) {
    var random = SeededRandom(seed: seed)
    let base = Scenario(seed: seed).fx
    let before = base.snapshot().freeMoney.main ?? .zero
    let at = Fx.at("2026-09-19", 14, 30)
    let sent = AmountE4(raw: Int64(random.int(in: 1...5_000_000)) * 100)
    let received = AmountE4(raw: Int64(random.int(in: 1...5_000_000)) * 100)

    var inside = base
    inside.transfers.append(
      Transfer(
        occurredAt: at, fromAccountId: Fx.main, fromCurrency: .rub, fromAmountE4: sent,
        toAccountId: Fx.card, toCurrency: .rub, toAmountE4: sent))
    #expect(inside.snapshot().freeMoney.main == before, "seed \(seed)")

    var out = base
    out.transfers.append(
      Transfer(
        occurredAt: at, fromAccountId: Fx.main, fromCurrency: .rub, fromAmountE4: sent,
        toAccountId: Fx.freedom, toCurrency: Fx.tenge, toAmountE4: received))
    #expect(out.snapshot().freeMoney.main == before - sent, "seed \(seed)")

    var back = base
    back.transfers.append(
      Transfer(
        occurredAt: at, fromAccountId: Fx.freedom, fromCurrency: Fx.tenge, fromAmountE4: sent,
        toAccountId: Fx.main, toCurrency: .rub, toAmountE4: received))
    #expect(back.snapshot().freeMoney.main == before + received, "seed \(seed)")
  }

  /// A rate that moves changes the rubles of a foreign balance and nothing else: the balance
  /// in its own currency stays, the ruble balances stay.
  @Test(arguments: seeds)
  func aRateThatMovesOnlyReconvertsTheForeignMoney(_ seed: UInt64) {
    var fx = Scenario(seed: seed).fx
    let before = fx.snapshot()
    fx.rubPerUnit[.usd] = 100
    let after = fx.snapshot()
    let usd = ReconciliationPropertyTests.cardUsd
    #expect(after.accounts.balances[usd]?.amountE4 == before.accounts.balances[usd]?.amountE4)
    let dollars = before.accounts.balances[usd]?.amountE4 ?? .zero
    let delta =
      SubscriptionMath.rounded(dollars.decimal * 100)
      - SubscriptionMath.rounded(dollars.decimal * 90)
    #expect(after.freeMoney.main == before.freeMoney.main.map { $0 + delta }, "seed \(seed)")
  }

  // MARK: - No count

  /// Nothing counted in the summary — only Kazakhstan, or nothing at all — is «Мало данных:
  /// сделайте первую сверку»: no figure, no guide, the balances of the summary listed as never
  /// counted. The group left out keeps its own total all the same.
  @Test func onlyTheGroupLeftOutCountedIsNoFreeSum() {
    var fx = Fx()
    fx.count([(Fx.freedom, Fx.tenge, "500000")], at: Fx.at("2026-09-10", 9))
    fx.scheduled = [Fx.payment(1, "Rent", "30000", day: 25, next: "2026-09-25")]
    let free = fx.snapshot().freeMoney
    #expect(free.state == .noReconciliation)
    #expect(free.main == nil)
    #expect(free.grey == nil)
    #expect(free.dailyGuide == .zero)
    #expect(
      free.unanchored == [
        BalanceKey(accountId: Fx.main, currency: .rub),
        BalanceKey(accountId: Fx.card, currency: .rub),
        BalanceKey(accountId: Fx.card, currency: .usd),
      ])
    #expect(free.excluded.first?.totalRub == Fx.money("100000"))
  }

  /// A legacy count of one total anchors nothing: after the update, without a count of the
  /// accounts, there is no free sum yet.
  @Test func aLegacyTotalIsNoCount() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-10", 9), kind: .total)
    #expect(fx.snapshot().freeMoney.state == .noReconciliation)
    var opening = Fx()
    opening.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-10", 9), kind: .opening)
    #expect(opening.snapshot().freeMoney.main == Fx.money("100000"))
  }

  // MARK: - D

  /// D is never before today and never more than twelve months ahead, the end of the month
  /// when none is given; the guide divides by the days of [today, D], both included.
  @Test(arguments: seeds)
  func theWindowIsTodayThroughAYearAhead(_ seed: UInt64) {
    var random = SeededRandom(seed: seed)
    for _ in 0..<50 {
      let today = Fx.day("2025-01-01").adding(days: random.int(in: 0...1_500))
      let asked = today.adding(days: random.int(in: -60...500))
      let window = FreeMoney.window(today: today, until: asked)
      let latest = today.adding(months: 12)
      #expect(window.start == today)
      #expect(window.end == min(max(asked, today), latest), "\(today) \(asked)")
      #expect(latest.monthKey == today.monthKey.adding(months: 12))
      #expect(latest.day == min(today.day, PlainCalendar.daysIn(latest.year, latest.month)))
      #expect(FreeMoney.window(today: today, until: nil).end == today.monthKey.lastDay)
    }
    // 29 February: a year ahead is 28 February.
    #expect(
      FreeMoney.window(today: Fx.day("2028-02-29"), until: Fx.day("2030-01-01")).end
        == Fx.day("2029-02-28"))
    // The last day of the month: D is today, one day.
    var fx = Fx()
    fx.count([(Fx.main, .rub, "3000")], at: Fx.at("2026-09-30", 9))
    let last = fx.snapshot(today: Fx.day("2026-09-30"), now: Fx.at("2026-09-30", 12)).freeMoney
    #expect(last.days == 1)
    #expect(last.until == Fx.day("2026-09-30"))
    #expect(last.dailyGuide == Fx.money("3000"))
  }

  /// The guide times the days is the grey line, give or take the rounding of one division.
  @Test(arguments: seeds)
  func theGuideSpreadsTheGreyLineOverTheDays(_ seed: UInt64) {
    var random = SeededRandom(seed: seed)
    var fx = Fx()
    fx.count(
      [
        (
          Fx.main, .rub,
          AmountE4(raw: Int64(random.int(in: 1...90_000_000)) * 100).decimal.description
        )
      ],
      at: Fx.at("2026-09-10", 9))
    let until = Fx.today.adding(days: random.int(in: 0...365))
    let free = fx.snapshot().freeMoney(until: until, ledger: fx.ledger)
    guard let grey = free.grey else {
      Issue.record("seed \(seed): counted")
      return
    }
    let spread = free.dailyGuide.raw * Int64(free.days)
    #expect(abs(spread - grey.raw) <= Int64(free.days), "seed \(seed)")
  }

  // MARK: - Goals

  /// For any goal, plan, savings and D: a contribution within this month's plan and within
  /// what the goal still needs changes neither the money now nor the grey line — the money
  /// stays on the account and moves from «план» to «накоплено» — and lowers what can be spent
  /// now by itself. Money saved in earlier months is never free.
  @Test(arguments: seeds)
  func aContributionWithinThePlanChangesNeitherFigure(_ seed: UInt64) {
    var random = SeededRandom(seed: seed)
    for _ in 0..<5 {
      var fx = Fx()
      fx.count([(Fx.main, .rub, "500000")], at: Fx.at("2026-08-01", 9))
      let planWhole = random.int(in: 1...50) * 1_000
      let plan = AmountE4(whole: Int64(planWhole))
      let target = AmountE4(whole: Int64(random.int(in: 1...400) * 1_000))
      // The plan counts from September: what was saved in August is no credit towards it.
      let goal = Goal(
        id: Fx.id(401), name: "Trip", targetE4: target, monthlyPlanE4: plan,
        subcategoryId: Fx.tripGoal, planStartMonth: MonthKey(year: 2026, month: 9))
      fx.goals = [goal]
      // Saved in August, and some of September's plan already put aside.
      let august = AmountE4(whole: Int64(random.int(in: 0...100) * 1_000))
      if august.raw > 0 {
        fx.add(
          .expense, august.decimal.description, at: Fx.at("2026-08-20", 12),
          category: Fx.tripGoal, goal: goal.id)
      }
      let early = AmountE4(whole: Int64(random.int(in: 0...planWhole)))
      if early.raw > 0 {
        fx.add(
          .expense, early.decimal.description, at: Fx.at("2026-09-02", 12),
          category: Fx.tripGoal, goal: goal.id)
      }
      let until = Fx.today.adding(days: random.int(in: 0...365))
      let before = fx.snapshot().freeMoney(until: until, ledger: fx.ledger)
      // Within the rest of this month's plan and within what the goal still needs.
      let room = min(plan - early, max(.zero, target - august - early))
      guard room.raw > 0 else { continue }
      let contribution = AmountE4(raw: Int64(random.int(in: 1...Int(room.raw / 100))) * 100)
      fx.add(
        .expense, contribution.decimal.description, at: Fx.at("2026-09-19", 10),
        category: Fx.tripGoal, goal: goal.id)
      let after = fx.snapshot().freeMoney(until: until, ledger: fx.ledger)
      // Goal money is not spendable: what can be spent now falls by the contribution, while
      // the money now and the grey line — the plan now paid — stay.
      #expect(after.moneyNow == before.moneyNow, "seed \(seed)")
      #expect(after.main == before.main.map { $0 - contribution }, "seed \(seed)")
      #expect(after.grey == before.grey, "seed \(seed): plan \(plan), +\(contribution)")
      #expect(after.plan.goalSavings == before.plan.goalSavings + contribution)
      #expect(after.plan.goalPlans == before.plan.goalPlans - contribution)
    }
  }

  /// With goal money kept on an account out of the summary (the switch off), what is saved is
  /// not subtracted — it left the summary when it was moved there: the contribution and the
  /// transfer of the same money together leave the grey line where it was.
  @Test func goalMoneyMovedOutOfTheSummaryIsNotSubtractedTwice() {
    var fx = Fx()
    fx.settings.reconcileIncludesGoalSavings = false
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-01", 9))
    fx.goals = [
      Goal(
        id: Fx.id(401), name: "Trip", targetE4: Fx.money("1000000"),
        monthlyPlanE4: Fx.money("10000"), subcategoryId: Fx.tripGoal)
    ]
    let before = fx.snapshot().freeMoney
    #expect(before.grey == Fx.money("90000"))
    fx.add(.expense, "10000", at: Fx.at("2026-09-19", 10), category: Fx.tripGoal, goal: Fx.id(401))
    fx.transfers.append(
      Transfer(
        occurredAt: Fx.at("2026-09-19", 10), fromAccountId: Fx.main, fromCurrency: .rub,
        fromAmountE4: Fx.money("10000"), toAccountId: Fx.freedom, toCurrency: Fx.tenge,
        toAmountE4: Fx.money("50000")))
    let after = fx.snapshot().freeMoney
    #expect(after.main == Fx.money("90000"))
    #expect(after.grey == Fx.money("90000"))
    #expect(after.goalSavings == .zero)
  }

  /// A goal in dollars fed from a ruble account: 9 000 ₽ on a day a dollar was 90 is 100 $ of
  /// progress for good — a dollar at 100 later does not make it 90 $. What is saved comes off
  /// the grey line at today's rate: 100 $ × 100 = 10 000 ₽ today.
  @Test func aDollarGoalCountsAContributionAtTheRateOfItsDay() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-01", 9))
    let goal = Goal(
      id: Fx.id(402), name: "Camera", targetE4: Fx.money("1000"),
      monthlyPlanE4: Fx.money("100"), subcategoryId: Fx.tripGoal, currency: .usd)
    fx.goals = [goal]
    fx.add(.expense, "9000", at: Fx.at("2026-09-05", 12), category: Fx.tripGoal, goal: goal.id)
    let rates = DayRates(series: [
      .usd: [
        DayRate(day: Fx.day("2026-09-05"), perUnit: 90),
        DayRate(day: Fx.day("2026-09-19"), perUnit: 100),
      ]
    ])
    let snapshot = PlanningSnapshot.build(
      ledger: fx.ledger, today: Fx.today, now: Fx.now, rubPerUnit: [.usd: 100], dayRates: rates)
    let status = snapshot.goals.first
    #expect(status?.saved == Fx.money("100"))
    #expect(status?.contributedThisMonth == Fx.money("100"))
    #expect(status?.savedRubToday == Fx.money("10000"))
    // The plan of September is met; nothing more is asked this month.
    #expect(snapshot.freeMoney.plan.goalPlans == .zero)
    #expect(snapshot.freeMoney.plan.goalSavings == Fx.money("10000"))
  }

  /// A goal archived is no goal of the plan: its savings and plans leave the grey line.
  @Test func anArchivedGoalLeavesTheGreyLine() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-01", 9))
    fx.goals = [
      Goal(
        id: Fx.id(401), name: "Trip", targetE4: Fx.money("50000"),
        monthlyPlanE4: Fx.money("10000"), subcategoryId: Fx.tripGoal, archived: true)
    ]
    fx.add(.expense, "5000", at: Fx.at("2026-08-10", 12), category: Fx.tripGoal, goal: Fx.id(401))
    let free = fx.snapshot().freeMoney
    #expect(free.plan.goalSavings == .zero)
    #expect(free.plan.goalPlans == .zero)
    #expect(free.grey == free.main)
  }
}
