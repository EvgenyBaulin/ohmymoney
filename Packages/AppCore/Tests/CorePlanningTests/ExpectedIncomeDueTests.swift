import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// «Зарплата не пришла?» for a recurring income: «Закрыть» skips that one due, «Перенести»
/// moves that one due to a chosen day, and the recurrence itself stays (`ExpectedIncomeDue`).
@Suite("Expected income: one due of a recurring income skipped or moved")
struct ExpectedIncomeDueTests: SavingsFixtures {
  /// «Зарплата 100 000 ₽» every 5th from August; the money of August came.
  func salary(_ book: SavingsBook) -> ExpectedIncome {
    ExpectedIncome(
      id: uid(800), name: "Зарплата", categoryId: book.salary, kind: .recurring,
      totalE4: rub("100000"), dueDate: date("2026-08-05"), freq: .monthly, day: 5)
  }

  func statuses(
    _ book: SavingsBook, _ income: ExpectedIncome, links: [UUID], dues: [ExpectedIncomeDue] = [],
    today: DateOnly
  ) -> [ExpectedIncomeStatus] {
    let planning = PlanningBook(
      expected: [income],
      expectedLinks: links.map {
        ExpectedIncomeLink(expectedIncomeId: income.id, transactionId: $0)
      },
      expectedDues: dues)
    return ExpectedIncomeRules.statuses(book: planning, ledger: book.ledger, today: today)
  }

  func status(
    _ book: SavingsBook, _ income: ExpectedIncome, links: [UUID], dues: [ExpectedIncomeDue] = [],
    today: DateOnly
  ) throws -> ExpectedIncomeStatus {
    try #require(statuses(book, income, links: links, dues: dues, today: today).first)
  }

  // MARK: - Without an answer, as before

  @Test func withoutAnAnswerTheMissedDueIsOverdue() throws {
    var book = SavingsBook()
    let august = book.income("2026-08-05", "100000")
    let income = salary(book)
    let today = date("2026-09-19")
    let status = try self.status(book, income, links: [august], today: today)
    #expect(status.isOverdue)
    let overdue = IncomeEstimate.overdue(statuses: [status], today: today)
    #expect(overdue.map(\.due) == [date("2026-09-05")])
    #expect(overdue.first?.scheduled == date("2026-09-05"))
    #expect(overdue.first?.isOneOff == false)
  }

  // MARK: - «Закрыть»: this due is skipped

