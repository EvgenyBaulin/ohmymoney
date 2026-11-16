import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CoreAnalytics

/// The change to the previous period on random pairs of figures, tiny and huge, either sign:
/// the percent exists only against a base that is at least 1 % of the current figure and at
/// least 100 ₽, and whatever is said, its sign agrees with the difference in rubles.
@Suite("Change to the previous period with a tiny base: random figures")
struct ChangeTinyBasePropertyTests {
  static let seeds: [UInt64] = Array(1...20)

  /// A figure of one of several sizes, so tiny bases meet big current figures often.
  static func figure(_ random: inout SeededRandom) -> AmountE4 {
    let units: [Int64] = [0, 1, 9_999, 10_000, 500_000, 990_000, 1_000_000, 50_000_000]
    let base = random.choice(from: units)
    let wiggle = Int64(random.int(in: -3...3)) * 7_919
    let scale = Int64(random.int(in: 1...400))
    let raw = random.chance(1, outOf: 3) ? base + wiggle : base * scale + wiggle
    return AmountE4(raw: random.chance(1, outOf: 5) ? -raw : raw)
  }

  @Test(arguments: seeds)
  func thePercentAppearsOnlyAgainstAComparableBase(_ seed: UInt64) {
    var random = SeededRandom(seed: seed)
    for _ in 0..<400 {
      let change = Change(current: Self.figure(&random), previous: Self.figure(&random))
      let size = change.previous.magnitude
      let big = size >= AmountE4(whole: 100)
      let notTiny = Decimal(size.raw) * 100 >= Decimal(change.current.magnitude.raw)
      let expectComparable = !change.previous.isZero && big && notTiny
      #expect(
        (change.basisPoints != nil) == expectComparable,
        "seed \(seed): \(change.current.raw) vs \(change.previous.raw)")
      #expect((change.base == .comparable) == expectComparable)
      #expect((change.base == .none) == change.previous.isZero)
      if change.base == .negligible { #expect(change.basisPoints == nil) }
    }
  }

  @Test(arguments: seeds)
  func theSignOfThePercentIsTheSignOfTheRubleDifference(_ seed: UInt64) {
    var random = SeededRandom(seed: seed &+ 1_000)
    for _ in 0..<400 {
      let change = Change(current: Self.figure(&random), previous: Self.figure(&random))
      #expect(change.delta == change.current - change.previous)
      guard let bp = change.basisPoints else { continue }
      let label = "seed \(seed): \(change.current.raw) vs \(change.previous.raw)"
      if change.delta.isZero { #expect(bp == 0, "\(label)") }
      if change.delta.raw > 0 { #expect(bp >= 0, "\(label)") }
      if change.delta.raw < 0 { #expect(bp <= 0, "\(label)") }
      if bp > 0 { #expect(change.delta.raw > 0, "\(label)") }
      if bp < 0 { #expect(change.delta.raw < 0, "\(label)") }
    }
  }

  @Test func theEdgesOfTheBaseAreExact() {
    let hundred = AmountE4(whole: 100)
    let justUnder = AmountE4(raw: hundred.raw - 1)
    #expect(Change(current: hundred, previous: justUnder).base == .negligible)
    #expect(Change(current: hundred, previous: hundred).base == .comparable)
    // Exactly 1 % of the current figure is comparable, a unit less is not.
    let current = AmountE4(whole: 20_000)
    let onePercent = AmountE4(whole: 200)
    #expect(Change(current: current, previous: onePercent).base == .comparable)
    #expect(
      Change(current: current, previous: AmountE4(raw: onePercent.raw - 1)).base == .negligible)
    #expect(Change(current: current, previous: .zero).base == .none)
  }
}
