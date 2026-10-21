import CoreAccounting
import CoreKit
import Foundation

/// Which monthly dues of a debt are paid: the one rule the Debts screen, the free sum, the
/// planned month, the forecast of the month, the reminders and the 7-day card share.
///
/// A due is paid by money. Counted from the start of the debt, the payments are laid against the
/// dues one after another, the earliest first, whatever months the payments were made in: a
/// payment made on 28 September «for October» pays October, a month missed stays owed after a
/// later payment. Two halves of the monthly payment pay one due, one payment of two monthly
/// payments pays two, and a small extra payment pays nothing yet — it is kept toward the next due
/// (`partialE4`). A few percent short of a due (`DebtDues.tolerance`) is the bank's interest, not
/// a missing payment. A payment that says «в этом месяце больше платежей не будет»
/// (`DebtEntry.closesTerm`) closes the due it was made for although it is smaller. A debt with
/// no monthly payment has no sum to reach: there each payment closes one due.
public struct DebtDueState: Hashable, Sendable {
  public var debtId: UUID
  /// The first due the debt owes — its payment day in the first month that owes, clipped to
  /// the length of the month; `nil` for a debt without a payment day.
  public var firstDue: DateOnly?
  /// The dues paid: the money of the payments that count, dated from the start of the debt
  /// through the day asked about, laid against the dues from the first.
  public var paidCount: Int
  /// The money paid toward the first unpaid due, less than the due: half a payment, an extra
  /// payment. Zero when the due it belongs to is closed, or when nothing is paid toward it.
  public var partialE4: AmountE4
  /// Something is still owed on the debt: it is open and its journal leaves money owed — or
  /// the journal never recorded what was owed (no line ever raised it), so it has no balance
  /// to go by and owes as it always did. Only then is a due anything to pay.
  public var owes: Bool
  /// The day of the month the debt is paid on.
  public let paymentDay: Int
  /// What is left to pay on the debt, as its journal says through the day the payments count
  /// to — a payment typed for a later day has not paid it yet —; `nil` when the journal never
  /// said what was owed. The dues never ask for more than this: the last due of a loan is what is
  /// left of it, and none after it is owed.
  public var balanceE4: AmountE4?
  /// The monthly payment of the debt, which tells how many dues the balance is enough for;
  /// `nil` when it has none, or the state was not worked out from the debt.
  public var monthlyE4: AmountE4?
  /// What each due asks for, by its index. Without a schedule of its own, the monthly payment
  /// (`monthlyE4`) for every due; none when there is no monthly payment either.
  public var instalments: DebtInstalments
  /// Dues every few days from a first day instead of on `paymentDay` of every month
  /// (`Debt.steps`); `nil` — monthly.
  public var steps: DebtSteps? = nil

  public init(
    debtId: UUID, firstDue: DateOnly?, paidCount: Int, owes: Bool, paymentDay: Int,
    partialE4: AmountE4 = .zero, balanceE4: AmountE4? = nil, monthlyE4: AmountE4? = nil,
    instalments: DebtInstalments? = nil
  ) {
    self.monthlyE4 = monthlyE4.flatMap { $0.raw > 0 ? $0 : nil }
    self.instalments = instalments ?? .flat(monthlyE4)
    self.debtId = debtId
    self.firstDue = firstDue
    self.paidCount = max(0, paidCount)
    self.partialE4 = max(AmountE4.zero, partialE4)
    self.owes = owes
    self.paymentDay = paymentDay
    self.balanceE4 = balanceE4.map { max(AmountE4.zero, $0) }
  }

  /// What is left on the debt as the dues see it (`balanceE4`), else `journal` — the balance of
  /// the whole journal — when the dues were never told one.
  public func balance(or journal: AmountE4) -> AmountE4 { balanceE4 ?? journal }

  /// A debt with nothing due: no payment day, nothing owed.
  public static func none(of debtId: UUID) -> DebtDueState {
    DebtDueState(debtId: debtId, firstDue: nil, paidCount: 0, owes: false, paymentDay: 0)
  }

