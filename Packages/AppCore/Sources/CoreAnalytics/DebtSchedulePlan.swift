import CoreAccounting
import CoreKit
import Foundation

/// What each due of a debt asks for (`DebtInstalments`): the monthly payment, or, for a loan with
/// a grace period, the grace payment until the main schedule starts and the main payment from it
/// on; a main payment the owner did not type is the annuity of what is owed over
/// `Debt.repayMonths`.
///
/// * Without a grace period: the monthly payment for every due; without one, the annuity over
///   `repayMonths` of what was owed when the schedule began (the lines before the first due),
///   frozen — it does not shrink as the loan is paid.
/// * A due of the grace period — one before `DebtGrace.mainFrom` — asks for the fixed sum, or
///   for the interest the money drawn earns over the days since the due before (`InterestMath`,
///   at the debt's rate, rounded once to the cent), every share of it for `.interest`, by year of
///   the loan for `.programme` (`GracePayment.interestShare`). The money drawn is every line of
///   the journal that is no payment, a tranche still to come included: it raises the due of the
///   month it is drawn in by its days, and every due after it in full.
/// * A due on `mainFrom` or after it asks for the monthly payment the owner typed, else the
///   annuity over `repayMonths` of what is owed when the main schedule starts: the money drawn
///   before `mainFrom` and the share of the grace interest the grace dues did not ask for, which
///   is put off, not forgiven. It is worked out once and holds for every main due.
/// * A due of zero — no money drawn yet, no rate — is no due: it is never listed and counts as
///   paid when its day comes (`DebtDueState`).
public enum DebtSchedulePlan {
  /// The schedule of a debt worked out from its journal.
  public struct Plan: Hashable, Sendable {
    public var instalments: DebtInstalments
    /// The index of the first due of the main schedule; `nil` without a grace period.
    public var mainIndex: Int?
    /// What every due of the main schedule asks for; `nil` when nothing does.
    public var mainAmount: AmountE4?
    /// The share of the grace interest the grace dues did not ask for, which joins what the main
    /// schedule repays.
    public var deferredE4: AmountE4

    public init(
      instalments: DebtInstalments, mainIndex: Int? = nil, mainAmount: AmountE4? = nil,
      deferredE4: AmountE4 = .zero
    ) {
      self.instalments = instalments
      self.mainIndex = mainIndex
      self.mainAmount = mainAmount
      self.deferredE4 = deferredE4
    }
  }

  /// The sums of the dues of `debt`, whose first due is `firstDue`, paid on `paymentDay`, as its
  /// `journal` stands on `today`.
  public static func instalments(
    debt: Debt, journal: [DebtEntry], firstDue: DateOnly, paymentDay: Int, today: DateOnly,
    calendar: CalendarContext
  ) -> DebtInstalments {
    plan(
      debt: debt, journal: journal, firstDue: firstDue, paymentDay: paymentDay, today: today,
      calendar: calendar
    ).instalments
  }

  /// The whole schedule of `debt` (`instalments`), with where its main schedule starts and what
  /// it asks for. An instalment plan asks for its parts (`InstalmentPlan.instalments`). `typed`
  /// are the sums of dues typed from the bank's app (`debt_instalments`): each holds from its due
  /// until the next step of either kind (`DebtInstalments.merged`).
  public static func plan(
    debt: Debt, journal: [DebtEntry], firstDue: DateOnly, paymentDay: Int, today: DateOnly,
    calendar: CalendarContext, typed: [DebtInstalmentStep] = []
  ) -> Plan {
    let bank = typed.filter { $0.debtId == debt.id }
    if debt.isInstalmentPlan {
      let parts = InstalmentPlan.instalments(
        debt: debt,
        price: InstalmentPlan.price(of: debt, journal: journal.filter { $0.debtId == debt.id }))
      let first = parts.amount(at: 0)
      return Plan(
        instalments: .merged(computed: parts, typed: bank),
        mainAmount: first.raw > 0 ? first : nil)
    }
    var computed = computedPlan(
      debt: debt, journal: journal, firstDue: firstDue, paymentDay: paymentDay,
      calendar: calendar)
    computed.instalments = .merged(computed: computed.instalments, typed: bank)
    return computed
  }

