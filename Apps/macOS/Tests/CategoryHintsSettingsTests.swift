import AppCore
import SwiftUI
import XCTest

@testable import OhMyMoney

@MainActor
final class CategoryHintsSettingsTests: XCTestCase {
  func testTheQualitySectionDoesNotAdvertiseASuggestionSwitch() {
    let keys = SettingsSection.categoryHints.index.map(\.key)
    XCTAssertFalse(keys.contains("settings.categoryHints.enabled"))
    XCTAssertFalse(keys.contains("settings.categoryHints.modeHint"))
  }

  func testTheFourCardsUseTheActualMetricsAndF1IsAScore() {
    var metrics = PrequentialEvaluation.Metrics()
    metrics.asked = 100
    metrics.top1Bp = 8_700
    metrics.macroF1Bp = 8_100
    metrics.coverageBp = 9_300
    let environment = AppEnvironment()
    let categories = ModelQuality.Categories(
      readiness: .on(classes: 3), examples: 1_240, metrics: metrics)
    let cards = CategoryHintsSummary.cards(categories, environment)
    XCTAssertEqual(
      cards.map(\.key),
      [
        "settings.categoryHints.accuracy", "settings.categoryHints.macroF1",
        "settings.categoryHints.coverage", "settings.categoryHints.examples",
      ])
    XCTAssertEqual(
      cards.map(\.value),
      [
        environment.money.percent(basisPoints: 8_700),
        environment.money.number(Decimal(8_100) / 10_000, fractionDigits: 2...2),
        environment.money.percent(basisPoints: 9_300),
        environment.money.count(1_240),
      ])
  }

  func testColdStartAndNoAnsweredQuestionsNeverClaimZeroAccuracy() {
    let environment = AppEnvironment()
    for metrics in [nil, PrequentialEvaluation.Metrics()] {
      let categories = ModelQuality.Categories(
        readiness: .tooFewExamples(have: 12, needed: 50), examples: 12, metrics: metrics)
      let cards = CategoryHintsSummary.cards(categories, environment)
      XCTAssertEqual(Array(cards.prefix(3).map(\.value)), ["—", "—", "—"])
      XCTAssertEqual(cards.last?.value, "12")
    }
  }

  func testTheGraphHasTwoNamedDistinguishableIntegerSeriesAndKeepsMonthGaps() {
    let months = [
      PrequentialEvaluation.Month(
        month: MonthKey(year: 2026, month: 1), asked: 12, accuracyBp: 8_700, historyBp: 6_500),
      PrequentialEvaluation.Month(
        month: MonthKey(year: 2026, month: 3), asked: 23, accuracyBp: 9_100, historyBp: 7_100),
    ]
    let environment = AppEnvironment()
    let series = ModelAccuracyChart.series(months, environment)
    XCTAssertEqual(series.map(\.id), ["model", "history"])
    XCTAssertEqual(series[0].points.map(\.value), [8_700, 9_100])
    XCTAssertEqual(series[1].points.map(\.value), [6_500, 7_100])
    XCTAssertEqual(series[0].points[1].x - series[0].points[0].x, 2)
    XCTAssertNotEqual(series[0].style.symbol, series[1].style.symbol)
    XCTAssertNotEqual(series[0].style.dash, series[1].style.dash)
    XCTAssertTrue(
      series.flatMap(\.points).allSatisfy { !$0.spokenLabel.isEmpty && !$0.valueText.isEmpty })
    XCTAssertTrue(ModelAccuracyChart.series([], environment).allSatisfy { $0.points.isEmpty })
  }

  func testEveryNewCaptionIsLocalizedAndSearchFindsTheMetrics() {
    let environment = AppEnvironment()
    let keys =
      CategoryHintsSummary.keys + [
        "settings.categoryHints.explanation", "settings.categoryHints.metricsHint",
        "settings.categoryHints.chart", "settings.categoryHints.model",
        "settings.categoryHints.history", "settings.categoryHints.details",
        "settings.categoryHints.noMonths",
        "categories.appearance.suggest",
      ]
    let before = environment.language.choice
    defer { environment.language.choice = before }
    for language in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = language
      for key in keys {
        XCTAssertNotEqual(environment.language(key, table: "Settings"), key, "\(language) \(key)")
      }
    }
    for key in CategoryHintsSummary.keys {
      XCTAssertTrue(SettingsSection.categoryHints.index.map(\.key).contains(key))
    }
    XCTAssertTrue(
      SettingsSection.categories.index.map(\.key).contains("categories.appearance.suggest"))
  }

  #if os(macOS)
    func testFourCardsFitTheSettingsContentWidth() {
      let environment = AppEnvironment()
      let categories = ModelQuality.Categories(
        readiness: .tooFewExamples(have: 12, needed: 50), examples: 12)
      let host = NSHostingView(
        rootView: CategoryHintsSummary(categories: categories)
          .appDependencies(AppDependencies.forTests(environment)).frame(width: 624))
      XCTAssertLessThanOrEqual(host.fittingSize.width, 624)
      XCTAssertGreaterThan(host.fittingSize.height, 60)
      XCTAssertFalse(CategoryHintsSummary.cards(categories, environment).isEmpty)
    }
  #endif
}