  /// Dues looked at, at most: a hundred years of months.
  static let limit = 1_200

  /// The due of index `index`, 0 the first: the payment day of the month `index` months after
  /// the first one, clipped to its length — or, for dues every few days (`steps`), the first due
  /// and `index` steps of days after it, whatever months they fall in. Without a first due, the
  /// payment day of no month: 1 January 1970.
  public func due(_ index: Int) -> DateOnly {
    guard let firstDue else { return DateOnly(year: 1970, month: 1, day: 1) }
    if let steps {
      return firstDue.adding(days: max(0, index) * max(1, steps.everyDays))
    }
    let month = firstDue.monthKey.adding(months: max(0, index))
    return DebtDueState.payday(paymentDay, in: month)
  }

  /// The payment day in `month`, clipped to its length: the 31st of September is its 30th.
  public static func payday(_ day: Int, in month: MonthKey) -> DateOnly {
    DateOnly(year: month.year, month: month.month, day: min(max(1, day), month.dayCount))
  }

  /// The earliest due nothing paid yet, while something is owed; it may lie in an earlier
  /// month — overdue. A due that asks for nothing is no due and is passed over.
  public var firstUnpaid: DateOnly? {
    guard let index = firstUnpaidIndex else { return nil }
    return due(index)
  }

  /// The index of `firstUnpaid`: the first due from `paidCount` on that asks for something;
  /// `nil` while nothing is owed, and when no due asks for anything any more.
  public var firstUnpaidIndex: Int? {
    guard owes, firstDue != nil else { return nil }
    return nextAsking(from: paidCount)
  }

  /// The first index from `index` on whose due asks for something — any due when the dues have
  /// no sums (each payment one due); `nil` when none does.
  func nextAsking(from index: Int) -> Int? {
    guard !instalments.isEmpty else { return index }
    if instalments.amount(at: index).raw > 0 { return index }
    return instalments.steps.first { $0.fromIndex > index && $0.amountE4.raw > 0 }?.fromIndex
  }

  /// Whether the due of index `index` asks for nothing: no due at all.
  func asksNothing(_ index: Int) -> Bool {
    !instalments.isEmpty && instalments.amount(at: index).isZero
  }

  /// The earliest unpaid due and every one after it, through `through` — up to the one that
  /// pays off what is left of the debt (`balanceE4`): none after it is owed. Dues that ask for
  /// nothing are not listed.
  public func unpaid(through: DateOnly) -> [DateOnly] {
    unpaidIndices(through: through).map(due)
  }

  /// The indices of `unpaid(through:)`.
  func unpaidIndices(through: DateOnly) -> [Int] {
    guard owes, firstDue != nil, var index = nextAsking(from: paidCount) else { return [] }
    var result: [Int] = []
    while result.count < Self.limit, index < Self.limit {
      let day = due(index)
      guard day <= through, !paysOff(beforeIndex: index) else { break }
      result.append(index)
      guard let next = nextAsking(from: index + 1) else { break }
      index = next
    }
    return result
  }

  /// The state with the dues of `debt` when it was built without any — by hand, from the debt
  /// alone —: its monthly payment for every due. A state that knows its dues keeps them.
  public func knowing(_ debt: Debt) -> DebtDueState {
    guard instalments.isEmpty, let monthly = debt.monthlyPaymentE4, monthly.raw > 0 else {
      return self
    }
    var copy = self
    copy.instalments = .flat(monthly)
    return copy
  }

  /// What the due of index `index` (0 the first) asks for, whatever was paid toward it.
  public func amount(ofDue index: Int) -> AmountE4 {
    instalments.amount(at: index)
  }

