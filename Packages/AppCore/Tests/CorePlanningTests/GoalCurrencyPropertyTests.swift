import CoreAccounting
import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CorePlanning

/// Goals in several currencies on random books of contributions and withdrawals in any
/// currency: what is saved is counted in the goal's currency — a row in that currency with its
/// own amount, a ruble goal in rubles, any other row by its rubles at the rate of its own day
/// (the latest rate on or before that day, the bank being closed at weekends; the first one
/// known for a day before any) —, a withdrawal takes off, a row whose currency has no rate at
/// all is skipped and counted, and the free sum holds back what is saved at today's rate.
@Suite("Goal currencies on random books")
struct GoalCurrencyPropertyTests {
  typealias Fx = CashFx

  static let seeds: [UInt64] = Array(1...25)
  static let goalIds = (0..<4).map { CashFx.id(460 + $0) }
  /// Rubles, dollars, tenge and euros; no rate of euros is known on any day.
  static let currencies: [CurrencyCode] = [.rub, .usd, CashFx.tenge, .eur]

  struct Book {
    var fx = CashFx()
    var rates: DayRates
    var series: [CurrencyCode: [DayRate]] = [:]
    /// Signed rows by goal: (day, currency, amount, rubles).
    var rows: [UUID: [(DateOnly, CurrencyCode, AmountE4, AmountE4, Bool)]] = [:]

    init(seed: UInt64) {
      var random = SeededRandom(seed: seed)
      // Dollars on weekdays only; tenge every third day; both from 1 June.
      var usd: [DayRate] = []
      var kzt: [DayRate] = []
      for offset in 0...110 {
        let day = CashFx.day("2026-06-01").adding(days: offset)
        if day.weekday <= 5 {
          usd.append(DayRate(day: day, perUnit: Decimal(random.int(in: 8_500...9_500)) / 100))
        }
        if offset % 3 == 0 {
          kzt.append(DayRate(day: day, perUnit: Decimal(random.int(in: 18...22)) / 100))
        }
      }
      series = [.usd: usd, CashFx.tenge: kzt]
      rates = DayRates(series: series)

      for (index, id) in GoalCurrencyPropertyTests.goalIds.enumerated() {
        fx.goals.append(
          Goal(
            id: id, name: "Goal \(index)", targetE4: CashFx.money("1000000"),
            subcategoryId: CashFx.tripGoal,
            currency: GoalCurrencyPropertyTests.currencies[index]))
      }
      for _ in 0..<random.int(in: 5...30) {
        let goal = random.choice(from: GoalCurrencyPropertyTests.goalIds)
        let currency = random.choice(from: GoalCurrencyPropertyTests.currencies)
        // Some days before the first rate, some on weekends, most in between.
        let day = CashFx.day("2026-05-25").adding(days: random.int(in: 0...116))
        let amount = AmountE4(raw: Int64(random.int(in: 1...500_000)) * 100)
        let perUnit = Self.rate(series, currency, on: day) ?? 100
        let rubles = currency == .rub ? amount : SubscriptionMath.rounded(amount.decimal * perUnit)
        let withdrawal = random.chance(1, outOf: 5)
        let id = fx.add(
          withdrawal ? .refund : .expense, amount.decimal.description,
          at: CalendarContext.utc.noon(of: day), currency: currency, category: CashFx.tripGoal,
          goal: goal)
        if let index = fx.entries.firstIndex(where: { $0.id == id }) {
          fx.entries[index].transaction.amountRubE4 = rubles
          fx.entries[index].parts[0].amountRubE4 = rubles
          if withdrawal {
            fx.entries[index].parts[0].quality = nil
            fx.entries[index].parts[0].qualitySource = nil
          }
        }
        rows[goal, default: []].append((day, currency, amount, rubles, withdrawal))
      }
      fx.count([(CashFx.main, .rub, "1000000")], at: CashFx.at("2026-09-01", 9))
      fx.settings.reserveGoalPlan = false
    }

    /// The rate of a day: the latest on or before it, else the first known.
    static func rate(
      _ series: [CurrencyCode: [DayRate]], _ currency: CurrencyCode, on day: DateOnly
    ) -> Decimal? {
      if currency == .rub { return 1 }
      guard let known = series[currency], let first = known.first else { return nil }
      return known.last { $0.day <= day }?.perUnit ?? first.perUnit
    }

    /// What is saved in `goal`, and how many rows were skipped for want of a rate.
    func saved(_ goal: Goal) -> (AmountE4, Int) {
      var total = AmountE4.zero
      var skipped = 0
      for (day, currency, amount, rubles, withdrawal) in rows[goal.id] ?? [] {
        let value: AmountE4
        if goal.currency == .rub {
          value = rubles
        } else if currency == goal.currency {
          value = amount
        } else if let perUnit = Self.rate(series, goal.currency, on: day) {
          value = SubscriptionMath.rounded(rubles.decimal / perUnit)
        } else {
          skipped += 1
          continue
        }
        total += withdrawal ? -value : value
      }
      return (total, skipped)
    }

    func snapshot() -> PlanningSnapshot {
      PlanningSnapshot.build(
        ledger: fx.ledger, today: CashFx.today, now: CashFx.now, rubPerUnit: fx.rubPerUnit,
        dayRates: rates)
    }
  }

