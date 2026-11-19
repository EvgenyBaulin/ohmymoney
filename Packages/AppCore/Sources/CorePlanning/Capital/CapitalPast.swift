import CoreAnalytics
import CoreKit
import Foundation

/// The rules that carry the chart of the capital back before the books began. Nothing here is
/// a balance: it is the chart's reading of what the owner bought, borrowed and said.
enum CapitalPast {
  /// The value on the straight line between two dated values, at `day`, to the kopeck.
  static func onTheLine(
    from start: (day: DateOnly, value: AmountE4), to end: (day: DateOnly, value: AmountE4),
    at day: DateOnly
  ) -> AmountE4 {
    let span = NetWorthChartModel.position(of: end.day) - NetWorthChartModel.position(of: start.day)
    let passed = NetWorthChartModel.position(of: day) - NetWorthChartModel.position(of: start.day)
    guard span > 0, passed > 0 else { return start.value }
    guard passed < span else { return end.value }
    let value =
      Decimal(start.value.raw)
      + (Decimal(end.value.raw) - Decimal(start.value.raw)) * Decimal(passed) / Decimal(span)
    return AmountE4(raw: (try? DecimalMath.int64(rounding: value)) ?? start.value.raw)
  }

  /// Puts the rough sum the owner named on the points before the books, along the straight line
  /// to the money of the first point the books count; without a sum (or for a point before the
  /// day it was named for) those points hold the assets and the debts alone.
  static func applyCash(_ cash: PastCash?, to points: inout [CapitalPoint]) {
    guard let end = points.first(where: { !$0.beforeBooks }) else { return }
    let endCash = end.accountsRub + end.depositsRub + end.outOfSummaryRub
    for index in points.indices where points[index].beforeBooks {
      guard let cash, points[index].day >= cash.day else {
        points[index].withoutCash = true
        continue
      }
      points[index].cashEstimated = true
      points[index].estimatedCashRub = onTheLine(
        from: (cash.day, cash.amountE4), to: (end.day, endCash), at: points[index].day)
    }
  }
}

/// What a loan I owe was worth before its journal begins: from the day it was taken out and the
/// sum borrowed, month by month along the schedule its rate, payment and term give, bent evenly
/// so that it meets the balance the journal begins with. From the first line of the journal on,
/// only the records speak.
///
/// A loan's stored payment schedule, grace period and payment pause shape the balance before the
/// journal begins. Where the database only has one rate, that rate holds for the whole schedule.
struct DebtRestoration {
  private static let scheduleLimit = 1_200

  let opening: DebtOpening
  /// The day of the first line of the journal: before it the loan is restored.
  let start: DateOnly
  private let schedule: [(day: DateOnly, balance: AmountE4)]
  private let monthsToStart: Int
  /// What the journal begins with less what the schedule gives on that day.
  private let gap: AmountE4

  init?(
    debt: Debt, journal: [DebtEntry], typedPayments: [DebtInstalmentStep] = [],
    calendar: CalendarContext
  ) {
    guard debt.direction == .iOwe, debt.type == .loan, let opening = debt.opening,
      !journal.isEmpty
    else { return nil }
    var days: [DateOnly] = []
    for line in journal {
      // A line with no day makes the start ambiguous: nothing is restored then.
      guard let day = line.date ?? line.occurredAt.map(calendar.day(of:)) else { return nil }
      days.append(day)
    }
    guard let start = days.min() else { return nil }
    let months = Self.months(from: opening.day.monthKey, to: start.monthKey)
    guard months >= 1 else { return nil }
    self.opening = opening
    self.start = start
    monthsToStart = months

    let payments = typedPayments.filter { $0.debtId == debt.id }
    let paymentDay = debt.paymentDay ?? opening.day.day
    let firstDue = opening.day.monthKey.next.firstDay
    let openingEntry = DebtEntry(
      id: debt.id, debtId: debt.id, date: opening.day, amountE4: opening.amountE4,
      kind: .borrowed)
    let plan = DebtSchedulePlan.plan(
      debt: debt, journal: [openingEntry], firstDue: firstDue, paymentDay: paymentDay,
      today: start, calendar: calendar, typed: payments)
    schedule = Self.schedule(
      debt: debt, opening: opening, firstDue: firstDue, paymentDay: paymentDay,
      instalments: plan.instalments, typedPayments: payments, through: start)
    let reached = Self.balance(in: schedule, on: start, opening: opening.amountE4)
    let first = DebtBalanceAt.balance(
      of: debt, journal: journal, through: start, calendar: calendar)
    gap = first - reached
  }

