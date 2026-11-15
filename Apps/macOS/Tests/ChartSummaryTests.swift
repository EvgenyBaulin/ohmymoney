import XCTest

@testable import OhMyMoney

/// The one sentence a chart is named by for VoiceOver: the count, the highest and the lowest,
/// in the words the marks already carry; no chart, no sentence.
@MainActor
final class ChartSummaryTests: XCTestCase {
  private let words = ChartSummary.Words(
    many: "n=%1$d high=%2$@ low=%3$@", single: "only %1$@")

  private func point(_ label: String, _ text: String, _ value: Int64) -> ChartSummary.Point {
    ChartSummary.Point(label: label, valueText: text, value: value)
  }

  func testNoMarksGiveNoSentence() {
    XCTAssertNil(ChartSummary.describe([], words: words))
  }

  func testOneMarkIsNamedAlone() {
    let sentence = ChartSummary.describe([point("March", "10 ₽", 10)], words: words)
    XCTAssertEqual(sentence, "only March, 10 ₽")
  }

  func testTheHighestAndTheLowestAreNamedWithTheirWords() {
    let sentence = ChartSummary.describe(
      [point("Jan", "5 ₽", 5), point("Feb", "9 ₽", 9), point("Mar", "−2 ₽", -2)], words: words)
    XCTAssertEqual(sentence, "n=3 high=Feb, 9 ₽ low=Mar, −2 ₽")
  }

  func testTiesGoToTheFirstMark() {
    let sentence = ChartSummary.describe(
      [point("A", "1", 1), point("B", "1", 1)], words: words)
    XCTAssertEqual(sentence, "n=2 high=A, 1 low=A, 1")
  }

  func testALabelThatCarriesItsValueIsNotRepeated() {
    XCTAssertEqual(point("Oct 2026, 21,400 ₽", "", 1).spoken, "Oct 2026, 21,400 ₽")
  }

  func testTheSentenceExistsInRussianAndEnglish() {
    let language = AppLanguage()
    let previous = language.choice
    defer { language.choice = previous }
    for choice in [AppLanguage.Choice.russian, .english] {
      language.choice = choice
      for key in ["chart.summary.many", "chart.summary.single"] {
        XCTAssertNotEqual(language(key), key, "\(key) has no text in \(choice)")
      }
    }
    language.choice = .russian
    XCTAssertTrue(language("chart.summary.many").hasPrefix("График"))
  }
}
