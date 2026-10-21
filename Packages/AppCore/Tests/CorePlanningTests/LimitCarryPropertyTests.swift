import CoreAccounting
import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CorePlanning

/// «Переносить остаток» on random months of spending: what a limit carries into a month is
/// what the months since its start left, each handing on max(0, limit + carry − spent) — never
/// a debt —, and nothing without rollover or before the start. An edit that changes what the
/// limit is, or turns rollover on, starts the carry again in the month of the edit.
@Suite("Limits carried over: random months against a fold")
struct LimitCarryPropertyTests {
  typealias Fx = CashFx

  static let seeds: [UInt64] = Array(1...40)

  /// Spending on Groceries in the months January–September: random, some months nothing, some
  /// far over; a refund now and then.
  static func book(seed: UInt64) -> (fx: CashFx, spent: [MonthKey: AmountE4]) {
    var random = SeededRandom(seed: seed &* 67 &+ 3)
    var fx = Fx()
    var spent: [MonthKey: AmountE4] = [:]
    for month in 1...9 {
      let key = MonthKey(year: 2026, month: month)
      for _ in 0..<random.int(in: 0...4) {
        let day = DateOnly(year: 2026, month: month, day: random.int(in: 1...28))
        let amount = AmountE4(whole: Int64(random.int(in: 1...8_000)))
        let purchase = fx.add(.expense, amount.decimal.description, at: Fx.at(day.iso, 12))
        spent[key, default: .zero] += amount
        if random.chance(1, outOf: 6) {
          let back = AmountE4(whole: Int64(random.int(in: 1...Int(amount.raw / 10_000))))
          LimitRefundAndGroupTests.refund(
            &fx, back.decimal.description, on: day.adding(days: random.int(in: 0...40)).iso,
            of: purchase)
          spent[key] = (spent[key] ?? .zero) - back
        }
      }
    }
    return (fx, spent)
  }

  /// Every month's carry is the fold of the months from the start through the one before it,
  /// and each month's spending is its purchases less their refunds, wherever a refund is dated.
  @Test(arguments: seeds)
  func theCarryIsTheFoldOfTheMonthsSinceTheStart(_ seed: UInt64) {
    var random = SeededRandom(seed: seed)
    let (fx, spent) = Self.book(seed: seed)
    let ledger = fx.ledger
    for _ in 0..<5 {
      let budget = Budget(
        id: Fx.id(760), scope: .category, categoryId: Fx.groceries,
        amountE4: AmountE4(whole: Int64(random.int(in: 1...15) * 1_000)),
        rollover: random.chance(3, outOf: 4),
        startMonth: random.chance(1, outOf: 6)
          ? nil : MonthKey(year: 2026, month: random.int(in: 1...9)))
      for month in 1...10 {
        let key = MonthKey(year: 2026, month: month)
        var carry = AmountE4.zero
        if budget.rollover, let start = budget.startMonth, start < key {
          for earlier in start.month..<month {
            let left =
              budget.amountE4 + carry
              - (spent[MonthKey(year: 2026, month: earlier)] ?? .zero)
            carry = max(.zero, left)
          }
        }
        #expect(
          LimitRules.carry(of: budget, into: key, ledger: ledger) == carry,
          "seed \(seed), \(key)")
        #expect(
          LimitRules.spent(of: budget, in: key, ledger: ledger) == (spent[key] ?? .zero),
          "seed \(seed), \(key)")
      }
    }
  }

  /// An edit restarts the carry in its month exactly when the amount, the scope, the category or
  /// the value changes, or rollover is turned on; a new limit starts in its month; any other
  /// save keeps its start.
  @Test(arguments: seeds)
  func anEditRestartsTheCarryOnlyWhenTheLimitChanges(_ seed: UInt64) {
    var random = SeededRandom(seed: seed &* 71)
    let month = MonthKey(year: 2026, month: 9)
    let stored = Budget(
      id: Fx.id(761), scope: .category, categoryId: Fx.groceries,
      amountE4: AmountE4(whole: 10_000), rollover: random.chance(1, outOf: 2),
      startMonth: random.chance(1, outOf: 4) ? nil : MonthKey(year: 2026, month: 3))
    var edited = stored
    var restarts = false
    switch random.int(in: 0...5) {
    case 0:
      edited.amountE4 = AmountE4(whole: 12_000)
      restarts = true
    case 1:
      edited.categoryId = Fx.fun
      restarts = true
    case 2:
      edited.scope = .forWhom
      edited.categoryId = nil
      edited.forWhom = .me
      restarts = true
    case 3:
      edited.rollover.toggle()
      restarts = edited.rollover
    default:
      break
    }
    let saved = LimitRules.saving(edited, over: stored, in: month)
    let start = restarts ? month : (stored.startMonth ?? month)
    #expect(saved.startMonth == start, "seed \(seed)")
    #expect(LimitRules.saving(edited, over: nil, in: month).startMonth == month)
  }
}