  /// Whether the unpaid dues before the due of index `index` already ask for everything left
  /// on the debt (`balanceE4`, at the sums of `instalments`): the first unpaid due is always
  /// owed while the debt owes.
  private func paysOff(beforeIndex index: Int) -> Bool {
    guard let balance = balanceE4, !instalments.isEmpty, index > paidCount else {
      return false
    }
    return owedBefore(index) >= balance
  }

  /// What the unpaid dues before the due of index `index` ask for: each its own sum, the first
  /// of them less what was paid toward it.
  private func owedBefore(_ index: Int) -> AmountE4 {
    guard index > paidCount else { return .zero }
    return max(instalments.total(from: paidCount, to: index) - partialE4, .zero)
  }

  /// What the unpaid dues before the due of index `index` ask for: the monthly payment each,
  /// the first of them less what was paid toward it.
  private func owedBefore(_ index: Int, monthly: AmountE4) -> AmountE4 {
    let count = index - paidCount
    guard count > 0 else { return .zero }
    return max(AmountE4.rounded(monthly.decimal * Decimal(count)) - partialE4, .zero)
  }

  /// The index of the due of `day`, one of the debt's dues.
  private func index(of day: DateOnly) -> Int? {
    guard let firstDue else { return nil }
    if let steps {
      return firstDue.days(to: day) / max(1, steps.everyDays)
    }
    return firstDue.monthKey.months(to: day.monthKey)
  }

  /// The index of the first due on `day` or after it; `nil` without a first due.
  public func firstIndex(onOrAfter day: DateOnly) -> Int? {
    guard let firstDue else { return nil }
    guard day > firstDue else { return 0 }
    var index = max(0, self.index(of: day) ?? 0)
    while index < Self.limit, due(index) < day { index += 1 }
    return min(index, Self.limit)
  }

  /// The unpaid dues before `today`.
  public func overdue(today: DateOnly) -> [DateOnly] {
    unpaid(through: today.adding(days: -1))
  }

  /// What is still owed on the due of `due`: what the due asks for (`amount(ofDue:)`), less
  /// what was paid toward it when it is the first unpaid due — the one the money paid so far was
  /// laid against —, and never more than is left on the debt once the unpaid dues before it are
  /// paid (`balanceE4`). A due that asks for nothing owes nothing.
  public func owed(_ due: DateOnly) -> AmountE4 {
    let index = max(0, index(of: due) ?? 0)
    let amount = instalments.amount(at: index)
    let plain = due == firstUnpaid ? max(amount - partialE4, .zero) : amount
    guard let balance = balanceE4, let first = firstUnpaid, due >= first else { return plain }
    return min(plain, max(balance - owedBefore(index), .zero))
  }

  /// What the unpaid dues through `through` add up to: each its own sum, less what was paid
  /// toward the first of them — never more than is left on the debt.
  public func owed(through: DateOnly) -> AmountE4 {
    let indices = unpaidIndices(through: through)
    guard let last = indices.last else { return .zero }
    let owed: AmountE4
    if instalments.isEmpty {
      owed = .zero
    } else {
      owed = max(instalments.total(from: paidCount, to: last + 1) - partialE4, .zero)
    }
    return balanceE4.map { min(owed, $0) } ?? owed
  }

  /// `owed(_:)` when every due is `monthly`: the form the callers had before the dues knew their
  /// own sums. Kept for the screens that still pass the monthly payment of the debt.
  public func owed(_ due: DateOnly, monthly: AmountE4) -> AmountE4 {
    let plain = due == firstUnpaid ? max(monthly - partialE4, .zero) : monthly
    guard let balance = balanceE4, let first = firstUnpaid, due >= first,
      let index = index(of: due)
    else { return plain }
    return min(plain, max(balance - owedBefore(index, monthly: monthly), .zero))
  }

  /// `owed(through:)` when every due is `monthly`: the form the callers had before the dues knew
  /// their own sums. Kept for the screens that still pass the monthly payment of the debt.
  public func owed(through: DateOnly, monthly: AmountE4) -> AmountE4 {
    let count = unpaid(through: through).count
    guard count > 0 else { return .zero }
    let owed = max(AmountE4.rounded(monthly.decimal * Decimal(count)) - partialE4, .zero)
    return balanceE4.map { min(owed, $0) } ?? owed
  }

