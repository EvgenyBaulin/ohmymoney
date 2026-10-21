import CoreAccounting
import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CorePlanning

/// «Ещё ждём до D»: what the expected income still waits for from the 1st of this month
/// through D — shown under the free sum and never added to it. Monthly on the last day,
/// weekly, yearly on 29 February, months and a year ahead.
@Suite("Income still expected until D")
struct StillExpectedPropertyTests {
  typealias Fx = CashFx

  static let seeds: [UInt64] = Array(1...30)

  /// The due dates of a recurring expectation from its first one through `last`, by the
  /// calendar: the first as stored; then every month on its day (the last day of a shorter
  /// month), every week on its weekday, every year in the first one's month.
  static func dues(of income: ExpectedIncome, through last: DateOnly) -> [DateOnly] {
    guard let first = income.dueDate, first <= last else { return [] }
    var result = [first]
    var step = 1
    while true {
      let due: DateOnly
      switch income.freq ?? .monthly {
      case .monthly:
        let month = first.monthKey.adding(months: step)
        due = DateOnly(
          year: month.year, month: month.month,
          day: min(income.day ?? first.day, PlainCalendar.daysIn(month.year, month.month)))
      case .weekly:
        due = first.weekStart.adding(days: 7 * step + (income.day ?? first.weekday) - 1)
      case .yearly:
        let year = first.year + step
        due = DateOnly(
          year: year, month: first.month,
          day: min(income.day ?? first.day, PlainCalendar.daysIn(year, first.month)))
      }
      guard due <= last else { break }
      result.append(due)
      step += 1
    }
    return result
  }

  /// Nothing came yet: every due date from the 1st of this month through D is waited for in
  /// full, dollars at today's rate; euros, which have no rate, are listed instead.
  @Test(arguments: seeds)
  func everyDueDateThroughDIsWaitedFor(_ seed: UInt64) {
    var random = SeededRandom(seed: seed)
    var fx = Fx()
    fx.count([(Fx.main, .rub, "1000")], at: Fx.at("2026-09-01", 9))
    var model = AmountE4.zero
    var withoutRate: Set<UUID> = []
    let until = Fx.today.adding(days: random.int(in: 0...365))
    for index in 0..<random.int(in: 1...4) {
      let freq = random.choice(from: [Frequency.weekly, .monthly, .yearly])
      let first = Fx.day("2025-10-01").adding(days: random.int(in: 0...600))
      var income = ExpectedIncome(
        id: Fx.id(600 + index), name: "Income \(index)", categoryId: Fx.salary,
        kind: .recurring, totalE4: AmountE4(whole: Int64(random.int(in: 1...200) * 1_000)),
        freq: freq)
      switch freq {
      case .weekly:
        let weekday = random.int(in: 1...7)
        income.day = weekday
        income.dueDate = first.weekStart.adding(days: weekday - 1)
      case .monthly:
        let day = random.chance(1, outOf: 2) ? 31 : random.int(in: 1...31)
        income.day = day
        income.dueDate = DateOnly(
          year: first.year, month: first.month,
          day: min(day, PlainCalendar.daysIn(first.year, first.month)))
      case .yearly:
        let month = random.chance(1, outOf: 3) ? 2 : random.int(in: 1...12)
        let day = month == 2 ? 29 : random.int(in: 1...28)
        income.day = day
        let year = random.chance(1, outOf: 2) ? 2026 : 2027
        income.dueDate = DateOnly(
          year: year, month: month, day: min(day, PlainCalendar.daysIn(year, month)))
      }
      switch random.int(in: 0...5) {
      case 0: income.currency = .usd
      case 1: income.currency = .eur
      default: break
      }
      fx.expected.append(income)
      let waited = Self.dues(of: income, through: until).filter {
        $0 >= Fx.today.monthKey.firstDay
      }
      guard !waited.isEmpty else { continue }
      switch income.currency {
      case .rub: model += SubscriptionMath.rounded(income.totalE4.decimal * Decimal(waited.count))
      case .usd:
        model += AmountE4.sum(
          Array(
            repeating: SubscriptionMath.rounded(income.totalE4.decimal * 90),
            count: waited.count))
      default: withoutRate.insert(income.id)
      }
    }
    let free = fx.snapshot().freeMoney(until: until, ledger: fx.ledger)
    #expect(free.info.first?.amount == model, "seed \(seed), D \(until)")
    #expect(Set(free.stillExpectedWithoutRate) == withoutRate, "seed \(seed)")
    // Never added: the grey line is the money now less the plan, whatever is expected.
    #expect(free.grey == free.main.map { $0 - free.plan.total })
  }

