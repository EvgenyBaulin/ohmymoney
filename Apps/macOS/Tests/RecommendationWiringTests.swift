import AppCore
import XCTest

@testable import OhMyMoney

@MainActor
final class RecommendationWiringTests: XCTestCase {
  func testSwitchingTheFirstWeekdayKeepsTheTimeZone() {
    let compute = ComputeStore(calendar: .utc, rebuildsInline: true)
    compute.useWeekStarting(on: 7)
    XCTAssertEqual(compute.calendar.firstWeekday, 7)
    XCTAssertEqual(compute.calendar.timeZone, CalendarContext.utc.timeZone)
    compute.useWeekStarting(on: 1)
    XCTAssertEqual(compute.calendar.firstWeekday, 1)
  }

  func testImportedHistoryUnlocksAnalysisWithoutAddingHabitDays() throws {
    let today = DateOnly(year: 2026, month: 11, day: 17)
    let entries = (1...60).map { back in
      let transaction = Transaction(
        kind: .expense,
        occurredAt: CalendarContext.utc.noon(of: today.adding(days: -back)),
        amountE4: AmountE4(whole: 100), createdAt: CalendarContext.utc.noon(of: today),
        source: "statement")
      return TransactionEntry(
        transaction: transaction,
        parts: [
          TransactionPart(transactionId: transaction.id, amountE4: transaction.amountE4)
        ])
    }
    let dataset = Dataset(entries: entries)
    let snapshot = DataSnapshot.build(
      dataset: dataset, calendar: .utc, today: today,
      context: SnapshotContext(), version: DataVersion(load: 1))
    let facts = BeginnerModeOnMac.facts(snapshot, hasLoans: false)
    XCTAssertNil(BeginnerMode.unlock(.analytics, facts: facts))
    XCTAssertNil(BeginnerMode.unlock(.reports, facts: facts))
    XCTAssertTrue(HabitEntryDays.typedDays(entries, calendar: .utc).isEmpty)

    let suite = "ohmymoney.tests.q-rec.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    _ = FirstMonthStore.current(dataset, calendar: .utc, today: today, defaults: defaults)
    XCTAssertFalse(BeginnerModeOnMac.enabled(defaults))
  }

  func testTheNewWordsExistInRussianAndEnglish() {
    let environment = AppEnvironment()
    for choice in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = choice
      for (key, table) in [
        ("overview.verdict.tight", "Overview"),
        ("overview.verdict.tight.daily", "Overview"),
        ("overview.comparison.shorter", "Overview"),
        ("afford.deficitAndPurchase", "WhatIf"),
        ("warranty.section.returned", "Warranty"),
        ("warranty.returned", "Warranty"),
        ("entry.error.amountUnreadable", "Entry"),
        ("privacy.copy.scope.period.hint", "PrivacyExport"),
      ] {
        XCTAssertNotEqual(environment.language(key, table: table), key)
      }
    }
  }
}
