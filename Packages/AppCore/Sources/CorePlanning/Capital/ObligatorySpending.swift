import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// The obligatory spending of one full month, in rubles: what was paid for scheduled payments
/// and subscriptions, the dues of the debts with a schedule, and the essential categories.
public struct ObligatoryMonth: Hashable, Sendable {
  public var month: MonthKey
  public var scheduledRub: AmountE4
  public var debtsRub: AmountE4
  public var essentialRub: AmountE4

  public init(
    month: MonthKey, scheduledRub: AmountE4, debtsRub: AmountE4, essentialRub: AmountE4
  ) {
    self.month = month
    self.scheduledRub = scheduledRub
    self.debtsRub = debtsRub
    self.essentialRub = essentialRub
  }

  public var total: AmountE4 { scheduledRub + debtsRub + essentialRub }
}

/// What a month without income would cost: the median of the obligatory spending of the last
/// full months, never below the payments committed today.
public struct ObligatorySpending: Hashable, Sendable {
  public enum State: Hashable, Sendable {
    case ready
    /// Fewer full months than `ObligatoryRules.minimumMonths`; `fullMonths` is how many there are.
    case notEnoughData(fullMonths: Int)
  }

  /// The full months taken, oldest first.
  public var months: [ObligatoryMonth]
  /// The median of the month totals; `nil` without enough months.
  public var medianRub: AmountE4?
  /// Today's monthly payments of the debts and the monthly equivalent of the live scheduled
  /// payments: the floor of `monthlyRub`.
  public var committedRub: AmountE4
  /// max(`medianRub`, `committedRub`); `nil` without enough months.
  public var monthlyRub: AmountE4?
  public var state: State

  public init(
    months: [ObligatoryMonth], medianRub: AmountE4?, committedRub: AmountE4,
    monthlyRub: AmountE4?, state: State
  ) {
    self.months = months
    self.medianRub = medianRub
    self.committedRub = committedRub
    self.monthlyRub = monthlyRub
    self.state = state
  }

  public static let empty = ObligatorySpending(
    months: [], medianRub: nil, committedRub: .zero, monthlyRub: nil,
    state: .notEnoughData(fullMonths: 0))
}

/// Builds the obligatory spending of the safety cushion: what a month without income would
/// cost.
///
/// For each of the last `CapitalSettings.historyMonths` full months before today's — never
/// before the month of the first operation — three sources, each row counted once:
/// * **scheduled** — my expenses that paid a scheduled payment or a subscription: written as
///   «Провести» (a `.scheduled` link) or matched to a due date (`ScheduledMatches`). Lines the
///   app wrote for its books, goal contributions, parts paid for somebody else and debt payments
///   are not in it.
/// * **debts** — for each debt I owe that has monthly dues, the money paid toward it in the
///   month (its operations and the journal's payments written without one), never more than
///   the dues of the month ask: paying a loan off early is a choice, not an obligation. A debt
///   with no dues is not obligatory.
/// * **essential** — the daily spending (`MonthForecast`'s variable rows) in the categories
///   marked as essential (`CategoryTree.isEssential`).
///
/// The monthly figure is the median of the month totals, and never less than what is committed
/// today: the monthly payments of the debts and the monthly equivalent of the live scheduled
/// payments, so a new loan or subscription counts at once.
public enum ObligatoryRules {
  /// Full months needed before the figure means anything.
  public static let minimumMonths = 3

