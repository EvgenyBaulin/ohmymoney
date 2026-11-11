import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CoreInsights

@Suite("«Итоги»: the board of «По периодам»")
struct PeriodBoardTests {
  let today = DateOnly(year: 2026, month: 10, day: 26)
  static let september = MonthKey(year: 2026, month: 9)
  /// Monday 14 to Sunday 20 September 2026.
  static let week = WeekKey(containing: DateOnly(year: 2026, month: 9, day: 16))

  /// June to September 2026 and September 2025: five categories, the qualities rated.
  func book() -> SummaryBook {
    var book = SummaryBook()
    let gifts = CoreKit.Category(kind: .expense, name: "Подарки")
    let home = CoreKit.Category(kind: .expense, name: "Жильё")
    book.categories += [gifts, home]
    for month in 6...9 {
      book.earn(100_000, on: DateOnly(year: 2026, month: month, day: 5))
      for day in [3, 9, 15, 21, 27] {
        let date = DateOnly(year: 2026, month: month, day: day)
        book.add(SummaryBook.Spec(amount: 3_000, quality: .good), on: date)
        book.add(
          SummaryBook.Spec(amount: 1_000, category: book.transport.id, quality: .neutral),
          on: date)
        book.add(
          SummaryBook.Spec(amount: 2_000, category: book.cafe.id, quality: .bad), on: date)
        book.add(SummaryBook.Spec(amount: 4_000, category: home.id), on: date)
      }
    }
    book.add(
      SummaryBook.Spec(amount: 500, category: gifts.id), on: DateOnly(year: 2026, month: 9, day: 16)
    )
    book.spend(7_000, on: DateOnly(year: 2025, month: 9, day: 16))
    return book
  }

  func board(_ id: SummaryID, _ book: SummaryBook) -> PeriodBoard {
    PeriodBoard.build(id, ledger: book.ledger, today: today)!
  }

  @Test func theFiguresAreTheOnesOfTheSummaryAndTheReports() {
    let book = book()
    for id in [SummaryID.month(Self.september), .year(2026)] {
      let made = board(id, book)
      let summary = SummaryBuilder.summary(id: id, ledger: book.ledger, today: today)!
      #expect(made.spent == summary.expenses)
      #expect(made.income == summary.income)
      #expect(made.savedBP == summary.savedBP)
      #expect(made.changeBP == summary.expensesChangeBP)
    }
    let week = board(.week(Self.week), book)
    let cards = WeekCards.build(week: Self.week, ledger: book.ledger)
    #expect(week.spent == cards.total.expenses)
    #expect(week.income == cards.total.income)
    #expect(week.changeBP == cards.comparison.changeBP)
  }

  @Test func theSlicesAreFourCategoriesAndTheRestAndMakeAWhole() {
    let made = board(.month(Self.september), book())
    #expect(made.slices.count == 5)
    #expect(made.slices.last?.categoryId == nil)
    #expect(made.slices.map(\.shareBP).reduce(0, +) == Shares.whole)
    #expect(made.slices.dropLast().map(\.amount) == made.topCategories.map(\.amount))
    #expect(AmountE4.sum(made.slices.map(\.amount)) == made.spent)
    // The most first: home 20,000, food 15,000, cafés 10,000, transport 5,000, gifts 500.
    #expect(made.topCategories.map(\.amount.decimal) == [20_000, 15_000, 10_000, 5_000])
  }

  @Test func theGradesAreGoodUsualPoorWithTheirShares() {
    let made = board(.month(Self.september), book())
    #expect(made.grades.map(\.quality) == [.good, .neutral, .bad])
    // A part without a rating counts as usual, as everywhere in the ledger: home and gifts.
    #expect(made.grades.map(\.amount.decimal) == [15_000, 25_500, 10_000])
    #expect(made.grades.compactMap(\.shareBP).reduce(0, +) == Shares.whole)
    #expect(made.grades.map(\.shareBP) == [2_970, 5_050, 1_980])
  }

  @Test func theColumnsAreSixSpansAgainstTheYearBefore() {
    let book = book()
    let month = board(.month(Self.september), book)
    #expect(month.columns.count == PeriodBoard.columnCount)
    #expect(month.columns.map(\.month) == (4...9).map { MonthKey(year: 2026, month: $0) })
    #expect(month.columns.last?.spent == month.spent)
    #expect(month.columns.last?.previous.decimal == 7_000)
    #expect(month.columns.first?.spent == .zero)

    let year = board(.year(2026), book)
    #expect(year.columns.map(\.month?.month) == [5, 6, 7, 8, 9, 10])

    let week = board(.week(Self.week), book)
    #expect(week.columns.count == 6)
    #expect(week.columns.last?.range == Self.week.range)
    #expect(week.columns.first?.range.start == Self.week.start.adding(days: -35))
    #expect(week.columns.last?.previous.decimal == 7_000)
    #expect(week.columns.last?.spent == week.spent)
  }

  @Test func theHighlightIsTheDearestDayOrTheBestMonth() {
    let book = book()
    let week = board(.week(Self.week), book)
    #expect(week.highlight == .dearestDay(DateOnly(year: 2026, month: 9, day: 15)))
    let year = board(.year(2026), book)
    let best = SummaryBuilder.summary(id: .year(2026), ledger: book.ledger, today: today)?
      .bestMonth?.month
    #expect(best != nil)
    #expect(year.highlight == best.map(PeriodBoard.Highlight.bestMonth))
    // A month has no best month: its dearest day.
    if case .dearestDay = board(.month(Self.september), book).highlight {
    } else {
      Issue.record("a month shows its dearest day")
    }
  }

  @Test func theBarIsTheShareKeptAndStaysInside() {
    var book = book()
    let made = board(.month(Self.september), book)
    #expect(made.keptFillBP == made.savedBP)
    #expect(made.saved == made.income - made.spent)
    book.spend(500_000, on: DateOnly(year: 2026, month: 9, day: 28))
    #expect(board(.month(Self.september), book).keptFillBP == 0)
  }

  @Test func anEmptyPeriodHasNoDataAndNoChange() {
    let made = board(.month(MonthKey(year: 2026, month: 2)), book())
    #expect(!made.hasData)
    #expect(made.slices.isEmpty)
    #expect(made.changeBP == nil)
    #expect(made.grades.allSatisfy { $0.shareBP == nil })
  }
}
