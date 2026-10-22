import AppCore
import XCTest

@testable import OhMyMoney

/// What the balance chart of a debt's card draws, worked out without a window.
final class DebtBalanceSeriesTests: XCTestCase {
  private func entry(
    _ date: DateOnly, _ rubles: Int64, _ kind: DebtEntryKind = .payment
  )
    -> DebtEntry
  {
    DebtEntry(debtId: UUID(), date: date, amountE4: AmountE4(raw: rubles * 10_000), kind: kind)
  }

  func testBalanceIsTheRunningTotalAtTheEndOfEachMonth() {
    let series = DebtBalanceSeries.make(
      entries: [
        entry(DateOnly(year: 2026, month: 3, day: 5), 1_000, .borrowed),
        entry(DateOnly(year: 2026, month: 4, day: 10), -100),
        entry(DateOnly(year: 2026, month: 4, day: 20), -100),
      ], schedule: [])
    XCTAssertEqual(series.fact.map(\.rubles), [1_000, 800])
    XCTAssertTrue(series.plan.isEmpty)
    XCTAssertTrue(series.isDrawable)
  }

  func testAMonthWithoutLinesKeepsTheBalanceBefore() {
    let series = DebtBalanceSeries.make(
      entries: [
        entry(DateOnly(year: 2026, month: 1, day: 5), 900, .borrowed),
        entry(DateOnly(year: 2026, month: 4, day: 5), -300),
      ], schedule: [])
    XCTAssertEqual(series.fact.map(\.rubles), [900, 900, 900, 600])
    XCTAssertEqual(
      series.fact.map { DebtBalanceSeries.monthKey($0.month).month }, [1, 2, 3, 4])
  }

  func testOneMonthIsNotEnoughForALine() {
    let series = DebtBalanceSeries.make(
      entries: [entry(DateOnly(year: 2026, month: 1, day: 5), 900, .borrowed)], schedule: [])
    XCTAssertFalse(series.isDrawable)
    XCTAssertTrue(DebtBalanceSeries.make(entries: [], schedule: []).fact.isEmpty)
  }

  func testTheScheduleStartsWhereTheJournalEndsAndOnlyGoesForward() {
    let rows = [
      AmortizationRow(
        index: 0, due: DateOnly(year: 2026, month: 4, day: 28), paymentE4: .zero,
        interestE4: .zero, principalE4: .zero, balanceAfterE4: AmountE4(raw: 400 * 10_000)),
      AmortizationRow(
        index: 1, due: DateOnly(year: 2026, month: 5, day: 28), paymentE4: .zero,
        interestE4: .zero, principalE4: .zero, balanceAfterE4: AmountE4(raw: 0)),
    ]
    let series = DebtBalanceSeries.make(
      entries: [
        entry(DateOnly(year: 2026, month: 3, day: 5), 600, .borrowed),
        entry(DateOnly(year: 2026, month: 4, day: 5), -100),
      ], schedule: rows)
    // The April row is not ahead of the journal's April: only May is added to the joint.
    XCTAssertEqual(series.plan.map(\.rubles), [500, 0])
    XCTAssertEqual(series.plan.first, series.fact.last)
  }

  func testAnOverpaidDebtNeverDrawsBelowZero() {
    let series = DebtBalanceSeries.make(
      entries: [
        entry(DateOnly(year: 2026, month: 1, day: 5), 100, .borrowed),
        entry(DateOnly(year: 2026, month: 2, day: 5), -300),
      ], schedule: [])
    XCTAssertEqual(series.fact.map(\.rubles), [100, 0])
  }

  func testPaidTotalIsWhatTheJournalTookFromTheBalance() {
    let debt = Debt(direction: .iOwe, type: .loan, name: "Loan")
    let line = DebtLine(
      debt: debt, balance: .zero, balanceRub: nil, groups: [], nextPayment: nil,
      paidThisMonth: false,
      entries: [
        entry(DateOnly(year: 2026, month: 1, day: 5), 900, .borrowed),
        entry(DateOnly(year: 2026, month: 2, day: 5), -300),
        entry(DateOnly(year: 2026, month: 3, day: 5), -200),
      ])
    XCTAssertEqual(line.paidTotal, AmountE4(raw: 500 * 10_000))
  }
}