  /// A salary of 100 000 on the last day of the month: waited for on 30 September, 31 October,
  /// 30 November, 31 December, 31 January, 28 February and 31 March — seven salaries through
  /// the end of March.
  @Test func aSalaryOnTheLastDayThroughFebruary() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "1000")], at: Fx.at("2026-09-01", 9))
    fx.expected = [
      ExpectedIncome(
        id: Fx.id(601), name: "Salary", categoryId: Fx.salary, kind: .recurring,
        totalE4: Fx.money("100000"), dueDate: Fx.day("2026-01-31"), freq: .monthly, day: 31)
    ]
    let snapshot = fx.snapshot()
    for (until, salaries) in [
      ("2026-09-29", 0), ("2026-09-30", 1), ("2027-02-27", 5), ("2027-02-28", 6),
      ("2027-03-31", 7),
    ] {
      let free = snapshot.freeMoney(until: Fx.day(until), ledger: fx.ledger)
      #expect(
        free.info.first?.amount == AmountE4(whole: Int64(100_000 * salaries)), "\(until)")
    }
  }

  /// A yearly bonus on 29 February: in a common year the 28th, and a year ahead reaches it —
  /// from 19 September 2027 D reaches 29 February 2028.
  @Test func aYearlyBonusOnTheLastDayOfFebruary() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "1000")], at: Fx.at("2026-09-01", 9))
    fx.expected = [
      ExpectedIncome(
        id: Fx.id(602), name: "Bonus", categoryId: Fx.salary, kind: .recurring,
        totalE4: Fx.money("50000"), dueDate: Fx.day("2026-02-28"), freq: .yearly, day: 29)
    ]
    let snapshot = fx.snapshot(today: Fx.day("2027-09-19"), now: Fx.at("2027-09-19", 12))
    let before = snapshot.freeMoney(until: Fx.day("2028-02-28"), ledger: fx.ledger)
    #expect(before.info.first?.amount == .zero)
    let on = snapshot.freeMoney(until: Fx.day("2028-02-29"), ledger: fx.ledger)
    #expect(on.info.first?.amount == Fx.money("50000"))
    // The common year before: the 28th.
    let common = fx.snapshot(today: Fx.day("2026-09-19"), now: Fx.now)
      .freeMoney(until: Fx.day("2027-02-28"), ledger: fx.ledger)
    #expect(common.info.first?.amount == Fx.money("50000"))
  }

  /// What came for this month's salary is not waited for, the rest is; a payment already
  /// written for a later day has not come yet and is waited for until its day, within D.
  @Test func whatCameIsNotWaitedForAndWhatIsWrittenAheadIs() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "1000")], at: Fx.at("2026-09-01", 9))
    let salary = ExpectedIncome(
      id: Fx.id(601), name: "Salary", categoryId: Fx.salary, kind: .recurring,
      totalE4: Fx.money("100000"), dueDate: Fx.day("2026-01-10"), freq: .monthly, day: 10)
    fx.expected = [salary]
    // 60 000 came on the 10th; October's 100 000 is written ahead for 9 October.
    let came = fx.add(.income, "60000", at: Fx.at("2026-09-10", 10), category: Fx.salary)
    let ahead = fx.add(.income, "100000", at: Fx.at("2026-10-09", 10), category: Fx.salary)
    fx.expectedLinks = [
      ExpectedIncomeLink(expectedIncomeId: salary.id, transactionId: came),
      ExpectedIncomeLink(expectedIncomeId: salary.id, transactionId: ahead),
    ]
    let snapshot = fx.snapshot()
    #expect(snapshot.freeMoney.info.first?.amount == Fx.money("40000"))
    let october = snapshot.freeMoney(until: Fx.day("2026-10-31"), ledger: fx.ledger)
    #expect(october.info.first?.amount == Fx.money("140000"))
    let beforeItsDay = snapshot.freeMoney(until: Fx.day("2026-10-08"), ledger: fx.ledger)
    #expect(beforeItsDay.info.first?.amount == Fx.money("40000"))
  }

  /// A salary of August never paid is not waited for any more — it is overdue, not money
  /// coming — and a closed expectation waits for nothing.
  @Test func anOldUnpaidDueAndAClosedExpectationAreNotWaitedFor() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "1000")], at: Fx.at("2026-09-01", 9))
    fx.expected = [
      ExpectedIncome(
        id: Fx.id(601), name: "Salary", categoryId: Fx.salary, kind: .recurring,
        totalE4: Fx.money("100000"), dueDate: Fx.day("2026-08-05"), freq: .monthly, day: 5),
      ExpectedIncome(
        id: Fx.id(602), name: "Old project", categoryId: Fx.salary,
        totalE4: Fx.money("30000"), dueDate: Fx.day("2026-08-20")),
      ExpectedIncome(
        id: Fx.id(603), name: "Closed", categoryId: Fx.salary, totalE4: Fx.money("70000"),
        dueDate: Fx.day("2026-09-25"), closed: true),
    ]
    let free = fx.snapshot().freeMoney
    // September's salary only: August's and the old project are overdue, the closed one
    // waits for nothing.
    #expect(free.info.first?.amount == Fx.money("100000"))
  }
}
