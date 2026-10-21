import CoreKit
import Foundation

/// Deterministic pseudo-random source for synthetic data and tests: the same seed must always
/// produce the same sequence, on every platform this package builds for (macOS, Linux). Never
/// backed by the system RNG, never touches floating point.
///
/// The core algorithm is SplitMix64 (Steele, Vigna & Bacik, 2014): a single 64-bit state
/// word advanced by a fixed odd increment, then mixed through three multiply/xor-shift
/// rounds. It has no seeding pitfalls, is fast, and its bit pattern is fully specified —
/// exactly what reproducible synthetic data needs. All arithmetic below is unsigned
/// 64-bit with wraparound (`&+`, `&*`), so it behaves identically everywhere Swift runs.
public struct SeededRandom: RandomSource, RandomNumberGenerator, Sendable {
  private var state: UInt64

  public init(seed: UInt64) {
    self.state = seed
  }

  /// Advances the generator and returns the next 64-bit word.
  public mutating func next() -> UInt64 {
    state = state &+ 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  /// `RandomSource` conformance for callers that only know the narrow protocol.
  public mutating func nextUInt64() -> UInt64 {
    next()
  }

  /// Uniform value in `0..<bound` with no modulo bias: draws that land in the last,
  /// incomplete bucket of the 64-bit space are rejected and redrawn.
  private mutating func uniform(lessThan bound: UInt64) -> UInt64 {
    guard bound > 1 else { return 0 }
    let limit = UInt64.max - (UInt64.max % bound)
    var value = next()
    while value >= limit {
      value = next()
    }
    return value % bound
  }

  /// Uniform integer in a closed range, e.g. `1...31` for a day of month.
  public mutating func int(in range: ClosedRange<Int>) -> Int {
    let span = UInt64(range.upperBound - range.lowerBound) + 1
    return range.lowerBound + Int(uniform(lessThan: span))
  }

  /// Uniform integer in a half-open range, e.g. `0..<count`.
  public mutating func int(in range: Range<Int>) -> Int {
    precondition(!range.isEmpty, "range must not be empty")
    return int(in: range.lowerBound...(range.upperBound - 1))
  }

  /// True with probability `numerator / denominator`, e.g. `chance(1, outOf: 7)` for
  /// "about once a week". Kept in plain integers so no floating point is ever involved.
  public mutating func chance(_ numerator: Int, outOf denominator: Int) -> Bool {
    precondition(denominator > 0 && numerator >= 0)
    return uniform(lessThan: UInt64(denominator)) < UInt64(numerator)
  }

  /// Picks one element uniformly at random.
  public mutating func choice<Element>(from items: [Element]) -> Element {
    precondition(!items.isEmpty, "cannot choose from an empty collection")
    return items[int(in: 0..<items.count)]
  }

  /// Picks one value with probability proportional to its (non-negative) weight.
  public mutating func weightedChoice<Value>(from items: [(value: Value, weight: Int)]) -> Value {
    precondition(!items.isEmpty, "cannot choose from an empty collection")
    let total = items.reduce(0) { $0 + max($1.weight, 0) }
    guard total > 0 else { return items[0].value }
    var target = Int(uniform(lessThan: UInt64(total)))
    for item in items {
      let weight = max(item.weight, 0)
      if target < weight { return item.value }
      target -= weight
    }
    return items[items.count - 1].value
  }

  /// Amount scattered evenly within `±spread` of `center`, in the same `AmountE4` units
  /// — the "sum around X with some spread" helper the sample generator relies on.
  public mutating func amount(around center: AmountE4, spread: AmountE4) -> AmountE4 {
    let magnitude = spread.raw.magnitude
    guard magnitude > 0 else { return center }
    let span = magnitude * 2 + 1
    let offset = Int64(uniform(lessThan: span)) - Int64(magnitude)
    return AmountE4(raw: center.raw + offset)
  }

  /// A random `UUID` built from two draws of this generator, so every id in the sample
  /// dataset — categories, people, transactions — is reproducible from the seed alone.
  /// Bytes are assembled by explicit shifting, so the result never depends on the host's
  /// native byte order.
  public mutating func nextUUID() -> UUID {
    let high = next()
    let low = next()
    var bytes = [UInt8]()
    bytes.reserveCapacity(16)
    for shift in stride(from: 56, through: 0, by: -8) {
      bytes.append(UInt8((high >> shift) & 0xFF))
    }
    for shift in stride(from: 56, through: 0, by: -8) {
      bytes.append(UInt8((low >> shift) & 0xFF))
    }
    bytes[6] = (bytes[6] & 0x0F) | 0x40  // version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }
}
