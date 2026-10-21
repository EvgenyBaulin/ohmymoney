import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// The debt load of the Advice section («нагрузка — платежи / доход»): what the monthly
/// payments of my debts take out of a month's income.
public struct DebtLoad: Hashable, Sendable {
  public enum Status: Hashable, Sendable {
    case ready
    /// No figure: the key says why, the app says it in words.
    case notEnoughData(reasonKey: String)
  }

  /// Where the income the load is measured against came from.
  public enum IncomeSource: Hashable, Sendable {
    /// The caller's estimate for the month.
    case given
    /// `IncomeEstimate` from the history: the median of the last complete months.
    case history
    case none
  }

  /// Neither an estimate nor a complete month of history to take the median of.
  public static let noIncomeKey = "debts.load.noIncome"

  /// Σ monthly payments of the open debts I owe, in rubles.
  public var monthlyPaymentsRub: AmountE4
  public var incomeRub: AmountE4?
  public var incomeSource: IncomeSource
  /// Payments ÷ income in basis points (10 000 = 100 %), rounded half away from zero.
  public var loadBp: Int?
  /// Open debts I owe in a currency without a known rate: left out, never guessed.
  public var withoutRate: [UUID]
  /// Open debts I owe with no monthly payment set: they add nothing to the load.
  public var withoutPayment: [UUID]
  public var status: Status

  public init(
    monthlyPaymentsRub: AmountE4, incomeRub: AmountE4?, incomeSource: IncomeSource,
    loadBp: Int?, withoutRate: [UUID], withoutPayment: [UUID], status: Status
  ) {
    self.monthlyPaymentsRub = monthlyPaymentsRub
    self.incomeRub = incomeRub
    self.incomeSource = incomeSource
    self.loadBp = loadBp
    self.withoutRate = withoutRate
    self.withoutPayment = withoutPayment
    self.status = status
  }

  /// The load for the month of `today`.
  ///
  /// Payments are the monthly payments of every open debt I owe — a payment on something
  /// bought in instalments is not spending, but it takes money out of the month all the
  /// same. A payment in another currency is converted at the last rate the caller knows
  /// (`rubPerUnit`); without one the debt is listed, not guessed.
  ///
  /// The income is the caller's estimate for the month (`income`, normally
  /// `IncomeEstimate.month`). Without one it is the same estimate from the history alone —
  /// the median of the last complete months, at most three, or what came this month when
  /// that is more — so the load and «can save» never divide by two different incomes. A
  /// month with only what came so far is no estimate: a half-month's income would inflate
  /// the load. No positive income — no load, «not enough data».
  ///
  /// A debt whose dues have sums of their own — a grace period, a main payment worked out over
  /// months — weighs what its next unpaid due asks for (`dues`, the states of the debts'
  /// dues); without its state, its monthly payment.
  public static func load(
    debts: [Debt], ledger: Ledger, today: DateOnly, income: AmountE4?,
    rubPerUnit: [CurrencyCode: Decimal], dues: [UUID: DebtDueState] = [:]
  ) -> DebtLoad {
    let payments = monthlyPayments(of: debts, rubPerUnit: rubPerUnit, dues: dues)
    let incomeRub: AmountE4?
    let source: IncomeSource
    if let income {
      incomeRub = income
      source = .given
    } else if let estimate = historyIncome(ledger: ledger, today: today) {
      incomeRub = estimate
      source = .history
    } else {
      incomeRub = nil
      source = .none
    }
    guard let incomeRub, incomeRub.raw > 0 else {
      return DebtLoad(
        monthlyPaymentsRub: payments.total, incomeRub: incomeRub, incomeSource: source,
        loadBp: nil, withoutRate: payments.withoutRate, withoutPayment: payments.withoutPayment,
        status: .notEnoughData(reasonKey: noIncomeKey))
    }
    let exact = payments.total.decimal * 10_000 / incomeRub.decimal
    let bp = (try? DecimalMath.int64(rounding: exact)).map { Int(clamping: $0) } ?? Int.max
    return DebtLoad(
      monthlyPaymentsRub: payments.total, incomeRub: incomeRub, incomeSource: source,
      loadBp: bp, withoutRate: payments.withoutRate, withoutPayment: payments.withoutPayment,
      status: .ready)
  }

