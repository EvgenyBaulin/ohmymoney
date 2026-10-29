import CoreKit
import Testing

@testable import CoreAccounting

@Suite("The wallet counted by the bill")
struct CashCountTests {
  @Test("5000 × 2, 1000 × 3, 100 × 7 make 13 700")
  func exampleSum() {
    var count = CashCount(currency: .rub)
    count.set(CashDenomination(5000, .note), 2)
    count.set(CashDenomination(1000, .note), 3)
    count.set(CashDenomination(100, .note), 7)
    #expect(count.total == AmountE4(whole: 13_700))
    #expect(count.terms == ["5000 × 2", "1000 × 3", "100 × 7"])
  }

  @Test("ruble tables hold the notes and the coins, ten of each apart")
  func rubleTable() throws {
    let table = try #require(CashCount.denominations(for: .rub))
    #expect(table.map(\.value) == [5000, 2000, 1000, 500, 200, 100, 50, 10, 10, 5, 2, 1])
    var count = CashCount(currency: .rub)
    count.set(CashDenomination(10, .note), 1)
    count.set(CashDenomination(10, .coin), 2)
    #expect(count.total == AmountE4(whole: 30))
  }

  @Test("dollars and euros have their own bills; an own currency has none")
  func otherCurrencies() {
    #expect(CashCount.denominations(for: .usd)?.map(\.value) == [100, 50, 20, 10, 5, 2, 1])
    #expect(CashCount.denominations(for: .eur)?.map(\.value) == [500, 200, 100, 50, 20, 10, 5])
    #expect(CashCount.denominations(for: CurrencyCode("GEL")) == nil)
  }

  @Test("a denomination of another currency is ignored; negatives and excess are clamped")
  func clamping() {
    var count = CashCount(currency: .usd)
    count.set(CashDenomination(5000, .note), 3)
    #expect(count.isEmpty)
    count.set(CashDenomination(20, .note), -4)
    #expect(count.isEmpty)
    count.set(CashDenomination(20, .note), Int.max)
    #expect(count.count(of: CashDenomination(20, .note)) == CashCount.maxPerDenomination)
    #expect(count.total < AmountE4.inputLimit)
  }

  @Test("the largest wallet possible stays inside the input limit")
  func largestWallet() {
    var count = CashCount(currency: .rub)
    for denomination in CashCount.denominations(for: .rub) ?? [] {
      count.set(denomination, CashCount.maxPerDenomination)
    }
    #expect(count.total < AmountE4.inputLimit)
  }

  @Test("an empty wallet is zero")
  func empty() {
    #expect(CashCount(currency: .eur).total == .zero)
    #expect(CashCount(currency: .eur).terms.isEmpty)
  }
}
