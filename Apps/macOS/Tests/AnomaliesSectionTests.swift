import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The «Аномалии» section of Analytics and the card of Overview: what the section shows for
/// the period on screen, and that every rule can say its name and its numbers in both
/// languages. The rules themselves are tested in `CoreInsightsTests`.
final class AnomaliesSectionTests: XCTestCase {
  private let september = MonthKey(year: 2026, month: 9)

  private func day(_ number: Int, of month: MonthKey? = nil) -> DateOnly {
    let month = month ?? september
    return DateOnly(year: month.year, month: month.month, day: number)
  }

  private func anomaly(
    _ rule: AnomalyRule, on day: DateOnly, subject: String = "x", hidden: Bool = false
  ) -> Anomaly {
    Anomaly(
      rule: rule, subject: subject, day: day, amount: AmountE4(whole: 1_000),
      reference: AmountE4(whole: 500), days: 40, isHidden: hidden)
  }

  private func model(_ report: AnomalyReport, period: Period) -> AnomaliesSectionModel {
    AnalyticsBuilder.anomalies(report, period: period)
  }

  /// The rules run over the whole history; the section shows the period the toolbar is on.
  func testTheSectionShowsThePeriodAndNotTheWholeHistory() {
    let report = AnomalyReport(all: [
      anomaly(.largeExpense, on: day(10), subject: "september"),
      anomaly(.largeExpense, on: day(10, of: september.previous), subject: "august"),
    ])

    let shown = model(report, period: .month(september))

    XCTAssertEqual(shown.found.content?.map(\.subject), ["september"])
  }

  /// «Это нормально» takes an anomaly out of the list and puts it under «Скрытые» — it does
  /// not take it out of the report, or the dismissal would be forgotten at the next write.
  func testWhatWasWavedAwayIsShownApart() {
    let report = AnomalyReport(all: [
      anomaly(.categorySpike, on: day(7), subject: "shown"),
      anomaly(.badSpendingRise, on: day(7), subject: "hidden", hidden: true),
    ])

    let shown = model(report, period: .month(september))

    XCTAssertEqual(shown.found.content?.map(\.subject), ["shown"])
    XCTAssertEqual(shown.hidden.map(\.subject), ["hidden"])
  }

  /// Nothing found is an answer, not «мало данных»: the rules ran.
  func testAQuietPeriodSaysSoInsteadOfSayingNothing() {
    let shown = model(AnomalyReport(), period: .month(september))

    XCTAssertEqual(shown.found.reason, .noAnomalies)
    XCTAssertTrue(shown.hidden.isEmpty)
  }

  /// Before the step has run there is nothing to say at all, and the block waits.
  func testWithoutTheStepTheSectionWaits() {
    XCTAssertEqual(
      AnalyticsBuilder.anomalies(nil, period: .month(september)).found.reason, .notStarted)
  }

