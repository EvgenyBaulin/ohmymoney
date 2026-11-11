import AppCore
import SwiftUI
import UIKit
import XCTest

@testable import OhMyMoney

@MainActor
final class PhoneCalendarTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 11, day: 11)

  private func snapshot() throws -> DataSnapshot {
    let food = CoreKit.Category(kind: .expense, name: "Food")
    var draft = TransactionDraft(
      occurredAt: CalendarContext.system.noon(of: today),
      amount: AmountE4(whole: 1_800), note: "Lunch")
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = food.id
    let rent = ScheduledPayment(
      name: "Rent", amountE4: AmountE4(whole: 30_000), day: 12,
      nextDate: today.adding(days: 1))
    return DataSnapshot.build(
      dataset: Dataset(
        entries: [try draft.materialize()], categories: [food],
        planning: PlanningBook(scheduled: [rent])),
      calendar: .system, today: today, context: SnapshotContext(), version: DataVersion(load: 0))
  }

  func testPhoneWeekAndDayUseTheSameSpendingOperationsAndPlansAsTheMonth() throws {
    let snapshot = try snapshot()
    let month = CalendarScreen.calendar(
      of: snapshot, scope: .month, anchor: today, firstWeekday: 1)
    let week = CalendarScreen.calendar(
      of: snapshot, scope: .week, anchor: today, firstWeekday: 1)
    XCTAssertEqual(week.day(today)?.spent, AmountE4(whole: 1_800))
    XCTAssertEqual(week.day(today)?.spent, month.day(today)?.spent)
    XCTAssertEqual(week.days.map(\.day).count, 7)
    let groups = CalendarScreen.groups(of: week.day(today), in: snapshot, calendar: .system)
    XCTAssertEqual(groups.flatMap(\.selectableIds).count, 1)
    let tomorrow = try XCTUnwrap(week.day(today.adding(days: 1)))
    XCTAssertEqual(tomorrow.plans.map(\.name), ["Rent"])
    XCTAssertEqual(tomorrow.plannedOut, AmountE4(whole: 30_000))
    XCTAssertEqual(tomorrow.plans, month.day(tomorrow.day)?.plans)
  }

  func testMonthWeekAndBothDayTabsDrawAtSmallAndLargePhoneWidths() throws {
    let snapshot = try snapshot()
    let environment = AppEnvironment()
    let before = environment.language.choice
    defer { environment.language.choice = before }
    let compute = ComputeStore(calendar: .system, rebuildsInline: true)
    compute.applyLight(snapshot)
    let deps = AppDependencies(
      environment: environment, store: TransactionsStore(), compute: compute)
    for language in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = language
      for width in [CGFloat(320), 440] {
        for scope in CalendarScope.allCases {
          var state = PhoneCalendarState()
          state.changeScope(to: scope, today: today)
          try draw(
            PhoneCalendarView(actions: OperationActions(), state: state), deps: deps,
            width: width, name: "Calendar \(scope) \(language) \(width)")
        }
        for tab in PhoneCalendarDayTab.allCases {
          try draw(
            PhoneCalendarDayScreen(
              route: PhoneCalendarDayRoute(
                day: tab == .plans ? today.adding(days: 1) : today, tab: tab),
              actions: OperationActions()),
            deps: deps, width: width, name: "Day \(tab) \(language) \(width)")
        }
      }
      for key in [
        "calendar.day.operations", "calendar.day.plans", "calendar.day.title",
        "calendar.day.noPlans",
      ] {
        let text = CalendarText.t(key, environment)
        XCTAssertFalse(text.isEmpty)
        XCTAssertNotEqual(text, key)
      }
    }
  }

  private func draw(
    _ view: some View, deps: AppDependencies, width: CGFloat, name: String
  ) throws {
    let content = view.environment(\.layoutIdiom, .phone).appDependencies(deps)
    let host = UIHostingController(rootView: content)
    let fitting = host.sizeThatFits(in: CGSize(width: width, height: 900))
    XCTAssertLessThanOrEqual(fitting.width, width + 0.5, name)
    XCTAssertGreaterThan(fitting.height, 100, name)
    let renderer = ImageRenderer(content: content.frame(width: width, height: 900))
    let picture = try XCTUnwrap(renderer.uiImage, name)
    let attachment = XCTAttachment(image: picture)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
