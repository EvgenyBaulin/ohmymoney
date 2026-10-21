import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// The tax on professional income of one month.
public struct NPDMonth: Hashable, Sendable {
  public enum State: String, Hashable, Sendable {
    /// The month is under way.
    case accruing
    /// The month is over and its tax is not due yet.
    case due
    /// Below the minimum: carried to the next month.
    case carried
    case paid
    case overdue
  }

  public var month: MonthKey
  public var incomeRub: AmountE4
  public var returnsRub: AmountE4
  public var baseRub: AmountE4
  public var taxBeforeDeductionE4: AmountE4
  public var deductionUsedE4: AmountE4
  public var taxE4: AmountE4
  /// Carried in from the month before, below the minimum there.
  public var carriedInE4: AmountE4
  public var toPayE4: AmountE4
  public var due: DateOnly
  public var paidE4: AmountE4?
  /// What the tax office charged less what was worked out.
  public var fnsGapE4: AmountE4?
  public var state: State

  public init(
    month: MonthKey, incomeRub: AmountE4 = .zero, returnsRub: AmountE4 = .zero,
    baseRub: AmountE4 = .zero, taxBeforeDeductionE4: AmountE4 = .zero,
    deductionUsedE4: AmountE4 = .zero, taxE4: AmountE4 = .zero, carriedInE4: AmountE4 = .zero,
    toPayE4: AmountE4 = .zero, due: DateOnly, paidE4: AmountE4? = nil,
    fnsGapE4: AmountE4? = nil, state: State = .accruing
  ) {
    self.month = month
    self.incomeRub = incomeRub
    self.returnsRub = returnsRub
    self.baseRub = baseRub
    self.taxBeforeDeductionE4 = taxBeforeDeductionE4
    self.deductionUsedE4 = deductionUsedE4
    self.taxE4 = taxE4
    self.carriedInE4 = carriedInE4
    self.toPayE4 = toPayE4
    self.due = due
    self.paidE4 = paidE4
    self.fnsGapE4 = fnsGapE4
    self.state = state
  }
}

/// The income of a year against the limit of self-employment.
public struct NPDYear: Hashable, Sendable {
  public var year: Int
  public var incomeRub: AmountE4
  public var limitRub: AmountE4
  public var leftRub: AmountE4
  /// The income over the limit, in basis points.
  public var shareBp: Int
  public var exceeded: Bool

  public init(
    year: Int, incomeRub: AmountE4 = .zero, limitRub: AmountE4 = NPDReference.law.yearLimitE4,
    leftRub: AmountE4 = NPDReference.law.yearLimitE4, shareBp: Int = 0, exceeded: Bool = false
  ) {
    self.year = year
    self.incomeRub = incomeRub
    self.limitRub = limitRub
    self.leftRub = leftRub
    self.shareBp = shareBp
    self.exceeded = exceeded
  }
}

/// The tax of one quarter at a rate other than the tax on professional income (УСН and the
/// like): the income of its three months at those rates, the tax on it, due on the 28th of the
/// month after the quarter.
public struct TaxQuarter: Hashable, Sendable {
  public enum State: String, Hashable, Sendable {
    /// The quarter is under way.
    case accruing
    /// The quarter is over and its tax is not due yet.
    case due
    case paid
    case overdue
  }

  public var year: Int
  /// 1…4.
  public var quarter: Int
  /// The income at the other rates, after returns, in rubles.
  public var baseRub: AmountE4
  public var toPayE4: AmountE4
  public var due: DateOnly
  public var paidE4: AmountE4?
  /// What the tax office charged less what was worked out.
  public var fnsGapE4: AmountE4?
  public var state: State

