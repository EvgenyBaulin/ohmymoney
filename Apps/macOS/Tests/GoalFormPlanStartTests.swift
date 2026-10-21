import AppCore
import XCTest

@testable import OhMyMoney

/// The month a goal's monthly plan counts from, as «Сохранить» of the goal form writes it: a
/// plan that appears starts this month, a plan removed has no start, and a new amount keeps the
/// start it had. The form says it under «План в месяц»: «Начало плана — Сентябрь 2026.
/// Внесённое сверх плана месяца засчитывается в следующие месяцы.»
@MainActor
final class GoalFormPlanStartTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 9, day: 27)
  private let may = MonthKey(year: 2026, month: 5)

  private func goal(plan: Int64?, start: MonthKey? = nil) -> Goal {
    Goal(
      name: "Отпуск", targetE4: AmountE4(whole: 150_000),
      targetDate: DateOnly(year: 2027, month: 6, day: 1),
      monthlyPlanE4: plan.map { AmountE4(whole: $0) }, planStartMonth: start)
  }

  /// A new goal with a plan, and a saved goal that gets one: the plan starts this month.
  func testAPlanThatAppearsStartsThisMonth() {
    let new = GoalForm.saving(goal(plan: 10_000), hasDate: true, original: nil, today: today)
    XCTAssertEqual(new.planStartMonth, today.monthKey)

    let saved = goal(plan: nil)
    var edited = saved
    edited.monthlyPlanE4 = AmountE4(whole: 10_000)
    XCTAssertEqual(
      GoalForm.saving(edited, hasDate: true, original: saved, today: today).planStartMonth,
      today.monthKey)
    XCTAssertNil(
      GoalForm.saving(goal(plan: nil), hasDate: true, original: nil, today: today)
        .planStartMonth, "a goal without a plan got a start")
  }

  /// The plan removed — emptied or zero —: no start is kept.
  func testAPlanRemovedHasNoStart() {
    let saved = goal(plan: 10_000, start: may)
    var emptied = saved
    emptied.monthlyPlanE4 = nil
    XCTAssertNil(
      GoalForm.saving(emptied, hasDate: true, original: saved, today: today).planStartMonth)
  }

  /// Another amount, the date taken away: the start stays May, and only the date goes.
  func testAnAmountChangeKeepsTheStart() {
    let saved = goal(plan: 10_000, start: may)
    var edited = saved
    edited.monthlyPlanE4 = AmountE4(whole: 12_000)
    let written = GoalForm.saving(edited, hasDate: false, original: saved, today: today)
    XCTAssertEqual(written.planStartMonth, may)
    XCTAssertNil(written.targetDate)
    XCTAssertEqual(written.monthlyPlanE4, AmountE4(whole: 12_000))
  }

  /// The words under the plan, with the month as a title, in both languages.
  func testTheHintNamesTheMonthInBothLanguages() {
    let environment = AppEnvironment()
    let before = environment.language.choice
    defer { environment.language.choice = before }
    let expected: [AppLanguage.Choice: String] = [
      .russian: "Начало плана — Май 2026.", .english: "The plan starts in May 2026.",
    ]
    for (choice, start) in expected {
      environment.language.choice = choice
      let text = environment.format(
        "form.goal.planHint", table: "Planning", environment.dates.monthTitle(may))
      XCTAssertTrue(text.hasPrefix(start), "\(choice.rawValue): \(text)")
    }
  }
}
