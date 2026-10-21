import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// One payout of a deposit's interest: what the period earned so far and is expected to earn,
/// the pair it goes to, and whether it came. Never an income — only what the owner records is.
public struct DepositPayout: Identifiable, Hashable, Sendable {
  public enum State: Hashable, Sendable {
    /// The period is still earning.
    case accruing
    /// The pay date came, and the few days the bank may take are not over.
    case due
    /// The income of this id brought it.
    case received(UUID)
    /// Nothing came days after the pay date: «Проценты ≈ X не пришли?».
    case missing
  }

  /// The account that earns.
  public var accountId: UUID
  /// Where the interest is paid: the account itself, or another one.
  public var target: BalanceKey
  public var periodStart: DateOnly
  public var payDate: DateOnly
  /// Earned through today, to the cent.
  public var accruedE4: AmountE4
  /// Expected on the pay date, to the cent.
  public var expectedE4: AmountE4
  /// The interest joins the balance it was earned on.
  public var capitalized: Bool
  public var state: State

  public init(
    accountId: UUID, target: BalanceKey, periodStart: DateOnly, payDate: DateOnly,
    accruedE4: AmountE4, expectedE4: AmountE4, capitalized: Bool, state: State
  ) {
    self.accountId = accountId
    self.target = target
    self.periodStart = periodStart
    self.payDate = payDate
    self.accruedE4 = accruedE4
    self.expectedE4 = expectedE4
    self.capitalized = capitalized
    self.state = state
  }

  /// An account pays once a day at most.
  public var id: String { "\(accountId.uuidString) \(payDate.iso)" }
}

/// Everything the account screen says of one account that earns interest.
public struct DepositOutlook: Hashable, Sendable {
  public var accountId: UUID
  public var terms: DepositTerms
  /// The pair that earns: the account in its main currency.
  public var key: BalanceKey
  /// The pair was counted: without a count there is no balance and no interest
  /// («Сверьте счёт — без остатка проценты не посчитать»), and `payouts` is empty.
  public var counted: Bool
  /// The account's payouts, by pay date (`DepositPayouts.build`).
  public var payouts: [DepositPayout]
  /// What is still to be paid through the day the deposit ends, to the cent («К концу срока
  /// ≈»): every payout dated after today not received yet; `nil` for a savings account.
  public var toEndE4: AmountE4?

  public init(
    accountId: UUID, terms: DepositTerms, key: BalanceKey, counted: Bool,
    payouts: [DepositPayout], toEndE4: AmountE4?
  ) {
    self.accountId = accountId
    self.terms = terms
    self.key = key
    self.counted = counted
    self.payouts = payouts
    self.toEndE4 = toEndE4
  }

  /// The payout of the period today earns in, or the one due today: the first not before
  /// today.
  public func current(today: DateOnly) -> DepositPayout? {
    payouts.first { $0.payDate >= today }
  }

  /// Payouts whose pay date passed days ago with nothing in: «Проценты ≈ X не пришли?».
  public var missing: [DepositPayout] {
    payouts.filter { $0.state == .missing }
  }
}

/// The payouts of every account that earns interest.
///
/// * A payout is expected on each pay date of the terms (`DepositSchedule`), worth the interest
///   its period earns on the balance at the end of each day (`DepositInterest`), rounded once.
/// * It is received by the earliest live income on the account it goes to — of any currency —,
///   every part of which is filed under the interest category or under one of its children,
///   dated from three days before the pay date to the day before the next one (45 days after
///   the last one), and not taken by a payout of an earlier pay date. Without an interest
///   category nothing is ever received.
/// * Not received five days after its pay date, it is missing, and the screen asks about it.
///   It never brings money: only the income the owner records is income.
/// * Interest paid onto the deposit itself joins the balance from its pay date while it is not
///   recorded, so the next periods earn on it; recorded, the income is in the balance already.
///   Interest paid to another account earns nothing more.
/// * The pair that earns is the account's main currency. It goes to the account the terms
///   name, or — archived or gone — to the main account; to the deposit itself when they name
///   none.
public enum DepositPayouts {
  /// How many days a payout may come before its pay date.
  public static let earlyDays = 3
  /// How many days after its pay date a payout not received is missing.
  public static let graceDays = 5
  /// How far back the payouts go: the pay dates after today minus this many days.
  public static let lookBackDays = 40
  /// How many days after its pay date the last payout of a deposit may still come.
  static let lastPayoutDays = 45