  public init(
    year: Int, quarter: Int, baseRub: AmountE4 = .zero, toPayE4: AmountE4 = .zero,
    due: DateOnly? = nil, paidE4: AmountE4? = nil, fnsGapE4: AmountE4? = nil,
    state: State = .accruing
  ) {
    self.year = year
    self.quarter = quarter
    self.baseRub = baseRub
    self.toPayE4 = toPayE4
    self.due = due ?? NPDTax.dueDay(ofQuarter: quarter, year: year)
    self.paidE4 = paidE4
    self.fnsGapE4 = fnsGapE4
    self.state = state
  }

  /// The quarter `month` is in.
  public init(of month: MonthKey) {
    self.init(year: month.year, quarter: (month.month - 1) / 3 + 1)
  }

  public var firstMonth: MonthKey { MonthKey(year: year, month: quarter * 3 - 2) }
  public var lastMonth: MonthKey { MonthKey(year: year, month: quarter * 3) }

  public func contains(_ month: MonthKey) -> Bool {
    month.year == year && (month.month - 1) / 3 + 1 == quarter
  }

  /// `tax:<YYYY>-Q<n>` — the payment of this quarter.
  public var paymentKey: String { NPDTax.paymentKey(year: year, quarter: quarter) }
}

/// Self-employment as it stands: the tax of every month, the deduction left, what is accrued
/// and unpaid, the year against its limit.
public struct NPDState: Hashable, Sendable {
  public var months: [NPDMonth]
  public var deductionLeftE4: AmountE4?
  /// The tax of every unpaid month and quarter, the current ones included, through today.
  public var accruedUnpaidE4: AmountE4
  public var year: NPDYear
  public var nextDue: NPDMonth?
  /// The tax at the other rates, quarter by quarter.
  public var quarters: [TaxQuarter]

  public init(
    months: [NPDMonth] = [], deductionLeftE4: AmountE4? = nil,
    accruedUnpaidE4: AmountE4 = .zero, year: NPDYear, nextDue: NPDMonth? = nil,
    quarters: [TaxQuarter] = []
  ) {
    self.months = months
    self.deductionLeftE4 = deductionLeftE4
    self.accruedUnpaidE4 = accruedUnpaidE4
    self.year = year
    self.nextDue = nextDue
    self.quarters = quarters
  }

  /// Nothing earned, nothing owed, in the year of `today`.
  public static func empty(today: DateOnly) -> NPDState {
    NPDState(year: NPDYear(year: today.year))
  }
}

/// The tax on professional income (НПД) and any other tax a category of income owes.
///
/// * The income of a month is every income part in a category with a tax
///   (`CategoryTree.tax(of:)`: its own, else its parent's), in rubles at the rate of the Bank of
///   Russia on the day of the operation — as the tax office counts it, not at the rubles the
///   operation was written at; without a rate of the day, at those rubles. The month is the
///   month of the day.
/// * A return to a client after the month of the income is an expense in the category of
///   returns (`SelfEmploymentSettings.returnCategoryId`, or under it): it takes its rubles off
///   the income of the month it is made in — first off the income from individuals, then off
///   the others, the lowest rate first —, never below zero; what is left of it goes on to the
///   next month. A return in the same month is an edit of the income itself.
/// * The tax of a month is Σ income × rate less the deduction, rounded to the kopeck once. The
///   deduction cuts the rate of the tax on professional income from individuals by
///   `individualsCut` points and from organisations by `organizationsCut`, while some of it is
///   left: what is left is what the owner said on `deductionLeftOn`, less what the income after
///   that day used. Until the owner says, no deduction is counted.
/// * A tax on professional income below `minimumTaxE4` is not due: once its month is over it
///   goes on to the next month. A tax at another rate has neither the deduction nor this rule.
/// * The tax on professional income of a month is due on `dueDay` of the next month (`NPDMonth`).
///   A tax at another rate — УСН and the like — is paid by the quarter: the income of its three
///   months at those rates, rounded to the kopeck once, due on the 28th of the month after it
///   (`TaxQuarter`).
/// * An expense with the key `npd:<YYYY-MM>` pays that month, one with `tax:<YYYY>-Q<n>` that
///   quarter, whatever it comes to; another expense in the category of the tax
///   (`taxCategoryId`, or under it) pays the earliest month or quarter over and unpaid before
///   its own month, by due day. What the tax office charged differently is `fnsGapE4`; the later
///   ones do not move.
/// * Off — `enabled` false — nothing is counted.
public enum NPDTax {
  /// One rate of one month: the rubles of income it taxes.
  private struct Bucket: Hashable {
    var rate: Decimal
    var npd: Bool
    /// The income was made after the day the owner said how much deduction is left.
    var deductible: Bool
  }