  /// Σ monthly payments of the open debts I owe, in rubles — the figure on top of the Debts
  /// section too — with the debts it could not convert and the ones without a payment. A debt
  /// whose dues have sums of their own counts its next unpaid due (`payment(of:dues:)`).
  static func monthlyPayments(
    of debts: [Debt], rubPerUnit: [CurrencyCode: Decimal], dues: [UUID: DebtDueState] = [:]
  ) -> (total: AmountE4, withoutRate: [UUID], withoutPayment: [UUID]) {
    var total = AmountE4.zero
    var withoutRate: [UUID] = []
    var withoutPayment: [UUID] = []
    for debt in debts where !debt.closed && debt.direction == .iOwe {
      guard let payment = payment(of: debt, dues: dues[debt.id]), !payment.isZero else {
        withoutPayment.append(debt.id)
        continue
      }
      guard let rubles = DebtRubles.convert(payment, from: debt.currency, rubPerUnit: rubPerUnit)
      else {
        withoutRate.append(debt.id)
        continue
      }
      total += rubles
    }
    return (total, DebtRubles.sorted(withoutRate), DebtRubles.sorted(withoutPayment))
  }

  /// What a month of `debt` takes: the monthly payment — or, for a debt whose dues have sums of
  /// their own (a grace period, a main payment over `repayMonths`), what its next unpaid due asks
  /// for, as `dues` know it; the monthly payment when they know none.
  public static func payment(of debt: Debt, dues: DebtDueState?) -> AmountE4? {
    guard
      debt.grace != nil || debt.repayMonths != nil || debt.steps != nil
        || debt.isInstalmentPlan, let dues,
      let index = dues.firstUnpaidIndex
    else { return debt.monthlyPaymentE4 }
    let amount = dues.amount(ofDue: index)
    return amount.raw > 0 ? amount : debt.monthlyPaymentE4
  }

  /// The income estimate of the month from the history alone, without expectations; `nil`
  /// before the first complete month.
  static func historyIncome(ledger: Ledger, today: DateOnly) -> AmountE4? {
    let estimate = IncomeEstimate.month(ledger: ledger, statuses: [], today: today)
    guard estimate.source == .median else { return nil }
    return estimate.value
  }
}

/// Rubles for the Debts section: a foreign amount at the last rate the caller knows, or
/// nothing — never a guess.
enum DebtRubles {
  /// `nil` without a rate, and for rubles that do not fit into stored units: the debt is then
  /// left out of the totals like one without a rate, rather than counted at the largest figure
  /// that fits — which nobody owes, and which the next balance added to it would overflow.
  static func convert(
    _ amount: AmountE4, from currency: CurrencyCode, rubPerUnit: [CurrencyCode: Decimal]
  ) -> AmountE4? {
    // Nothing is worth nothing in any currency: a settled foreign debt needs no rate.
    if currency == .rub || amount.isZero { return amount }
    guard let rate = rubPerUnit[currency] else { return nil }
    return try? AmountE4(decimal: amount.decimal * rate)
  }

  /// A sum of rubles worked out in `Decimal`, rounded once to stored units; values beyond any
  /// real money clamp instead of trapping.
  static func round(_ value: Decimal) -> AmountE4 {
    (try? AmountE4(decimal: value)) ?? (value < 0 ? AmountE4(raw: .min) : AmountE4(raw: .max))
  }

  /// Ids in a stable order, so a list never depends on hashing.
  static func sorted(_ ids: some Sequence<UUID>) -> [UUID] {
    ids.sorted { $0.uuidString < $1.uuidString }
  }
}

/// The debt load of one month, for its history.
public struct DebtLoadMonth: Hashable, Sendable {
  public var month: MonthKey
  public var load: DebtLoad

  public init(month: MonthKey, load: DebtLoad) {
    self.month = month
    self.load = load
  }
}

extension DebtLoad {
  /// «ЦБ считает высокой от 50 %».
  public static let highBp = 5_000
  /// «…очень высокой от 80 %».
  public static let veryHighBp = 8_000

