import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

@MainActor
final class FreeMoneySettingsTests: CushionDatabaseTestCase {
  func testHorizonPersistsThroughThePlanningRepository() throws {
    let settings = try XCTUnwrap(environment.settings)
    let planning = try XCTUnwrap(environment.planning)
    XCTAssertEqual(try planning.book().settings.freeMoneyHorizon, .thirtyDays)
    try settings.set(PlanningSettings.freeMoneyHorizonKey, to: "nearestIncome")
    XCTAssertEqual(try planning.book().settings.freeMoneyHorizon, .nearestIncome)
    try settings.set(PlanningSettings.freeMoneyHorizonKey, to: "thirtyDays")
    XCTAssertEqual(try planning.book().settings.freeMoneyHorizon, .thirtyDays)
    try settings.set(PlanningSettings.freeMoneyHorizonKey, to: "invalid")
    XCTAssertEqual(try planning.book().settings.freeMoneyHorizon, .thirtyDays)
  }

  func testHorizonWritesOnlyItsOwnKey() {
    let before = PlanningSettings()
    var after = before
    after.freeMoneyHorizon = .nearestIncome
    XCTAssertEqual(
      PlanningSettingsView.changedKeys(before: before.storedValues, after: after.storedValues),
      [PlanningSettings.freeMoneyHorizonKey])
    XCTAssertEqual(after.storedValues[PlanningSettings.freeMoneyHorizonKey], "nearestIncome")
  }

  func testCushionDefaultAndExplicitChoicesSurviveReading() throws {
    let settings = try XCTUnwrap(environment.settings)
    XCTAssertTrue(CushionGoalForm.read(environment).outOfFreeMoney)
    try settings.set(CapitalSettings.outOfFreeMoneyKey, to: "0")
    XCTAssertFalse(CushionGoalForm.read(environment).outOfFreeMoney)
    try settings.set(CapitalSettings.historyMonthsKey, to: "9")
    XCTAssertFalse(CushionGoalForm.read(environment).outOfFreeMoney)
    try settings.set(CapitalSettings.outOfFreeMoneyKey, to: "1")
    XCTAssertTrue(CushionGoalForm.read(environment).outOfFreeMoney)
  }

  func testHeroAndSettingsWordsInBothLanguages() throws {
    let day = DateOnly(year: 2026, month: 9, day: 19)
    let account = PaymentMethod(name: "Main", currency: .rub, isDefault: true)
    let count = Reconciliation(
      date: day, reconciledAt: CalendarContext.utc.startOfDay(day), actualTotalRubE4: .zero,
      kind: .accounts)
    let balance = ReconciledBalance(
      reconciliationId: count.id, accountId: account.id, currency: .rub,
      actualE4: AmountE4(whole: 44_580))
    let bill = ScheduledPayment(
      name: "Bill", amountE4: AmountE4(whole: 3_000), day: 25,
      nextDate: DateOnly(year: 2026, month: 9, day: 25))
    let dataset = Dataset(
      paymentMethods: [account],
      planning: PlanningBook(
        scheduled: [bill], reconciliations: [count], reconciledBalances: [balance]))
    let ledger = Ledger(dataset: dataset, calendar: .utc)
    let snapshot = PlanningSnapshot.build(
      ledger: ledger, today: day, now: CalendarContext.utc.startOfDay(day), rubPerUnit: [:])
    let free = snapshot.configuredFreeMoney(ledger: ledger)
    for russian in [true, false] {
      environment.language.choice = russian ? .russian : .english
      let hero = try XCTUnwrap(OverviewHero.content(free: free, horizon: .thirtyDays, environment))
      XCTAssertEqual(hero.caption, russian ? "Сейчас свободно" : "Free now")
      XCTAssertEqual(hero.figure, environment.money.rounded(AmountE4(whole: 41_580)))
      XCTAssertTrue(hero.lines[0].contains(environment.money.rounded(AmountE4(whole: 1_386))))
      let nearest = try XCTUnwrap(
        OverviewHero.content(free: free, horizon: .nearestIncome, environment))
      XCTAssertTrue(nearest.lines[0].hasPrefix(russian ? "До " : "Until "))
      for key in [
        "settings.planning.freeMoneyHorizon", "settings.planning.freeMoneyHorizonHint",
        "settings.planning.freeMoneyHorizon.thirtyDays",
        "settings.planning.freeMoneyHorizon.nearestIncome",
      ] {
        XCTAssertNotEqual(environment.language(key, table: "Settings"), key)
      }
    }
  }
}