  /// Every rule can name itself and describe its numbers in both languages: a key that
  /// resolved to itself would show up on the card as it is.
  @MainActor
  func testEveryRuleSpeaksBothLanguages() {
    let environment = AppEnvironment()
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      for rule in AnomalyRule.allCases {
        for key in [
          "analytics.anomaly.\(rule.rawValue)", "analytics.anomaly.\(rule.rawValue).detail",
        ] {
          XCTAssertNotEqual(
            environment.language(key, table: "Analytics"), key, "\(key), \(choice)")
        }
      }
      for key in [
        "analytics.block.anomalies", "analytics.basis.anomalies", "analytics.reason.noAnomalies",
        "analytics.anomaly.normal", "analytics.anomaly.restore", "analytics.anomaly.hidden",
      ] {
        XCTAssertNotEqual(environment.language(key, table: "Analytics"), key, "\(key), \(choice)")
      }
      for key in ["overview.anomalies", "overview.anomaliesNone", "overview.anomaliesMore"] {
        XCTAssertNotEqual(environment.language(key, table: "Overview"), key, "\(key), \(choice)")
      }
      for key in [
        "settings.anomalies", "settings.anomalies.sensitivity", "settings.anomalies.hint",
        "settings.anomalies.low", "settings.anomalies.normal", "settings.anomalies.high",
      ] {
        XCTAssertNotEqual(environment.language(key, table: "Settings"), key, "\(key), \(choice)")
      }
    }
  }

  /// The anomalies come from the last full run, the names from the freshest snapshot: an
  /// event or a category deleted in between is named by the words of its own kind — never
  /// «Без человека» for an event, never the bare key for a category.
  @MainActor
  func testANameDeletedSinceTheRunIsSaidInTheWordsOfItsKind() {
    let environment = AppEnvironment()
    var event = anomaly(.eventOverBudget, on: day(10))
    event.eventId = UUID()
    var large = anomaly(.largeExpense, on: day(10))
    large.categoryId = UUID()
    let names = AnalyticsNames()

    environment.language.choice = .russian
    let eventText = AnalyticsText.anomalyDetail(event, names: names, environment)
    XCTAssertTrue(eventText.contains("«Без события»"), eventText)
    XCTAssertFalse(eventText.contains("Без человека"), eventText)
    let largeText = AnalyticsText.anomalyDetail(large, names: names, environment)
    XCTAssertTrue(largeText.contains("«Без категории»"), largeText)

    environment.language.choice = .english
    XCTAssertTrue(
      AnalyticsText.anomalyDetail(event, names: names, environment).contains("No event"))
    XCTAssertTrue(
      AnalyticsText.anomalyDetail(large, names: names, environment).contains("Uncategorized"))
  }

  /// «Долгий возврат» counts its days in the plural of the language: the rule fires from the
  /// 31st day, and «ждут 31 дней» was the first thing it ever said.
  @MainActor
  func testTheDaysOfASlowReimbursementTakeTheirPluralForms() {
    let environment = AppEnvironment()
    func text(_ days: Int) -> String {
      var waiting = anomaly(.slowReimbursement, on: day(1, of: september.previous))
      waiting.days = days
      return AnalyticsText.anomalyDetail(waiting, names: AnalyticsNames(), environment)
    }

    environment.language.choice = .russian
    XCTAssertTrue(text(31).hasSuffix("ждут 31 день"), text(31))
    XCTAssertTrue(text(32).hasSuffix("ждут 32 дня"), text(32))
    XCTAssertTrue(text(35).hasSuffix("ждут 35 дней"), text(35))
    XCTAssertTrue(text(111).hasSuffix("ждут 111 дней"), text(111))
    environment.language.choice = .english
    XCTAssertTrue(text(31).hasSuffix("waiting 31 days"), text(31))
    XCTAssertTrue(text(1).hasSuffix("waiting 1 day"), text(1))
  }

  /// The anomalies are a card of Overview now, not a line saying they are coming.
  func testOverviewHasACardForThem() {
    XCTAssertTrue(OverviewTiles.standard.contains(.worthALook))
  }

  /// The section is no longer a placeholder, and it follows the period of the toolbar.
  func testTheSectionIsReal() {
    XCTAssertNil(AnalyticsSection.anomalies.plannedFor)
    XCTAssertTrue(AnalyticsSection.anomalies.followsThePeriod)
  }

  /// «Это нормально» and «Вернуть» that went through: the row is written or taken away, and
  /// the data is read again once each, so the rules run on the new dismissals.
  @MainActor
  func testAWrittenDismissalReadsTheDataAgain() throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let repository = AnomalyRepository(writer: stack.writer)
    let recounts = WriteCounter()
    let actions = AnomalyActions(repository: repository) { recounts.increment() }
    let found = anomaly(.largeExpense, on: day(10), subject: "coffee-shop")

    XCTAssertNil(actions.hide(found, active: nil))
    XCTAssertEqual(try repository.all().map(\.subject), ["coffee-shop"])
    XCTAssertEqual(recounts.value, 1)

    XCTAssertNil(actions.show(found))
    XCTAssertEqual(try repository.all().map(\.subject), [])
    XCTAssertEqual(recounts.value, 2)
  }

  /// A dismissal the database did not take — a full disk, a database closed while an archive
  /// replaces it — is not swallowed: the journal says which one failed, the owner is told in
  /// words of the catalogue, and the data is not read again for nothing (every card would
  /// blink through «Считается» and bring the same anomaly back without a word).
  @MainActor
  func testADismissalThatWasNotWrittenIsToldAndNothingIsRecounted() throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    try stack.close()
    let recounts = WriteCounter()
    let found = anomaly(.largeExpense, on: day(10), subject: "coffee-shop")
    let logs = FileManager.default.temporaryDirectory
      .appendingPathComponent("AnomaliesSectionTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: logs) }
    Logbook.shared.open(directory: logs, threshold: .debug)

    let closed = AnomalyActions(repository: AnomalyRepository(writer: stack.writer)) {
      recounts.increment()
    }
    let noDatabase = AnomalyActions(repository: nil) { recounts.increment() }
    let messages = [
      closed.hide(found, active: nil), closed.show(found), noDatabase.hide(found, active: nil),
      noDatabase.show(found),
    ]
    let lines = Logbook.shared.lines()
    Logbook.shared.close()

    XCTAssertEqual(recounts.value, 0, "the data was read again after a write that failed")
    XCTAssertEqual(messages.filter { $0 == nil }.count, 0, "a failure said nothing: \(messages)")
    let environment = AppEnvironment()
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      for key in Set(messages.compactMap { $0 }) {
        XCTAssertNotEqual(environment.language(key, table: "Analytics"), key, "\(key), \(choice)")
      }
    }
    XCTAssertEqual(lines.filter { $0.contains(" anomaly.dismiss.failed ") }.count, 2, "\(lines)")
    XCTAssertEqual(lines.filter { $0.contains(" anomaly.restore.failed ") }.count, 2, "\(lines)")
    XCTAssertFalse(lines.contains { $0.contains("coffee-shop") }, "the subject reached the journal")
  }
}