  /// The current period of each live account with interest and the pay dates in
  /// (today − 40 days, `through`], each matched with the income that brought it, if any; by
  /// pay date, then account.
  public static func build(
    ledger: Ledger, balances: AccountBalances, interestCategoryId: UUID?, today: DateOnly,
    through: DateOnly
  ) -> [DepositPayout] {
    outlooks(
      ledger: ledger, balances: balances, interestCategoryId: interestCategoryId, today: today,
      through: through
    )
    .flatMap(\.payouts)
    .sorted { ($0.payDate, $0.accountId.uuidString) < ($1.payDate, $1.accountId.uuidString) }
  }

  /// The outlook of one account, `nil` when it is not a live account with interest.
  public static func outlook(
    of accountId: UUID, ledger: Ledger, balances: AccountBalances, interestCategoryId: UUID?,
    today: DateOnly, through: DateOnly
  ) -> DepositOutlook? {
    outlooks(
      ledger: ledger, balances: balances, interestCategoryId: interestCategoryId, today: today,
      through: through
    ).first { $0.accountId == accountId }
  }

  /// The outlook of every live account with interest, in the order of the accounts.
  public static func outlooks(
    ledger: Ledger, balances: AccountBalances, interestCategoryId: UUID?, today: DateOnly,
    through: DateOnly
  ) -> [DepositOutlook] {
    let accounts = ledger.dataset.paymentMethods
    let mainId = accounts.first { $0.isDefault && !$0.archived }?.id
    let from = today.adding(days: -lookBackDays)

    // The pay dates of every account first: an income goes to the earliest payout that may
    // take it, whatever the account.
    var plans: [Plan] = []
    for account in accounts where !account.archived {
      guard let terms = account.interest else { continue }
      let key = BalanceKey(accountId: account.id, currency: account.mainCurrency)
      let targetId =
        terms.payoutAccountId.map { DueAccounts.effective($0, accounts: accounts) ?? mainId }
        ?? account.id
      let firstCount = balances.anchors(key).first.map { balances.day(of: $0.at) }
      var plan = Plan(
        account: account, terms: terms, key: key, firstCount: firstCount,
        target: targetId.map { BalanceKey(accountId: $0, currency: account.mainCurrency) },
        capitalized: terms.capitalizes && targetId == account.id)
      if let firstCount {
        // The pay dates of the window, and the first one after today however far.
        var dates = DepositSchedule.payDates(terms: terms, after: from, through: through)
        if !dates.contains(where: { $0 > today }),
          let next = DepositSchedule.period(
            terms: terms, containing: today.adding(days: 1), firstCount: firstCount)?.payDate
        {
          dates.append(next)
        }
        // A period that ended before the first count earned on nothing known.
        plan.dates = dates.filter { $0 > firstCount }
      }
      plans.append(plan)
    }

    let received = match(
      plans: plans, ledger: ledger, mainId: mainId, interestCategoryId: interestCategoryId)

    return plans.map { plan in
      outlook(plan, received: received, balances: balances, today: today)
    }
  }

  // MARK: - Pieces

  /// One account's terms and pay dates.
  struct Plan {
    var account: PaymentMethod
    var terms: DepositTerms
    var key: BalanceKey
    var firstCount: DateOnly?
    var target: BalanceKey?
    var capitalized: Bool
    var dates: [DateOnly] = []

    /// The pay date after `date` in the terms: the window's end of what may bring it.
    func next(after date: DateOnly) -> DateOnly? {
      DepositSchedule.period(
        terms: terms, containing: date.adding(days: 1), firstCount: firstCount)?.payDate
    }
  }

  /// A payout by its account and pay date.
  struct PayoutKey: Hashable {
    var accountId: UUID
    var payDate: DateOnly
  }

