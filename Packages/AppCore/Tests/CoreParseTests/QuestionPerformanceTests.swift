import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// A question is read on Enter and the palette is searched on every keystroke, so both have
/// to stay far below a frame. Only `make bench` runs the stopwatch (release, `OHMYMONEY_BENCH=1`).
@Suite("Performance of questions and the palette", .serialized, .enabled(if: ParseBench.isOn))
struct QuestionPerformanceTests {
  static let today = DateOnly(year: 2026, month: 10, day: 22)

  @Test func readingAQuestion() {
    let corpus = QuestionCorpusTests.corpus.map(\.text)
    let times = ParseBench.measure("question parse, \(corpus.count) phrases", runs: 11) {
      for text in corpus { _ = QuestionParser.parse(text, today: Self.today) }
    }
    // The whole corpus in a few milliseconds: one phrase well under a tenth of one.
    #expect(times.median < .milliseconds(40))
  }

  @Test func resolvingAgainstALargeCatalog() {
    let catalog = QuestionCatalog(
      categories: (0..<300).map {
        QuestionName(id: UUID(), name: "Категория номер \($0)", kind: .expense)
      },
      places: (0..<2_000).map { QuestionName(id: UUID(), name: "Место \($0)") },
      people: (0..<100).map { QuestionName(id: UUID(), name: "Человек \($0)") })
    let parsed = try! QuestionParser.parse(
      "сколько на категория номер 77 в месте 1500", today: Self.today
    ).get()
    let times = ParseBench.measure("question resolve, 2 400 names", runs: 11) {
      _ = QuestionResolver.resolve(parsed, in: catalog)
    }
    #expect(times.median < .milliseconds(30))
  }

  @Test func searchingThePalette() {
    let source = PaletteSource(
      accounts: (0..<500).map { PaletteNamed(id: UUID(), name: "Счёт \($0) Сбербанк") },
      debts: (0..<200).map { PaletteNamed(id: UUID(), name: "Долг \($0)") },
      goals: (0..<200).map { PaletteNamed(id: UUID(), name: "Цель \($0)") },
      categories: (0..<300).map { PaletteNamed(id: UUID(), name: "Категория \($0)") },
      people: (0..<300).map { PaletteNamed(id: UUID(), name: "Человек \($0)") })
    let entries = PaletteCatalog.entries(for: source)
    #expect(entries.count > 2_000)
    let index = PaletteIndex(entries)
    let building = ParseBench.measure("palette index, \(entries.count) lines", runs: 5) {
      _ = PaletteIndex(entries)
    }
    #expect(building.median < .milliseconds(60))
    for query in ["", "сбер", "сверить сбер", "перевод со счёта 42"] {
      let times = ParseBench.measure("palette \"\(query)\", \(entries.count) lines", runs: 11) {
        _ = CommandPalette.search(query, in: index)
      }
      #expect(times.median < .milliseconds(8), "«\(query)»")
    }
  }

  /// Work that grows with the square of the question is a frozen window.
  @Test func aVeryLongQuestion() {
    func words(_ count: Int) -> String {
      "сколько на " + (0..<count).map { "слово\($0 % 50)" }.joined(separator: " ") + " в сентябре"
    }
    let short = ParseBench.measure("question, 500 words", runs: 5) {
      _ = QuestionParser.parse(words(500), today: Self.today)
    }
    let long = ParseBench.measure("question, 2 000 words", runs: 5) {
      _ = QuestionParser.parse(words(2_000), today: Self.today)
    }
    #expect(long.median < .milliseconds(100))
    #expect(long.median < short.median * 8)
  }
}
