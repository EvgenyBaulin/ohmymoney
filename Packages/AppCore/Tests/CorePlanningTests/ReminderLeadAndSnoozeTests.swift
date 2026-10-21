import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// How far ahead a payment or a debt is reminded — its own number of days, three when it sets
/// none — and what becomes of a reminder put off when an ordinary operation pays its due date:
/// the one put off is gone with its occasion, the next due date is a new one and comes back by
/// itself.
@Suite("Reminders: their own lead and a reminder put off")
struct ReminderLeadAndSnoozeTests {
  typealias Fx = CashFx

  func payments(_ fx: CashFx, today: String) -> [DateOnly?] {
    fx.snapshot(today: Fx.day(today), now: Fx.at(today, 12)).reminders
      .filter { $0.kind == .payment }.map(\.due)
  }

  func debts(_ fx: CashFx, today: String) -> [DateOnly?] {
    fx.snapshot(today: Fx.day(today), now: Fx.at(today, 12)).reminders
      .filter { $0.kind == .debtPayment }.map(\.due)
  }

  /// Rent on the 30th reminded ten days ahead: on the 20th, not on the 19th. Without a lead of
  /// its own, three days: on the 27th, not the 26th. A lead of zero: on the day only. A
  /// negative lead is none.
  @Test func aPaymentIsRemindedByItsOwnLead() {
    var fx = Fx()
    var rent = Fx.payment(1, "Rent", "30000", day: 30, next: "2026-09-30")
    rent.remindDaysBefore = 10
    fx.scheduled = [rent]
    #expect(payments(fx, today: "2026-09-19").isEmpty)
    #expect(payments(fx, today: "2026-09-20") == [Fx.day("2026-09-30")])

    rent.remindDaysBefore = nil
    fx.scheduled = [rent]
    #expect(payments(fx, today: "2026-09-26").isEmpty)
    #expect(payments(fx, today: "2026-09-27") == [Fx.day("2026-09-30")])

    for lead in [0, -5] {
      rent.remindDaysBefore = lead
      fx.scheduled = [rent]
      #expect(payments(fx, today: "2026-09-29").isEmpty, "\(lead)")
      #expect(payments(fx, today: "2026-09-30") == [Fx.day("2026-09-30")], "\(lead)")
    }
  }

  /// A loan paid on the 25th, taken on 1 September, reminded a week ahead: on the 18th, not
  /// the 17th.
  @Test func aDebtIsRemindedByItsOwnLead() {
    var fx = Fx()
    let loan = Debt(
      id: Fx.id(321), direction: .iOwe, type: .loan, name: "Loan",
      monthlyPaymentE4: Fx.money("8000"), paymentDay: 25, remindDaysBefore: 7)
    fx.debts = [loan]
    fx.debtEntries = [
      DebtEntry(
        debtId: loan.id, date: Fx.day("2026-09-01"), amountE4: Fx.money("80000"),
        kind: .borrowed)
    ]
    #expect(debts(fx, today: "2026-09-17").isEmpty)
    #expect(debts(fx, today: "2026-09-18") == [Fx.day("2026-09-25")])
  }

  /// Cleaning every Monday, the one of the 14th put off. While it is unpaid it stays away.
  /// Once an ordinary operation pays it, the reminder put off is no longer one — it is dropped
  /// from the setting — and the next Monday, the 21st, is reminded: a new occasion.
  @Test func aReminderPutOffGoesWithItsDueAndTheNextComesBack() {
    var fx = Fx()
    var cleaning = ScheduledPayment(
      id: Fx.id(1), name: "Cleaning", amountE4: Fx.money("2000"), categoryId: Fx.housing,
      freq: .weekly, day: 1, nextDate: Fx.day("2026-09-14"))
    cleaning.remindDaysBefore = 3
    fx.scheduled = [cleaning]
    let putOff = "pay:\(cleaning.id.uuidString.lowercased()):2026-09-14"
    fx.settings.dismissedReminders = [putOff]
    #expect(payments(fx, today: "2026-09-19").isEmpty)
    let all = ReminderRules.all(
      book: fx.book, debts: [], ledger: fx.ledger, today: Fx.today)
    #expect(all.filter { $0.kind == .payment }.map(\.id) == [putOff])

    fx.add(.expense, "2000", at: Fx.at("2026-09-15", 10), category: Fx.housing)
    #expect(payments(fx, today: "2026-09-19") == [Fx.day("2026-09-21")])
    let active = Set(
      ReminderRules.all(book: fx.book, debts: [], ledger: fx.ledger, today: Fx.today).map(\.id))
    #expect(!active.contains(putOff))
    let next = "pay:\(cleaning.id.uuidString.lowercased()):2026-09-21"
    #expect(
      ReminderRules.dismissed(adding: next, to: fx.settings.dismissedReminders, active: active)
        == [next])
  }
}
