import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// The order the debts are paid off in: the highest rate first, or the smallest balance first.
public enum LadderMethod: String, Hashable, Sendable, CaseIterable {
  case avalanche
  case snowball
}

/// A debt on the ladder: a debt I owe, or a credit card in debt.
public struct LadderDebt: Hashable, Sendable, Identifiable {
  public enum Source: Hashable, Sendable {
    case debt(UUID)
    case creditCard(UUID)
  }

  public var id: UUID
  public var source: Source
  public var name: String
  public var balanceRub: AmountE4
  public var ratePercent: Decimal
  public var minimumRub: AmountE4

  public init(
    id: UUID, source: Source, name: String, balanceRub: AmountE4, ratePercent: Decimal,
    minimumRub: AmountE4
  ) {
    self.id = id
    self.source = source
    self.name = name
    self.balanceRub = balanceRub
    self.ratePercent = ratePercent
    self.minimumRub = minimumRub
  }
}

/// One month of the ladder: what was paid and what is left.
public struct LadderMonth: Hashable, Sendable {
  public var month: MonthKey
  public var paidRub: AmountE4
  public var interestRub: AmountE4
  public var balanceRub: AmountE4

  public init(month: MonthKey, paidRub: AmountE4, interestRub: AmountE4, balanceRub: AmountE4) {
    self.month = month
    self.paidRub = paidRub
    self.interestRub = interestRub
    self.balanceRub = balanceRub
  }
}

/// The ladder of one method: when the debts are paid off and what the interest comes to.
public struct LadderPlan: Hashable, Sendable {
  public var method: LadderMethod
  /// `nil`: not paid off within the horizon.
  public var months: Int?
  public var freeFrom: MonthKey?
  public var interestRub: AmountE4
  public var order: [UUID]
  public var payoff: [UUID: MonthKey]
  /// The first 24 months.
  public var firstMonths: [LadderMonth]

  public init(
    method: LadderMethod, months: Int? = nil, freeFrom: MonthKey? = nil,
    interestRub: AmountE4 = .zero, order: [UUID] = [], payoff: [UUID: MonthKey] = [:],
    firstMonths: [LadderMonth] = []
  ) {
    self.method = method
    self.months = months
    self.freeFrom = freeFrom
    self.interestRub = interestRub
    self.order = order
    self.payoff = payoff
    self.firstMonths = firstMonths
  }
}

/// Both orders side by side, and what the avalanche saves.
public struct LadderComparison: Hashable, Sendable {
  public var avalanche: LadderPlan
  public var snowball: LadderPlan
  public var interestSavedRub: AmountE4?
  public var monthsSaved: Int?

  public init(
    avalanche: LadderPlan, snowball: LadderPlan, interestSavedRub: AmountE4? = nil,
    monthsSaved: Int? = nil
  ) {
    self.avalanche = avalanche
    self.snowball = snowball
    self.interestSavedRub = interestSavedRub
    self.monthsSaved = monthsSaved
  }
}

/// The payoff ladder: every month the minimum payment of every debt, and above them the money
/// the owner can put in (`extraRub`) and the minimums of the debts already paid off — the
/// «snowball» — into the first debt of the order still open. Interest is monthly: the balance ×
/// the yearly rate ÷ 1200, to the kopeck (`DebtPayoff`'s rule). The avalanche goes by the
/// highest rate first, then the smaller balance; the snowball by the smaller balance first, then
/// the higher rate; debts at 0 % come last in both. The horizon is 600 months.
public enum DebtLadder {
  /// Months looked at, at most.
  public static let horizon = 600

  /// The debts on the ladder: every open debt I owe with something left on it that is not taken
  /// off (`Debt.inLadder`), and every credit card in debt not kept out
  /// (`DebtSettings.ladderAccountsOut`). A debt's minimum is what its next unpaid due asks for —
  /// a debt without dues pays only from the money above —; a card's is its minimum payment
  /// (`CreditStatements.minimum`), its rate the rate of purchases. Balances and minimums are in
  /// rubles at today's rate; a debt without a rate is left out.
  public static func candidates(
    debts: [Debt], states: [UUID: DebtDueState], balances: [UUID: AmountE4],
    accounts: AccountsSnapshot, settings: DebtSettings, rubPerUnit: [CurrencyCode: Decimal]
  ) -> [LadderDebt] {
    var result: [LadderDebt] = []
    for debt in debts
    where !debt.closed && !debt.isDeleted && debt.direction == .iOwe && debt.inLadder != false {
      let state = states[debt.id]?.knowing(debt)
      guard let balance = balances[debt.id] ?? state?.balanceE4, balance.raw > 0,
        let balanceRub = DebtRubles.convert(balance, from: debt.currency, rubPerUnit: rubPerUnit)
      else { continue }
      var minimum = AmountE4.zero
      if let state, let index = state.firstUnpaidIndex {
        minimum = state.amount(ofDue: index)
      }
      let minimumRub =
        DebtRubles.convert(minimum, from: debt.currency, rubPerUnit: rubPerUnit) ?? .zero
      result.append(
        LadderDebt(
          id: debt.id, source: .debt(debt.id), name: debt.name, balanceRub: balanceRub,
          ratePercent: max(debt.interestRate ?? 0, 0), minimumRub: minimumRub))
    }
    let out = Set(settings.ladderAccountsOut)
    for section in accounts.sections {
      for line in section.accounts {
        let account = line.account
        guard let terms = account.credit, !account.archived, !out.contains(account.id),
          let key = line.keys.first(where: { $0.key.currency == account.mainCurrency }),
          let balance = key.balance, balance.isNegative
        else { continue }
        let debt = balance.magnitude
        guard
          let debtRub = DebtRubles.convert(debt, from: account.mainCurrency, rubPerUnit: rubPerUnit)
        else { continue }
        let minimum = CreditStatements.minimum(debt: debt, terms: terms) ?? .zero
        result.append(
          LadderDebt(
            id: account.id, source: .creditCard(account.id), name: account.name,
            balanceRub: debtRub, ratePercent: max(terms.purchaseRate ?? 0, 0),
            minimumRub: DebtRubles.convert(
              minimum, from: account.mainCurrency, rubPerUnit: rubPerUnit) ?? .zero))
      }
    }
    return result
  }