  /// Whether the due of `day` — one of the debt's dues — is owed and nothing paid it yet: it is
  /// not before the first due and not before the first unpaid one, something is owed, and the
  /// unpaid dues before it do not already pay off what is left of the debt.
  public func isUnpaid(_ day: DateOnly) -> Bool {
    guard let first = firstUnpaid, day >= first else { return false }
    guard let index = index(of: day) else { return true }
    return !asksNothing(index) && !paysOff(beforeIndex: index)
  }

  /// Whether the due of `day` — one of the debt's dues — is paid: it is one the debt owes
  /// and comes before the first unpaid one; with nothing owed any more every due is.
  public func isPaid(_ day: DateOnly) -> Bool {
    guard let firstDue, day >= firstDue else { return false }
    guard owes else { return true }
    guard let first = firstUnpaidIndex else { return true }
    return day < due(first)
  }
}

/// The dues of the debts, worked out once for all of them.
public enum DebtDues {
  /// A bank's interest and a few kopecks of rounding make a payment a little short of the due;
  /// that much short is still the due. One percent of the monthly payment.
  public static func tolerance(of monthly: AmountE4) -> AmountE4 {
    AmountE4(raw: monthly.raw / 100)
  }

  /// One payment toward a debt, as the dues are laid against it. `at` is the moment it was made —
  /// the start of its day when only the day is known.
  struct Payment: Hashable, Sendable {
    var day: DateOnly
    var at: Date
    var amountE4: AmountE4
    var closesTerm: Bool
    /// An early repayment (`DebtEntry.prepay` term or payment): its money pays what is left of
    /// the due it was made for, and the rest lowers the debt alone — it is not kept toward the
    /// next dues. A payment ahead (`forward`) is not one.
    var prepay: Bool = false
  }

  /// How many dues the money of `payments` pays when the monthly payment is `monthly`, and what
  /// is left over toward the next one.
  ///
  /// The payments go in the order they were made — by day and moment; two that are not told
  /// apart by that, the ones that say nothing go before the ones that close their term —, so the
  /// answer does not depend on the order the journal came in. Each adds its money to what was
  /// left over and pays as many dues as it now
  /// covers — a due a percent short (`tolerance`) too —; the rest is kept toward the next. A
  /// payment that closes its term and did not pay the due it was made for — the earliest unpaid
  /// one before it — pays that due anyway, and nothing is kept.
  static func laid(
    _ payments: [Payment], monthly: AmountE4
  ) -> (paid: Int, partial: AmountE4) {
    let slack = tolerance(of: monthly)
    var paid = 0
    var kept = AmountE4.zero
    let ordered = payments.sorted { left, right in
      if left.at != right.at { return left.at < right.at }
      if left.closesTerm != right.closesTerm { return !left.closesTerm }
      return left.amountE4 < right.amountE4
    }
    for payment in ordered {
      let target = paid
      kept += payment.amountE4
      if payment.prepay {
        if kept + slack >= monthly { paid += 1 }
        kept = kept + slack >= monthly ? .zero : kept
        paid = min(paid, DebtDueState.limit)
        continue
      }
      let covered = Int(min((kept + slack).raw / monthly.raw, Int64(DebtDueState.limit)))
      if covered > 0 {
        paid += covered
        kept = max(kept - AmountE4(raw: monthly.raw * Int64(covered)), .zero)
      }
      if payment.closesTerm, paid == target {
        paid += 1
        kept = .zero
      }
      paid = min(paid, DebtDueState.limit)
    }
    return (paid, kept)
  }

