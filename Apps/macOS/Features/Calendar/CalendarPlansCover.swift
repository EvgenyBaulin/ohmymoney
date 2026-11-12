import AppCore
import Foundation

/// The plans the lists leave out while the hidden accounts are covered: a scheduled payment paid
/// from a hidden account or with a card of one, and an expected income that comes to a hidden
/// account. Like an operation of such an account, the plan is not listed — not in the calendar,
/// not in «Ближайшие 14 дней», not in the blocks of payments and incomes — and the sums that
/// count it keep its money. A debt names no account, so its payments always stay.
///
/// Read from the snapshot the screen draws (`DataSnapshot.hiding`), so not a frame lists a plan
/// of an account the owner hid; the whole snapshot hides nothing.
struct HiddenPlans: Hashable, Sendable {
  let scheduled: Set<UUID>
  let expected: Set<UUID>
  let creditAccounts: Set<UUID>

  static let none = HiddenPlans(scheduled: [], expected: [])

  init(scheduled: Set<UUID>, expected: Set<UUID>, creditAccounts: Set<UUID> = []) {
    self.scheduled = scheduled
    self.expected = expected
    self.creditAccounts = creditAccounts
  }

  /// The plans of `book` that `hidden` leaves out.
  init(book: PlanningBook, hidden: HiddenOperations) {
    guard !hidden.isEmpty else {
      self = .none
      return
    }
    creditAccounts = hidden.accounts.ids
    scheduled = Set(
      book.scheduled.filter { hidden.hides(account: $0.paymentMethodId, card: $0.cardId) }
        .map(\.id))
    expected = Set(
      book.expected.filter { hidden.hides(account: $0.paymentMethodId, card: nil) }.map(\.id))
  }

  /// What the snapshot on screen is presented without; nothing for the whole one.
  init(snapshot: DataSnapshot) {
    self.init(
      book: snapshot.ledger.dataset.planning, hidden: HiddenOperations(snapshot: snapshot))
  }

  var isEmpty: Bool { scheduled.isEmpty && expected.isEmpty && creditAccounts.isEmpty }

  func hides(scheduled id: UUID) -> Bool { scheduled.contains(id) }
  func hides(expected id: UUID) -> Bool { expected.contains(id) }

  func hides(_ plan: CalendarPlan) -> Bool {
    switch plan.kind {
    case .payment:
      scheduled.contains(plan.sourceId)
        || plan.creditAccountId.map(creditAccounts.contains) == true
    case .income: expected.contains(plan.sourceId)
    }
  }

  func hides(_ payment: UpcomingPayment) -> Bool {
    payment.kind == .scheduled && scheduled.contains(payment.id)
  }

  /// The calendar without the hidden plans in its days; what each day plans in and out is
  /// counted as before, all the money in it.
  func covering(_ calendar: SpendingCalendar) -> SpendingCalendar {
    guard !isEmpty else { return calendar }
    var copy = calendar
    copy.weeks = calendar.weeks.map { week in
      week.map { day in
        var day = day
        day.plans = day.plans.filter { !hides($0) }
        return day
      }
    }
    return copy
  }

  /// «Ближайшие 14 дней» without the hidden plans on its days; the two sums under it keep them.
  func covering(_ ribbon: PlanningRibbon) -> PlanningRibbon {
    guard !isEmpty else { return ribbon }
    var copy = ribbon
    copy.days = ribbon.days.map { day in
      var day = day
      day.incomes = day.incomes.filter { !hides($0) }
      day.payments = day.payments.filter { !hides($0) }
      return day
    }
    return copy
  }
}
