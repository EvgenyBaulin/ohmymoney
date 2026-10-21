import Foundation
import Testing

@testable import CoreKit

/// The rubles of a saved operation and of its parts, on random drafts: the parts share the
/// operation's rubles to the unit, each part in proportion to its amount and never on the
/// other side of zero; a leg in rubles typed from the statement is the operation's rubles and
/// sets the rate it implies.
@Suite("Rubles of an operation and its parts, on random drafts")
struct DraftRublesPropertyTests {
  private let day = DateOnly(year: 2026, month: 9, day: 26)

  /// A split in another currency: the rubles of the operation are the amount at the rate,
  /// rounded half away from zero, and the parts share exactly those rubles.
  @Test("The parts share the operation's rubles to the unit")
  func partsShareTheRublesExactly() throws {
    var random = DraftDice(seed: 11)
    for _ in 0..<5_000 {
      let parts = (0..<(1 + random.below(6))).map { _ in
        let size = random.below(2) == 0 ? 100 : 50_000_000
        return PartDraft(amount: AmountE4(raw: 1 + Int64(random.below(size))))
      }
      let total = AmountE4.sum(parts.map(\.amount))
      var draft = TransactionDraft(currency: CurrencyCode("KZT"), amount: total)
      draft.parts = parts
      let rate = Rate(
        date: day, currency: CurrencyCode("KZT"),
        rubPerUnit: Decimal(
          sign: .plus, exponent: -4, significand: Decimal(1 + random.below(2_000_000))),
        nominal: [1, 10, 100][random.below(3)])
      let entry = try draft.materialize(rublesConverter: { try rate.toRubles($0) })
      let rubles = try rate.toRubles(total)
      #expect(entry.transaction.amountRubE4 == rubles)
      #expect(
        AmountE4.sum(entry.parts.map(\.amountRubE4)) == rubles, "\(parts.map(\.amount.raw))")
      #expect(entry.isBalanced)
      for part in entry.parts {
        #expect(part.amountRubE4.raw >= 0, "\(parts.map(\.amount.raw)) at \(rate.perUnit)")
        // In proportion to its amount, to within one unit per part.
        let exact = Decimal(part.amountE4.raw) * Decimal(rubles.raw) / Decimal(total.raw)
        #expect(
          (Decimal(part.amountRubE4.raw) - exact).magnitude <= Decimal(entry.parts.count),
          "\(parts.map(\.amount.raw)) at \(rate.perUnit)")
      }
    }
  }

  /// A leg in rubles is what the operation cost. When it is exactly what the bank's rate gives,
  /// the bank's rate stays and is refined later with the rest; when it differs, the rate
  /// becomes the one the leg implies, to six places, a manual rate nobody refines.
  @Test("A ruble leg is the operation's rubles and sets the rate it implies")
  func aRubleLegSetsTheRubles() throws {
    var random = DraftDice(seed: 12)
    for _ in 0..<5_000 {
      let amount = AmountE4(raw: 1 + Int64(random.below(100_000_000)))
      let bankRate = Decimal(
        sign: .plus, exponent: -4, significand: Decimal(1 + random.below(1_500_000)))
      let prefill = try AmountE4(decimal: amount.decimal * bankRate)
      let offBy = Int64(random.below(3) == 0 ? 0 : random.below(20_000)) - 10_000
      let leg = AmountE4(raw: Swift.max(1, prefill.raw + offBy))
      var draft = TransactionDraft(
        currency: .usd, amount: amount, rate: bankRate, rateDate: day, rateSource: .cbr,
        rateProvisional: true, accountCurrency: .rub, accountAmount: leg)
      draft.parts = [
        PartDraft(amount: AmountE4(raw: amount.raw / 2)),
        PartDraft(amount: AmountE4(raw: amount.raw - amount.raw / 2)),
      ].filter { !$0.amount.isZero }
      let entry = try draft.materialize(rublesConverter: { _ in
        Issue.record("a ruble leg is the rubles; the rate is not asked")
        return .zero
      })
      #expect(entry.transaction.amountRubE4 == leg)
      #expect(AmountE4.sum(entry.parts.map(\.amountRubE4)) == leg)
      if leg == prefill {
        #expect(entry.transaction.rate == bankRate)
        #expect(entry.transaction.rateSource == .cbr)
        #expect(entry.transaction.rateProvisional)
      } else {
        #expect(
          entry.transaction.rate == DecimalMath.round(leg.decimal / amount.decimal, scale: 6))
        #expect(entry.transaction.rateSource == .manual)
        #expect(!entry.transaction.rateProvisional)
      }
    }
  }

  /// A refund taken back from a purchase keeps the purchase's rate whatever its leg says: the
  /// leg is only the money that moved.
  @Test("A refund of a purchase keeps the purchase's rate over its ruble leg")
  func aRefundKeepsThePurchaseRate() throws {
    var draft = TransactionDraft(
      kind: .refund, currency: .usd, amount: AmountE4(whole: 10), rate: Decimal(80),
      rateDate: day, rateSource: .cbr, accountCurrency: .rub, accountAmount: AmountE4(whole: 950))
    draft.parts = [PartDraft(amount: AmountE4(whole: 10), refundOfPartId: UUID())]
    let entry = try draft.materialize(rublesConverter: { try AmountE4(decimal: $0.decimal * 80) })
    #expect(entry.transaction.amountRubE4 == AmountE4(whole: 800))
    #expect(entry.transaction.rate == Decimal(80))
    #expect(entry.transaction.rateSource == .cbr)
    #expect(entry.parts.map(\.amountRubE4) == [AmountE4(whole: 800)])
  }

  /// An equal split of any total into any number of parts balances the draft; in rubles the
  /// parts are their own amounts.
  @Test("An equal split in rubles balances and its parts are their rubles")
  func anEqualSplitInRublesBalances() throws {
    var random = DraftDice(seed: 13)
    for _ in 0..<5_000 {
      let total = AmountE4(raw: 1 + Int64(random.below(1_000_000_000)))
      let count = 1 + random.below(12)
      var draft = TransactionDraft(amount: total)
      draft.parts = total.split(into: count).filter { !$0.isZero }.map { PartDraft(amount: $0) }
      #expect(draft.isBalanced)
      #expect(draft.unallocated.isZero)
      let entry = try draft.materialize()
      let rubles = entry.parts.map(\.amountRubE4.raw)
      #expect(rubles == draft.parts.map(\.amount.raw), "rubles of a ruble split are its parts")
    }
  }

  /// An equal split in another currency: the parts share the operation's rubles to the unit,
  /// none below zero; every part but the last gets its exact share rounded half away from zero,
  /// or one unit less when the last part would otherwise fall below zero, and the last takes
  /// what is left.
  @Test("An equal split in another currency shares its rubles exactly")
  func anEqualSplitInAnotherCurrency() throws {
    var random = DraftDice(seed: 14)
    for _ in 0..<5_000 {
      let total = AmountE4(raw: 1 + Int64(random.below(random.below(2) == 0 ? 50 : 1_000_000_000)))
      let count = 1 + random.below(12)
      var draft = TransactionDraft(currency: CurrencyCode("AMD"), amount: total)
      draft.parts = total.split(into: count).filter { !$0.isZero }.map { PartDraft(amount: $0) }
      let quoted = Int64(1 + random.below(3_000_000))
      let rate = Rate(
        date: day, currency: CurrencyCode("AMD"),
        rubPerUnit: Decimal(sign: .plus, exponent: -4, significand: Decimal(quoted)),
        nominal: [1, 10, 100][random.below(3)])
      let entry = try draft.materialize(rublesConverter: { try rate.toRubles($0) })
      let rubles = Int128(entry.transaction.amountRubE4.raw)
      let shares = entry.parts.map { Int128($0.amountRubE4.raw) }
      let described = "\(draft.parts.map(\.amount.raw)) at \(quoted)/\(rate.nominal)"
      #expect(shares.reduce(0, +) == rubles, "\(described)")
      #expect(shares.allSatisfy { $0 >= 0 }, "\(described) → \(shares)")
      for (part, share) in zip(draft.parts.dropLast(), shares) {
        let exact = roundedHalfAway(Int128(part.amount.raw) * rubles, Int128(total.raw))
        #expect(share == exact || share == exact - 1, "\(described) → \(shares)")
      }
    }
  }
}

/// The quotient rounded to the nearest integer, a tie going away from zero.
private func roundedHalfAway(_ numerator: Int128, _ denominator: Int128) -> Int128 {
  let quotient = numerator / denominator
  let remainder = numerator % denominator
  guard remainder != 0, remainder.magnitude * 2 >= denominator.magnitude else { return quotient }
  return (numerator < 0) != (denominator < 0) ? quotient - 1 : quotient + 1
}

/// A seeded generator (SplitMix64): every run sees the same drafts, so a failure repeats.
private struct DraftDice {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var mixed = state
    mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
    mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
    return mixed ^ (mixed >> 31)
  }

  mutating func below(_ bound: Int) -> Int {
    Int(next() % UInt64(bound))
  }
}
