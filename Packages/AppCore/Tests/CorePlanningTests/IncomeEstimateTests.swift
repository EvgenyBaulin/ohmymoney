import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("Income estimate of the month: expectations, median, received only")
struct IncomeEstimateTests: SavingsFixtures {
  let today = DateOnly(year: 2026, month: 9, day: 19)

  /// Salary of 100 000 on 1 June — the book begins on the 1st, so June is a whole month —,
  /// 120 000 in July, 90 000 in August — the August one arriving on 3 September, marked «for
  /// August» — and 50 000 on 5 September.
  func history() -> SavingsBook {
    var book = SavingsBook()
    book.income("2026-06-01", "100000")
    book.income("2026-07-05", "120000")
    book.income("2026-09-03", "90000", for: "2026-08")
    book.income("2026-09-05", "50000")
    return book
  }

  func estimate(
    _ book: SavingsBook, _ expected: [ExpectedIncome] = [], links: [(UUID, UUID)] = [],
    until: DateOnly? = nil
  ) -> MonthIncomeEstimate {
    let planning = PlanningBook(
      expected: expected,
      expectedLinks: links.map { ExpectedIncomeLink(expectedIncomeId: $0.0, transactionId: $0.1) })
    let ledger = book.ledger
    let statuses = ExpectedIncomeRules.statuses(book: planning, ledger: ledger, today: today)
    return IncomeEstimate.month(ledger: ledger, statuses: statuses, today: today, until: until)
  }

  /// Received: 50 000 salary + 5 000 of help = 55 000 (the advance dated 28 September has not
  /// come yet). Expected: the project's 30 000 due on the 25th + 15 000 of September's help
  /// due on the 30th = 45 000; August's unpaid help is overdue, not September's income.
  /// Estimate: 55 000 + 45 000 = 100 000.
  @Test func expectationsOfTheMonthAreAddedToWhatCame() {
    var book = history()
    let project = ExpectedIncome(
      id: uid(600), name: "Project", totalE4: rub("30000"), dueDate: date("2026-09-25"))
    let help = ExpectedIncome(
      id: uid(610), name: "Help", kind: .recurring, totalE4: rub("20000"),
      dueDate: date("2026-08-31"), freq: .monthly, day: 31)
    let helpPart = book.income("2026-09-10", "5000", category: book.help)
    book.income("2026-09-28", "7000")
    let expected = [project, help]
    let links = [(help.id, helpPart)]

    let whole = estimate(book, expected, links: links)
    #expect(whole.received == rub("55000"))
    #expect(whole.expectedRemaining == rub("45000"))
    #expect(whole.value == rub("100000"))
    #expect(whole.source == .expectations)
    #expect(!whole.lowData)
    // The median is still worked out: 100 000 of 90 000, 100 000 and 120 000.
    #expect(whole.median3 == rub("100000"))
    #expect(whole.monthsInMedian == 3)

    // Until the 26th only the project is due: 55 000 + 30 000.
    let untilThe26th = estimate(book, expected, links: links, until: date("2026-09-26"))
    #expect(untilThe26th.expectedRemaining == rub("30000"))
    #expect(untilThe26th.value == rub("85000"))
  }

  /// The project's 30 000 is due on the 20th, and the owner has already entered its payment,
  /// linked, dated the 28th. The month waits for it; a window through the 24th does not —
  /// the money comes after the window ends — while one through the 28th does.
  @Test func aLinkedPaymentDatedAfterTheWindowIsNotExpectedInIt() {
    var book = history()
    let project = ExpectedIncome(
      id: uid(600), name: "Project", totalE4: rub("30000"), dueDate: date("2026-09-20"))
    let paid = book.income("2026-09-28", "30000", category: book.projects)
    let links = [(project.id, paid)]

    let whole = estimate(book, [project], links: links)
    #expect(whole.expectedRemaining == rub("30000"))
    #expect(whole.value == rub("80000"))
    let untilThe24th = estimate(book, [project], links: links, until: date("2026-09-24"))
    #expect(untilThe24th.expectedRemaining == .zero)
    #expect(untilThe24th.value == rub("50000"))
    let untilThe28th = estimate(book, [project], links: links, until: date("2026-09-28"))
    #expect(untilThe28th.expectedRemaining == rub("30000"))
  }

  /// An expectation of the month that came in whole still makes the estimate «received +
  /// expected»: 50 000 + 30 000 received, nothing left, 80 000 — not the median.
  @Test func aFulfilledExpectationStillCounts() {
    var book = history()
    let project = ExpectedIncome(
      id: uid(600), name: "Project", totalE4: rub("30000"), dueDate: date("2026-09-12"))
    let paid = book.income("2026-09-12", "30000", category: book.projects)
    let result = estimate(book, [project], links: [(project.id, paid)])
    #expect(result.source == .expectations)
    #expect(result.expectedRemaining == .zero)
    #expect(result.value == rub("80000"))
  }

