import CoreKit
import Foundation

/// A small seeded generator (SplitMix64) for the random histories of the money suites: the same
/// seed gives the same history on every platform, so a failed check names a seed that
/// reproduces it.
struct MoneyDice {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var mixed = state
    mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
    mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
    return mixed ^ (mixed >> 31)
  }

  /// A number in `0..<bound`.
  mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(max(1, bound))) }

  mutating func int(_ range: ClosedRange<Int>) -> Int {
    range.lowerBound + below(range.upperBound - range.lowerBound + 1)
  }

  /// `true` `percent` times out of a hundred.
  mutating func chance(_ percent: Int) -> Bool { below(100) < percent }

  mutating func pick<T>(_ items: [T]) -> T { items[below(items.count)] }

  /// An amount in whole units and kopecks, from 1.00 to `whole`.
  mutating func amount(upTo whole: Int) -> AmountE4 {
    AmountE4(raw: Int64(int(100...(whole * 100))) * 100)
  }

  /// An amount with all four places used, from 0.0001 to `whole`: the crumbs rounding leaves.
  mutating func fineAmount(upTo whole: Int) -> AmountE4 {
    AmountE4(raw: Int64(int(1...(whole * 10_000))))
  }

  /// The items in a random order.
  mutating func shuffled<T>(_ items: [T]) -> [T] {
    var result = items
    guard result.count > 1 else { return result }
    for index in stride(from: result.count - 1, to: 0, by: -1) {
      result.swapAt(index, below(index + 1))
    }
    return result
  }

  /// An exact figure in stored units, rounded half away from zero.
  static func rounded(_ decimal: Decimal) -> AmountE4 {
    (try? AmountE4(decimal: decimal)) ?? .zero
  }

  /// `rub × taken ÷ whole`, rounded half away from zero, in whole integers — the share of a
  /// purchase part's rubles a refund takes back, worked out without the code under test; all of
  /// `rub` once `taken` covers `whole`.
  static func share(_ rub: AmountE4, taken: AmountE4, of whole: AmountE4) -> AmountE4 {
    guard !whole.isZero else { return .zero }
    if taken >= whole { return rub }
    return scaled(rub, taken, whole)
  }

  /// `amount × numerator ÷ denominator`, rounded half away from zero, in whole integers.
  static func scaled(
    _ amount: AmountE4, _ numerator: AmountE4, _ denominator: AmountE4
  )
    -> AmountE4
  {
    guard !denominator.isZero else { return .zero }
    let top = Int128(amount.raw) * Int128(numerator.raw)
    let bottom = Int128(denominator.raw)
    let magnitude = (abs(top) * 2 + abs(bottom)) / (abs(bottom) * 2)
    return AmountE4(raw: Int64((top < 0) != (bottom < 0) ? -magnitude : magnitude))
  }
}
