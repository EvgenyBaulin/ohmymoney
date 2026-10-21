import CoreAccounting
import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CorePlanning

/// The lists of Planning and Overview on random books: the list of payments, the 7-day card,
/// the reminders and the planned month each name the due dates the calendar gives, less the
/// ones «Провести» paid — every preset, the last day of the month, one-off payments.
@Suite("Planning lists on random books: every screen names the same due dates")
struct PlanningListsPropertyTests {
  typealias Book = CashPlanPropertyTests.Book
  typealias Fx = CashFx

  static let seeds: [UInt64] = Array(1...24)

  /// The due dates of a payment from its `next_date` through `last`, by the calendar.
  static func dues(of payment: ScheduledPayment, through last: DateOnly) -> [DateOnly] {
    guard let next = payment.nextDate else { return [] }
    return PlainCalendar.days(from: next, through: last).filter {
      PlainCalendar.isDue($0, of: payment)
    }
  }

  static func price(_ book: Book, _ payment: ScheduledPayment, on day: DateOnly) -> AmountE4 {
    book.fx.prices.last { $0.paymentId == payment.id && $0.date <= day }?.amountE4
      ?? payment.amountE4
  }

  /// The 7-day card: every unpaid due date of an active payment from its `next_date` through
  /// today + 7, at the price of its day; the ones before today overdue.
  @Test(arguments: seeds)
  func theSevenDayCardNamesTheUnpaidDueDates(_ seed: UInt64) {
    let book = Book(seed: seed)
    let snapshot = book.fx.snapshot()
    let horizon = Fx.today.adding(days: PlanningSnapshot.upcomingDays)
    var model: [UpcomingPayment] = []
    for payment in book.fx.scheduled where payment.active {
      guard let next = payment.nextDate, payment.endDate.map({ next <= $0 }) ?? true else {
        continue
      }
      let unpaid = Self.dues(of: payment, through: horizon).filter {
        book.linked[payment.id]?.contains($0) != true
      }.prefix(PlanningSnapshot.upcomingPerPayment)
      for due in unpaid {
        model.append(
          UpcomingPayment(
            kind: .scheduled, id: payment.id, name: payment.name, due: due,
            currency: payment.currency, amount: Self.price(book, payment, on: due),
            isOverdue: due < Fx.today))
      }
    }
    let card = snapshot.upcoming.filter { $0.kind == .scheduled }
    #expect(Set(card) == Set(model), "seed \(seed)")
    #expect(card.count == model.count, "seed \(seed)")
    // Overdue first, then by date.
    let order = card.map { ($0.isOverdue ? 0 : 1, $0.due.dayNumber) }
    #expect(
      zip(order, order.dropFirst()).allSatisfy { $0.0 < $1.0 || ($0.0 == $1.0 && $0.1 <= $1.1) },
      "seed \(seed)")
  }

  /// The reminder of a payment is its first unpaid due date from `next_date`, while it is no
  /// more than 3 days ahead — an overdue one included.
  @Test(arguments: seeds)
  func theReminderIsTheFirstUnpaidDue(_ seed: UInt64) {
    let book = Book(seed: seed)
    let reminders = book.fx.snapshot().reminders.filter { $0.kind == .payment }
    var model: [String] = []
    for payment in book.fx.scheduled where payment.active {
      let horizon = Fx.today.adding(days: ReminderRules.defaultDaysBefore)
      if let due = Self.dues(of: payment, through: horizon).first(where: {
        book.linked[payment.id]?.contains($0) != true
      }) {
        model.append("pay:\(payment.id.uuidString.lowercased()):\(due.iso)")
      }
    }
    #expect(Set(reminders.map(\.id)) == Set(model), "seed \(seed)")
  }

  /// The planned month: every unpaid due date of this month from `next_date` on, at the price
  /// of its day, my share in rubles — none for a currency without a rate.
  @Test(arguments: seeds)
  func thePlannedMonthNamesThisMonthsUnpaidDueDates(_ seed: UInt64) {
    let book = Book(seed: seed)
    let planned = book.fx.snapshot().planned
    var model: [PlannedItem] = []
    for payment in book.fx.scheduled where payment.active {
      for due in Self.dues(of: payment, through: Fx.today.monthKey.lastDay)
      where due >= Fx.today.monthKey.firstDay && book.linked[payment.id]?.contains(due) != true {
        let price = Self.price(book, payment, on: due)
        model.append(
          PlannedItem(
            kind: .scheduled, id: payment.id, due: due, currency: payment.currency, amount: price,
            myShareRub: book.rubles(price, payment.currency), categoryId: payment.categoryId,
            forWhom: payment.forWhom))
      }
    }
    let items = planned.items.filter { $0.kind == .scheduled }
    #expect(Set(items) == Set(model), "seed \(seed)")
    #expect(items.count == model.count)
    #expect(
      planned.scheduled == AmountE4.sum(model.compactMap(\.myShareRub)), "seed \(seed)")
  }

  /// The list: one line per active payment still due, showing its first due date nothing paid
  /// — overdue when that is before today — and this month's due dates from `next_date`.
  @Test(arguments: seeds)
  func theListShowsTheFirstUnpaidDue(_ seed: UInt64) {
    let book = Book(seed: seed)
    let statuses = book.fx.snapshot().scheduled
    let far = Fx.today.adding(days: 3_000)
    for payment in book.fx.scheduled where payment.active {
      guard let next = payment.nextDate, payment.endDate.map({ next <= $0 }) ?? true else {
        #expect(!statuses.contains { $0.id == payment.id })
        continue
      }
      guard let status = statuses.first(where: { $0.id == payment.id }) else {
        Issue.record("seed \(seed): \(payment.name) is missing")
        continue
      }
      let all = Self.dues(of: payment, through: far)
      let unpaid = all.first { book.linked[payment.id]?.contains($0) != true }
      #expect(status.nextUnpaid == (unpaid ?? all.last), "seed \(seed): \(payment.name)")
      #expect(status.isOverdue == (unpaid.map { $0 < Fx.today } ?? false), "seed \(seed)")
      #expect(status.amountNext == Self.price(book, payment, on: status.nextUnpaid))
      #expect(
        status.dueDates
          == Array(Self.dues(of: payment, through: Fx.today.monthKey.lastDay).suffix(12)),
        "seed \(seed)")
    }
    // Soonest unpaid first.
    #expect(
      statuses.map(\.nextUnpaid) == statuses.map(\.nextUnpaid).sorted(), "seed \(seed)")
  }
}