  /// The share of the debt on credit cards a month of the load counts: 5 %.
  public static let creditCardShare = Decimal(5) / 100

  /// The load of `month`: what the schedules of every open debt I owe ask for in the month — the
  /// sums of all its dues that fall in it, paid or not; dues every few days count each — plus 5 %
  /// of the debt on credit cards (`creditDebtRub`, in rubles), over the median income of
  /// «Заработок» of the six full months before it (`earningsMedianRub`). A debt in a currency
  /// without a rate is listed and left out, one without dues adds nothing. No earnings — no
  /// figure, «not enough data».
  public static func month(
    _ month: MonthKey, debts: [Debt], states: [UUID: DebtDueState], creditDebtRub: AmountE4,
    earningsMedianRub: AmountE4?, rubPerUnit: [CurrencyCode: Decimal]
  ) -> DebtLoad {
    var total = Decimal(0)
    var withoutRate: [UUID] = []
    var withoutPayment: [UUID] = []
    for debt in debts where !debt.closed && !debt.isDeleted && debt.direction == .iOwe {
      guard let state = states[debt.id]?.knowing(debt), state.owes, state.firstDue != nil,
        !state.instalments.isEmpty
      else {
        withoutPayment.append(debt.id)
        continue
      }
      var dues = AmountE4.zero
      if var index = state.firstIndex(onOrAfter: month.firstDay) {
        while index < 1_200, state.due(index) <= month.lastDay {
          dues += state.amount(ofDue: index)
          index += 1
        }
      }
      guard !dues.isZero else { continue }
      guard let rubles = DebtRubles.convert(dues, from: debt.currency, rubPerUnit: rubPerUnit)
      else {
        withoutRate.append(debt.id)
        continue
      }
      total += rubles.decimal
    }
    total += creditDebtRub.magnitude.decimal * creditCardShare
    let payments = DebtRubles.round(total)
    return figure(
      payments: payments, income: earningsMedianRub, withoutRate: withoutRate,
      withoutPayment: withoutPayment)
  }

  /// The load of payments over an income: basis points, rounded half away from zero; no income
  /// above zero — none.
  static func figure(
    payments: AmountE4, income: AmountE4?, withoutRate: [UUID], withoutPayment: [UUID]
  ) -> DebtLoad {
    guard let income, income.raw > 0 else {
      return DebtLoad(
        monthlyPaymentsRub: payments, incomeRub: income, incomeSource: .none, loadBp: nil,
        withoutRate: DebtRubles.sorted(withoutRate),
        withoutPayment: DebtRubles.sorted(withoutPayment),
        status: .notEnoughData(reasonKey: noIncomeKey))
    }
    let exact = payments.decimal * 10_000 / income.decimal
    let bp = (try? DecimalMath.int64(rounding: exact)).map { Int(clamping: $0) } ?? Int.max
    return DebtLoad(
      monthlyPaymentsRub: payments, incomeRub: income, incomeSource: .given, loadBp: bp,
      withoutRate: DebtRubles.sorted(withoutRate),
      withoutPayment: DebtRubles.sorted(withoutPayment),
      status: .ready)
  }

  /// The load of each of the last `months` months, the current one last. A month before the
  /// current one counts what was paid in it — the payment lines of the journals of the debts I
  /// owe, dated in it —; the current month counts what the schedules ask (`month(_:…)`). Each
  /// adds 5 % of the debt on credit cards at the end of the month (today for the current one):
  /// the accounts with credit terms in the minus, and the debts kept as a credit card. The income
  /// is the median of «Заработок» (`Allocation.isEarnings`) over the six full months before the
  /// month, of those the ledger has; none — «not enough data».
  public static func history(
    months: Int = 12, ledger: Ledger, debts: [Debt], journal: [DebtEntry],
    accounts: AccountBalances, tree: CategoryTree, allocation: AllocationSettings,
    rubPerUnit: [CurrencyCode: Decimal], today: DateOnly
  ) -> [DebtLoadMonth] {
    history(
      months: months, ledger: ledger, debts: debts, journal: journal, accounts: accounts,
      rubPerUnit: rubPerUnit, today: today,
      earnings: { categoryId in
        Allocation.isEarnings(categoryId: categoryId, tree: tree, settings: allocation)
      })
  }