  private struct MonthIncome {
    var income = Decimal(0)
    var returns = Decimal(0)
    var buckets: [Bucket: Decimal] = [:]
  }

  public static func state(
    ledger: Ledger, tree: CategoryTree, settings: SelfEmploymentSettings, dayRates: DayRates,
    today: DateOnly
  ) -> NPDState {
    guard settings.enabled else { return .empty(today: today) }
    let reference = settings.reference
    var months: [MonthKey: MonthIncome] = [:]
    var payments: [(day: DateOnly, key: MonthKey?, quarter: TaxQuarter?, rub: AmountE4)] = []
    var paymentIndex: [UUID: Int] = [:]

    for row in ledger.rows {
      switch row.kind {
      case .income:
        guard let tax = tree.tax(of: row.categoryId) else { continue }
        let rub = rubles(row, dayRates: dayRates)
        let bucket = Bucket(
          rate: tax.rate, npd: tax.npd,
          deductible: tax.npd && isDeductible(row.day, settings: settings))
        months[row.day.monthKey, default: MonthIncome()].income += rub
        months[row.day.monthKey, default: MonthIncome()].buckets[bucket, default: 0] += rub
      case .expense:
        if let returns = settings.returnCategoryId, isUnder(row.categoryId, returns, tree: tree) {
          months[row.day.monthKey, default: MonthIncome()].returns += rubles(
            row, dayRates: dayRates)
          continue
        }
        let externalId = ledger.entry(row.transactionId)?.transaction.externalId
        let key = paidMonth(externalId)
        let quarterKey = paidQuarter(externalId)
        let inCategory =
          settings.taxCategoryId.map { isUnder(row.categoryId, $0, tree: tree) } ?? false
        guard key != nil || quarterKey != nil || inCategory else { continue }
        if let index = paymentIndex[row.transactionId] {
          payments[index].rub += row.amountRubE4
        } else {
          paymentIndex[row.transactionId] = payments.count
          payments.append((row.day, key, quarterKey, row.amountRubE4))
        }
      case .refund, .reimbursement:
        continue
      }
    }

    guard let first = months.keys.min() else { return .empty(today: today) }
    let current = today.monthKey
    let last = max(current, months.keys.max() ?? current)
    var deductionLeft = settings.deductionLeftE4?.decimal
    var carriedReturns = Decimal(0)
    var carriedTax = AmountE4.zero
    var result: [NPDMonth] = []
    var yearIncome = Decimal(0)
    // The tax at the other rates, quarter by quarter, before the one rounding.
    var quarterTax: [TaxQuarter: (base: Decimal, tax: Decimal)] = [:]

    for month in MonthKey.range(first, through: last) where month <= current {
      var income = months[month] ?? MonthIncome()
      // Returns: off the income from individuals first, then the others, the lowest rate first.
      var toTake = income.returns + carriedReturns
      let order = income.buckets.keys.sorted { left, right in
        let leftFirst = left.npd && left.rate == reference.individualsRate
        let rightFirst = right.npd && right.rate == reference.individualsRate
        if leftFirst != rightFirst { return leftFirst }
        if left.rate != right.rate { return left.rate < right.rate }
        return left.deductible && !right.deductible
      }
      for bucket in order where toTake > 0 {
        let base = income.buckets[bucket] ?? 0
        let taken = min(base, toTake)
        income.buckets[bucket] = base - taken
        toTake -= taken
      }
      carriedReturns = toTake

      var npdBefore = Decimal(0)
      var otherBefore = Decimal(0)
      var otherBase = Decimal(0)
      var npdEarned = false
      var wanted = Decimal(0)
      var base = Decimal(0)
      for (bucket, amount) in income.buckets {
        base += amount
        let tax = amount * bucket.rate / 100
        if bucket.npd {
          npdBefore += tax
          npdEarned = true
          if bucket.deductible { wanted += amount * cut(of: bucket.rate, reference) / 100 }
          if month.year == today.year { yearIncome += amount }
        } else {
          otherBefore += tax
          otherBase += amount
        }
      }
      if income.buckets.keys.contains(where: { !$0.npd }) {
        let quarter = TaxQuarter(of: month)
        let sum = quarterTax[quarter] ?? (0, 0)
        quarterTax[quarter] = (sum.base + otherBase, sum.tax + otherBefore)
      }
      var used = Decimal(0)
      if let left = deductionLeft, wanted > 0 {
        used = min(wanted, max(0, left))
        deductionLeft = left - used
      }
      let npdTax = InterestMath.cents(max(0, npdBefore - used))
      let taxBefore = InterestMath.cents(npdBefore)
      let usedE4 = InterestMath.cents(used)
      let carriedIn = carriedTax
      let due = dueDay(of: month, reference)
      var state: NPDMonth.State
      var toPay: AmountE4
      if month == current {
        state = .accruing
        toPay = npdTax + carriedIn
        carriedTax = .zero
      } else if (npdTax + carriedIn).raw > 0 && npdTax + carriedIn < reference.minimumTaxE4 {
        state = .carried
        carriedTax = npdTax + carriedIn
        toPay = .zero
      } else {
        carriedTax = .zero
        toPay = npdTax + carriedIn
        state = today > due ? .overdue : .due
      }
      // A month of income at the other rates alone is a month of the quarter, not of this tax.
      let hasAnything =
        npdEarned || !income.returns.isZero || !carriedIn.isZero || !toPay.isZero
        || (month == current && months[month] != nil)
      guard hasAnything else { continue }
      result.append(
        NPDMonth(
          month: month, incomeRub: decimalAmount(income.income),
          returnsRub: decimalAmount(income.returns), baseRub: decimalAmount(base),
          taxBeforeDeductionE4: taxBefore, deductionUsedE4: usedE4, taxE4: npdTax,
          carriedInE4: carriedIn, toPayE4: toPay, due: due, state: state))
    }

    var quarters: [TaxQuarter] = quarterTax.keys.sorted { left, right in
      (left.year, left.quarter) < (right.year, right.quarter)
    }.map { key in
      let sum = quarterTax[key] ?? (0, 0)
      var quarter = key
      quarter.baseRub = decimalAmount(sum.base)
      quarter.toPayE4 = InterestMath.cents(sum.tax)
      quarter.state =
        quarter.contains(current) ? .accruing : today > quarter.due ? .overdue : .due
      return quarter
    }

    // The payments, oldest first: a key pays its month or quarter, the rest the earliest month
    // or quarter over and unpaid before their own month, by due day.
    for payment in payments.sorted(by: { $0.day < $1.day }) {
      if let key = payment.quarter {
        guard
          let index = quarters.firstIndex(where: {
            $0.year == key.year && $0.quarter == key.quarter
          })
        else { continue }
        pay(&quarters[index], payment.rub)
        continue
      }
      if let key = payment.key {
        guard let index = result.firstIndex(where: { $0.month == key }) else { continue }
        pay(&result[index], payment.rub)
        continue
      }
      let paymentMonth = payment.day.monthKey
      let month = result.firstIndex { month in
        month.paidE4 == nil && month.month < paymentMonth && !month.toPayE4.isZero
      }
      let quarter = quarters.firstIndex { quarter in
        quarter.paidE4 == nil && quarter.lastMonth < paymentMonth && !quarter.toPayE4.isZero
      }
      switch (month, quarter) {
      case (let month?, let quarter?):
        if quarters[quarter].due < result[month].due {
          pay(&quarters[quarter], payment.rub)
        } else {
          pay(&result[month], payment.rub)
        }
      case (let month?, nil): pay(&result[month], payment.rub)
      case (nil, let quarter?): pay(&quarters[quarter], payment.rub)
      case (nil, nil): continue
      }
    }

    var accrued = AmountE4.zero
    for month in result {
      switch month.state {
      case .accruing, .due, .overdue: accrued += month.toPayE4
      case .carried, .paid: break
      }
    }
    for quarter in quarters where quarter.state != .paid {
      accrued += quarter.toPayE4
    }
    let yearIncomeE4 = decimalAmount(yearIncome)
    let limit = reference.yearLimitE4
    let year = NPDYear(
      year: today.year, incomeRub: yearIncomeE4, limitRub: limit,
      leftRub: max(.zero, limit - yearIncomeE4),
      shareBp: limit.raw > 0
        ? Int(truncatingIfNeeded: yearIncomeE4.raw * 10_000 / limit.raw) : 0,
      exceeded: yearIncomeE4 > limit)
    return NPDState(
      months: result,
      deductionLeftE4: deductionLeft.map { InterestMath.cents(max(0, $0)) },
      accruedUnpaidE4: accrued, year: year,
      nextDue: result.first { ($0.state == .due || $0.state == .overdue) && $0.toPayE4.raw > 0 },
      quarters: quarters)
  }

