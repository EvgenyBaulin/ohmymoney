import Foundation
import Testing

@testable import CoreKit

@Suite("Money is stored as integer 1/10000 units")
struct MoneyTests {
  @Test func decimalRoundTripKeepsFourFractionDigits() throws {
    let amount = try AmountE4(decimal: Decimal(string: "1234.5678")!)
    #expect(amount.raw == 12_345_678)
    #expect(amount.decimal == Decimal(string: "1234.5678")!)
  }

  @Test func roundsHalfAwayFromZero() throws {
    #expect(try AmountE4(decimal: Decimal(string: "0.00005")!).raw == 1)
    #expect(try AmountE4(decimal: Decimal(string: "-0.00005")!).raw == -1)
    #expect(try AmountE4(decimal: Decimal(string: "0.00004")!).raw == 0)
  }

  @Test func wholeUnitsUseTheDeclaredScale() {
    #expect(AmountE4(whole: 250).raw == 2_500_000)
    #expect(AmountE4(whole: 250).decimal == Decimal(250))
  }

  @Test func sumOfPartsEqualsTheTotal() {
    let parts = [AmountE4(whole: 100), AmountE4(raw: 12_345), AmountE4(raw: -45)]
    #expect(AmountE4.sum(parts).raw == 1_000_000 + 12_345 - 45)
  }

  @Test func splittingNeverLosesAUnit() {
    let total = AmountE4(raw: 1_000)
    for count in 1...7 {
      let shares = total.split(into: count)
      #expect(shares.count == count)
      #expect(AmountE4.sum(shares) == total)
    }
  }

  @Test func splittingNegativeAmountsAlsoBalances() {
    let total = AmountE4(raw: -1_001)
    let shares = total.split(into: 3)
    #expect(AmountE4.sum(shares) == total)
  }

  @Test(arguments: [
    ("250", Decimal(250)),
    ("1 250,50", Decimal(string: "1250.50")!),
    ("1,250.50", Decimal(string: "1250.50")!),
    ("1.250,50", Decimal(string: "1250.50")!),
    ("0,01", Decimal(string: "0.01")!),
    ("-42", Decimal(-42)),
    ("1 250 000", Decimal(1_250_000)),
    ("12 345.67", Decimal(string: "12345.67")!),
    ("1\u{00A0}250,50", Decimal(string: "1250.50")!),
    ("1\u{202F}250\u{2009}000", Decimal(1_250_000)),
    (" 250 ", Decimal(250)),
  ])
  func parsesBothDecimalSeparators(input: String, expected: Decimal) {
    #expect(DecimalMath.parse(input) == expected)
  }

  @Test(arguments: ["", "abc", "12abc", "1..2"])
  func rejectsGarbage(input: String) {
    #expect(DecimalMath.parse(input) == nil)
  }

  // A space inside a number groups thousands, and nothing else: exactly three digits
  // follow it, before the decimal part. A stray space between digits is a typo, not a
  // different plausible number — «1 5» in the «Received» field must not record 15.
  @Test(arguments: [
    "1 2", "1 5", "9 0", "12 5", "1 2 3", "1 25,50", "1 2345", "1 250 00", "1,5 120",
    "2.5 300", "1 250,50 0", "- 250", "1  250",
  ])
  func rejectsASpaceThatDoesNotGroupThousands(input: String) {
    #expect(DecimalMath.parse(input) == nil)
  }

  // A decimal separator is written once, so a `,` or `.` written twice or more groups
  // thousands, and so does the one that is not the rightmost of the two. Either way it is
  // followed by exactly three digits: «1,234,567» is a million and more, «1,2.3» is garbage,
  // not 12.3.
  @Test(arguments: [
    ("1,250,000", Decimal(1_250_000)),
    ("1.250.000", Decimal(1_250_000)),
    ("1,234,567.89", Decimal(string: "1234567.89")!),
    ("1.234.567,89", Decimal(string: "1234567.89")!),
    ("-1,250,000", Decimal(-1_250_000)),
    ("12,500.5", Decimal(string: "12500.5")!),
  ])
  func aRepeatedSeparatorGroupsThousands(input: String, expected: Decimal) {
    #expect(DecimalMath.parse(input) == expected)
  }