  public static func build(
    ledger: Ledger, book: PlanningBook, matches: ScheduledMatches, debts: DebtsOverview,
    subscriptionsMonthly: AmountE4, settings: CapitalSettings, today: DateOnly
  ) -> ObligatorySpending {
    let committed =
      debts.monthlyPaymentsRub + subscriptionsMonthly + billsMonthly(book: book, today: today)
    let history = min(
      max(settings.historyMonths, CapitalSettings.historyMonthsRange.lowerBound),
      CapitalSettings.historyMonthsRange.upperBound)
    let thisMonth = today.monthKey
    guard let firstMonth = ledger.firstDay?.monthKey else {
      return ObligatorySpending(
        months: [], medianRub: nil, committedRub: committed, monthlyRub: nil,
        state: .notEnoughData(fullMonths: 0))
    }
    let window = MonthKey.range(
      max(firstMonth, thisMonth.adding(months: -history)), through: thisMonth.previous)

    let paidDebts = DebtMoney(ledger: ledger, book: book, debts: debts, window: window)
    let months = window.map { month -> ObligatoryMonth in
      var scheduled = AmountE4.zero
      var essential = AmountE4.zero
      for row in ledger.rows(in: DayRange(month.firstDay, month.lastDay)) {
        if isScheduled(row, matches: matches) {
          scheduled += row.contribution
        } else if isVariable(row, matches: matches), ledger.tree.isEssential(row.categoryId) {
          essential += row.contribution
        }
      }
      return ObligatoryMonth(
        month: month, scheduledRub: scheduled, debtsRub: paidDebts.obligatory(in: month),
        essentialRub: essential)
    }

    guard months.count >= minimumMonths,
      let median = IncomeEstimate.median(months.map(\.total))
    else {
      return ObligatorySpending(
        months: months, medianRub: nil, committedRub: committed, monthlyRub: nil,
        state: .notEnoughData(fullMonths: months.count))
    }
    return ObligatorySpending(
      months: months, medianRub: median, committedRub: committed,
      monthlyRub: max(median, committed), state: .ready)
  }

  /// My expense that paid a scheduled payment: «Провести» wrote it, or it matched a due date.
  static func isScheduled(_ row: LedgerRow, matches: ScheduledMatches) -> Bool {
    let paysScheduled: Bool
    if case .scheduled = row.link {
      paysScheduled = true
    } else {
      paysScheduled = matches.operationIds.contains(row.transactionId)
    }
    guard paysScheduled, !row.contribution.isZero else { return false }
    if row.link?.isBookkeeping == true { return false }
    return !row.isGoalContribution && !row.reimbursable && row.debtId == nil
  }

  /// Daily spending, as the forecast of the month reads it: not a scheduled payment, not a
  /// debt payment, not a goal, not a part paid for somebody else, not a line the app wrote for
  /// its books, not a category of the app.
  static func isVariable(_ row: LedgerRow, matches: ScheduledMatches) -> Bool {
    if case .scheduled = row.link { return false }
    if matches.operationIds.contains(row.transactionId) { return false }
    if row.link?.isBookkeeping == true { return false }
    return !row.contribution.isZero && !row.isGoalContribution && row.debtId == nil
      && !row.reimbursable && row.systemRole == nil
  }

  /// The monthly equivalent of the live scheduled payments that are not subscriptions (those
  /// come in `subscriptionsMonthly`): bills paid for me, in rubles, that still repeat — not a
  /// one-off payment, not one that ended. A bill in another currency has no rate here and is
  /// left out.
  static func billsMonthly(book: PlanningBook, today: DateOnly) -> AmountE4 {
    var total = AmountE4.zero
    for payment in book.scheduled
    where payment.active && payment.kind != .subscription && !payment.isOneOff
      && !payment.reimbursable && payment.currency == .rub && payment.nextDate != nil
      && (payment.endDate.map { $0 >= today } ?? true)
    {
      let price = SubscriptionMath.price(of: payment, on: today, prices: book.prices)
      total += SubscriptionMath.monthlyEquivalent(price, rule: RecurrenceRule(payment: payment))
    }
    return total
  }

  /// The money paid toward the debts I owe that have dues, by month, capped by what the dues
  /// of the month ask, in rubles.
  private struct DebtMoney {
    /// Per debt and month: the money paid in the debt's currency, and its rubles when the
    /// operations tell them.
    private var paid: [UUID: [MonthKey: (money: AmountE4, opMoney: AmountE4, opRub: AmountE4)]] =
      [:]
    private var lines: [DebtLine] = []

