import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// A paste is read on ⌘V and a line with «;» on every keystroke, so neither may grow faster than
/// its length. Only `make bench` runs this, in release, with `OHMYMONEY_BENCH=1`.
@Suite("Performance of quick entry", .serialized, .enabled(if: ParseBench.isOn))
struct QuickEntryPerformanceTests {
  let parser = BankTextParser()
  let today = DateOnly(year: 2026, month: 10, day: 13)

  static func pushes(_ count: Int) -> String {
    let shops = ["PYATEROCHKA", "YANDEX GO", "MAGNIT 9876 RUS", "LENTA", "OZON"]
    return (0..<count).map { index in
      "MIR-3230 12:\(String(format: "%02d", index % 60)) Покупка \(100 + index)р \(shops[index % shops.count]) Баланс: \(50_000 - index).11р"
    }.joined(separator: "\n")
  }

  @Test func aLongListOfPushes() {
    let short = ParseBench.measure("paste, 100 pushes") {
      _ = parser.reading(of: Self.pushes(100), today: today)
    }
    let long = ParseBench.measure("paste, 400 pushes") {
      _ = parser.reading(of: Self.pushes(400), today: today)
    }
    // A hundred pushes is far more than anyone copies at once; it must still feel instant.
    #expect(short.median < .milliseconds(100))
    #expect(long.median < .milliseconds(400))
    #expect(long.median < short.median * 8)
  }

  @Test func aLongTextThatIsNotBankTextsIsGivenBackFast() {
    let prose = String(
      repeating: "Это просто длинное письмо про покупку 500 р и карту. ", count: 2_000)
    let times = ParseBench.measure("paste, 100 KB of prose") {
      _ = parser.reading(of: prose, today: today)
    }
    #expect(times.median < .milliseconds(250))
  }

  @Test func aHistoryOfRows() {
    let rows = (0..<300).map { "SHOP \($0) −\(100 + $0),50 ₽ \(1 + $0 % 28) октября" }.joined(
      separator: "\n")
    let times = ParseBench.measure("paste, 300 history rows") {
      _ = parser.reading(of: rows, today: today)
    }
    #expect(times.median < .milliseconds(300))
  }

  @Test func theBatchLineIsReadOnEveryKeystroke() {
    let line = (1...30).map { "кофе \($0)" }.joined(separator: "; ")
    let times = ParseBench.measure("batch line, 30 parts") {
      _ = MultiEntryLine.read(line, parser: Fixture.parser, today: Fixture.today)
    }
    #expect(times.median < .milliseconds(50))
  }

  @Test func theTipIsLookedForOnEveryKeystroke() {
    let line = String(repeating: "кофе ", count: 200) + "2000 чай 200"
    let times = ParseBench.measure("tip line, 200 words") {
      _ = TipLine.read(line, parser: Fixture.parser, today: Fixture.today)
    }
    #expect(times.median < .milliseconds(100))
  }

  @Test func placeSuggestionsOverAYearOfHistory() {
    let places = (0..<300).map { ParserVocabulary.Entry(id: UUID(), name: "Магазин \($0)") }
    let history = (0..<20_000).map { index in
      PlacePurchase(
        placeId: places[index % places.count].id,
        money: Money(amount: AmountE4(whole: Int64(100 + index % 900)), currency: .rub),
        occurredAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 600))
    }
    let times = ParseBench.measure("place suggestions, 20 000 purchases") {
      _ = PlaceSuggestions.suggest(prefix: "маг", places: places, history: history)
    }
    #expect(times.median < .milliseconds(250))
  }
}
