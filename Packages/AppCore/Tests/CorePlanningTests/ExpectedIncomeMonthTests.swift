import CoreAccounting
import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CorePlanning

/// Income that comes early for a later month is that month's, and one-off expectations are
/// waited for while their day is in this month or ahead, by D, for what has not come of them.
@Suite("Income still expected: the month an income is for, and one-off expectations")
struct ExpectedIncomeMonthTests {
  typealias Fx = CashFx

  static let seeds: [UInt64] = Array(1...30)

  /// A salary of 100 000 on the 10th; October's came early, on 15 September, written for
  /// October. September's has not come: waited for through the end of September; through
  /// October only September's is — October's is in.
  @Test func anIncomeForNextMonthIsNotThisMonths() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "1000")], at: Fx.at("2026-09-01", 9))
    let salary = ExpectedIncome(
      id: Fx.id(611), name: "Salary", categoryId: Fx.salary, kind: .recurring,
      totalE4: Fx.money("100000"), dueDate: Fx.day("2026-01-10"), freq: .monthly, day: 10)
    fx.expected = [salary]
    let early = fx.add(.income, "100000", at: Fx.at("2026-09-15", 10), category: Fx.salary)
    if let index = fx.entries.firstIndex(where: { $0.id == early }) {
      fx.entries[index].transaction.periodMonth = MonthKey(year: 2026, month: 10)
    }
    fx.expectedLinks = [ExpectedIncomeLink(expectedIncomeId: salary.id, transactionId: early)]
    let snapshot = fx.snapshot()
    #expect(snapshot.freeMoney.info.first?.amount == Fx.money("100000"))
    let october = snapshot.freeMoney(until: Fx.day("2026-10-31"), ledger: fx.ledger)
    #expect(october.info.first?.amount == Fx.money("100000"))

    // Written for September, the same money is September's: nothing is waited for this month,
    // October's salary is.
    if let index = fx.entries.firstIndex(where: { $0.id == early }) {
      fx.entries[index].transaction.periodMonth = nil
    }
    let asSeptember = fx.snapshot()
    #expect(asSeptember.freeMoney.info.first?.amount == .zero)
    #expect(
      asSeptember.freeMoney(until: Fx.day("2026-10-31"), ledger: fx.ledger).info.first?.amount
        == Fx.money("100000"))
  }

  /// Random one-off expectations — some long overdue, some this month, some ahead, some partly
  /// come, some closed — and any D within a year: waited for is what has not come of each open
  /// one whose day is from the 1st of this month through D, dollars at today's rate.
  @Test(arguments: seeds)
  func oneOffsAreWaitedForFromThisMonthThroughD(_ seed: UInt64) {
    var random = SeededRandom(seed: seed &+ 500)
    var fx = Fx()
    fx.count([(Fx.main, .rub, "1000")], at: Fx.at("2026-09-01", 9))
    let until = Fx.today.adding(days: random.int(in: 0...365))
    var model = AmountE4.zero
    for index in 0..<random.int(in: 1...6) {
      let due = Fx.day("2026-06-01").adding(days: random.int(in: 0...500))
      let total = AmountE4(whole: Int64(random.int(in: 1...100) * 1_000))
      let dollars = random.chance(1, outOf: 4)
      var income = ExpectedIncome(
        id: Fx.id(620 + index), name: "Project \(index)", categoryId: Fx.salary,
        totalE4: total, currency: dollars ? .usd : .rub, dueDate: due)
      income.closed = random.chance(1, outOf: 6)
      fx.expected.append(income)
      var received = AmountE4.zero
      if random.chance(1, outOf: 3) {
        let part = AmountE4(raw: total.raw * Int64(random.int(in: 1...120)) / 100)
        let id = fx.add(
          .income, part.decimal.description,
          at: Fx.at(min(Fx.today, due).iso, 10), currency: dollars ? .usd : .rub,
          category: Fx.salary)
        fx.expectedLinks.append(ExpectedIncomeLink(expectedIncomeId: income.id, transactionId: id))
        received = part
      }
      guard !income.closed, due >= Fx.today.monthKey.firstDay, due <= until else { continue }
      let left = max(.zero, total - received)
      model += dollars ? SubscriptionMath.rounded(left.decimal * 90) : left
    }
    let free = fx.snapshot().freeMoney(until: until, ledger: fx.ledger)
    #expect(free.info.first?.amount == model, "seed \(seed), D \(until)")
  }
}
