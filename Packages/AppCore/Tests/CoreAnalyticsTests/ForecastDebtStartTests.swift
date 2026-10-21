import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// A debt owes nothing before it began, and the forecast of the month knows it as the planned
/// month, the free sum, the reminders and the Debts screen do: a loan written today that
/// begins on the 28th, paid on the 25th, first owes on 25 October — the forecast of September
/// does not expect 8 000 on 25 September.
@Suite("The forecast expects no debt payment before the debt began")
struct ForecastDebtStartTests {
  /// A loan of 8 000 a month on the 25th whose payments are expenses.
  static let loan = Debt(
    id: id(95), direction: .iOwe, type: .loan, name: "Loan", monthlyPaymentE4: money("8000"),
    paymentDay: 25, paymentsAreExpenses: true, origin: .existing)

  func ledger(_ sketch: Sketch, journal: [DebtEntry], debt: Debt = Self.loan) -> Ledger {
    Ledger(
      dataset: Dataset(
        entries: sketch.entries, categories: sketch.categories, debts: [debt],
        planning: PlanningBook(debtEntries: journal)),
      calendar: .utc)
  }

  func borrowed(on iso: String?, at moment: String? = nil, debt: Debt = Self.loan) -> DebtEntry {
    DebtEntry(
      id: id(9500), debtId: debt.id, date: iso.map(day), amountE4: money("80000"),
      kind: .borrowed,
      occurredAt: moment.map { CalendarContext.utc.startOfDay(day($0)).addingTimeInterval(3600) })
  }

  /// Today 19 September; the loan's only journal line is «borrowed» on 28 September. The 25th of
  /// September comes before the loan: nothing is expected this month.
  @Test func aLoanThatBeginsAfterItsDayIsNotExpectedThisMonth() {
    let today = day("2026-09-19")
    let later = ledger(Sketch(), journal: [borrowed(on: "2026-09-28")])
    #expect(PlannedPayments(ledger: later, today: today).debts == .zero)
    // A loan written for November is not expected in September either.
    let november = ledger(Sketch(), journal: [borrowed(on: "2026-11-10")])
    #expect(PlannedPayments(ledger: november, today: today).debts == .zero)
    // In October, after it began, its 25th is expected.
    #expect(PlannedPayments(ledger: later, today: day("2026-10-19")).debts == money("8000"))
  }

  /// A loan that began on its payment day owes that day; one that began before it owes as
  /// always; a journal line with only a moment counts by the day of that moment; a loan with
  /// an empty journal has nothing to say when it began and is expected as before.
  @Test func aLoanThatBeganByItsDayIsExpected() {
    let today = day("2026-09-19")
    for journal in [
      [borrowed(on: "2026-09-25")], [borrowed(on: "2026-09-01")],
      [borrowed(on: nil, at: "2026-09-10")], [],
    ] {
      #expect(
        PlannedPayments(ledger: ledger(Sketch(), journal: journal), today: today).debts
          == money("8000"), "\(journal.map { $0.date?.iso ?? "moment" })")
    }
    #expect(
      PlannedPayments(
        ledger: ledger(Sketch(), journal: [borrowed(on: nil, at: "2026-09-27")]), today: today
      ).debts == .zero)
  }

  /// A loan taken on 15 September, paid on the 5th: September owed nothing, so a payment made
  /// on 25 September pays the first due, 5 October — the rule of the planned month. The
  /// forecast of October does not expect it again.
  @Test func aPaymentInTheMonthItBeganPaysTheFirstDue() {
    var early = Self.loan
    early.paymentDay = 5
    var sketch = Sketch()
    sketch.expense("2026-09-25", "8000", category: id(4), debt: early.id)
    let paid = ledger(sketch, journal: [borrowed(on: "2026-09-15", debt: early)], debt: early)
    #expect(PlannedPayments(ledger: paid, today: day("2026-10-01")).debts == .zero)
    // November is owed again.
    #expect(PlannedPayments(ledger: paid, today: day("2026-11-01")).debts == money("8000"))

    // Paid in the journal alone, the same.
    let journalOnly = ledger(
      Sketch(),
      journal: [
        borrowed(on: "2026-09-15", debt: early),
        DebtEntry(
          id: id(9501), debtId: early.id, date: day("2026-09-25"), amountE4: money("-8000"),
          kind: .payment),
      ], debt: early)
    #expect(PlannedPayments(ledger: journalOnly, today: day("2026-10-01")).debts == .zero)

    // Taken on the 1st, September owed its 5th: a payment on the 25th paid September, and
    // October is still expected.
    let owedSeptember = ledger(
      sketch, journal: [borrowed(on: "2026-09-01", debt: early)], debt: early)
    #expect(
      PlannedPayments(ledger: owedSeptember, today: day("2026-10-01")).debts == money("8000"))
  }
}