    init(ledger: Ledger, book: PlanningBook, debts: DebtsOverview, window: [MonthKey]) {
      guard let first = window.first, let last = window.last else { return }
      lines = (debts.iOwe + debts.closed).filter {
        $0.debt.direction == .iOwe && $0.debt.hasDues && !$0.debt.isDeleted
      }
      guard !lines.isEmpty else { return }
      let wanted = Set(lines.map(\.debt.id))
      let currencies = Dictionary(
        lines.map { ($0.debt.id, $0.debt.currency) }, uniquingKeysWith: { first, _ in first })
      let journal = book.debtEntries.filter { wanted.contains($0.debtId) }
      let notPayments = DebtRules.notPayments(journal)
      let lineOfOperation = Dictionary(
        journal.filter { $0.kind == .payment }.compactMap { line in
          line.transactionId.map { ($0, line) }
        }, uniquingKeysWith: { first, _ in first })
      let range = DayRange(first.firstDay, last.lastDay)

      // The operations: the money of the journal line written with each, else of its parts.
      var operations: [UUID: (debtId: UUID, month: MonthKey, money: AmountE4, rub: AmountE4)] =
        [:]
      var live: Set<UUID> = []
      for row in ledger.rows {
        guard let debtId = row.debtId, wanted.contains(debtId),
          !notPayments.contains(row.transactionId)
        else { continue }
        live.insert(row.transactionId)
        guard range.contains(row.day) else { continue }
        var operation =
          operations[row.transactionId]
          ?? (debtId, row.day.monthKey, .zero, .zero)
        if row.currency == currencies[debtId] { operation.money += row.amountE4 }
        operation.rub += row.amountRubE4
        operations[row.transactionId] = operation
      }
      for (transactionId, operation) in operations {
        let money = lineOfOperation[transactionId]?.amountE4.magnitude ?? operation.money
        var month = paid[operation.debtId, default: [:]][operation.month] ?? (.zero, .zero, .zero)
        month.money += money
        // Only money whose rubles the operation tells gives a rate.
        if money.raw > 0, !operation.rub.isZero {
          month.opMoney += money
          month.opRub += operation.rub
        }
        paid[operation.debtId, default: [:]][operation.month] = month
      }
      // The journal's payments written without a live operation: «Уже списано до сверки», a
      // payment recorded on the debt card alone, the payments of a purchase on credit.
      for line in journal where line.kind == .payment {
        if let transactionId = line.transactionId, live.contains(transactionId) { continue }
        guard let day = line.date ?? line.occurredAt.map(ledger.calendar.day(of:)),
          range.contains(day)
        else { continue }
        var month = paid[line.debtId, default: [:]][day.monthKey] ?? (.zero, .zero, .zero)
        month.money += line.amountE4.magnitude
        paid[line.debtId, default: [:]][day.monthKey] = month
      }
    }

    /// Σ over the debts of min(money paid in the month, what its dues of the month ask).
    func obligatory(in month: MonthKey) -> AmountE4 {
      var total = AmountE4.zero
      for line in lines {
        guard let paidInMonth = paid[line.debt.id]?[month], paidInMonth.money.raw > 0,
          let firstDue = line.dues.firstDue
        else { continue }
        let index = firstDue.monthKey.months(to: month)
        guard index >= 0 else { continue }
        let asked = line.dues.amount(ofDue: index)
        let capped = min(paidInMonth.money, asked)
        guard capped.raw > 0 else { continue }
        if let rub = rubles(capped, line: line, paid: paidInMonth) { total += rub }
      }
      return total
    }

    /// Rubles of money of the debt's currency: as the operations of the month paid them, else
    /// at the rate the Debts screen used for the balance today; `nil` with neither.
    private func rubles(
      _ amount: AmountE4, line: DebtLine,
      paid: (money: AmountE4, opMoney: AmountE4, opRub: AmountE4)
    ) -> AmountE4? {
      if line.debt.currency == .rub { return amount }
      if paid.opMoney.raw > 0 {
        return SubscriptionMath.rounded(amount.decimal * paid.opRub.decimal / paid.opMoney.decimal)
      }
      if let balanceRub = line.balanceRub, !line.balance.isZero {
        return SubscriptionMath.rounded(
          amount.decimal * balanceRub.decimal / line.balance.decimal)
      }
      return nil
    }
  }
}
