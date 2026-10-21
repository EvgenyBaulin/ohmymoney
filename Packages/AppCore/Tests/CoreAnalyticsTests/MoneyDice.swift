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
}
