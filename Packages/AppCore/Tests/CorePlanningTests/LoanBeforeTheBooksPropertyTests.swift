import CoreAccounting
import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CorePlanning

/// A loan taken out before the books began, restored from its schedule and bent to the first
/// balance of its journal, on random loans: never below zero, never above the sum borrowed when
/// there is no interest, and exactly the journal's balance when the journal begins.
@Suite("The loan before the books: random loans")
struct LoanBeforeTheBooksPropertyTests {
  typealias Fx = CapitalFx

  static let seeds: [UInt64] = Array(1...40)

  struct Case {
    var debt: Debt
    var journal: [DebtEntry]
    var firstBalance: AmountE4

    init(seed: UInt64, interest: Bool) {
      var random = SeededRandom(seed: seed)
      let rough = Fx.day("2024-01-10").adding(days: random.int(in: 0...400))
      // Opened early in a month, so the payment days of the start month all come before it.
      let opened = DateOnly(year: rough.year, month: rough.month, day: random.int(in: 1...5))
      let amount = Int64(random.int(in: 50_000...5_000_000))
      let paymentDay = random.int(in: 1...5)
      var debt = Debt(
        id: Fx.id(20), direction: .iOwe, type: .loan, name: "Loan",
        interestRate: interest ? Decimal(random.int(in: 1...25)) : (random.chance(1, outOf: 2) ? 0 : nil),
        monthlyPaymentE4: random.chance(3, outOf: 4)
          ? Fx.rub(String(max(1_000, Int(amount) / random.int(in: 6...60)))) : nil,
        paymentDay: paymentDay, openedOn: opened, originalAmountE4: Fx.rub(String(amount)))
      if random.chance(1, outOf: 6) { debt.paymentDay = nil }
      // The journal begins 2 to 30 months later, on a day after every payment day.
      var begin = opened.monthKey
      for _ in 0..<random.int(in: 2...30) { begin = begin.next }
      let startDay = DateOnly(year: begin.year, month: begin.month, day: random.int(in: 10...25))
      let firstUnits = Int64(random.int(in: 0...Int(amount)))
      let entry = DebtEntry(
        id: Fx.id(21), debtId: debt.id, date: startDay, amountE4: Fx.rub(String(firstUnits)),
        kind: .borrowed)
      self.debt = debt
      journal = [entry]
      firstBalance = Fx.rub(String(firstUnits))
    }

    var start: DateOnly { journal[0].date ?? Fx.day("2030-01-01") }
  }

  /// The capital reads the restored loan at the end of each month.
  static func monthEnds(from first: DateOnly, before limit: DateOnly) -> [DateOnly] {
    var result: [DateOnly] = []
    var month = first.monthKey
    while month.lastDay < limit {
      result.append(month.lastDay)
      month = month.next
    }
    return result
  }

  func restoration(_ item: Case) -> DebtRestoration? {
    DebtRestoration(debt: item.debt, journal: item.journal, calendar: .utc)
  }

  @Test(arguments: seeds)
  func theRestoredBalanceIsNeverNegative(_ seed: UInt64) {
    let item = Case(seed: seed, interest: seed % 2 == 0)
    guard let restored = restoration(item) else {
      Issue.record("seed \(seed): no restoration")
      return
    }
    var checked = 0
    for day in Self.monthEnds(from: item.debt.openedOn ?? item.start, before: item.start) {
      if let balance = restored.balance(on: day) {
        #expect(balance.raw >= 0, "seed \(seed), \(day.iso): \(balance.raw)")
        checked += 1
      }
    }
    #expect(checked > 0, "seed \(seed)")
  }

  @Test(arguments: seeds)
  func withoutInterestItIsNeverAboveTheSumBorrowed(_ seed: UInt64) {
    let item = Case(seed: seed, interest: false)
    guard let restored = restoration(item), let opening = item.debt.opening else {
      Issue.record("seed \(seed): no restoration")
      return
    }
    for day in Self.monthEnds(from: opening.day, before: item.start) {
      if let balance = restored.balance(on: day) {
        #expect(
          balance <= opening.amountE4,
          "seed \(seed), \(day.iso): \(balance.raw) > \(opening.amountE4.raw)")
      }
    }
  }

  /// In the month the journal begins, after the payment days and before the first line, the
  /// restored loan is exactly what the journal then says.
  @Test(arguments: seeds)
  func itMeetsTheFirstJournalBalanceOnTheStartDay(_ seed: UInt64) {
    let item = Case(seed: seed, interest: seed % 2 == 0)
    guard let restored = restoration(item) else {
      Issue.record("seed \(seed): no restoration")
      return
    }
    #expect(restored.start == item.start)
    let eve = item.start.adding(days: -1)
    #expect(restored.balance(on: eve) == item.firstBalance, "seed \(seed), \(eve.iso)")
    #expect(restored.balance(on: item.start) == nil, "from the start day only the records speak")
  }
}