  @Test func aSkippedDueIsNotOverdueAndExpectsNothing() throws {
    var book = SavingsBook()
    let august = book.income("2026-08-05", "100000")
    let income = salary(book)
    let today = date("2026-09-19")
    let skip = try #require(ExpectedIncomeRules.skipped(income, due: date("2026-09-05")))
    let status = try self.status(book, income, links: [august], dues: [skip], today: today)
    #expect(!status.isOverdue)
    let september = try #require(status.occurrences.last)
    #expect(september.isSkipped)
    #expect(september.scheduled == date("2026-09-05"))
    #expect(september.remaining == .zero)
    #expect(september.total == .zero)
    #expect(IncomeEstimate.overdue(statuses: [status], today: today).isEmpty)
    #expect(
      IncomeEstimate.month(ledger: book.ledger, statuses: [status], today: today).notArrived
        == .zero)
    // August is untouched, and the recurrence goes on: October is expected in full.
    #expect(status.occurrences.first?.received == rub("100000"))
    let october = try self.status(
      book, income, links: [august], dues: [skip], today: date("2026-10-02"))
    #expect(october.occurrences.last?.due == date("2026-10-05"))
    #expect(october.occurrences.last?.remaining == rub("100000"))
  }

  /// Part of the money came and the rest never will: what came still counts, nothing more is
  /// waited for.
  @Test func aSkippedDueKeepsWhatCame() throws {
    var book = SavingsBook()
    let august = book.income("2026-08-05", "100000")
    let part = book.income("2026-09-06", "30000")
    let income = salary(book)
    let skip = try #require(ExpectedIncomeRules.skipped(income, due: date("2026-09-05")))
    let status = try self.status(
      book, income, links: [august, part], dues: [skip], today: date("2026-09-19"))
    let september = try #require(status.occurrences.last)
    #expect(september.received == rub("30000"))
    #expect(september.total == rub("30000"))
    #expect(september.isFulfilled)
    #expect(status.received == rub("130000"))
    #expect(!status.isOverdue)
  }

  // MARK: - «Перенести»: this due on another day

  @Test func aMovedDueWaitsUntilItsNewDayAndAsksAgainAfterIt() throws {
    var book = SavingsBook()
    let august = book.income("2026-08-05", "100000")
    let income = salary(book)
    let move = try #require(
      ExpectedIncomeRules.moved(income, due: date("2026-09-05"), to: date("2026-09-25")))
    let before = try self.status(
      book, income, links: [august], dues: [move], today: date("2026-09-19"))
    #expect(!before.isOverdue)
    let september = try #require(before.occurrences.last)
    #expect(september.due == date("2026-09-25"))
    #expect(september.scheduled == date("2026-09-05"))
    #expect(september.isMoved)
    // It is money to count on again in this month's estimate.
    let month = IncomeEstimate.expectedThisMonth(
      ledger: book.ledger, statuses: [before], today: date("2026-09-19"))
    #expect(month.total == rub("100000"))

    let after = try self.status(book, income, links: [august], dues: [move], today: date("2026-09-26"))
    #expect(after.isOverdue)
    let overdue = IncomeEstimate.overdue(statuses: [after], today: date("2026-09-26"))
    #expect(overdue.map(\.due) == [date("2026-09-25")])
    #expect(overdue.map(\.scheduled) == [date("2026-09-05")])
  }

  /// Due on the 28th, moved to the 2nd of the next month, and the money came then: it pays the
  /// due it was late for, and the next month's due still waits for its own money.
  @Test func aDueMovedIntoTheNextMonthTakesTheMoneyThatCameByItsNewDay() throws {
    var book = SavingsBook()
    let late = book.income("2026-10-02", "100000")
    let income = ExpectedIncome(
      id: uid(801), name: "Зарплата", categoryId: book.salary, kind: .recurring,
      totalE4: rub("100000"), dueDate: date("2026-09-28"), freq: .monthly, day: 28)
    let move = try #require(
      ExpectedIncomeRules.moved(income, due: date("2026-09-28"), to: date("2026-10-02")))
    let status = try self.status(book, income, links: [late], dues: [move], today: date("2026-10-10"))
    #expect(status.occurrences.map(\.scheduled) == [date("2026-09-28"), date("2026-10-28")])
    #expect(status.occurrences.first?.isFulfilled == true)
    #expect(status.occurrences.last?.received == .zero)
    #expect(!status.isOverdue)
    // Without the move the money is October's and September waits.
    let plain = try self.status(book, income, links: [late], today: date("2026-10-10"))
    #expect(plain.occurrences.first?.received == .zero)
    #expect(plain.occurrences.last?.received == rub("100000"))
  }

  /// A moved due takes only up to its amount: the rest of the next month's money is that
  /// month's.
  @Test func aMovedDueTakesNoMoreThanItsAmount() throws {
    var book = SavingsBook()
    let late = book.income("2026-10-01", "100000")
    let october = book.income("2026-10-02", "100000")
    let income = ExpectedIncome(
      id: uid(802), name: "Зарплата", categoryId: book.salary, kind: .recurring,
      totalE4: rub("100000"), dueDate: date("2026-09-28"), freq: .monthly, day: 28)
    let move = try #require(
      ExpectedIncomeRules.moved(income, due: date("2026-09-28"), to: date("2026-10-05")))
    let status = try self.status(
      book, income, links: [late, october], dues: [move], today: date("2026-10-10"))
    #expect(status.occurrences.first?.received == rub("100000"))
    #expect(status.occurrences.last?.received == rub("100000"))
  }

  /// An income the owner marked as for October stays October's: the moved September due takes
  /// only money that says nothing of its month.
  @Test func aMovedDueDoesNotTakeMoneyMarkedForAnotherMonth() throws {
    var book = SavingsBook()
    let october = book.income("2026-10-01", "100000", for: "2026-10")
    let income = ExpectedIncome(
      id: uid(806), name: "Зарплата", categoryId: book.salary, kind: .recurring,
      totalE4: rub("100000"), dueDate: date("2026-09-28"), freq: .monthly, day: 28)
    let move = try #require(
      ExpectedIncomeRules.moved(income, due: date("2026-09-28"), to: date("2026-10-02")))
    let status = try self.status(
      book, income, links: [october], dues: [move], today: date("2026-10-10"))
    #expect(status.occurrences.first?.received == .zero)
    #expect(status.occurrences.last?.received == rub("100000"))
  }

  // MARK: - Marks that change nothing

  /// The recurrence was edited after an answer (another day of the month): the old mark names a
  /// due that is no more and changes nothing.
  @Test func aMarkOfADueTheRecurrenceNoLongerHasChangesNothing() throws {
    var book = SavingsBook()
    let august = book.income("2026-08-05", "100000")
    var income = salary(book)
    let skip = try #require(ExpectedIncomeRules.skipped(income, due: date("2026-09-05")))
    income.day = 10
    let withMark = try self.status(
      book, income, links: [august], dues: [skip], today: date("2026-09-19"))
    let without = try self.status(book, income, links: [august], today: date("2026-09-19"))
    #expect(withMark == without)
  }

  @Test func aMarkOfAnotherIncomeChangesNothing() throws {
    var book = SavingsBook()
    let august = book.income("2026-08-05", "100000")
    let income = salary(book)
    let other = ExpectedIncomeDue(expectedIncomeId: uid(999), due: date("2026-09-05"))
    let status = try self.status(
      book, income, links: [august], dues: [other], today: date("2026-09-19"))
    #expect(status.isOverdue)
  }

  @Test func aOneOffOrClosedIncomeHasNoMarkOfADue() {
    let oneOff = ExpectedIncome(
      id: uid(803), name: "Проект", totalE4: rub("50000"), dueDate: date("2026-09-05"))
    #expect(ExpectedIncomeRules.skipped(oneOff, due: date("2026-09-05")) == nil)
    #expect(
      ExpectedIncomeRules.moved(oneOff, due: date("2026-09-05"), to: date("2026-09-25")) == nil)
    var closed = salary(SavingsBook())
    closed.closed = true
    #expect(ExpectedIncomeRules.skipped(closed, due: date("2026-09-05")) == nil)
  }

  /// The row of the income in «Планирование» answers for its oldest missed due, the one «Что
  /// сделать сейчас» asks about; nothing once it is answered or for a one-off income.
  @Test func theMissedDueIsTheOldestOneWithoutItsMoney() throws {
    var book = SavingsBook()
    let income = salary(book)
    let today = date("2026-10-19")
    let unanswered = try self.status(book, income, links: [], today: today)
    #expect(
      ExpectedIncomeRules.missedDue(of: unanswered, today: today)?.scheduled
        == date("2026-08-05"))
    let skip = try #require(ExpectedIncomeRules.skipped(income, due: date("2026-08-05")))
    let answered = try self.status(book, income, links: [], dues: [skip], today: today)
    #expect(
      ExpectedIncomeRules.missedDue(of: answered, today: today)?.scheduled
        == date("2026-09-05"))
    // September moved to the 25th of October: the first money of October pays it, the second
    // pays October.
    let first = book.income("2026-10-05", "100000")
    let paid = book.income("2026-10-06", "100000")
    let move = try #require(
      ExpectedIncomeRules.moved(income, due: date("2026-09-05"), to: date("2026-10-25")))
    let waiting = try self.status(
      book, income, links: [first, paid], dues: [skip, move], today: today)
    #expect(ExpectedIncomeRules.missedDue(of: waiting, today: today) == nil)
    let oneOff = ExpectedIncome(
      id: uid(805), name: "Проект", totalE4: rub("50000"), dueDate: date("2026-09-05"))
    let late = try self.status(book, oneOff, links: [], today: today)
    #expect(late.isOverdue)
    #expect(ExpectedIncomeRules.missedDue(of: late, today: today) == nil)
  }

  // MARK: - The id

  /// One due of one income has one id on every device; another due or another income has
  /// another one. The id stays a version-4 UUID.
  @Test func theIdOfAMarkIsMadeFromTheIncomeAndTheDue() throws {
    let income = try #require(UUID(uuidString: "6F1C2D3E-4A5B-4C6D-8E7F-1A2B3C4D5E6F"))
    let september = ExpectedIncomeDue.id(incomeId: income, due: date("2026-09-05"))
    #expect(september == ExpectedIncomeDue.id(incomeId: income, due: date("2026-09-05")))
    #expect(september != ExpectedIncomeDue.id(incomeId: income, due: date("2026-10-05")))
    #expect(september != ExpectedIncomeDue.id(incomeId: income, due: date("2027-09-05")))
    #expect(september != income)
    #expect(september.uuid.6 == income.uuid.6)
    #expect(september.uuid.8 == income.uuid.8)
    // Skipping and then moving the same due writes the same row.
    let skip = ExpectedIncomeDue(expectedIncomeId: income, due: date("2026-09-05"))
    let move = ExpectedIncomeDue(
      expectedIncomeId: income, due: date("2026-09-05"), movedTo: date("2026-09-20"))
    #expect(skip.id == move.id)
    #expect(skip.isSkipped)
    #expect(!move.isSkipped)
  }

  // MARK: - The days the recurrence is read by without money

  @Test func expectedDaysLeaveOutASkippedDueAndPutAMovedOneOnItsNewDay() {
    let income = salary(SavingsBook())
    let dues = [
      ExpectedIncomeDue(expectedIncomeId: income.id, due: date("2026-09-05")),
      ExpectedIncomeDue(
        expectedIncomeId: income.id, due: date("2026-10-05"), movedTo: date("2026-10-12")),
    ]
    let days = ExpectedIncomeRules.expectedDays(
      of: income, through: date("2026-11-30"), today: date("2026-09-19"), dues: dues)
    #expect(
      days.map(\.day) == [date("2026-08-05"), date("2026-10-12"), date("2026-11-05")])
    #expect(
      days.map(\.scheduled) == [date("2026-08-05"), date("2026-10-05"), date("2026-11-05")])
  }

  @Test func theAllocationWindowSkipsASkippedDue() {
    let income = salary(SavingsBook())
    let today = date("2026-09-01")
    #expect(Allocation.until(today: today, expected: [income], links: []) == date("2026-09-05"))
    let skip = ExpectedIncomeDue(expectedIncomeId: income.id, due: date("2026-09-05"))
    #expect(
      Allocation.until(today: today, expected: [income], links: [], dues: [skip])
        == date("2026-10-05"))
  }

  // MARK: - «Что сделать сейчас»

  /// A recurring income that did not come asks too, about its oldest missed due, keyed by the
  /// day the recurrence puts it on — a moved due keeps its item.
  @Test func aRecurringIncomeAsksAboutItsMissedDue() {
    let today = date("2026-09-26")
    let id = uid(804)
    let moved = OverdueIncomeItem(
      incomeId: id, name: "Зарплата", due: date("2026-09-25"), rub: rub("100000"),
      isOneOff: false, scheduled: date("2026-09-05"))
    let list = WhatToDoNow.list(payments: [], overdueIncomes: [moved], today: today)
    let item = list.items.first
    #expect(item?.action == .income)
    #expect(item?.day == date("2026-09-25"))
    #expect(item?.scheduled == date("2026-09-05"))
    #expect(item?.recurring == true)
    #expect(item?.id == "income:\(id.uuidString):2026-09-05")
  }
}
