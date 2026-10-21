import CoreAccounting
import CoreKit
import Foundation

/// An early repayment of a loan: the money of a payment above what the dues ask for by its day.
/// The owner says what it does — a shorter term, a smaller payment, or the next dues paid ahead
/// (`PrepayChoice.forward`, a payment as before 1.9) —, and the answer is kept on the payment's
/// line (`DebtEntry.prepay`). Above the due it pays, the money of an early repayment lowers the
/// debt alone (`DebtDues`); a smaller payment is worked out anew (`DebtAmortization.prepaySteps`).
public enum DebtPrepay {
  /// The money of the payment above what the dues still ask through its day — the overdue ones
  /// and the first unpaid one, whatever its day. A debt with no dues has nothing early.
  public static func excess(payment: AmountE4, dues: DebtDueState, on day: DateOnly) -> AmountE4 {
    guard payment.raw > 0, dues.owes, let first = dues.firstUnpaid else { return .zero }
    let owed = dues.owed(through: max(day, first))
    return max(payment - owed - DebtDues.tolerance(of: owed), .zero)
  }

  /// Whether to ask what the early repayment does: a debt I owe, open, not an instalment plan,
  /// with a rate or a monthly payment, and money above the due.
  public static func asks(
    debt: Debt, dues: DebtDueState, payment: AmountE4, day: DateOnly
  ) -> Bool {
    guard debt.direction == .iOwe, !debt.closed, !debt.isDeleted, !debt.isInstalmentPlan,
      debt.type != .creditCard
    else { return false }
    let hasRate = (debt.interestRate ?? 0) > 0
    let hasPayment = (debt.monthlyPaymentE4?.raw ?? 0) > 0 || debt.hasDues
    guard hasRate || hasPayment else { return false }
    return excess(payment: payment, dues: dues.knowing(debt), on: day).raw > 0
  }

  /// The answer offered first: the last `prepay` of the journal of this debt — «Это платёж
  /// вперёд» too —, else `.term`.
  public static func defaultChoice(debtId: UUID, journal: [DebtEntry]) -> PrepayChoice {
    let answered = journal.filter { $0.debtId == debtId && $0.prepay != nil }
    // The journal comes in the order it was written: of two answers of one day and moment the
    // later one is the last given, so a tie goes to the later line (`max` keeps the first).
    func key(_ line: DebtEntry) -> (String, Date) {
      (line.date?.iso ?? "", line.occurredAt ?? .distantPast)
    }
    let last = answered.reduce(nil as DebtEntry?) { latest, line in
      guard let latest else { return line }
      return key(line) < key(latest) ? latest : line
    }
    return last?.prepay ?? .term
  }

  /// The day the early repayment lowers the debt from: the day of the payment when the bank
  /// takes one on any day, else the nearest due on or after it.
  public static func effectiveDay(
    debt: Debt, paidOn: DateOnly, dues: DebtDueState
  ) -> DateOnly {
    guard !debt.prepayAnyDay, let index = dues.firstIndex(onOrAfter: paidOn) else {
      return paidOn
    }
    return dues.due(index)
  }

  /// `effectiveDay` from the terms of the debt alone, for a reading that has no dues yet: the
  /// next payment day of the month, or the next step of days.
  public static func effectiveDay(debt: Debt, paidOn: DateOnly) -> DateOnly {
    guard !debt.prepayAnyDay else { return paidOn }
    if let steps = debt.steps {
      guard paidOn > steps.firstDue else { return steps.firstDue }
      let every = max(1, steps.everyDays)
      let count = (steps.firstDue.days(to: paidOn) + every - 1) / every
      return steps.firstDue.adding(days: count * every)
    }
    guard let day = debt.paymentDay, day >= 1 else { return paidOn }
    let this = DebtDueState.payday(day, in: paidOn.monthKey)
    return this >= paidOn ? this : DebtDueState.payday(day, in: paidOn.monthKey.next)
  }
}
