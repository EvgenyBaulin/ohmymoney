import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// The plans of the spending calendar come from the rules Planning has: the unpaid due dates of
/// the scheduled payments, the due dates of the expected incomes with money still to come — from
/// today through the last day shown.
@Suite("The plans of the spending calendar")
struct CalendarPlansTests {
  private let today = DateOnly(year: 2026, month: 10, day: 14)

  private func day(_ month: Int, _ day: Int) -> DateOnly {
    DateOnly(year: 2026, month: month, day: day)
  }

  private func ledger(_ entries: [TransactionEntry] = [], book: PlanningBook) -> Ledger {
    Ledger(dataset: Dataset(entries: entries, planning: book), calendar: .utc)
  }

  @Test func scheduledDuesFromTodayThroughTheLastDay() {
    let rent = ScheduledPayment(
      name: "Rent", amountE4: AmountE4(whole: 30_000), day: 20, nextDate: day(10, 20))
    let stale = ScheduledPayment(
      name: "Stopped", amountE4: AmountE4(whole: 10), day: 25, nextDate: day(10, 25),
      active: false)
    let gym = ScheduledPayment(
      name: "Gym", amountE4: AmountE4(whole: 2_000), day: 2, nextDate: day(10, 2))
    let book = PlanningBook(scheduled: [rent, stale, gym])
    let plans = CalendarPlans.collect(
      ledger: ledger(book: book), book: book, today: today, through: day(12, 31))
    #expect(plans.map(\.day) == [day(10, 20), day(11, 2), day(11, 20), day(12, 2), day(12, 20)])
    #expect(plans.allSatisfy { $0.kind == .payment })
    #expect(plans.first?.name == "Rent")
    #expect(plans.first?.amount == AmountE4(whole: 30_000))
    #expect(plans.first?.sourceId == rent.id)
    // The overdue 2 October of «Gym» is before today: «Просроченные платежи» speak of it.
    #expect(!plans.contains { $0.day < today })
  }

  /// A due date «Отметить оплаченным» wrote (`sched:<payment>:<due>`) is paid.
  @Test func aPaidDueIsNotPlanned() throws {
    let rent = ScheduledPayment(
      name: "Rent", amountE4: AmountE4(whole: 30_000), day: 20, nextDate: day(10, 20))
    var draft = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(day(10, 13)), amount: AmountE4(whole: 30_000))
    draft.parts = [PartDraft(amount: AmountE4(whole: 30_000))]
    var paid = try draft.materialize()
    paid.transaction.externalId = "sched:\(rent.id.uuidString.lowercased()):2026-10-20"
    let book = PlanningBook(scheduled: [rent])
    let plans = CalendarPlans.collect(
      ledger: ledger([paid], book: book), book: book, today: today, through: day(11, 30))
    #expect(plans.map(\.day) == [day(11, 20)])
  }

  @Test func expectedIncomesWithMoneyStillToCome() {
    let salary = ExpectedIncome(
      name: "Salary", kind: .recurring, totalE4: AmountE4(whole: 100_000),
      dueDate: day(8, 25), freq: .monthly, day: 25)
    let project = ExpectedIncome(
      name: "Project", totalE4: AmountE4(whole: 50_000), dueDate: day(10, 1))
    let closed = ExpectedIncome(
      name: "Closed", totalE4: AmountE4(whole: 5), dueDate: day(10, 30), closed: true)
    let book = PlanningBook(expected: [salary, project, closed])
    let plans = CalendarPlans.collect(
      ledger: ledger(book: book), book: book, today: today, through: day(11, 30))
    #expect(plans.map(\.day) == [day(10, 25), day(11, 25)])
    #expect(plans.allSatisfy { $0.kind == .income && $0.name == "Salary" })
    #expect(plans.first?.amount == AmountE4(whole: 100_000))
  }

  @Test func nothingWhenTheLastDayIsBeforeToday() {
    let rent = ScheduledPayment(
      name: "Rent", amountE4: AmountE4(whole: 30_000), day: 20, nextDate: day(9, 20))
    let book = PlanningBook(scheduled: [rent])
    #expect(
      CalendarPlans.collect(
        ledger: ledger(book: book), book: book, today: today, through: day(10, 13)
      ).isEmpty)
  }
}