  /// Every goal's saved amount and its skipped rows are the model's; what the free sum holds
  /// back is Σ of what is saved, at today's rate, over the goals with money in them — a goal
  /// whose currency has no rate today named instead of guessed.
  @Test(arguments: seeds)
  func whatIsSavedIsCountedInTheGoalsCurrency(_ seed: UInt64) {
    let book = Book(seed: seed)
    let snapshot = book.snapshot()
    var held = AmountE4.zero
    var missing = false
    for goal in book.fx.goals {
      let status = snapshot.goals.first { $0.goal.id == goal.id }
      let (saved, skipped) = book.saved(goal)
      #expect(status?.saved == saved, "seed \(seed), \(goal.currency)")
      #expect(status?.withoutRate == skipped, "seed \(seed), \(goal.currency)")
      guard saved.raw > 0 else { continue }
      if let rubles = SubscriptionMath.rubles(
        saved, in: goal.currency, rubPerUnit: book.fx.rubPerUnit)
      {
        held += rubles
      } else {
        missing = true
      }
    }
    #expect(snapshot.freeMoney.plan.goalSavings == held, "seed \(seed)")
    #expect(snapshot.freeMoney.plan.withoutRate.contains(.eur) == missing, "seed \(seed)")
  }

  /// A contribution to a dollar goal made on Saturday 12 September counts at Friday's rate:
  /// 9 000 ₽ at 90 is 100 $, whatever Monday's rate. One made before the first rate known
  /// counts at that first rate.
  @Test func aWeekendContributionCountsAtFridaysRate() {
    var fx = Fx()
    fx.goals = [
      Goal(
        id: Fx.id(470), name: "Camera", targetE4: Fx.money("1000"),
        subcategoryId: Fx.tripGoal, currency: .usd)
    ]
    fx.add(.expense, "9000", at: Fx.at("2026-09-12", 12), category: Fx.tripGoal, goal: Fx.id(470))
    fx.add(.expense, "8000", at: Fx.at("2026-05-20", 12), category: Fx.tripGoal, goal: Fx.id(470))
    let rates = DayRates(series: [
      .usd: [
        DayRate(day: Fx.day("2026-06-01"), perUnit: 80),
        DayRate(day: Fx.day("2026-09-11"), perUnit: 90),
        DayRate(day: Fx.day("2026-09-14"), perUnit: 120),
      ]
    ])
    let snapshot = PlanningSnapshot.build(
      ledger: fx.ledger, today: Fx.today, now: Fx.now, rubPerUnit: fx.rubPerUnit,
      dayRates: rates)
    #expect(snapshot.goals.first?.saved == Fx.money("200"))
  }

  /// Taken out of a goal, money comes off what is saved — and so off what the free sum holds
  /// back: 30 000 put in and 12 000 taken out is 18 000.
  @Test func aWithdrawalComesOffWhatIsSaved() {
    var fx = Fx()
    fx.settings.reserveGoalPlan = false
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-01", 9))
    fx.goals = [
      Goal(
        id: Fx.id(471), name: "Sofa", targetE4: Fx.money("50000"), subcategoryId: Fx.tripGoal)
    ]
    fx.add(.expense, "30000", at: Fx.at("2026-08-05", 12), category: Fx.tripGoal, goal: Fx.id(471))
    let out = fx.add(
      .refund, "12000", at: Fx.at("2026-09-10", 12), category: Fx.tripGoal, goal: Fx.id(471))
    if let index = fx.entries.firstIndex(where: { $0.id == out }) {
      fx.entries[index].parts[0].quality = nil
      fx.entries[index].parts[0].qualitySource = nil
    }
    let snapshot = fx.snapshot()
    #expect(snapshot.goals.first?.saved == Fx.money("18000"))
    #expect(snapshot.freeMoney.plan.goalSavings == Fx.money("18000"))
    // Money taken out of a goal stays on the account, as money put in did; what is still in
    // the goal is not spendable.
    #expect(snapshot.freeMoney.moneyNow == Fx.money("100000"))
    #expect(snapshot.freeMoney.main == Fx.money("82000"))
  }

  /// The random books reach every case: rows in the goal's own currency and in others, rows
  /// before the first rate and on weekends, withdrawals, rows skipped for want of a rate.
  @Test func theBooksReachEveryCase() {
    var own = 0
    var other = 0
    var weekend = 0
    var early = 0
    var withdrawals = 0
    var skipped = 0
    for seed in Self.seeds {
      let book = Book(seed: seed)
      for goal in book.fx.goals {
        for row in book.rows[goal.id] ?? [] {
          if row.1 == goal.currency { own += 1 } else { other += 1 }
          if row.0.weekday > 5 { weekend += 1 }
          if row.0 < Fx.day("2026-06-01") { early += 1 }
          if row.4 { withdrawals += 1 }
        }
        skipped += book.saved(goal).1
      }
    }
    for (name, count) in [
      ("own", own), ("other", other), ("weekend", weekend), ("early", early),
      ("withdrawals", withdrawals), ("skipped", skipped),
    ] {
      #expect(count >= 5, "\(name)")
    }
  }
}