  /// The income that brought each payout: the earliest that fits, pay date by pay date.
  static func match(
    plans: [Plan], ledger: Ledger, mainId: UUID?, interestCategoryId: UUID?
  ) -> [PayoutKey: UUID] {
    guard let category = interestCategoryId, !plans.isEmpty else { return [:] }
    let tree = ledger.tree
    func isInterest(_ id: UUID?) -> Bool {
      var current = id
      var steps = 0
      while let id = current, steps < 64 {
        if id == category { return true }
        current = tree.parent(of: id)?.id
        steps += 1
      }
      return false
    }
    // Live incomes of the interest category, by account, oldest first.
    var incomes: [UUID: [(day: DateOnly, at: Date, id: UUID)]] = [:]
    for entry in ledger.dataset.entries {
      let transaction = entry.transaction
      guard transaction.kind == .income, !transaction.isDeleted, !entry.parts.isEmpty,
        entry.parts.allSatisfy({ isInterest($0.categoryId) }),
        let accountId = transaction.paymentMethodId ?? mainId
      else { continue }
      incomes[accountId, default: []].append(
        (ledger.calendar.day(of: transaction.occurredAt), transaction.occurredAt, transaction.id))
    }
    for (account, list) in incomes {
      incomes[account] = list.sorted { ($0.at, $0.id.uuidString) < ($1.at, $1.id.uuidString) }
    }

    var due: [(key: PayoutKey, target: UUID, first: DateOnly, last: DateOnly)] = []
    for plan in plans {
      guard let target = plan.target?.accountId else { continue }
      for date in plan.dates {
        let last =
          plan.next(after: date).map { $0.adding(days: -1) }
          ?? date.adding(days: lastPayoutDays)
        due.append(
          (
            PayoutKey(accountId: plan.account.id, payDate: date), target,
            date.adding(days: -earlyDays), last
          ))
      }
    }
    due.sort {
      ($0.key.payDate, $0.key.accountId.uuidString) < ($1.key.payDate, $1.key.accountId.uuidString)
    }

    var taken: Set<UUID> = []
    var result: [PayoutKey: UUID] = [:]
    for payout in due {
      guard
        let income = incomes[payout.target]?.first(where: {
          $0.day >= payout.first && $0.day <= payout.last && !taken.contains($0.id)
        })
      else { continue }
      taken.insert(income.id)
      result[payout.key] = income.id
    }
    return result
  }

  /// One account's payouts, worked out pay date by pay date so that interest paid onto the
  /// deposit and not recorded earns in the periods after it.
  static func outlook(
    _ plan: Plan, received: [PayoutKey: UUID], balances: AccountBalances, today: DateOnly
  ) -> DepositOutlook {
    let terms = plan.terms
    var outlook = DepositOutlook(
      accountId: plan.account.id, terms: terms, key: plan.key, counted: plan.firstCount != nil,
      payouts: [], toEndE4: nil)
    guard let firstCount = plan.firstCount else { return outlook }

    let opening = plan.dates.first.flatMap {
      DepositSchedule.period(terms: terms, containing: $0, firstCount: firstCount)
    }
    var end = plan.dates.last ?? today
    if let ends = terms.endsOn, ends > end { end = ends }
    let start = opening?.start ?? today
    guard
      var steps = DepositInterest.segments(
        key: plan.key, balances: balances, from: min(start, today), through: max(end, today),
        today: today)
    else { return outlook }

    var periodStart = start
    var receivedAhead = AmountE4.zero
    // The balance as the payouts through today leave it.
    var pastSteps: [(from: DateOnly, amount: AmountE4)]?
    for payDate in plan.dates {
      if payDate > today, pastSteps == nil { pastSteps = steps }
      let period = DepositPeriod(start: periodStart, payDate: payDate)
      periodStart = payDate
      let expected = DepositInterest.expected(terms: terms, segments: steps, period: period)
      let accrued = InterestMath.cents(
        DepositInterest.accrued(terms: terms, segments: steps, period: period, through: today))
      let income = received[PayoutKey(accountId: plan.account.id, payDate: payDate)]
      let state: DepositPayout.State
      if let income {
        state = .received(income)
      } else if payDate > today {
        state = .accruing
      } else if today <= payDate.adding(days: graceDays) {
        state = .due
      } else {
        state = .missing
      }
      // Nothing earned is nothing to wait for.
      if payDate <= today, expected.isZero, income == nil { continue }
      if payDate > today, income != nil { receivedAhead += expected }
      if plan.capitalized, income == nil, !expected.isZero {
        steps = DepositInterest.compounded(steps, adding: [(payDate, expected)])
      }
      guard let target = plan.target else { continue }
      outlook.payouts.append(
        DepositPayout(
          accountId: plan.account.id, target: target, periodStart: period.start,
          payDate: payDate, accruedE4: accrued, expectedE4: expected,
          capitalized: plan.capitalized, state: state))
    }

    if terms.endsOn != nil {
      // Every payout after today through the end, on the balance with the unrecorded interest
      // of the payouts so far; one already received is not still to come.
      let whole = DepositInterest.projectionToEnd(
        terms: terms, segments: pastSteps ?? steps, today: today)
      outlook.toEndE4 = whole.map { max(.zero, $0 - receivedAhead) }
    }
    return outlook
  }
}