  /// The schedule as the debt's terms and journal work it out, before any sum typed by hand.
  private static func computedPlan(
    debt: Debt, journal: [DebtEntry], firstDue: DateOnly, paymentDay: Int,
    calendar: CalendarContext
  ) -> Plan {
    let lines = journal.filter { $0.debtId == debt.id }
    let typed = debt.monthlyPaymentE4.flatMap { $0.raw > 0 ? $0 : nil }
    let percent = debt.interestRate ?? 0
    func dayOf(_ line: DebtEntry) -> DateOnly? {
      line.date ?? line.occurredAt.map(calendar.day(of:))
    }

    guard let grace = debt.grace else {
      if let typed { return Plan(instalments: .flat(typed), mainAmount: typed) }
      guard let months = debt.repayMonths, months >= 1 else { return Plan(instalments: .none) }
      var opening = AmountE4.sum(
        lines.filter { line in dayOf(line).map { $0 < firstDue } ?? true }.map(\.amountE4))
      if opening.raw <= 0 {
        opening = AmountE4.sum(lines.map(\.amountE4).filter { $0.raw > 0 })
      }
      let main = InterestMath.annuity(principal: opening, percent: percent, months: months)
      return Plan(instalments: .flat(main), mainAmount: main.raw > 0 ? main : nil)
    }

    func due(_ index: Int) -> DateOnly {
      DebtDueState.payday(paymentDay, in: firstDue.monthKey.adding(months: index))
    }
    let mainIndex = mainIndex(firstDue: firstDue, paymentDay: paymentDay, mainFrom: grace.mainFrom)

    // The money drawn, in steps by day: every line that is no payment, the undated ones before
    // the first dated day.
    var undated = AmountE4.zero
    var byDay: [DateOnly: AmountE4] = [:]
    for line in lines where line.kind != .payment {
      if let day = dayOf(line) {
        byDay[day, default: .zero] += line.amountE4
      } else {
        undated += line.amountE4
      }
    }
    var segments: [(from: DateOnly, amount: AmountE4)] = []
    var running = undated
    let drawnDays = byDay.keys.sorted()
    if !undated.isZero {
      segments.append(((drawnDays.first ?? firstDue).adding(days: -1), running))
    }
    for day in drawnDays {
      running += byDay[day] ?? .zero
      segments.append((day, running))
    }
    let loanStart = Self.loanStart(of: lines, calendar: calendar) ?? firstDue

    var steps: [DebtInstalments.Step] = []
    var deferred = Decimal(0)
    for index in 0..<mainIndex {
      let amount: AmountE4
      let year = loanYear(of: due(index), from: loanStart)
      if let share = grace.payment.interestShare(inLoanYear: year) {
        let accrued = InterestMath.accrue(
          segments: segments, percent: percent, after: due(index - 1), through: due(index))
        amount = InterestMath.cents(accrued * share)
        if share < 1 { deferred += accrued * (1 - share) }
      } else {
        amount = grace.payment.fixedAmount ?? .zero
      }
      steps.append(DebtInstalments.Step(fromIndex: index, amountE4: amount))
    }
    let deferredE4 = max(InterestMath.cents(deferred), .zero)

    var main = typed
    if main == nil, let months = debt.repayMonths, months >= 1 {
      let drawn = segments.last { $0.from < grace.mainFrom }?.amount ?? .zero
      let principal = max(drawn, .zero) + deferredE4
      let annuity = InterestMath.annuity(principal: principal, percent: percent, months: months)
      main = annuity.raw > 0 ? annuity : nil
    }
    steps.append(DebtInstalments.Step(fromIndex: mainIndex, amountE4: main ?? .zero))
    return Plan(
      instalments: DebtInstalments(steps: steps), mainIndex: mainIndex, mainAmount: main,
      deferredE4: deferredE4)
  }

  /// The index of the first due on `mainFrom` or after it, of the dues on `paymentDay` from
  /// `firstDue` on; 0 when the first due already is.
  public static func mainIndex(firstDue: DateOnly, paymentDay: Int, mainFrom: DateOnly) -> Int {
    guard mainFrom > firstDue else { return 0 }
    var index = max(0, firstDue.monthKey.months(to: mainFrom.monthKey))
    if DebtDueState.payday(paymentDay, in: firstDue.monthKey.adding(months: index)) < mainFrom {
      index += 1
    }
    return min(index, DebtDueState.limit)
  }

  /// The day a loan's years are counted from: its first tranche, else the day it began.
  public static func loanStart(
    of journal: [DebtEntry], calendar: CalendarContext
  ) -> DateOnly? {
    let tranches = journal.filter(\.tranche).compactMap { line in
      line.date ?? line.occurredAt.map(calendar.day(of:))
    }
    return tranches.min() ?? DebtStart.day(of: journal, calendar: calendar)
  }

  /// The year of the loan `day` lies in, 1 the first: the year from `start`, the anniversary
  /// starting the next one.
  public static func loanYear(of day: DateOnly, from start: DateOnly) -> Int {
    guard day > start else { return 1 }
    var years = day.year - start.year
    if (day.month, day.day) < (start.month, start.day) { years -= 1 }
    return max(0, years) + 1
  }

  /// The money drawn on `debt` through `through`: every line that raised it — the loan, each
  /// tranche, an adjustment up —, undated ones included.
  public static func drawnE4(
    journal: [DebtEntry], through: DateOnly, calendar: CalendarContext
  ) -> AmountE4 {
    AmountE4.sum(
      journal.filter { line in
        guard line.amountE4.raw > 0, line.kind != .payment else { return false }
        guard let day = line.date ?? line.occurredAt.map(calendar.day(of:)) else { return true }
        return day <= through
      }.map(\.amountE4))
  }
}
