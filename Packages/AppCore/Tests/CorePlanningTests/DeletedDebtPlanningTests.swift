import CoreAccounting
import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation
import Testing

/// A deleted debt is in no list, reminder, due date or free sum of Planning and Debts, while
/// the ledger still finds it for the operations that point at it.
@Suite("A deleted debt in Planning")
struct DeletedDebtPlanningTests {
  func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "DE1E7ED0-0000-0000-0000-%012d", number)) ?? UUID()
  }

  let today = DateOnly(year: 2026, month: 9, day: 19)
  var now: Date { CalendarContext.utc.startOfDay(today).addingTimeInterval(12 * 3600) }

  /// A loan of 100,000 ₽ with a monthly payment of 5,000 ₽ on the 25th, reminded 7 days before;
  /// the same loan deleted, when `deleted`.
  func planning(deleted: Bool) -> (PlanningSnapshot, Ledger) {
    var debt = Debt(
      id: id(1), direction: .iOwe, type: .loan, name: "Loan",
      monthlyPaymentE4: AmountE4(whole: 5000), paymentDay: 25, remindDaysBefore: 7,
      paymentsAreExpenses: true, origin: .existing)
    let opening = DebtRules.makeEntry(
      id: id(2), debtId: debt.id, kind: .borrowed, amountE4: AmountE4(whole: 100_000),
      date: DateOnly(year: 2026, month: 1, day: 10))
    if deleted { debt.deletedAt = now }
    let ledger = Ledger(
      dataset: Dataset(
        debts: deleted ? [] : [debt], planning: PlanningBook(debtEntries: [opening]),
        deletedDebts: deleted ? [debt] : []),
      calendar: .utc)
    return (
      PlanningSnapshot.build(ledger: ledger, today: today, now: now, rubPerUnit: [:]), ledger
    )
  }

  @Test func aDeletedDebtIsInNoListReminderOrFreeSum() {
    let (live, _) = planning(deleted: false)
    #expect(live.debts.iOwe.map(\.debt.id) == [id(1)])
    #expect(live.reminders.contains { $0.subjectId == id(1) })
    #expect(live.planned.items.contains { $0.id == id(1) })
    #expect(live.debts.totalIOweRub == AmountE4(whole: 100_000))

    let (gone, ledger) = planning(deleted: true)
    #expect(gone.debts.iOwe.isEmpty)
    #expect(gone.debts.closed.isEmpty)
    #expect(gone.debts.owedToMe.isEmpty)
    #expect(gone.debts.totalIOweRub == .zero)
    #expect(gone.debts.monthlyPaymentsRub == .zero)
    #expect(!gone.reminders.contains { $0.subjectId == id(1) })
    #expect(!gone.planned.items.contains { $0.id == id(1) })
    #expect(!gone.upcoming.contains { $0.id == id(1) })
    #expect(!gone.overdue.contains { $0.subject == .debt(id(1)) })
    // The ledger still knows it: the operations that point at it count as they did.
    #expect(ledger.dataset.debtsById[id(1)]?.isDeleted == true)
  }
}
