import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Цель подушки»: six months unless set, a month to be done by only when asked, the free-sum
/// switch off unless set; the save writes only the settings that changed, as one step of ⌘Z,
/// and «Убрать цель» takes the goal and its month away.
@MainActor
final class CushionGoalFormTests: CushionDatabaseTestCase {
  /// A new goal starts at six months, no month, the cushion in the free sum.
  func testTheDefaults() {
    let draft = CushionGoalDraft(.standard)
    XCTAssertEqual(draft.months, 6)
    XCTAssertNil(draft.byMonth)
    XCTAssertFalse(draft.outOfFreeMoney)
    let stored = CushionGoalDraft(
      CapitalSettings(
        targetMonths: 3, targetMonth: MonthKey(year: 2027, month: 3), outOfFreeMoney: true))
    XCTAssertEqual(stored.months, 3)
    XCTAssertEqual(stored.byMonth, MonthKey(year: 2027, month: 3))
    XCTAssertTrue(stored.outOfFreeMoney)
  }

  /// The months stay within 1…24, and the history of the spending is never touched by the form.
  func testTheSettingsTheFormWrites() {
    var draft = CushionGoalDraft(.standard)
    draft.months = 40
    let over = CapitalSettings(historyMonths: 9)
    XCTAssertEqual(draft.settings(over: over).targetMonths, 24)
    XCTAssertEqual(draft.settings(over: over).historyMonths, 9)
    draft.months = 0
    XCTAssertEqual(draft.settings(over: over).targetMonths, 1)
    draft.byMonth = MonthKey(year: 2027, month: 1)
    let removed = draft.settings(over: over, removingGoal: true)
    XCTAssertNil(removed.targetMonths)
    XCTAssertNil(removed.targetMonth)
  }

  /// «Собрать к» offers five years of months from this one, and the month stored even if past.
  func testTheMonthsOffered() {
    let today = DateOnly(year: 2026, month: 10, day: 11)
    let months = CushionGoalDraft.monthChoices(today: today, including: nil)
    XCTAssertEqual(months.first, MonthKey(year: 2026, month: 10))
    XCTAssertEqual(months.count, 60)
    let past = MonthKey(year: 2026, month: 1)
    XCTAssertEqual(CushionGoalDraft.monthChoices(today: today, including: past).first, past)
  }

  /// The save writes the three settings that changed and nothing else, read back as written;
  /// one ⌘Z takes the goal away again. Saving the same again writes nothing.
  func testTheSaveIsOneStepOfUndo() throws {
    let before = CushionGoalForm.read(environment)
    XCTAssertEqual(before, .standard)
    var draft = CushionGoalDraft(before)
    draft.months = 8
    draft.byMonth = MonthKey(year: 2027, month: 3)
    draft.outOfFreeMoney = true
    let change = try XCTUnwrap(
      CushionGoalDraft.change(from: before, to: draft.settings(over: before), at: Date()))
    XCTAssertEqual(
      Set(change.settings.keys),
      [
        CapitalSettings.targetMonthsKey, CapitalSettings.targetMonthKey,
        CapitalSettings.outOfFreeMoneyKey,
      ])
    XCTAssertTrue(CushionGoalForm.save(draft, over: before, store: store, now: environment.now()))
    let after = CushionGoalForm.read(environment)
    XCTAssertEqual(after.targetMonths, 8)
    XCTAssertEqual(after.targetMonth, MonthKey(year: 2027, month: 3))
    XCTAssertTrue(after.outOfFreeMoney)
    XCTAssertEqual(after.historyMonths, CapitalSettings.defaultHistoryMonths)
    XCTAssertTrue(store.canUndo)

    XCTAssertNil(CushionGoalDraft.change(from: after, to: draft.settings(over: after), at: Date()))

    store.undo()
    XCTAssertEqual(CushionGoalForm.read(environment), .standard, "one ⌘Z: the goal is gone")
  }

  /// «Убрать цель» deletes the goal and its month and keeps the switch; one ⌘Z brings them back.
  func testRemovingTheGoal() throws {
    let set = CapitalSettings(targetMonths: 6, targetMonth: MonthKey(year: 2027, month: 6))
    XCTAssertTrue(
      CushionGoalForm.save(
        CushionGoalDraft(set), over: .standard, store: store, now: environment.now()))
    let stored = CushionGoalForm.read(environment)
    XCTAssertEqual(stored.targetMonths, 6)
    XCTAssertTrue(
      CushionGoalForm.save(
        CushionGoalDraft(stored), over: stored, removingGoal: true, store: store,
        now: environment.now()))
    XCTAssertNil(CushionGoalForm.read(environment).targetMonths)
    XCTAssertNil(CushionGoalForm.read(environment).targetMonth)
    store.undo()
    XCTAssertEqual(CushionGoalForm.read(environment).targetMonths, 6)
  }

  /// The words of the form, in both languages.
  func testTheWords() {
    environment.language.choice = .russian
    XCTAssertEqual(
      environment.format("cushion.goal.months", table: "Cushion", counts: 6),
      "Подушка на 6 месяцев")
    XCTAssertEqual(
      environment.format("cushion.goal.months", table: "Cushion", counts: 3),
      "Подушка на 3 месяца")
    environment.language.choice = .english
    XCTAssertEqual(
      environment.format("cushion.goal.months", table: "Cushion", counts: 1),
      "A cushion for 1 month")
  }
}