  @Test(arguments: [
    "1,2.3", "1.2,3", "12,34.5", "1,2345.6", "12,34,567.89", "1,250,00", "1,25,000", ",250,000",
    "1,,250", "1.250.000,5,0",
  ])
  func rejectsASeparatorThatDoesNotGroupThousands(input: String) {
    #expect(DecimalMath.parse(input) == nil)
  }

  // In the rule of rates a lone separator is the decimal one, whichever it is: «1,25» and
  // «1.25» are the same number, and so are «1,250» and «1.250» — 1.25, not 1 250. An amount
  // typed by hand reads «1,250» as 1 250 (`TypedNumber`).
  @Test func aLoneSeparatorIsDecimal() {
    #expect(DecimalMath.parse("1,250") == Decimal(string: "1.25")!)
    #expect(DecimalMath.parse("1.250") == Decimal(string: "1.25")!)
    #expect(DecimalMath.parse("1,25") == Decimal(string: "1.25")!)
    #expect(DecimalMath.parse("83,125") == Decimal(string: "83.125")!)
  }

  // Foundation stops at the first character it cannot read, so anything it would swallow
  // has to be refused here: "1\u{00B2}" must not quietly become 1, and "2\u{0662}" must
  // not become 2. Only the ten ASCII digits are digits of an amount.
  @Test(arguments: ["1\u{00B2}", "2\u{0662}", "\u{00BD}", "\u{0665}", "1\u{2070}"])
  func rejectsDigitLookalikesFoundationWouldTruncate(input: String) {
    #expect(DecimalMath.parse(input) == nil)
  }

  @Test func splitHandsTheRemainingUnitsToTheFirstShares() {
    #expect(AmountE4(raw: 10).split(into: 3).map(\.raw) == [4, 3, 3])
    #expect(AmountE4(raw: -10).split(into: 3).map(\.raw) == [-4, -3, -3])
    #expect(AmountE4(raw: 2).split(into: 5).map(\.raw) == [1, 1, 0, 0, 0])
    #expect(AmountE4.zero.split(into: 3).map(\.raw) == [0, 0, 0])
  }

  /// Proportional shares, rounded half away from zero, the last one takes the rest.
  @Test func proportionalSharesAddUpAndTheLastTakesTheRest() {
    let rubles = AmountE4(raw: 8_143_210)
    let weights = [33_300, 33_300, 33_400].map(AmountE4.init(raw:))
    let shares = rubles.allocated(proportionallyTo: weights, outOf: AmountE4(raw: 100_000))
    #expect(shares.map(\.raw) == [2_711_689, 2_711_689, 2_719_832])

    // Whatever the weights, the shares add up to the amount to the unit.
    for count in 1...7 {
      let uneven = (1...count).map { AmountE4(raw: Int64($0 * 7 + 3)) }
      let whole = AmountE4.sum(uneven)
      for amount in [AmountE4(raw: 1_000_003), AmountE4(raw: -999_997), .zero] {
        #expect(AmountE4.sum(amount.allocated(proportionallyTo: uneven, outOf: whole)) == amount)
      }
    }
  }

  /// Parts that do not add up to the whole — mixed signs, a row brought by an archive —
  /// may ask for a share beyond what `Int64` units hold. It stops at the edge like every sum of
  /// money; it does not quietly become zero and hand the whole amount to the last part.
  @Test func aShareBeyondTheRangeStopsAtTheEdgeInsteadOfBecomingZero() {
    let amount = AmountE4(raw: 4_000_000_000_000_000_000)
    let weights = [AmountE4(raw: 3), AmountE4(raw: -2)]
    let shares = amount.allocated(proportionallyTo: weights, outOf: AmountE4(raw: 1))
    #expect(shares.first == AmountE4(raw: .max))
    #expect(AmountE4.sum(shares) == amount)

    let negative = AmountE4(raw: -4_000_000_000_000_000_000)
    let negativeShares = negative.allocated(proportionallyTo: weights, outOf: AmountE4(raw: 1))
    #expect(negativeShares.first == AmountE4(raw: .min))
    #expect(AmountE4.sum(negativeShares) == negative)
  }

