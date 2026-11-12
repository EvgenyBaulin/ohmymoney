import CoreAccounting
import CoreKit
import Foundation

/// How a payment of a debt stands against the schedule: the colour of its stripe on the phone.
public enum DebtPaymentMark: String, Hashable, Sendable, CaseIterable {
  /// Made on the schedule for what the dues ask: the standard payment.
  case regular
  /// Money above what the dues ask by its day (an early repayment, the next dues paid ahead),
  /// or a payment the owner marked as an early repayment.
  case extra
  /// Made after the day of the earliest unpaid due.
  case overdue

  /// What a debt as a whole says: one overdue payment — or a due that passed unpaid — makes it
  /// `overdue`; else one extra payment makes it `extra`; else it is `regular`.
  public static func combined(
    _ marks: some Sequence<DebtPaymentMark>, overdueNow: Bool
  )
    -> DebtPaymentMark
  {
    var extra = false
    for mark in marks {
      if mark == .overdue { return .overdue }
      if mark == .extra { extra = true }
    }
    if overdueNow { return .overdue }
    return extra ? .extra : .regular
  }
}

/// Classifies the payments of a debt I owe against its schedule.
///
/// The payments are laid against the dues in the order they were made (`DebtDues.laid`), so for
/// each payment the dues as they stood just before it are known: the earliest unpaid due and
/// what was kept toward it. From that:
/// * **overdue** — the payment's day is after the day of the earliest unpaid due (a payment on
///   the day of the due is in time);
/// * **extra** — it carries an early-repayment answer (`DebtEntry.prepay`), or its money is above
///   what the unpaid dues through its day ask (`DebtPrepay.excess`, a few percent of the due
///   being the bank's interest, not extra);
/// * **regular** — any other.
/// Overdue wins over extra: a late payment is late whatever its size. A debt without a schedule
/// (no payment day, or dues that ask for nothing) has no dues to be late for or above, so only
/// an explicit early repayment makes a payment extra there.
public enum DebtPaymentHistory {
  /// The mark of each payment line of `entries`, by the id of the line. Only a debt I owe has
  /// marks; the other lines (money borrowed, offsets, adjustments) have none.
  public static func marks(
    debt: Debt, entries: [DebtEntry], dues: DebtDueState, calendar: CalendarContext
  ) -> [UUID: DebtPaymentMark] {
    guard debt.direction == .iOwe else { return [:] }
    struct Line {
      var id: UUID
      var payment: DebtDues.Payment
      var prepay: Bool
    }
    var lines: [Line] = []
    for entry in entries where entry.kind == .payment {
      guard let day = entry.date ?? entry.occurredAt.map(calendar.day(of:)) else { continue }
      let early = entry.prepay?.isEarlyRepayment == true
      lines.append(
        Line(
          id: entry.id,
          payment: DebtDues.Payment(
            day: day, at: entry.occurredAt ?? calendar.startOfDay(day),
            amountE4: entry.amountE4.magnitude, closesTerm: entry.closesTerm, prepay: early),
          prepay: entry.prepay != nil))
    }
    // The same order the dues are laid in, ties broken by the id so the answer is stable.
    lines.sort { left, right in
      let a = left.payment
      let b = right.payment
      if a.at != b.at { return a.at < b.at }
      if a.closesTerm != b.closesTerm { return !a.closesTerm }
      if a.amountE4 != b.amountE4 { return a.amountE4 < b.amountE4 }
      return left.id.uuidString < right.id.uuidString
    }

    let scheduled = dues.firstDue != nil && !dues.instalments.isEmpty
    var result: [UUID: DebtPaymentMark] = [:]
    var before: [DebtDues.Payment] = []
    for line in lines {
      defer { before.append(line.payment) }
      guard scheduled else {
        result[line.id] = line.prepay ? .extra : .regular
        continue
      }
      let (paid, partial) = DebtDues.laid(before, instalments: dues.instalments)
      var probe = dues
      probe.paidCount = paid
      probe.partialE4 = partial
      probe.balanceE4 = nil
      probe.owes = true
      if let first = probe.firstUnpaid, first < line.payment.day {
        result[line.id] = .overdue
      } else if line.prepay
        || DebtPrepay.excess(payment: line.payment.amountE4, dues: probe, on: line.payment.day).raw
          > 0
      {
        result[line.id] = .extra
      } else {
        result[line.id] = .regular
      }
    }
    return result
  }

  /// The stripe of the whole debt: `nil` for a debt I am owed or one that was deleted; see
  /// `DebtPaymentMark.combined`. A due that passed unpaid counts as an overdue now only while
  /// the debt is open.
  public static func stripe(
    debt: Debt, marks: [UUID: DebtPaymentMark], dues: DebtDueState, today: DateOnly
  ) -> DebtPaymentMark? {
    guard debt.direction == .iOwe, !debt.isDeleted else { return nil }
    let overdueNow = !debt.closed && !dues.overdue(today: today).isEmpty
    return DebtPaymentMark.combined(marks.values, overdueNow: overdueNow)
  }
}