  private static func pay(_ month: inout NPDMonth, _ rub: AmountE4) {
    let paid = (month.paidE4 ?? .zero) + rub
    month.paidE4 = paid
    month.state = .paid
    let gap = paid - month.toPayE4
    month.fnsGapE4 = gap.isZero ? nil : gap
  }

  private static func pay(_ quarter: inout TaxQuarter, _ rub: AmountE4) {
    let paid = (quarter.paidE4 ?? .zero) + rub
    quarter.paidE4 = paid
    quarter.state = .paid
    let gap = paid - quarter.toPayE4
    quarter.fnsGapE4 = gap.isZero ? nil : gap
  }

  /// The tax of one income, in rubles, and the rate it is taxed at — less the cut of the
  /// deduction while `deductionLeft` covers it; `nil` when self-employment is off or no part
  /// of the income is in a category with a tax. A foreign income counts at the rate of the Bank
  /// of Russia of the day it was written at (`rateDate`), else at its own rubles.
  public static func tax(
    of entry: TransactionEntry, tree: CategoryTree, settings: SelfEmploymentSettings,
    dayRates: DayRates, deductionLeft: AmountE4?
  ) -> (taxE4: AmountE4, rate: Decimal)? {
    guard settings.enabled, entry.transaction.kind == .income, !entry.transaction.isDeleted
    else { return nil }
    let reference = settings.reference
    var total = Decimal(0)
    var wanted = Decimal(0)
    var rate: Decimal?
    var cutOfRate = Decimal(0)
    for part in entry.parts {
      guard let tax = tree.tax(of: part.categoryId) else { continue }
      let rub = partRubles(part, of: entry.transaction, dayRates: dayRates)
      total += rub * tax.rate / 100
      if rate == nil {
        rate = tax.rate
        cutOfRate = tax.npd ? cut(of: tax.rate, reference) : 0
      }
      if tax.npd { wanted += rub * cut(of: tax.rate, reference) / 100 }
    }
    guard let rate else { return nil }
    var used = Decimal(0)
    if let left = deductionLeft, left.raw > 0, wanted > 0 { used = min(wanted, left.decimal) }
    let shown = used == wanted && wanted > 0 ? rate - cutOfRate : rate
    return (InterestMath.cents(max(0, total - used)), shown)
  }