  /// `history` with the rule of what is earnings given.
  static func history(
    months: Int, ledger: Ledger, debts: [Debt], journal: [DebtEntry], accounts: AccountBalances,
    rubPerUnit: [CurrencyCode: Decimal], today: DateOnly, earnings: (UUID?) -> Bool
  ) -> [DebtLoadMonth] {
    guard months >= 1 else { return [] }
    let calendar = ledger.calendar
    let current = today.monthKey
    let owing = debts.filter { !$0.isDeleted && $0.direction == .iOwe }
    let owingIds = Set(owing.map(\.id))
    let byId = Dictionary(owing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let firstMonth = ledger.rows.first?.month

    // Earnings by the month they are for.
    var earned: [MonthKey: Decimal] = [:]
    for row in ledger.rows where row.kind == .income && earnings(row.categoryId) {
      earned[row.month, default: 0] += row.amountRubE4.decimal
    }
    func median(before month: MonthKey) -> AmountE4? {
      let window = (1...6).map { month.adding(months: -$0) }.filter { candidate in
        guard let firstMonth else { return false }
        return candidate >= firstMonth
      }
      let values = window.map { earned[$0] ?? 0 }.sorted()
      guard !values.isEmpty, values.contains(where: { $0 > 0 }) else { return nil }
      let middle = values.count / 2
      let value = values.count % 2 == 1 ? values[middle] : (values[middle - 1] + values[middle]) / 2
      return DebtRubles.round(value)
    }
    func dayOf(_ line: DebtEntry) -> DateOnly? {
      line.date ?? line.occurredAt.map(calendar.day(of:))
    }
    let cardAccounts = ledger.dataset.paymentMethods.filter { $0.credit != nil }
    let cardDebts = owing.filter { $0.type == .creditCard }
    func creditDebt(at day: DateOnly) -> AmountE4 {
      var total = Decimal(0)
      let end = calendar.endOfDay(day)
      for account in cardAccounts {
        let key = BalanceKey(accountId: account.id, currency: account.mainCurrency)
        guard let balance = accounts.balance(key, at: end), balance.isNegative,
          let rubles = DebtRubles.convert(
            balance.magnitude, from: account.mainCurrency, rubPerUnit: rubPerUnit)
        else { continue }
        total += rubles.decimal
      }
      for debt in cardDebts {
        let left = DebtRules.balance(
          entries: journal.filter { line in
            line.debtId == debt.id && (dayOf(line).map { $0 <= day } ?? true)
          })
        guard left.raw > 0,
          let rubles = DebtRubles.convert(left, from: debt.currency, rubPerUnit: rubPerUnit)
        else { continue }
        total += rubles.decimal
      }
      return DebtRubles.round(total)
    }

    var result: [DebtLoadMonth] = []
    for offset in stride(from: months - 1, through: 0, by: -1) {
      let month = current.adding(months: -offset)
      let income = median(before: month)
      if month == current {
        let states = DebtDues.states(
          debts: owing, ledger: ledger, journal: journal, today: today)
        result.append(
          DebtLoadMonth(
            month: month,
            load: self.month(
              month, debts: owing, states: states, creditDebtRub: creditDebt(at: today),
              earningsMedianRub: income, rubPerUnit: rubPerUnit)))
        continue
      }
      var paid = Decimal(0)
      var withoutRate: Set<UUID> = []
      for line in journal
      where owingIds.contains(line.debtId) && line.kind == .payment && line.amountE4.isNegative {
        guard let day = dayOf(line), day.monthKey == month, let debt = byId[line.debtId] else {
          continue
        }
        guard
          let rubles = DebtRubles.convert(
            line.amountE4.magnitude, from: debt.currency, rubPerUnit: rubPerUnit)
        else {
          withoutRate.insert(debt.id)
          continue
        }
        paid += rubles.decimal
      }
      paid += creditDebt(at: month.lastDay).decimal * creditCardShare
      result.append(
        DebtLoadMonth(
          month: month,
          load: figure(
            payments: DebtRubles.round(paid), income: income, withoutRate: Array(withoutRate),
            withoutPayment: [])))
    }
    return result
  }
}
