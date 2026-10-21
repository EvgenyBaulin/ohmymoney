import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// Laying the money of the payments against dues of their own sums (`DebtDues.laid(_:
/// instalments:)`) is the rule of one monthly payment when every due asks for the same: for any
/// payments — halves, doubles, extras, a percent short, «больше платежей не будет» — the dues
/// paid and the money kept are the same as `laid(_:monthly:)` gives. A schedule with sums of its
/// own pays each due by its sum and its own percent, and passes over a due of nothing.
@Suite("Debt dues laid against sums of their own")
struct DebtInstalmentsLaidPropertyTests {
  /// SplitMix64: the same numbers on every run.
  struct Numbers {
    var state: UInt64
    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
  }

  func payment(
    _ dayNumber: Int, _ amount: AmountE4, closesTerm: Bool = false, hour: Int = 0
  ) -> DebtDues.Payment {
    let day = DateOnly(year: 2026, month: 1, day: 1).adding(days: dayNumber)
    return DebtDues.Payment(
      day: day, at: CalendarContext.utc.startOfDay(day).addingTimeInterval(Double(hour) * 3600),
      amountE4: amount, closesTerm: closesTerm)
  }

  @Test func flatInstalmentsLayTheMoneyAsOneMonthlyPaymentDoes() {
    var numbers = Numbers(state: 20_261_011)
    for _ in 0..<2_000 {
      let monthly = AmountE4(raw: Int64(1 + numbers.below(50_000)) * 100)
      var payments: [DebtDues.Payment] = []
      for _ in 0..<numbers.below(14) {
        // Halves, wholes, two at once, a percent short, an extra — of the monthly payment.
        let fractions: [Int64] = [50, 100, 200, 99, 98, 5, 150, 33, 101]
        let share = fractions[numbers.below(fractions.count)]
        let amount = AmountE4(raw: max(1, monthly.raw * share / 100 + Int64(numbers.below(3)) - 1))
        payments.append(
          payment(
            numbers.below(400), amount, closesTerm: numbers.below(5) == 0,
            hour: numbers.below(3)))
      }
      let flat = DebtDues.laid(payments, instalments: .flat(monthly))
      let old = DebtDues.laid(payments, monthly: monthly)
      #expect(flat.paid == old.paid, "monthly \(monthly), payments \(payments)")
      #expect(flat.partial == old.partial, "monthly \(monthly), payments \(payments)")
    }
  }

  /// Dues of 100, 100, then 1 000: two payments of 100 pay the first two, 990 — a percent of
  /// 1 000 short — pays the third, and the percent is of that due, not of the first one.
  @Test func eachDueIsPaidByItsOwnSumAndItsOwnPercent() {
    let instalments = DebtInstalments(steps: [
      .init(fromIndex: 0, amountE4: money("100")),
      .init(fromIndex: 2, amountE4: money("1000")),
    ])
    let early = DebtDues.laid(
      [payment(1, money("100")), payment(30, money("100"))],
      instalments: instalments)
    #expect(early.paid == 2)
    #expect(early.partial.isZero)
    let later = DebtDues.laid(
      [
        payment(1, money("100")), payment(30, money("100")),
        payment(60, money("990")),
      ], instalments: instalments)
    #expect(later.paid == 3)
    #expect(later.partial.isZero)
    // 1 200 at once pays the two small dues and the big one, and keeps nothing over.
    let once = DebtDues.laid([payment(1, money("1200"))], instalments: instalments)
    #expect(once.paid == 3)
    #expect(once.partial.isZero)
    // 98 is two percent short of the first due: kept, not a due.
    let short = DebtDues.laid([payment(1, money("98"))], instalments: instalments)
    #expect(short.paid == 0)
    #expect(short.partial == money("98"))
  }

  /// A due of nothing is no due: the money goes to the next one that asks for something, and a
  /// payment that closes its term closes that one.
  @Test func aDueOfNothingIsPassedOver() {
    let instalments = DebtInstalments(steps: [
      .init(fromIndex: 0, amountE4: .zero),
      .init(fromIndex: 3, amountE4: money("500")),
    ])
    let paid = DebtDues.laid([payment(1, money("500"))], instalments: instalments)
    #expect(paid.paid == 4, "three dues of nothing, then the due of 500")
    let closing = DebtDues.laid(
      [payment(1, money("100"), closesTerm: true)], instalments: instalments)
    #expect(closing.paid == 4)
    #expect(closing.partial.isZero)
    // Nothing asked for at all: the money is kept, no due is paid.
    let nothing = DebtDues.laid([payment(1, money("100"))], instalments: .none)
    #expect(nothing.paid == 0)
  }
}