  /// No expectation: the median of June, July and August is 100 000, more than the 50 000
  /// received, so 100 000. With 130 000 received the estimate is 130 000 — money in hand is
  /// never ignored.
  @Test func withoutExpectationsTheMedianOfThreeMonths() {
    var book = history()
    // May is older than three complete months and does not count.
    book.income("2026-05-05", "1000000")
    let result = estimate(book)
    #expect(result.source == .median)
    #expect(result.median3 == rub("100000"))
    #expect(result.monthsInMedian == 3)
    #expect(result.received == rub("50000"))
    #expect(result.value == rub("100000"))
    #expect(!result.lowData)

    book.income("2026-09-15", "80000")
    #expect(estimate(book).value == rub("130000"))
  }

  /// The history starts on 1 July: two complete months, and their median is the mean
  /// (120 000 + 90 000) ÷ 2 = 105 000.
  @Test func aShortHistoryTakesTheMonthsItHas() {
    var book = SavingsBook()
    book.income("2026-07-01", "120000")
    book.income("2026-08-05", "90000")
    book.income("2026-09-05", "50000")
    let result = estimate(book)
    #expect(result.monthsInMedian == 2)
    #expect(result.median3 == rub("105000"))
    #expect(result.value == rub("105000"))
  }

  /// The history starts this month: only what came, marked «not enough data»; with nothing
  /// come there is no estimate at all.
  @Test func withoutHistoryOnlyWhatCame() {
    var book = SavingsBook()
    book.expense("2026-09-02", "1000")
    let empty = estimate(book)
    #expect(empty.source == .receivedOnly)
    #expect(empty.value == nil)
    #expect(empty.median3 == nil)
    #expect(empty.lowData)

    book.income("2026-09-05", "50000")
    let some = estimate(book)
    #expect(some.value == rub("50000"))
    #expect(some.lowData)
  }

  /// Complete months without any income are no history of income. The owner began in July and
  /// wrote down only expenses: the median of July and August would be 0, a confident estimate
  /// that «can save» turns into a deficit. It is «not enough data» instead — nothing at all,
  /// or what came, marked. One month with income is a history, and a month without any beside
  /// it is a real zero: the median of 0 and 90 000 is 45 000.
  @Test func monthsWithoutAnyIncomeAreNoHistoryOfIncome() {
    var book = SavingsBook()
    book.expense("2026-07-01", "30000")
    book.expense("2026-08-10", "30000")
    book.expense("2026-09-02", "1000")
    let none = estimate(book)
    #expect(none.source == .receivedOnly)
    #expect(none.median3 == nil)
    #expect(none.value == nil)
    #expect(none.lowData)
    let canSave = CanSave(
      CanSaveInputs(
        income: none, spentWithoutGoals: rub("1000"), plannedStillDue: .zero,
        remainder: MonthForecast.Remainder(
          p10: .zero, middle: .zero, p90: .zero, lowData: true, computedFor: today, daysLeft: 11,
          windowDays: 0),
        alreadySaved: .zero))
    #expect(canSave.status == .notEnoughData(reasonKey: CanSave.Key.noIncome))

    book.income("2026-09-05", "50000")
    let some = estimate(book)
    #expect(some.source == .receivedOnly)
    #expect(some.value == rub("50000"))
    #expect(some.lowData)

    book.income("2026-08-20", "90000")
    let history = estimate(book)
    #expect(history.source == .median)
    #expect(history.median3 == rub("45000"))
    #expect(history.value == rub("50000"))
    #expect(!history.lowData)
  }

