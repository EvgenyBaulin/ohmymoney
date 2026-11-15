import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

@Suite("A share cut off in basis points")
struct TruncatedRatioTests {
  @Test func isCutOffNotRounded() {
    #expect(
      Shares.truncatedRatio(AmountE4(whole: 2_150_000), of: AmountE4(whole: 2_400_000)) == 8958)
    // 99.996 % is not yet the whole.
    #expect(Shares.truncatedRatio(AmountE4(whole: 99_996), of: AmountE4(whole: 100_000)) == 9_999)
    #expect(Shares.truncatedRatio(AmountE4(whole: 300), of: AmountE4(whole: 200)) == 15_000)
  }

  @Test func noBaseIsZero() {
    #expect(Shares.truncatedRatio(AmountE4(whole: 5), of: .zero) == 0)
    #expect(Shares.truncatedRatio(AmountE4(whole: 5), of: AmountE4(whole: -5)) == 0)
  }

  @Test func aHundredBillionAndMoreNeverTrap() {
    let income = AmountE4(whole: 100_000_000_000)
    let limit = AmountE4(whole: 2_400_000)
    #expect(Shares.truncatedRatio(income, of: limit) == 416_666_666)
    #expect(Shares.truncatedRatio(AmountE4(raw: .max), of: AmountE4(raw: 1)) == Int(Int32.max))
    #expect(Shares.truncatedRatio(AmountE4(raw: .min), of: AmountE4(raw: 1)) == -Int(Int32.max))
  }
}