  /// `npd:<YYYY-MM>` — the payment of the tax of a month.
  public static func paymentKey(month: MonthKey) -> String {
    "npd:\(month.iso)"
  }

  /// The month a payment key names; `nil` for anything else.
  public static func paidMonth(_ externalId: String?) -> MonthKey? {
    guard let externalId, externalId.hasPrefix("npd:") else { return nil }
    let text = String(externalId.dropFirst(4))
    let parts = text.split(separator: "-")
    guard parts.count == 2, parts[0].count == 4, parts[1].count == 2 else { return nil }
    return MonthKey(iso: text)
  }

  /// `tax:<YYYY>-Q<n>` — the payment of the tax at the other rates of a quarter.
  public static func paymentKey(year: Int, quarter: Int) -> String {
    "tax:\(String(format: "%04d", year))-Q\(quarter)"
  }

  /// The quarter a payment key names; `nil` for anything else.
  public static func paidQuarter(_ externalId: String?) -> TaxQuarter? {
    guard let externalId, externalId.hasPrefix("tax:") else { return nil }
    let parts = externalId.dropFirst(4).split(separator: "-")
    guard parts.count == 2, parts[0].count == 4, let year = Int(parts[0]),
      parts[1].count == 2, parts[1].first == "Q", let quarter = Int(parts[1].dropFirst()),
      (1...4).contains(quarter)
    else { return nil }
    return TaxQuarter(year: year, quarter: quarter)
  }

