import AppCore
import XCTest

@testable import OhMyMoney

/// Each day of Overview is one list by time, newest first: income, spending, refunds, money
/// back and transfers side by side, told apart by their symbols rather than by headings. Of
/// two lines of one moment, the one written later is on top. What a day comes to is the same as
/// before the lists were merged.
final class DayListOrderTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 9, day: 27)
  private let sber = UUID()
  private let kaspi = UUID()

  private func moment(_ hour: Int, _ minute: Int = 0, second: Int = 0) -> Date {
    CalendarContext.utc.startOfDay(today)
      .addingTimeInterval(TimeInterval(hour * 3600 + minute * 60 + second))
  }

  private func operation(
    _ kind: TransactionKind, _ amount: Int64, at happened: Date, written: Date? = nil
  ) -> TransactionEntry {
    let id = UUID()
    return TransactionEntry(
      transaction: Transaction(
        id: id, kind: kind, occurredAt: happened, amountE4: AmountE4(whole: amount),
        paymentMethodId: sber, createdAt: written ?? happened, updatedAt: written ?? happened),
      parts: [TransactionPart(transactionId: id, amountE4: AmountE4(whole: amount))])
  }

  private func transfer(at happened: Date, written: Date? = nil) -> Transfer {
    Transfer(
      occurredAt: happened, fromAccountId: sber, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 5_000), toAccountId: kaspi, toCurrency: .rub,
      toAmountE4: AmountE4(whole: 5_000), createdAt: written ?? happened,
      updatedAt: written ?? happened)
  }

  /// 27.09: money back from Аня at 09:00, the salary at 10:00, a transfer at 11:15, a coffee at
  /// 12:30, a refund of sneakers at 16:00 — listed from the refund down to the money back.
  func testADayListsEveryKindByTimeNewestFirst() throws {
    let moneyBack = operation(.reimbursement, 500, at: moment(9))
    let salary = operation(.income, 100_000, at: moment(10))
    let moved = transfer(at: moment(11, 15))
    let coffee = operation(.expense, 250, at: moment(12, 30))
    let refund = operation(.refund, 1_000, at: moment(16))

    // Whatever order the operations come in, the day is sorted by time.
    for entries in [[moneyBack, salary, coffee, refund], [coffee, refund, salary, moneyBack]] {
      let groups = TransactionsStore.group(entries, calendar: .utc, transfers: [moved])
      let day = try XCTUnwrap(groups.first)
      XCTAssertEqual(groups.count, 1)
      XCTAssertEqual(
        day.items.map(\.id),
        [
          DayItem.operation(refund).id, DayItem.operation(coffee).id, DayItem.transfer(moved).id,
          DayItem.operation(salary).id, DayItem.operation(moneyBack).id,
        ])
      // The operations alone, and each side, keep the same order.
      XCTAssertEqual(day.entries.map(\.id), [refund.id, coffee.id, salary.id, moneyBack.id])
      XCTAssertEqual(day.expenses.map(\.id), [refund.id, coffee.id])
      XCTAssertEqual(day.income.map(\.id), [salary.id, moneyBack.id])
      XCTAssertEqual(day.transfers.map(\.id), [moved.id])
      // The header says what it always said: the transfer adds nothing, the money back is
      // not income.
      XCTAssertEqual(
        day.totals, RowTotals(entries: [moneyBack, salary, coffee, refund], debts: [:]))
      XCTAssertEqual(day.totals.income, AmountE4(whole: 100_000))
      XCTAssertEqual(
        Set(day.selectableIds), [refund.id, coffee.id, moved.id, salary.id, moneyBack.id])
    }
  }

  func testOfTwoAtOneMomentTheLaterWrittenIsFirst() throws {
    let first = operation(.expense, 250, at: moment(12), written: moment(12, 1))
    let second = operation(.expense, 300, at: moment(12), written: moment(12, 1, second: 1))
    let moved = transfer(at: moment(12), written: moment(12, 1, second: 2))

    let groups = TransactionsStore.group([second, first], calendar: .utc, transfers: [moved])
    XCTAssertEqual(
      try XCTUnwrap(groups.first).items.map(\.id),
      [DayItem.transfer(moved).id, DayItem.operation(second).id, DayItem.operation(first).id])
    let again = TransactionsStore.group([first, second], calendar: .utc, transfers: [moved])
    XCTAssertEqual(
      try XCTUnwrap(again.first).items.map(\.id),
      try XCTUnwrap(groups.first).items.map(\.id), "the same order on every read")
  }

  /// Days stay newest first, each with its own lines; a day of transfers alone is a day too.
  func testDaysKeepTheirOrderAndTheirOwnLines() throws {
    let yesterday = CalendarContext.utc.adding(days: -1, to: today)
    let late = operation(.expense, 250, at: moment(20))
    let early = operation(
      .income, 1_000,
      at: CalendarContext.utc.startOfDay(yesterday).addingTimeInterval(8 * 3600))
    let alone = transfer(
      at: CalendarContext.utc.startOfDay(yesterday).addingTimeInterval(9 * 3600))

    let groups = TransactionsStore.group([early, late], calendar: .utc, transfers: [alone])
    XCTAssertEqual(groups.map(\.day), [today, yesterday])
    XCTAssertEqual(groups[0].items.map(\.id), [DayItem.operation(late).id])
    XCTAssertEqual(
      groups[1].items.map(\.id), [DayItem.transfer(alone).id, DayItem.operation(early).id])
  }
}