  /// How many dues the money of `payments` pays when the dues ask for `instalments`, and what
  /// is left over toward the next one: `laid(_:monthly:)` with a sum of its own for each due.
  ///
  /// The payments go in the same order. Each adds its money to what was left over; then, due
  /// after due, a due that asks for nothing is passed over, and a due is paid while what is kept
  /// reaches it — a percent of that due short of it too (`tolerance`) —, its sum taken from what
  /// is kept. A payment that closes its term and paid no due pays the due it was made for — the
  /// earliest one asking for something — anyway, and nothing is kept. With the same sum for every
  /// due this is `laid(_:monthly:)` exactly.
  static func laid(
    _ payments: [Payment], instalments: DebtInstalments
  ) -> (paid: Int, partial: AmountE4) {
    var paid = 0
    var kept = AmountE4.zero
    func skipNothing() {
      while paid < DebtDueState.limit, instalments.amount(at: paid).isZero {
        guard
          let next = instalments.steps.first(where: {
            $0.fromIndex > paid && $0.amountE4.raw > 0
          })
        else { return }
        paid = min(next.fromIndex, DebtDueState.limit)
      }
    }
    for payment in ordered(payments) {
      skipNothing()
      let target = paid
      kept += payment.amountE4
      if payment.prepay {
        // What is left of the due it was made for; the rest went to the principal.
        let amount = instalments.amount(at: paid)
        if amount.raw > 0, kept + tolerance(of: amount) >= amount {
          paid += 1
          kept = .zero
          skipNothing()
        }
        paid = min(paid, DebtDueState.limit)
        continue
      }
      while paid < DebtDueState.limit {
        let amount = instalments.amount(at: paid)
        guard amount.raw > 0, kept + tolerance(of: amount) >= amount else { break }
        kept = max(kept - amount, .zero)
        paid += 1
        skipNothing()
      }
      if payment.closesTerm, paid == target, instalments.amount(at: paid).raw > 0 {
        paid += 1
        kept = .zero
      }
      paid = min(paid, DebtDueState.limit)
    }
    return (paid, kept)
  }

  /// The payments in the order they were made — by day and moment; two that are not told apart
  /// by that, the ones that say nothing go before the ones that close their term.
  static func ordered(_ payments: [Payment]) -> [Payment] {
    payments.sorted { left, right in
      if left.at != right.at { return left.at < right.at }
      if left.closesTerm != right.closesTerm { return !left.closesTerm }
      return left.amountE4 < right.amountE4
    }
  }