  @Test func proportionalSharesOfNothingAreZero() {
    let weights = [AmountE4(raw: 1), AmountE4(raw: 2)]
    #expect(AmountE4(raw: 5).allocated(proportionallyTo: weights, outOf: .zero) == [.zero, .zero])
    #expect(AmountE4(raw: 5).allocated(proportionallyTo: [], outOf: AmountE4(raw: 3)).isEmpty)
    #expect(
      AmountE4(raw: 5).allocated(proportionallyTo: [AmountE4(raw: 3)], outOf: AmountE4(raw: 3))
        == [AmountE4(raw: 5)])
  }

  @Test func amountsOutsideTheInt64RangeAreRefused() {
    #expect(throws: CoreError.amountOutOfRange) {
      try AmountE4(decimal: Decimal(string: "1e30")!)
    }
    #expect(throws: CoreError.amountOutOfRange) {
      try AmountE4(decimal: Decimal(string: "-1e30")!)
    }
    // Untrusted input is added without trapping.
    #expect(AmountE4(raw: .max).adding(AmountE4(raw: 1)) == nil)
    #expect(AmountE4(raw: .max).adding(.zero) == AmountE4(raw: .max))
  }

  /// What is stored may hold any `Int64` — an archive, a CSV, a row saved before
  /// the ceiling — and the ledger adds it up on every open. A sum that leaves the range
  /// stops at its edge; it never takes the process down.
  @Test func sumsStopAtTheEdgeOfTheRangeInsteadOfTrapping() {
    #expect(AmountE4(raw: .max) + AmountE4(raw: 1) == AmountE4(raw: .max))
    #expect(AmountE4(raw: .max) - AmountE4(raw: -1) == AmountE4(raw: .max))
    #expect(AmountE4(raw: .min) + AmountE4(raw: -1) == AmountE4(raw: .min))
    #expect(AmountE4(raw: .min) - AmountE4(raw: 1) == AmountE4(raw: .min))
    #expect(-AmountE4(raw: .min) == AmountE4(raw: .max))
    var total = AmountE4(raw: .max - 1)
    total += AmountE4(raw: 2)
    #expect(total == AmountE4(raw: .max))
    // Two operations of 600 000 000 000 000 on one day.
    let huge = AmountE4(raw: 6_000_000_000_000_000_000)
    #expect(AmountE4.sum([huge, huge]) == AmountE4(raw: .max))
    #expect(AmountE4.sum([-huge, -huge]) == AmountE4(raw: .min))
    // Inside the range nothing changes.
    #expect(AmountE4(raw: 5) - AmountE4(raw: 7) == AmountE4(raw: -2))
  }

  /// One typed amount is at most a trillion whole units, and more than nine
  /// hundred of them still add up to an exact number.
  @Test func theInputLimitLeavesRoomForSums() {
    #expect(AmountE4.inputLimit.decimal == Decimal(1_000_000_000_000))
    let many = Array(repeating: AmountE4.inputLimit, count: 900)
    #expect(AmountE4.sum(many).decimal == Decimal(900) * AmountE4.inputLimit.decimal)
  }

  @Test func convertsToRublesUsingNominal() throws {
    // The Bank of Russia quotes some currencies per 10 or 100 units.
    let rate = Rate(
      date: DateOnly(year: 2026, month: 9, day: 16),
      currency: CurrencyCode("AMD"),
      rubPerUnit: Decimal(string: "21.5")!,
      nominal: 100)
    let rubles = try rate.toRubles(AmountE4(whole: 1_000))
    #expect(rubles.decimal == Decimal(215))
  }
}
