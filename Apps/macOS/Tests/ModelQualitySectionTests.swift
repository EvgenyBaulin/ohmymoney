import AppCore
import XCTest

@testable import OhMyMoney

/// «Качество модели»: the section says what was measured on this history, and says so in
/// both languages. The measurements themselves are tested in the package.
final class ModelQualitySectionTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 9, day: 18)

  /// An empty history: the model has nothing to be right about and there is no past to check
  /// a forecast against — two reasons, not two empty tables.
  func testAnEmptyHistoryExplainsItselfTwice() {
    let model = AnalyticsBuilder.modelQuality(
      ledger: Ledger(dataset: .empty, calendar: .utc), today: today)

    XCTAssertEqual(model.categories.reason, AnalyticsReason.modelNotReady)
    XCTAssertEqual(model.forecast.reason, AnalyticsReason.noBacktest)
  }

  /// The figures the section lists, in the order it lists them: how often the model is
  /// right, how often it dares, and the two baselines it must beat to be worth having.
  @MainActor
  func testTheTableListsWhatTheModelScored() {
    var metrics = PrequentialEvaluation.Metrics()
    metrics.asked = 300
    metrics.classes = 27
    metrics.classesReady = 19
    metrics.top1Bp = 7_280
    metrics.baselineLastSameTextBp = 6_250
    let categories = ModelQuality.Categories(
      readiness: .on(classes: 19), examples: 421, metrics: metrics)

    let rows = MeasuredTable.rows(of: categories, AppEnvironment())

    XCTAssertEqual(rows.count, 10)
    XCTAssertEqual(rows.first?.value, "421")
    XCTAssertEqual(rows[1].value, "300")
    XCTAssertEqual(rows[2].value, "27 / 19")
    // Every figure is a share of a hundred, never a raw basis-point count.
    XCTAssertTrue(rows[3].value.contains("72"), rows[3].value)
    XCTAssertTrue(rows[9].value.contains("62"), rows[9].value)
  }

  /// The owner's choices against the model close the table: how many, how
  /// many went elsewhere, and how sure the model was when they did.
  @MainActor
  func testTheTableEndsWithTheOwnersChoices() {
    var metrics = PrequentialEvaluation.Metrics()
    metrics.asked = 300
    let categories = ModelQuality.Categories(
      readiness: .on(classes: 19), examples: 421, metrics: metrics,
      choices: ModelQuality.Choices(made: 12, overruled: 3, confidenceWhenOverruledBp: 7_150))

    let rows = MeasuredTable.rows(of: categories, AppEnvironment())

    XCTAssertEqual(rows.count, 13)
    XCTAssertEqual(rows[10].value, "12")
    XCTAssertEqual(rows[11].value, "3")
    XCTAssertTrue(rows[12].value.contains("71"), rows[12].value)
  }

  /// A model that is still silent has no table at all — and the rows say so by being none.
  @MainActor
  func testASilentModelHasNothingToList() {
    let categories = ModelQuality.Categories(
      readiness: .tooFewExamples(have: 10, needed: 50), examples: 10)

    XCTAssertTrue(MeasuredTable.rows(of: categories, AppEnvironment()).isEmpty)
  }

  @MainActor
  func testTheSectionSpeaksBothLanguages() {
    let environment = AppEnvironment()
    let keys =
      [
        "analytics.block.modelCategories", "analytics.block.modelForecast",
        "analytics.basis.modelQuality", "analytics.reason.modelNotReady",
        "analytics.reason.noBacktest", "analytics.forecast.origins", "analytics.forecast.mae",
        "analytics.forecast.pinball", "analytics.forecast.coverage", "analytics.forecast.inUse",
        "analytics.model.examples", "analytics.model.asked", "analytics.model.classes",
        "analytics.model.top1", "analytics.model.top3", "analytics.model.coverage",
        "analytics.model.precision", "analytics.model.macroF1",
        "analytics.model.baselineFrequent", "analytics.model.baselineText",
        "analytics.model.choices", "analytics.model.overruled",
        "analytics.model.sureWhenOverruled",
      ] + MonthForecast.Method.allCases.map { "analytics.forecast.method.\($0.rawValue)" }

    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      for key in keys {
        XCTAssertNotEqual(environment.language(key, table: "Analytics"), key, "\(key), \(choice)")
      }
    }
  }

  /// Nothing on the Analytics sidebar is a promise any more: every section computes.
  func testNoSectionIsAPlaceholder() {
    for section in AnalyticsSection.allCases {
      XCTAssertNil(section.plannedFor, "\(section)")
    }
  }
}
