import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// «Календарь»: the data step's snapshot becomes the core's calendar with the plans of Planning
/// laid on it; a day lists its operations as «Траты» lists a day; the weeks start on Monday in
/// Russian; every level of a day is said in words and by a symbol, never by the tint alone; the
/// section is ⌘5 after «Траты», and its tile is one Overview can add.
@MainActor
final class CalendarScreenTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 10, day: 14)
  private let food = CoreKit.Category(kind: .expense, name: "Food")

  private func entry(
    _ whole: Int64, on day: DateOnly, note: String = "Lunch"
  ) throws
    -> TransactionEntry
  {
    var draft = TransactionDraft(
      occurredAt: CalendarContext.system.startOfDay(day).addingTimeInterval(12 * 3600),
      amount: AmountE4(whole: whole), note: note)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = food.id
    return try draft.materialize()
  }

  private func snapshot(
    _ entries: [TransactionEntry], planning: PlanningBook = PlanningBook()
  ) -> DataSnapshot {
    DataSnapshot.build(
      dataset: Dataset(entries: entries, categories: [food], planning: planning),
      calendar: .system, today: today, context: SnapshotContext(),
      version: DataVersion(load: 0))
  }

  private func environment(_ choice: AppLanguage.Choice) -> AppEnvironment {
    let environment = AppEnvironment()
    environment.language.choice = choice
    return environment
  }

  /// The Overview tile is a strip of seven narrow cells; the number of today, «15», stood as
  /// «1» over «5» there (owner, 15.10). A two-digit number, today's with its capsule or not, is
  /// as tall as a one-digit one at any size of the font.
  func testATwoDigitDayStaysOnOneLineInTheNarrowStrip() {
    for size in AppFontSize.allCases {
      for language in [AppLanguage.Choice.russian, .english] {
        let deps = AppDependencies.forTests(environment(language))
        func height(of dayNumber: Int, today isToday: Bool) -> CGFloat {
          let day = SpendingCalendarDay(
            day: DateOnly(year: 2026, month: 10, day: dayNumber), inScope: true,
            isToday: isToday, isFuture: false, spent: nil, level: nil, transactionIds: [],
            plans: [], plannedOut: nil, plannedIn: nil, plansWithoutRate: false)
          let calendar = SpendingCalendar(
            scope: .week, anchor: day.day, today: day.day, firstWeekday: 1, currency: .rub,
            range: DayRange(day.day, day.day), weeks: [[day]], spent: .zero,
            usual: nil, lowData: false)
          let cell = CalendarDayCell(day: day, calendar: calendar, compact: true)
            .environment(\.appFontSize, size)
            .appDependencies(deps)
          let host = NSHostingController(rootView: cell)
          // The width one cell gets when the tile is as narrow as the window allows.
          return host.sizeThatFits(in: CGSize(width: 22, height: 400)).height
        }
        let one = height(of: 5, today: false)
        XCTAssertEqual(height(of: 15, today: true), one, "\(size) \(language): today wrapped")
        XCTAssertEqual(height(of: 15, today: false), one, "\(size) \(language): «15» wrapped")
      }
    }
  }

  // MARK: - The model of the snapshot

  /// Spending of the past days, plans of the days ahead — the rent of Planning and the expected
  /// salary — in the default currency.
  func testTheSnapshotBecomesTheCalendarWithItsPlans() throws {
    let rent = ScheduledPayment(
      name: "Rent", amountE4: AmountE4(whole: 30_000), day: 20,
      nextDate: DateOnly(year: 2026, month: 10, day: 20))
    let salary = ExpectedIncome(
      name: "Salary", totalE4: AmountE4(whole: 100_000),
      dueDate: DateOnly(year: 2026, month: 10, day: 25))
    let lunch = try entry(1_250, on: DateOnly(year: 2026, month: 10, day: 5))
    let data = snapshot([lunch], planning: PlanningBook(scheduled: [rent], expected: [salary]))

    let calendar = CalendarScreen.calendar(
      of: data, scope: .month, anchor: today, firstWeekday: 1)
    XCTAssertEqual(calendar.currency, .rub)
    XCTAssertEqual(
      calendar.day(DateOnly(year: 2026, month: 10, day: 5))?.spent, AmountE4(whole: 1_250))
    XCTAssertEqual(calendar.spent, AmountE4(whole: 1_250))
    let twentieth = try XCTUnwrap(calendar.day(DateOnly(year: 2026, month: 10, day: 20)))
    XCTAssertNil(twentieth.spent, "a day ahead has nothing spent")
    XCTAssertEqual(twentieth.plans.map(\.name), ["Rent"])
    XCTAssertEqual(twentieth.plannedOut, AmountE4(whole: 30_000))
    let payday = try XCTUnwrap(calendar.day(DateOnly(year: 2026, month: 10, day: 25)))
    XCTAssertEqual(payday.plans.map(\.kind), [.income])
    XCTAssertEqual(payday.plannedIn, AmountE4(whole: 100_000))

    // The week of today on the tile, the same rule.
    let week = CalendarScreen.calendar(of: data, scope: .week, anchor: today, firstWeekday: 1)
    XCTAssertEqual(week.weeks.count, 1)
    XCTAssertEqual(week.weeks.first?.first?.day, DateOnly(year: 2026, month: 10, day: 12))
  }

  /// A click on a day lists its operations as «Траты» does: one day, newest first.
  func testADayListsItsOperations() throws {
    let day = DateOnly(year: 2026, month: 10, day: 5)
    let first = try entry(100, on: day, note: "Coffee")
    let second = try entry(200, on: day, note: "Lunch")
    let other = try entry(300, on: DateOnly(year: 2026, month: 10, day: 6))
    let data = snapshot([first, second, other])
    let calendar = CalendarScreen.calendar(of: data, scope: .month, anchor: today, firstWeekday: 1)

    let groups = CalendarScreen.groups(of: calendar.day(day), in: data, calendar: .system)
    XCTAssertEqual(groups.map(\.day), [day])
    XCTAssertEqual(Set(groups.flatMap(\.selectableIds)), [first.id, second.id])
    XCTAssertTrue(
      CalendarScreen.groups(
        of: calendar.day(DateOnly(year: 2026, month: 10, day: 7)), in: data, calendar: .system
      ).isEmpty)
  }

  /// Monday in Russian whatever the Mac says; the Mac's first weekday in English.
  func testTheWeeksStartOnMondayInRussian() {
    var sundayFirst = Calendar(identifier: .gregorian)
    sundayFirst.firstWeekday = 1
    XCTAssertEqual(
      CalendarScreen.firstWeekday(locale: Locale(identifier: "ru_RU"), system: sundayFirst), 1)
    XCTAssertEqual(
      CalendarScreen.firstWeekday(locale: Locale(identifier: "en_US"), system: sundayFirst), 7)
    var mondayFirst = Calendar(identifier: .gregorian)
    mondayFirst.firstWeekday = 2
    XCTAssertEqual(
      CalendarScreen.firstWeekday(locale: Locale(identifier: "en_GB"), system: mondayFirst), 1)
  }

  // MARK: - Words and symbols

  /// A level is never a tint alone: each has a symbol and its words, and VoiceOver reads them.
  func testEveryLevelHasASymbolAndWords() {
    XCTAssertNil(CalendarText.symbol(of: SpendingLevel.usual))
    XCTAssertNil(CalendarText.symbol(of: nil))
    XCTAssertEqual(CalendarText.symbol(of: SpendingLevel.higher), "arrow.up")
    XCTAssertEqual(CalendarText.symbol(of: SpendingLevel.muchHigher), "flame")
    XCTAssertNotEqual(
      CalendarText.symbol(of: CalendarPlan.Kind.payment),
      CalendarText.symbol(of: CalendarPlan.Kind.income))
    for level in [SpendingLevel.higher, .muchHigher] {
      XCTAssertNotNil(CalendarText.levelKey(level))
      XCTAssertNotNil(
        NSImage(systemSymbolName: CalendarText.symbol(of: level)!, accessibilityDescription: nil))
    }
    for kind in [CalendarPlan.Kind.payment, .income] {
      XCTAssertNotNil(
        NSImage(systemSymbolName: CalendarText.symbol(of: kind), accessibilityDescription: nil))
    }
    XCTAssertNotNil(
      NSImage(
        systemSymbolName: MainWindow.Section.calendar.symbol, accessibilityDescription: nil))
  }

  /// The label of a day says what the cell shows: the spending to the ruble, the level, the
  /// plans.
  func testTheLabelOfADaySaysWhatTheCellShows() {
    let ru = environment(.russian)
    let calendar = SpendingCalendar.build(
      ledger: Ledger(dataset: Dataset(), calendar: .system), scope: .week, anchor: today,
      today: today, firstWeekday: 1)
    let spent = SpendingCalendarDay(
      day: DateOnly(year: 2026, month: 10, day: 12), inScope: true, isToday: false,
      isFuture: false, spent: AmountE4(whole: 4_500), level: .muchHigher, transactionIds: [],
      plans: [], plannedOut: nil, plannedIn: nil, plansWithoutRate: false)
    let label = CalendarText.label(of: spent, in: calendar, ru)
    XCTAssertTrue(label.contains("4,500"), label)
    XCTAssertTrue(label.contains("Намного дороже обычного"), label)

    let ahead = SpendingCalendarDay(
      day: DateOnly(year: 2026, month: 10, day: 16), inScope: true, isToday: false,
      isFuture: true, spent: nil, level: nil, transactionIds: [], plans: [],
      plannedOut: AmountE4(whole: 30_000), plannedIn: AmountE4(whole: 100_000),
      plansWithoutRate: true)
    let planned = CalendarText.label(of: ahead, in: calendar, ru)
    XCTAssertTrue(planned.contains("платежи ≈ 30,000"), planned)
    XCTAssertTrue(planned.contains("поступления ≈ 100,000"), planned)
    XCTAssertTrue(planned.contains("план в валюте без курса"), planned)
    XCTAssertFalse(planned.contains("без трат"), planned)

    let quiet = SpendingCalendarDay(
      day: DateOnly(year: 2026, month: 10, day: 13), inScope: true, isToday: false,
      isFuture: false, spent: .zero, level: nil, transactionIds: [], plans: [],
      plannedOut: nil, plannedIn: nil, plansWithoutRate: false)
    XCTAssertTrue(CalendarText.label(of: quiet, in: calendar, ru).contains("без трат"))
  }

  /// Every word of the calendar, its section and its tile, in both languages.
  func testEveryWordInBothLanguages() {
    for choice in [AppLanguage.Choice.english, .russian] {
      let environment = environment(choice)
      for key in CalendarText.keys {
        XCTAssertNotEqual(environment.language(key, table: "Overview"), key, "\(key), \(choice)")
      }
      XCTAssertNotEqual(
        environment.language(MainWindow.Section.calendar.titleKey),
        MainWindow.Section.calendar.titleKey)
      XCTAssertNotEqual(
        OverviewTileText.name(of: .spendingCalendar, environment),
        OverviewTileText.nameKey(of: .spendingCalendar))
    }
    XCTAssertEqual(environment(.russian).language("section.calendar"), "Календарь")
    XCTAssertEqual(environment(.english).language("section.calendar"), "Calendar")
  }

  // MARK: - The section and the tile

  /// «Календарь» stands after «Траты» and is ⌘5; it lists no operations of the selection bar.
  func testTheSectionIsCommandFive() {
    XCTAssertEqual(MainWindow.Section.allCases.firstIndex(of: .calendar), 4)
    XCTAssertEqual(MainWindow.Section.calendar.shortcutIndex, 5)
    XCTAssertEqual(
      Set(MainWindow.Section.allCases.map(\.shortcutIndex)).count,
      MainWindow.Section.allCases.count, "two sections share a shortcut")
    XCTAssertFalse(SidebarItem.section(.calendar).listsOperations)
  }

  /// The tile is one more to choose, not among the twelve of the default.
  func testTheTileIsNotInTheDefault() {
    XCTAssertTrue(OverviewTile.allCases.contains(.spendingCalendar))
    XCTAssertFalse(OverviewTiles.standard.contains(.spendingCalendar))
    XCTAssertEqual(OverviewTile.allCases.firstIndex(of: .spendingCalendar), 19)
  }
}