  /// Every debt's state as of `today`.
  ///
  /// * The schedule starts on `allocationStart` of the debt's journal; the first due is the
  ///   payment day of the first month that owes (`DebtStart.firstMonth`: the month it began, or
  ///   the next one when that month's payment day came before the start — or on it, for
  ///   something bought on credit). A debt whose journal has no day at all starts with this
  ///   month: its first due is this month's payment day, and only payments of this month on
  ///   count — the month rule it always had.
  /// * The payments are the live operations that point at the debt, once each — not those the
  ///   journal wrote as an «Offset» or as more money borrowed (`DebtRules.notPayments`) — and the
  ///   journal's `payment` lines that belong to no such operation (a payment recorded on the
  ///   debt card alone, or «Уже списано до сверки»). Only those dated from the start through
  ///   `paymentsThrough` — today when not said — count: a payment typed ahead pays nothing
  ///   before its day. The plan of the month's end asks with a later day.
  /// * The money of an operation is the amount of its journal line, else the sum of its parts —
  ///   an operation older than the journal has no line; the money of a line of the card alone
  ///   is its amount. With a monthly payment, the money pays dues (`laid`); without one each
  ///   payment is one due.
  public static func states(
    debts: [Debt], ledger: Ledger, journal: [DebtEntry], today: DateOnly,
    paymentsThrough: DateOnly? = nil
  ) -> [UUID: DebtDueState] {
    guard !debts.isEmpty else { return [:] }
    let wanted = Set(debts.map(\.id))
    let through = paymentsThrough ?? today
    let calendar = ledger.calendar
    let notPayments = DebtRules.notPayments(journal)
    var typed: [UUID: [DebtInstalmentStep]] = [:]
    for step in ledger.dataset.debtInstalments where wanted.contains(step.debtId) {
      typed[step.debtId, default: []].append(step)
    }

    var journals: [UUID: [DebtEntry]] = [:]
    for line in journal where wanted.contains(line.debtId) {
      journals[line.debtId, default: []].append(line)
    }
    // The operations that pay each debt, by day, with the money of their parts.
    var operationDays: [UUID: [(transactionId: UUID, day: DateOnly, at: Date)]] = [:]
    var partsMoney: [UUID: AmountE4] = [:]
    for row in ledger.rows {
      guard let debtId = row.debtId, wanted.contains(debtId),
        !notPayments.contains(row.transactionId)
      else { continue }
      partsMoney[row.transactionId, default: .zero] += row.amountE4
      if row.isFirstPart {
        operationDays[debtId, default: []].append((row.transactionId, row.day, row.occurredAt))
      }
    }

    var result: [UUID: DebtDueState] = [:]
    for debt in debts {
      let lines = journals[debt.id] ?? []
      // The journal as of `through`: a line written for a later day — a payment typed ahead —
      // has not happened yet, as it pays no due before its day. Lines without a day count.
      let byThen = lines.filter { line in
        guard let day = line.date ?? line.occurredAt.map(calendar.day(of:)) else { return true }
        return day <= through
      }
      let opened = byThen.contains { $0.amountE4.raw > 0 }
      // A loan that accrues interest owes its principal — the journal with the interest its
      // payments paid given back — and the interest accrued on it since.
      let interest = DebtInterest.walk(
        debt: debt, journal: lines, through: through, calendar: calendar)
      let effective = interest.map { lines + $0.lines } ?? lines
      var left = DebtRules.balance(entries: byThen)
      if let interest {
        left += DebtRules.balance(entries: interest.lines) + interest.accruedE4
      }
      let owes = !debt.closed && (!opened || left.raw > 0)
      // Dues every few days start on their first day, whatever the month.
      let steps = debt.steps
      let paymentDay = steps?.firstDue.day ?? debt.paymentDay ?? 0
      guard steps != nil || paymentDay >= 1 else {
        result[debt.id] = DebtDueState(
          debtId: debt.id, firstDue: nil, paidCount: 0, owes: owes, paymentDay: 0)
        continue
      }
      let start = allocationStart(of: effective, calendar: calendar)
      let firstDue: DateOnly
      let countsFrom: DateOnly
      if let steps {
        firstDue = steps.firstDue
        countsFrom = min(start ?? steps.firstDue, steps.firstDue)
      } else if let start,
        let month = DebtStart.firstMonth(of: debt, startsOn: start, calendar: calendar)
      {
        firstDue = DebtDueState.payday(paymentDay, in: month)
        countsFrom = start
      } else {
        firstDue = DebtDueState.payday(paymentDay, in: today.monthKey)
        countsFrom = today.monthKey.firstDay
      }
      func counts(_ day: DateOnly) -> Bool { day >= countsFrom && day <= through }

      let operations = operationDays[debt.id] ?? []
      let paidByOperation = Set(operations.map(\.transactionId))
      let ownLines = Dictionary(
        lines.filter { $0.kind == .payment }.compactMap { line in
          line.transactionId.map { ($0, line) }
        }, uniquingKeysWith: { first, _ in first })
      var payments: [Payment] = []
      for (transactionId, day, at) in operations where counts(day) {
        let line = ownLines[transactionId]
        payments.append(
          Payment(
            day: day, at: at,
            amountE4: line?.amountE4.magnitude ?? partsMoney[transactionId] ?? .zero,
            closesTerm: line?.closesTerm ?? false, prepay: line?.prepay?.isEarlyRepayment == true))
      }
      for line in lines where line.kind == .payment {
        if let transactionId = line.transactionId, paidByOperation.contains(transactionId) {
          continue
        }
        guard let day = line.date ?? line.occurredAt.map(calendar.day(of:)), counts(day) else {
          continue
        }
        payments.append(
          Payment(
            day: day, at: line.occurredAt ?? calendar.startOfDay(day),
            amountE4: line.amountE4.magnitude, closesTerm: line.closesTerm,
            prepay: line.prepay?.isEarlyRepayment == true))
      }

      let instalments = Self.instalments(
        of: debt, journal: lines, firstDue: firstDue, paymentDay: paymentDay, steps: steps,
        today: today, typed: typed[debt.id] ?? [], calendar: calendar)
      let paid: Int
      var partial = AmountE4.zero
      if !instalments.isEmpty {
        (paid, partial) = laid(payments, instalments: instalments)
      } else {
        paid = payments.count
      }
      var state = DebtDueState(
        debtId: debt.id, firstDue: firstDue, paidCount: paid, owes: owes,
        paymentDay: paymentDay, partialE4: partial,
        balanceE4: opened ? left : nil,
        monthlyE4: debt.monthlyPaymentE4, instalments: instalments)
      state.steps = steps
      result[debt.id] = state
    }
    return result
  }