  /// What was owed at the end of the month `day` closes, or `nil` before the loan was taken out
  /// or from the day the journal begins.
  func balance(on day: DateOnly) -> AmountE4? {
    let months = Self.months(from: opening.day.monthKey, to: day.monthKey)
    guard months >= 0, day < start else { return nil }
    let planned = Self.balance(in: schedule, on: day, opening: opening.amountE4)
    let bent = Decimal(gap.raw) * Decimal(months) / Decimal(monthsToStart)
    let share = AmountE4(raw: (try? DecimalMath.int64(rounding: bent)) ?? 0)
    return max(.zero, planned + share)
  }

  private static func balance(
    in schedule: [(day: DateOnly, balance: AmountE4)], on day: DateOnly,
    opening: AmountE4
  ) -> AmountE4 {
    schedule.last { $0.day <= day }?.balance ?? opening
  }

  /// Month by month, the named due amounts first pay interest and then principal. A skipped due
  /// during a pause leaves its interest on the balance; a paid interest-only grace due does not
  /// lower principal.
  private static func schedule(
    debt: Debt, opening: DebtOpening, firstDue: DateOnly, paymentDay: Int,
    instalments: DebtInstalments, typedPayments: [DebtInstalmentStep], through: DateOnly
  ) -> [(day: DateOnly, balance: AmountE4)] {
    var dues = DebtDueState(
      debtId: debt.id, firstDue: firstDue, paidCount: 0, owes: true, paymentDay: paymentDay,
      balanceE4: opening.amountE4, monthlyE4: debt.monthlyPaymentE4, instalments: instalments)
    dues.pause = debt.pause
    dues.explicitDates = DebtDues.namedDays(of: typedPayments)

    var events: [(day: DateOnly, index: Int)] = []
    for index in 0..<scheduleLimit {
      let day = dues.due(index)
      guard day <= through else { break }
      events.append((day, index))
    }

    var result: [(day: DateOnly, balance: AmountE4)] = [(opening.day, opening.amountE4)]
    var balance = opening.amountE4
    var month = opening.day.monthKey.next
    let hasPaymentSchedule = !instalments.isEmpty
    let typedSchedule = DebtInstalments(
      steps: typedPayments.map { .init(fromIndex: $0.fromIndex, amountE4: $0.amountE4) })

    while month <= through.monthKey {
      let dueEvents = events.filter { $0.day.monthKey == month }
      if !dueEvents.isEmpty {
        for event in dueEvents {
          let interest = DebtAmortization.monthInterest(
            of: balance, percent: debt.interestRate ?? 0)
          let isTypedDue = typedSchedule.steps.contains { $0.fromIndex <= event.index }
          let isInterestOnlyGrace =
            !isTypedDue
            && debt.grace.map {
              $0.payment == .interest && event.day < $0.mainFrom
            } == true
          guard hasPaymentSchedule, !isInterestOnlyGrace else {
            result.append((event.day, balance))
            continue
          }
          let amountOwed = balance + interest
          let payment = min(instalments.amount(at: event.index), amountOwed)
          balance = max(.zero, amountOwed - payment)
          result.append((event.day, balance))
        }
      } else if hasPaymentSchedule, let pause = debt.pause, pause.isValid {
        let periodEnd = min(month.lastDay, through)
        if pause.from <= periodEnd, pause.to >= month.firstDay {
          balance += DebtAmortization.monthInterest(
            of: balance, percent: debt.interestRate ?? 0)
          result.append((periodEnd, balance))
        }
      }
      guard month < through.monthKey else { break }
      month = month.next
    }
    return result
  }

  private static func months(from first: MonthKey, to last: MonthKey) -> Int {
    (last.year * 12 + last.month) - (first.year * 12 + first.month)
  }
}