  /// The day the tax of the other rates of a quarter is due: the 28th of the month after it.
  public static func dueDay(ofQuarter quarter: Int, year: Int) -> DateOnly {
    let next = MonthKey(year: year, month: quarter * 3).next
    return DateOnly(year: next.year, month: next.month, day: quarterDueDay)
  }

  /// The day of the month after a quarter its tax at the other rates is due on.
  public static let quarterDueDay = 28

  /// The day the tax of `month` is due: `dueDay` of the next month, clipped to its length.
  public static func dueDay(of month: MonthKey, _ reference: NPDReference) -> DateOnly {
    let next = month.next
    return DateOnly(
      year: next.year, month: next.month, day: min(max(1, reference.dueDay), next.dayCount))
  }

  // MARK: - Pieces

  /// The points the deduction takes off a rate of the tax on professional income.
  static func cut(of rate: Decimal, _ reference: NPDReference) -> Decimal {
    if rate == reference.individualsRate { return reference.individualsCut }
    if rate == reference.organizationsRate { return reference.organizationsCut }
    return 0
  }

  private static func isDeductible(_ day: DateOnly, settings: SelfEmploymentSettings) -> Bool {
    guard settings.deductionLeftE4 != nil else { return false }
    guard let since = settings.deductionLeftOn else { return true }
    return day > since
  }

  private static func isUnder(_ categoryId: UUID?, _ root: UUID, tree: CategoryTree) -> Bool {
    var current = tree.category(categoryId)
    var seen: Set<UUID> = []
    while let category = current, seen.insert(category.id).inserted {
      if category.id == root { return true }
      current = tree.parent(of: category.id)
    }
    return false
  }

  /// A row in rubles at the rate of the Bank of Russia of its day; without one, its own rubles.
  private static func rubles(_ row: LedgerRow, dayRates: DayRates) -> Decimal {
    guard row.currency != .rub else { return row.amountE4.decimal }
    guard let rate = dayRates.perUnit(row.currency, on: row.day), rate > 0 else {
      return row.amountRubE4.decimal
    }
    return row.amountE4.decimal * rate
  }

  private static func partRubles(
    _ part: TransactionPart, of transaction: Transaction, dayRates: DayRates
  ) -> Decimal {
    guard transaction.currency != .rub else { return part.amountE4.decimal }
    if let day = transaction.rateDate,
      let rate = dayRates.perUnit(transaction.currency, on: day), rate > 0
    {
      return part.amountE4.decimal * rate
    }
    return part.amountRubE4.decimal
  }

  private static func decimalAmount(_ value: Decimal) -> AmountE4 {
    (try? AmountE4(decimal: value)) ?? .zero
  }
}
