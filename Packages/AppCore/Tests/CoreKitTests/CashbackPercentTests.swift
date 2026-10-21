import Foundation
import Testing

@testable import CoreKit

/// A cashback percent is kept exactly, in 1/10000 of a percent, from 0 to 100 %: the owner types
/// «1.5» and the bank's «33.3333» and gets back exactly what was typed.
@Suite("A cashback percent is kept exactly")
struct CashbackPercentTests {
  private func percent(_ text: String) -> CashbackPercent? {
    CashbackPercent(decimal: Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!)
  }

  @Test func parsesExactDecimals() {
    #expect(percent("1.5")?.e4 == 15_000)
    #expect(percent("0.75")?.e4 == 7_500)
    #expect(percent("33.3333")?.e4 == 333_333)
    #expect(percent("5")?.e4 == 50_000)
    #expect(percent("0.0001")?.e4 == 1)
  }

  @Test func refusesFivePlaces() {
    #expect(percent("1.23456") == nil)
    #expect(percent("0.00001") == nil)
    // Trailing zeros are no places of their own.
    #expect(percent("1.50000")?.e4 == 15_000)
  }

  @Test func refusesAboveHundredAndNegative() {
    #expect(percent("100.0001") == nil)
    #expect(percent("150") == nil)
    #expect(percent("-0.5") == nil)
    #expect(percent("-0.0001") == nil)
    #expect(CashbackPercent(e4: -1) == nil)
    #expect(CashbackPercent(e4: CashbackPercent.maxE4 + 1) == nil)
    #expect(CashbackPercent(decimal: .nan) == nil)
  }

  @Test func zeroAndHundredAreAllowed() {
    #expect(percent("0") == .zero)
    #expect(percent("100")?.e4 == CashbackPercent.maxE4)
    #expect(CashbackPercent(e4: 0) == .zero)
    #expect(CashbackPercent(e4: 1_000_000)?.e4 == 1_000_000)
  }

  @Test func theDecimalAndTheFractionAreExact() throws {
    let rate = try #require(percent("1.5"))
    #expect(rate.decimal == Decimal(string: "1.5")!)
    #expect(rate.fraction == Decimal(string: "0.015")!)
    let odd = try #require(percent("33.3333"))
    #expect(odd.decimal == Decimal(string: "33.3333")!)
    #expect(odd.fraction == Decimal(string: "0.333333")!)
    #expect(CashbackPercent.zero.fraction == 0)
  }

  @Test func percentsCompareByTheirValue() throws {
    let low = try #require(percent("0.5"))
    let high = try #require(percent("10"))
    #expect(low < high)
    #expect([high, .zero, low].sorted() == [.zero, low, high])
  }

  /// Decoding holds the same range: a value out of it is refused, not taken in.
  @Test func decodingRefusesAValueOutOfRange() throws {
    let good = try JSONDecoder().decode(
      CashbackPercent.self, from: Data(#"{"e4":15000}"#.utf8))
    #expect(good.e4 == 15_000)
    #expect(
      try JSONDecoder().decode(CashbackPercent.self, from: JSONEncoder().encode(good)) == good)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(CashbackPercent.self, from: Data(#"{"e4":1000001}"#.utf8))
    }
  }
}