  /// What each due of `debt` asks for: its schedule (`DebtSchedulePlan.plan`), the new sums the
  /// early repayments that lowered the payment worked out (`DebtAmortization.prepaySteps`), and
  /// over them the sums typed from the bank's app, each holding until the next step of either
  /// kind. A debt with none of these reads as its schedule alone.
  public static func instalments(
    of debt: Debt, journal: [DebtEntry], firstDue: DateOnly, paymentDay: Int,
    steps: DebtSteps?, today: DateOnly, typed: [DebtInstalmentStep], calendar: CalendarContext
  ) -> DebtInstalments {
    let schedule = DebtSchedulePlan.plan(
      debt: debt, journal: journal, firstDue: firstDue, paymentDay: paymentDay, today: today,
      calendar: calendar
    ).instalments
    var computed = schedule
    if journal.contains(where: { $0.debtId == debt.id && $0.prepay == .payment }) {
      var probe = DebtDueState(
        debtId: debt.id, firstDue: firstDue, paidCount: 0, owes: true, paymentDay: paymentDay,
        monthlyE4: debt.monthlyPaymentE4, instalments: schedule)
      probe.steps = steps
      let prepaid = DebtAmortization.prepaySteps(
        debt: debt, journal: journal, dues: probe, calendar: calendar)
      if !prepaid.isEmpty { computed = DebtInstalments(steps: schedule.steps + prepaid) }
    }
    return .merged(computed: computed, typed: typed.filter { $0.debtId == debt.id })
  }

  /// The day the schedule of a debt starts: the day it began (`DebtStart.day`), moved to the
  /// day after the latest day its balance fell to zero or below when it grew again afterwards —
  /// a debt paid off and taken again, or a credit card kept as a debt, starts a new schedule
  /// instead of letting old payments pay new dues. Lines without a day come first; the
  /// balance is read at the end of each day. `nil` for a journal with no day at all.
  public static func allocationStart(
    of journal: [DebtEntry], calendar: CalendarContext
  ) -> DateOnly? {
    guard var start = DebtStart.day(of: journal, calendar: calendar) else { return nil }
    var undated = AmountE4.zero
    var byDay: [DateOnly: AmountE4] = [:]
    for line in journal {
      if let day = line.date ?? line.occurredAt.map(calendar.day(of:)) {
        byDay[day, default: .zero] += line.amountE4
      } else {
        undated += line.amountE4
      }
    }
    var balance = undated
    var lastZero: DateOnly?
    for day in byDay.keys.sorted() {
      balance += byDay[day] ?? .zero
      if balance.raw <= 0 { lastZero = day }
    }
    if balance.raw > 0, let lastZero { start = max(start, lastZero.adding(days: 1)) }
    return start
  }
}
