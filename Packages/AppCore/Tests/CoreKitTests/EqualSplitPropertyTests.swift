import Foundation
import Testing

@testable import CoreKit

/// An amount split into N parts, on random amounts and counts and through both ways the app
/// splits (equal shares, and shares by equal weights), always adds back to the whole.
@Suite("Splitting an amount into parts adds back to the whole")
struct EqualSplitPropertyTests {
  static let seeds: [UInt64] = Array(1...20)

  @Test(arguments: seeds)
  func equalPartsAddUpToTheWhole(_ seed: UInt64) {
    var random = SplitDice(seed: seed)
    for _ in 0..<500 {
      let raw = Int64(random.int(in: -2_000_000_000...2_000_000_000)) * 1_000
        + Int64(random.int(in: -999...999))
      let count = random.int(in: 1...120)
      let amount = AmountE4(raw: raw)
      let parts = amount.split(into: count)
      #expect(parts.count == count)
      #expect(parts.reduce(Int128(0)) { $0 + Int128($1.raw) } == Int128(raw), "\(raw) / \(count)")

      let weights = Array(repeating: AmountE4(raw: 1_000), count: count)
      let whole = AmountE4(raw: 1_000 * Int64(count))
      let shares = amount.allocated(proportionallyTo: weights, outOf: whole)
      #expect(shares.count == count)
      #expect(shares.reduce(Int128(0)) { $0 + Int128($1.raw) } == Int128(raw), "\(raw) / \(count)")
    }
  }

  /// Splitting a decimal total, rounded through `DecimalMath`, loses nothing either.
  @Test(arguments: seeds)
  func aDecimalTotalSplitThroughDecimalMathLosesNothing(_ seed: UInt64) throws {
    var random = SplitDice(seed: seed &+ 77)
    for _ in 0..<200 {
      let total = Decimal(random.int(in: 1...9_000_000_000)) / 10_000
      let count = random.int(in: 1...60)
      let raw = try DecimalMath.int64(rounding: total * 10_000)
      let parts = AmountE4(raw: raw).split(into: count)
      let sum = parts.reduce(Decimal(0)) { $0 + $1.decimal }
      #expect(sum == DecimalMath.round(total, scale: 4), "\(total) / \(count)")
    }
  }
}

/// A small seeded generator (SplitMix64), so a failing seed repeats.
private struct SplitDice {
  private var state: UInt64
  init(seed: UInt64) { state = seed }

  mutating func int(in range: ClosedRange<Int>) -> Int {
    state = state &+ 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    z ^= z >> 31
    return range.lowerBound + Int(z % UInt64(range.upperBound - range.lowerBound + 1))
  }
}