  /// The first record on 25 July, 100 000 of salary in August, nothing expected in September,
  /// today the 20th: July is only part of a month and no history of income, so the median is
  /// August's 100 000 — not the 50 000 a zero July would make of it.
  @Test func aFirstMonthStartedAfterThe1stIsNoHistory() {
    var book = SavingsBook()
    book.expense("2026-07-25", "3000")
    book.income("2026-08-05", "100000")
    let result = IncomeEstimate.month(
      ledger: book.ledger, statuses: [], today: DateOnly(year: 2026, month: 9, day: 20))
    #expect(result.source == .median)
    #expect(result.monthsInMedian == 1)
    #expect(result.median3 == rub("100000"))
    #expect(result.value == rub("100000"))
    #expect(
      IncomeEstimate.historyStart(firstDay: date("2026-07-25")) == MonthKey(year: 2026, month: 8))
  }

  /// A book begun on 1 July is a whole July: without income it is a real zero beside August's
  /// 100 000, and the median of the two is 50 000.
  @Test func aFirstMonthStartedOnThe1stCounts() {
    var book = SavingsBook()
    book.expense("2026-07-01", "3000")
    book.income("2026-08-05", "100000")
    let result = IncomeEstimate.month(
      ledger: book.ledger, statuses: [], today: DateOnly(year: 2026, month: 9, day: 20))
    #expect(result.monthsInMedian == 2)
    #expect(result.median3 == rub("50000"))
    #expect(
      IncomeEstimate.historyStart(firstDay: date("2026-07-01")) == MonthKey(year: 2026, month: 7))
    #expect(IncomeEstimate.historyStart(firstDay: nil) == nil)
  }

  /// A book begun on 3 September has no complete month of income before November: in
  /// September and in October the estimate is what came, «мало данных»; in November October
  /// is history.
  @Test func aStartThisMonthGivesNoMedianUntilAMonthIsComplete() {
    var book = SavingsBook()
    book.expense("2026-09-03", "1000")
    book.income("2026-09-05", "50000")
    book.income("2026-10-05", "60000")
    for iso in ["2026-09-20", "2026-10-20"] {
      let result = IncomeEstimate.month(ledger: book.ledger, statuses: [], today: date(iso))
      #expect(result.source == .receivedOnly, "\(iso)")
      #expect(result.median3 == nil, "\(iso)")
      #expect(result.lowData, "\(iso)")
    }
    let november = IncomeEstimate.month(
      ledger: book.ledger, statuses: [], today: date("2026-11-20"))
    #expect(november.source == .median)
    #expect(november.monthsInMedian == 1)
    #expect(november.median3 == rub("60000"))
  }

  @Test func medianOfOddAndEvenCounts() {
    #expect(IncomeEstimate.median([]) == nil)
    #expect(IncomeEstimate.median(["3", "1", "2"].map(rub)) == rub("2"))
    #expect(IncomeEstimate.median(["1", "4"].map(rub)) == rub("2.5"))
    #expect(IncomeEstimate.median(["0.0001", "0.0002"].map(rub)) == rub("0.0002"))
  }

  /// «ещё ждём до D» with D two months ahead: the salaries of 25 September and 25 October and
  /// a one-off 20 000 due on 10 October. October's salary was entered ahead, dated the 24th:
  /// its money has not come yet, so it is still waited for. Statuses built only through the
  /// month would miss October.
  @Test func stillExpectedReachesMonthsAhead() {
    var book = SavingsBook()
    let salary = ExpectedIncome(
      id: uid(620), name: "Salary", kind: .recurring, totalE4: rub("100000"),
      dueDate: date("2026-01-25"), freq: .monthly, day: 25)
    let project = ExpectedIncome(
      id: uid(621), name: "Project", totalE4: rub("20000"), dueDate: date("2026-10-10"))
    let ahead = book.income("2026-10-24", "100000")
    let planning = PlanningBook(
      expected: [salary, project],
      expectedLinks: [ExpectedIncomeLink(expectedIncomeId: salary.id, transactionId: ahead)])
    let ledger = book.ledger
    let through = date("2026-11-19")
    let statuses = ExpectedIncomeRules.statuses(
      book: planning, ledger: ledger, today: today, through: through)
    let still = IncomeEstimate.stillExpected(
      statuses: statuses, today: today, through: through, ledger: ledger)
    #expect(still.amount == rub("220000"))
    #expect(still.withoutRate.isEmpty)

    let monthOnly = ExpectedIncomeRules.statuses(book: planning, ledger: ledger, today: today)
    #expect(
      IncomeEstimate.stillExpected(
        statuses: monthOnly, today: today, through: through, ledger: ledger
      ).amount == rub("120000"))
  }

  /// A weekly expectation looked at a year ahead keeps the due dates of this month: the latest
  /// 24 are kept through the end of the month, and every one after it up to the horizon.
  @Test func aYearAheadKeepsThisMonthsWeeks() {
    let book = SavingsBook()
    let lessons = ExpectedIncome(
      id: uid(630), name: "Lessons", kind: .recurring, totalE4: rub("1000"),
      dueDate: date("2026-01-05"), freq: .weekly, day: 1)
    let planning = PlanningBook(expected: [lessons])
    let ledger = book.ledger
    let through = date("2027-09-19")
    let statuses = ExpectedIncomeRules.statuses(
      book: planning, ledger: ledger, today: today, through: through)
    let dues = statuses.first?.occurrences.map(\.due) ?? []
    #expect(dues.contains(date("2026-09-07")))
    #expect(dues.last == date("2027-09-13"))
    #expect(dues.filter { $0 <= date("2026-09-30") }.count == 24)
    // 7, 14, 21 and 28 September, then 50 Mondays through 13 September 2027.
    #expect(
      IncomeEstimate.stillExpected(
        statuses: statuses, today: today, through: through, ledger: ledger
      ).amount == rub("54000"))
  }
}