  /// The order of `method`: avalanche by rate down, then balance up; snowball by balance up,
  /// then rate down; 0 % last in both; the name and id settle the rest.
  public static func ordered(_ debts: [LadderDebt], method: LadderMethod) -> [LadderDebt] {
    debts.sorted { left, right in
      let leftFree = left.ratePercent <= 0
      let rightFree = right.ratePercent <= 0
      if leftFree != rightFree { return rightFree }
      switch method {
      case .avalanche:
        if left.ratePercent != right.ratePercent { return left.ratePercent > right.ratePercent }
        if left.balanceRub != right.balanceRub { return left.balanceRub < right.balanceRub }
      case .snowball:
        if left.balanceRub != right.balanceRub { return left.balanceRub < right.balanceRub }
        if left.ratePercent != right.ratePercent { return left.ratePercent > right.ratePercent }
      }
      if left.name != right.name { return left.name < right.name }
      return left.id.uuidString < right.id.uuidString
    }
  }

  /// The ladder of `method` from `start`: month by month until every debt is paid off or the
  /// horizon ends (`months` and `freeFrom` then `nil`).
  public static func plan(
    _ debts: [LadderDebt], extraRub: AmountE4, method: LadderMethod, start: MonthKey
  ) -> LadderPlan {
    let order = ordered(debts, method: method)
    guard !order.isEmpty else { return LadderPlan(method: method, months: 0) }
    var balances = order.map { $0.balanceRub }
    let budget = AmountE4.sum(order.map(\.minimumRub)) + max(extraRub, .zero)
    var payoff: [UUID: MonthKey] = [:]
    var interestTotal = AmountE4.zero
    var firstMonths: [LadderMonth] = []
    var monthCount = 0
    while balances.contains(where: { $0.raw > 0 }), monthCount < horizon {
      let month = start.adding(months: monthCount)
      var interestMonth = AmountE4.zero
      // Interest of the month first, on what is owed.
      for index in balances.indices where balances[index].raw > 0 {
        let interest = DebtAmortization.monthInterest(
          of: balances[index], percent: order[index].ratePercent)
        balances[index] += interest
        interestMonth += interest
      }
      var money = budget
      // The minimums of the debts still open.
      for index in balances.indices where balances[index].raw > 0 {
        let pay = min(order[index].minimumRub, balances[index], money)
        balances[index] = balances[index] - pay
        money = money - pay
      }
      // Everything left — the money above and the minimums of the debts paid off — in order.
      for index in balances.indices where balances[index].raw > 0 && money.raw > 0 {
        let pay = min(balances[index], money)
        balances[index] = balances[index] - pay
        money = money - pay
      }
      let paid = budget - money
      for index in balances.indices
      where balances[index].raw <= 0 && payoff[order[index].id] == nil {
        payoff[order[index].id] = month
      }
      interestTotal += interestMonth
      if firstMonths.count < 24 {
        firstMonths.append(
          LadderMonth(
            month: month, paidRub: paid, interestRub: interestMonth,
            balanceRub: AmountE4.sum(balances.map { max($0, .zero) })))
      }
      monthCount += 1
      // Nothing paid while something is owed: the ladder never ends.
      if paid.isZero { break }
    }
    let done = !balances.contains(where: { $0.raw > 0 })
    return LadderPlan(
      method: method, months: done ? monthCount : nil,
      freeFrom: done ? start.adding(months: max(0, monthCount - 1)) : nil,
      interestRub: interestTotal, order: order.map(\.id), payoff: payoff,
      firstMonths: firstMonths)
  }

  /// Both orders, and what the avalanche saves over the snowball: the interest and the months,
  /// when both pay off.
  public static func compare(
    _ debts: [LadderDebt], extraRub: AmountE4, start: MonthKey
  ) -> LadderComparison {
    let avalanche = plan(debts, extraRub: extraRub, method: .avalanche, start: start)
    let snowball = plan(debts, extraRub: extraRub, method: .snowball, start: start)
    let bothDone = avalanche.months != nil && snowball.months != nil
    return LadderComparison(
      avalanche: avalanche, snowball: snowball,
      interestSavedRub: bothDone ? snowball.interestRub - avalanche.interestRub : nil,
      monthsSaved: bothDone ? (snowball.months ?? 0) - (avalanche.months ?? 0) : nil)
  }

  /// «В среднем у вас остаётся N»: the median of income less my spending over the last three
  /// full months, not below zero, down to 1,000 ₽; fewer than three months of the ledger —
  /// `nil`.
  public static func suggestedExtra(ledger: Ledger, today: DateOnly) -> AmountE4? {
    guard let first = ledger.rows.first?.month else { return nil }
    let months = (1...3).map { today.monthKey.adding(months: -$0) }
    guard months.allSatisfy({ $0 >= first }) else { return nil }
    let left = months.map { month in
      ledger.income(attributedTo: [month])
        - ledger.expenses(in: DayRange(month.firstDay, month.lastDay))
    }.sorted()
    let median = max(left[1], .zero)
    let thousand: Int64 = 1_000 * 10_000
    return AmountE4(raw: median.raw / thousand * thousand)
  }
}
