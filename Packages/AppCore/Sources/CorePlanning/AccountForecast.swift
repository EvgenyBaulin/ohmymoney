import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// What is known about every balance through the end of the month: built with the data after
/// every write, so it is always fresh, while the one slow input — the forecast of the month's
/// variable spending — comes from the forecast step and is laid over it in `forecast`.
///
/// For every (account, currency) pair of a live account, the balance on the last day of the
/// month is
///
/// ```
/// now                  the latest count plus every real movement after it
/// + written ahead      movements already written for the days after now, through the month's end
/// + expected income    what the expectations still due this month bring to this account
/// − scheduled          unpaid due dates of the payments on this account, through the month's end
/// − debts              what the debts I owe still ask this month, from the account of their last payment
/// − count losses       the net the pair's counts lost in the window, at its pace for the days left
/// − for others         paid from the pair for others less money back onto it, at the same pace
/// − spending           the forecast's variable spending of the days left × this pair's share
/// + interest           what deposits are expected to pay onto the pair through the month's end
/// ```
///
/// * Count losses and spending for others are money that really leaves an account without
///   being my spending, so the forecast of my spending never holds them. Over the window of
///   the shares — `MonthForecast.windowLength` days before today through yesterday, fewer when
///   the history is shorter and never before the day of the pair's first count — each pair's
///   net of each is taken in what moved on the account, floored at zero (what a count found or
///   more money back than paid is not forecast), and goes on at the same pace: net ÷ days of
///   the window × days after today through the month's end. A window shorter than four weeks
///   keeps no pace, and neither does an archived account, as it keeps no share. A refund of a
///   part paid for others is money back for others too.
///
/// * The first count of a pair is where its balance starts; operations dated before it are
///   history, never income or spending of the pair. A line the app wrote for its books — the
///   difference of a count among them — moves no money, is no expected income and no part of
///   the pace.
/// * Due dates and expectations are judged **as of the end of the month**: an operation already
///   written for a later day that pays a due date, or that an expectation would take, fulfils
///   it — it is in «written ahead» and nowhere else. Only expectations due today or later
///   bring money; one of this month already overdue brings none and is shown apart.
/// * A due date or a debt of an archived or missing account comes off the main account, where
///   «Провести» pays it from, as the free sum takes it. An expectation goes to the account
///   chosen for it, else to that of its latest linked income, else to the main account.
/// * A flow in a currency the account holds stays in it; any other goes to the account's main
///   currency through rubles at today's rates, or — without a rate — is left out and its
///   currency listed, never guessed.
/// * Out of the summary is out of the summary: a group left out keeps its pairs in a section of
///   their own, and its money never reaches «Всего».
/// * Interest of a deposit is the payouts dated today through the month's end and not received
///   yet (`DepositPayouts`), on the pair they are paid to — the deposit itself, the account the
///   terms name, or the main account when that one is archived or gone. One received is in the
///   balance already; one overdue brings nothing. It is the forecast's own grey line and never
///   part of the free sum or of the income expected.
public struct AccountMonthPlan: Hashable, Sendable {
  /// An expectation of this month whose due date has passed with nothing in: no money is
  /// counted for it, and the line asks about it.
  public struct OverdueIncome: Hashable, Sendable {
    public var expectationId: UUID
    public var name: String
    public var due: DateOnly
    /// What is still missing, in `currency`.
    public var remaining: AmountE4
    public var currency: CurrencyCode

    public init(
      expectationId: UUID, name: String, due: DateOnly, remaining: AmountE4,
      currency: CurrencyCode
    ) {
      self.expectationId = expectationId
      self.name = name
      self.due = due
      self.remaining = remaining
      self.currency = currency
    }
  }

  /// Everything known about one pair through the end of the month, in the pair's currency
  /// unless a field says rubles.
  public struct Flows: Hashable, Sendable {
    public var key: BalanceKey
    public var account: PaymentMethod
    /// The account holds the currency; a currency it does not hold only appears when money
    /// moved in it anyway.
    public var isHeld: Bool
    /// The balance now; `nil` while the pair was never counted.
    public var now: AmountE4?
    /// What already written movements change after now through the end of the month; zero
    /// while never counted.
    public var writtenAhead: AmountE4
    /// Expected income still to come this month, never below zero.
    public var income: AmountE4
    /// Unpaid due dates of scheduled payments through the end of the month, never below zero.
    public var scheduled: AmountE4
    /// Debt payments still due this month, never below zero.
    public var debts: AmountE4
    /// What counts of the pair are expected to find missing by the end of the month, at the
    /// pace of the window's net loss; never below zero.
    public var reconcileLoss: AmountE4
    /// What is expected to leave the pair for others by the end of the month — paid for them
    /// less the money back onto the pair, at the pace of the window; never below zero.
    public var othersSpending: AmountE4
    /// Rubles of variable spending of the window (`SpendingByBalance.weights`).
    public var spendingWeight: AmountE4
    /// Currencies of flows left out for want of a rate today, by code.
    public var withoutRate: [CurrencyCode]
    /// Expectations of this month overdue with nothing in, by due date.
    public var overdueIncome: [OverdueIncome]
    /// Interest of deposits expected on the pair through the end of the month and not received
    /// yet, never below zero (`DepositPayouts`).
    public var interest: AmountE4

    public init(
      key: BalanceKey, account: PaymentMethod, isHeld: Bool = true, now: AmountE4?,
      writtenAhead: AmountE4 = .zero, income: AmountE4 = .zero, scheduled: AmountE4 = .zero,
      debts: AmountE4 = .zero, reconcileLoss: AmountE4 = .zero,
      othersSpending: AmountE4 = .zero, spendingWeight: AmountE4 = .zero,
      withoutRate: [CurrencyCode] = [], overdueIncome: [OverdueIncome] = [],
      interest: AmountE4 = .zero
    ) {
      self.key = key
      self.account = account
      self.isHeld = isHeld
      self.now = now
      self.writtenAhead = writtenAhead
      self.income = income
      self.scheduled = scheduled
      self.debts = debts
      self.reconcileLoss = reconcileLoss
      self.othersSpending = othersSpending
      self.spendingWeight = spendingWeight
      self.withoutRate = withoutRate
      self.overdueIncome = overdueIncome
      self.interest = interest
    }

    /// The balance at the end of the month before any variable spending; `nil` while never
    /// counted.
    public var base: AmountE4? {
      now.map {
        $0 + writtenAhead + income + interest - scheduled - debts - reconcileLoss - othersSpending
      }
    }
  }

  /// A section of the sidebar: a group and the pairs of its accounts, or those of no group.
  public struct Section: Hashable, Sendable {
    public var group: AccountGroup?
    public var inSummary: Bool
    /// In the order of the sidebar: account by account, each account's currencies in its own
    /// order.
    public var keys: [Flows]

    public init(group: AccountGroup?, inSummary: Bool, keys: [Flows]) {
      self.group = group
      self.inSummary = inSummary
      self.keys = keys
    }
  }

  public var today: DateOnly
  /// The last day of today's month.
  public var through: DateOnly
  public var sections: [Section]
  /// Rubles of variable spending of the window by pair — every pair of a live account, those
  /// never counted and those without a line of their own too: the forecast is shared among all
  /// of them, and a pair without a projection simply keeps its share.
  public var weights: [BalanceKey: AmountE4]
  /// Variable spending already written for the days after today, rubles.
  public var aheadSpendingRub: AmountE4
  /// Where the spending goes when no pair spent anything in the window: the main account's main
  /// currency.
  public var fallbackKey: BalanceKey?
  /// Held pairs of live accounts never counted, in the order of the sidebar.
  public var unanchored: [BalanceKey]
  public var rubPerUnit: [CurrencyCode: Decimal]

  public init(
    today: DateOnly, through: DateOnly, sections: [Section], weights: [BalanceKey: AmountE4],
    aheadSpendingRub: AmountE4, fallbackKey: BalanceKey?, unanchored: [BalanceKey],
    rubPerUnit: [CurrencyCode: Decimal]
  ) {
    self.today = today
    self.through = through
    self.sections = sections
    self.weights = weights
    self.aheadSpendingRub = aheadSpendingRub
    self.fallbackKey = fallbackKey
    self.unanchored = unanchored
    self.rubPerUnit = rubPerUnit
  }

  /// Nothing known yet.
  public static let empty: AccountMonthPlan = {
    let day = DateOnly(year: 1970, month: 1, day: 1)
    return AccountMonthPlan(
      today: day, through: day.monthKey.lastDay, sections: [], weights: [:],
      aheadSpendingRub: .zero, fallbackKey: nil, unanchored: [], rubPerUnit: [:])
  }()

  /// Every pair, in the order of the sidebar.
  public var flows: [Flows] { sections.flatMap(\.keys) }

  // MARK: - Building

  /// The plan of the month as the planning snapshot of the same data sees it.
  public static func build(ledger: Ledger, planning: PlanningSnapshot) -> AccountMonthPlan {
    build(
      ledger: ledger, accounts: planning.accounts, today: planning.today,
      rubPerUnit: planning.rubPerUnit, dayRates: planning.dayRates, debts: planning.debts,
      expected: planning.expected, deposits: planning.deposits)
  }

  /// The plan for `today`. `accounts` are the balances as of now (`AccountsSnapshot`),
  /// `debts` the Debts section, `expected` the expectations that are not closed — each as the
  /// planning snapshot builds it. `dayRates` are what an operation in another currency is
  /// compared at when it may pay a due date. `deposits` are the payouts of interest
  /// (`DepositPayouts.build`).
  public static func build(
    ledger: Ledger, accounts: AccountsSnapshot, today: DateOnly,
    rubPerUnit: [CurrencyCode: Decimal], dayRates: DayRates = .empty, debts: DebtsOverview,
    expected: [ExpectedIncomeStatus], deposits: [DepositPayout] = []
  ) -> AccountMonthPlan {
    let dataset = ledger.dataset
    let book = dataset.planning
    let list = dataset.paymentMethods
    let accountsById = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let main = list.first { $0.isDefault && !$0.archived }
    let mainId = main?.id
    let through = today.monthKey.lastDay
    // The last moment of the month: moments are kept to the millisecond.
    let endOfMonth = ledger.calendar.startOfDay(through.adding(days: 1))
      .addingTimeInterval(-0.001)

    // What operations already written for later days pay: judged as of the end of the month.
    let planMatches = ScheduledMatching.matches(
      book: book, ledger: ledger, today: today,
      rejections: book.settings.scheduledMatchRejections, dayRates: dayRates,
      rubPerUnit: rubPerUnit, operationsThrough: through)

    var router = Router(accountsById: accountsById, rubPerUnit: rubPerUnit)

    // Scheduled payments: the free sum's due dates through the month's end.
    for due in CashPlan.scheduledDues(
      ledger: ledger, book: book, accounts: accounts, today: today, until: through,
      matches: planMatches)
    {
      let accountId = DueAccounts.effective(due.accountId, accounts: list) ?? mainId
      router.add(\.scheduled, due.amount, in: due.currency, to: accountId)
    }

    // Debts I owe: what they still ask this month, from the account of their last payment.
    for due in CashPlan.debtDues(
      ledger: ledger, book: book, debts: debts, today: today, until: through,
      paymentsThrough: through)
    {
      let accountId = DueAccounts.effective(due.accountId, accounts: list) ?? mainId
      router.add(\.debts, due.amount, in: due.currency, to: accountId)
    }

    // Expected income: what is still to come for the due dates of today through the month's
    // end. An income already written for a later day that is not linked yet fulfils the due
    // date it would be linked to, as a linked one does.
    let typedAhead = incomeTypedAhead(
      ledger: ledger, today: today, through: through, statuses: expected, rubPerUnit: rubPerUnit)
    for status in expected {
      let income = status.income
      let chosen = ExpectedIncomeRules.account(
        of: income, links: book.expectedLinks, ledger: ledger, mainId: mainId)
      let accountId = DueAccounts.effective(chosen, accounts: list) ?? mainId
      for (index, occurrence) in status.occurrences.enumerated() {
        let typed = typedAhead[OccurrenceKey(expectation: income.id, index: index)] ?? .zero
        let remaining = max(.zero, occurrence.remaining - typed)
        guard !remaining.isZero, occurrence.due <= through else { continue }
        if occurrence.due >= today {
          router.add(\.income, remaining, in: income.currency, to: accountId)
        } else if occurrence.due.monthKey == today.monthKey {
          router.overdue(
            OverdueIncome(
              expectationId: income.id, name: income.name, due: occurrence.due,
              remaining: remaining, currency: income.currency),
            to: accountId)
        }
      }
    }

    // Interest of deposits: the payouts still to come this month, on the pair they go to.
    for payout in deposits where payout.payDate >= today && payout.payDate <= through {
      if case .received = payout.state { continue }
      let accountId = DueAccounts.effective(payout.target.accountId, accounts: list) ?? mainId
      router.add(\.interest, payout.expectedE4, in: payout.target.currency, to: accountId)
    }

    let live = Set(list.filter { !$0.archived }.map(\.id))
    let spending = VariableSpending.byBalance(
      ledger: ledger, today: today, through: through,
      scheduledOperations: planMatches.operationIds, mainId: mainId, liveAccounts: live)
    let balances = accounts.balances
    let outflows = Outflows.paced(
      ledger: ledger, today: today, mainId: mainId, liveAccounts: live, balances: balances)

    let sections = accounts.sections.map { section in
      Section(
        group: section.group, inSummary: section.inSummary,
        keys: section.accounts.flatMap { line in
          line.keys.map { keyLine in
            let key = keyLine.key
            let now = keyLine.balance
            var ahead = AmountE4.zero
            if let now, let atEnd = balances.balance(key, at: endOfMonth) {
              ahead = atEnd - now
            }
            let routed = router.flows[key] ?? Router.Pending()
            return Flows(
              key: key, account: line.account, isHeld: keyLine.isHeld, now: now,
              writtenAhead: ahead, income: routed.income, scheduled: routed.scheduled,
              debts: routed.debts,
              reconcileLoss: outflows.reconcileLoss[key] ?? .zero,
              othersSpending: outflows.othersSpending[key] ?? .zero,
              spendingWeight: spending.weights[key] ?? .zero,
              withoutRate: routed.withoutRate.sorted { $0.code < $1.code },
              overdueIncome: routed.overdueIncome.sorted { $0.due < $1.due },
              interest: routed.interest)
          }
        })
    }

    return AccountMonthPlan(
      today: today, through: through, sections: sections, weights: spending.weights,
      aheadSpendingRub: spending.ahead,
      fallbackKey: main.map { BalanceKey(accountId: $0.id, currency: $0.mainCurrency) },
      unanchored: accounts.unanchored, rubPerUnit: rubPerUnit)
  }

  /// A due date of an expectation.
  private struct OccurrenceKey: Hashable {
    var expectation: UUID
    var index: Int
  }

  /// Income operations dated after today through the month's end that no expectation holds
  /// yet, each counted towards the due date it would be linked to
  /// (`ExpectedIncomeRules.suggestLink`), in the expectation's currency.
  private static func incomeTypedAhead(
    ledger: Ledger, today: DateOnly, through: DateOnly, statuses: [ExpectedIncomeStatus],
    rubPerUnit: [CurrencyCode: Decimal]
  ) -> [OccurrenceKey: AmountE4] {
    guard today < through, !statuses.isEmpty else { return [:] }
    let byId = Dictionary(statuses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var typed: [OccurrenceKey: AmountE4] = [:]
    for row in ledger.rows(in: DayRange(today.adding(days: 1), through))
    where row.isFirstPart && row.kind == .income {
      guard let entry = ledger.entry(row.transactionId),
        let id = ExpectedIncomeRules.suggestLink(for: entry, statuses: statuses),
        let status = byId[id],
        let index = ExpectedIncomeRules.occurrenceIndex(of: entry, in: status, ledger: ledger),
        let amount = ExpectedIncomeRules.amount(
          of: entry.transaction, towards: status.income, rubPerUnit: rubPerUnit)
      else { continue }
      typed[OccurrenceKey(expectation: id, index: index), default: .zero] += amount
    }
    return typed
  }

  /// The flows found so far, by the pair they land on.
  private struct Router {
    struct Pending {
      var income = AmountE4.zero
      var scheduled = AmountE4.zero
      var debts = AmountE4.zero
      var interest = AmountE4.zero
      var withoutRate: Set<CurrencyCode> = []
      var overdueIncome: [OverdueIncome] = []
    }

    let accountsById: [UUID: PaymentMethod]
    let rubPerUnit: [CurrencyCode: Decimal]
    var flows: [BalanceKey: Pending] = [:]

    init(accountsById: [UUID: PaymentMethod], rubPerUnit: [CurrencyCode: Decimal]) {
      self.accountsById = accountsById
      self.rubPerUnit = rubPerUnit
    }

    /// `amount` of `currency` onto the account: in that currency when the account holds it,
    /// else in the account's main currency through rubles; without a rate it is left out and
    /// its currency listed on the main currency's pair.
    mutating func add(
      _ field: WritableKeyPath<Pending, AmountE4>, _ amount: AmountE4,
      in currency: CurrencyCode, to accountId: UUID?
    ) {
      guard let accountId, let account = accountsById[accountId], !amount.isZero else { return }
      if account.holds(currency) {
        flows[BalanceKey(accountId: accountId, currency: currency), default: Pending()][
          keyPath: field] += amount
        return
      }
      let key = BalanceKey(accountId: accountId, currency: account.mainCurrency)
      guard let from = perUnit(currency), let to = perUnit(key.currency),
        let converted = AccountRules.crossConvert(amount, fromPerUnit: from, toPerUnit: to)
      else {
        flows[key, default: Pending()].withoutRate.insert(currency)
        return
      }
      flows[key, default: Pending()][keyPath: field] += converted
    }

    /// An overdue expectation onto the pair its money would have landed on.
    mutating func overdue(_ income: OverdueIncome, to accountId: UUID?) {
      guard let accountId, let account = accountsById[accountId] else { return }
      let currency = account.holds(income.currency) ? income.currency : account.mainCurrency
      flows[BalanceKey(accountId: accountId, currency: currency), default: Pending()]
        .overdueIncome.append(income)
    }

    private func perUnit(_ currency: CurrencyCode) -> Decimal? {
      if currency == .rub { return 1 }
      guard let rate = rubPerUnit[currency], rate > 0 else { return nil }
      return rate
    }
  }

  /// Money that leaves the accounts without being my spending, by pair, at the pace it left
  /// over the window, for the days after today through the month's end.
  struct Outflows {
    var reconcileLoss: [BalanceKey: AmountE4] = [:]
    var othersSpending: [BalanceKey: AmountE4] = [:]

    /// Over the window of the shares through yesterday — from the first day of the history
    /// when that is later — each pair's net, in what moved on its account:
    ///
    /// * count losses — the differences the counts of the pair wrote
    ///   (`OperationLink.reconciledBalance`), an expense being money that disappeared and an
    ///   income money that appeared;
    /// * for others — the parts paid for somebody else (`reimbursable`), each its share of what
    ///   moved, less the money back onto the pair and less the refunds of those parts onto it.
    ///   Money back that repays a debt is the debt's, not the parts'; a purchase on credit moved
    ///   no money.
    ///
    /// A pair's window starts no earlier than the day of its first count (`balances`): what was
    /// written before it is history, not money the pair lost, and a pair never counted keeps
    /// nothing. A window shorter than `MonthForecast.minimumWindow` days keeps no pace, as a
    /// spending forecast of so short a history has too little data: a few days say nothing of
    /// the month. Each net below zero is nothing: a gain is not forecast. What is dated today or
    /// later is no pace — it is in «written ahead», or it is today's and the window ends
    /// yesterday.
    static func paced(
      ledger: Ledger, today: DateOnly, mainId: UUID?, liveAccounts: Set<UUID>,
      balances: AccountBalances
    ) -> Outflows {
      let daysLeft = today.monthKey.dayCount - today.day
      let yesterday = today.adding(days: -1)
      var start = today.adding(days: -MonthForecast.windowLength)
      if let first = ledger.firstDay, first > start { start = first }
      guard daysLeft > 0, start <= yesterday else { return Outflows() }

      // The moment of each pair's first count, read once per pair.
      var firstCounts: [BalanceKey: Date?] = [:]
      func firstCount(_ key: BalanceKey) -> Date? {
        if let known = firstCounts[key] { return known }
        let moment = balances.anchors(key).first?.at
        firstCounts[key] = moment
        return moment
      }
      // The parts of live purchases paid for somebody else: a refund of one is money back for
      // others too.
      var paidForOthers: Set<UUID>?
      func isPaidForOthers(_ part: UUID) -> Bool {
        if paidForOthers == nil {
          paidForOthers = Set(
            ledger.dataset.entries.lazy
              .filter { $0.transaction.kind == .expense && !$0.transaction.isDeleted }
              .flatMap { $0.parts.filter(\.reimbursable).map(\.id) })
        }
        return paidForOthers?.contains(part) ?? false
      }

      var losses: [BalanceKey: AmountE4] = [:]
      var others: [BalanceKey: AmountE4] = [:]
      for row in ledger.rows(in: DayRange(start, yesterday)) where row.isFirstPart {
        guard let entry = ledger.entry(row.transactionId) else { continue }
        let transaction = entry.transaction
        guard let accountId = transaction.paymentMethodId ?? mainId,
          liveAccounts.contains(accountId)
        else { continue }
        let moved = transaction.movedMoney
        let key = BalanceKey(accountId: accountId, currency: moved.currency)
        guard let counted = firstCount(key), transaction.occurredAt > counted else { continue }
        if case .reconciledBalance = row.link {
          switch transaction.kind {
          case .expense: losses[key, default: .zero] += moved.amount
          case .income: losses[key, default: .zero] += -moved.amount
          case .refund, .reimbursement: break
          }
          continue
        }
        guard AccountBalances.movesMoney(entry, tree: ledger.tree) else { continue }
        switch transaction.kind {
        case .expense where entry.parts.contains(where: \.reimbursable):
          let shares = moved.amount.allocated(
            proportionallyTo: entry.parts.map(\.amountE4), outOf: transaction.amountE4)
          let paid = zip(shares, entry.parts).filter { $0.1.reimbursable }.map(\.0)
          others[key, default: .zero] += AmountE4.sum(paid)
        case .reimbursement where transaction.debtId == nil:
          others[key, default: .zero] += -moved.amount
        case .refund:
          let backForOthers = entry.parts.map {
            $0.refundOfPartId.map(isPaidForOthers) ?? false
          }
          guard backForOthers.contains(true) else { break }
          let shares = moved.amount.allocated(
            proportionallyTo: entry.parts.map(\.amountE4), outOf: transaction.amountE4)
          let back = zip(shares, backForOthers).filter { $0.1 }.map(\.0)
          others[key, default: .zero] += -AmountE4.sum(back)
        default:
          break
        }
      }

      // The days of a pair's window: from its first count's day when that is later than the
      // window's start, through yesterday.
      func windowDays(_ key: BalanceKey) -> Int {
        var from = start
        if let counted = firstCount(key) {
          let day = ledger.calendar.day(of: counted)
          if day > from { from = day }
        }
        return yesterday.dayNumber - from.dayNumber + 1
      }
      func paced(_ nets: [BalanceKey: AmountE4]) -> [BalanceKey: AmountE4] {
        var result: [BalanceKey: AmountE4] = [:]
        for (key, net) in nets where net.raw > 0 {
          let days = windowDays(key)
          guard days >= MonthForecast.minimumWindow else { continue }
          result[key] = SubscriptionMath.rounded(net.decimal / Decimal(days) * Decimal(daysLeft))
        }
        return result
      }
      return Outflows(reconcileLoss: paced(losses), othersSpending: paced(others))
    }
  }

  // MARK: - The forecast

  /// The plan with the forecast's remainder laid over it: a few multiplications per pair.
  ///
  /// The remainder's three figures, clamped as the month forecast clamps them, less the
  /// variable spending already written for later days, are shared among the pairs by their
  /// weights — exactly, so the shares add up to each figure. A pair's spending is its share in
  /// its own currency at today's rate. The balance takes the most spending for its low end and
  /// the least for its high end.
  public func forecast(remainder: MonthForecast.Remainder) -> AccountForecast {
    let middle = remainder.middle
    let quantiles = [min(remainder.p10, middle), middle, max(remainder.p90, middle)].map {
      max(.zero, $0 - aheadSpendingRub)
    }

    var weightList = weights.filter { $0.value.raw > 0 }
    if weightList.isEmpty, let fallbackKey {
      weightList = [fallbackKey: AmountE4(raw: 1)]
    }
    let keys = weightList.keys.sorted()
    let amounts = keys.map { weightList[$0] ?? .zero }
    let whole = AmountE4.sum(amounts)
    var shares: [BalanceKey: [AmountE4]] = [:]
    let split = quantiles.map { $0.allocated(proportionallyTo: amounts, outOf: whole) }
    for (index, key) in keys.enumerated() {
      shares[key] = split.map { $0[index] }
    }
    let basisPoints = Dictionary(
      uniqueKeysWithValues: zip(keys, Shares.basisPoints(amounts)).compactMap { key, share in
        share.map { (key, $0) }
      })

    var result: [AccountForecast.Section] = []
    for section in sections {
      var lines: [AccountForecast.Line] = []
      var total = (low: AmountE4.zero, middle: AmountE4.zero, high: AmountE4.zero)
      var converted = false
      var missing: Set<CurrencyCode> = []
      for flows in section.keys {
        let line = self.line(flows, shares: shares[flows.key], shareBp: basisPoints[flows.key])
        missing.formUnion(flows.withoutRate)
        if case .noRate(let currency) = line.status { missing.insert(currency) }
        if let rub = line.balanceRub {
          total.low += rub.low
          total.middle += rub.middle
          total.high += rub.high
          converted = true
        }
        lines.append(line)
      }
      result.append(
        AccountForecast.Section(
          group: section.group, inSummary: section.inSummary, lines: lines,
          totalRub: converted
            ? AccountForecast.Band(low: total.low, middle: total.middle, high: total.high) : nil,
          withoutRate: missing.sorted { $0.code < $1.code }))
    }

    let counted = result.filter(\.inSummary).compactMap(\.totalRub)
    let inSummary =
      counted.isEmpty
      ? nil
      : AccountForecast.Band(
        low: AmountE4.sum(counted.map(\.low)), middle: AmountE4.sum(counted.map(\.middle)),
        high: AmountE4.sum(counted.map(\.high)))
    return AccountForecast(
      through: through, computedFor: remainder.computedFor, lowData: remainder.lowData,
      sections: result, inSummaryTotalRub: inSummary, unanchored: unanchored)
  }

  private func line(
    _ flows: Flows, shares: [AmountE4]?, shareBp: Int?
  ) -> AccountForecast.Line {
    let currency = flows.key.currency
    guard let base = flows.base, let now = flows.now else {
      return AccountForecast.Line(flows: flows, status: .notCounted, shareBp: shareBp)
    }
    let rate: Decimal? = currency == .rub ? 1 : rubPerUnit[currency].flatMap { $0 > 0 ? $0 : nil }
    guard let rate else {
      return AccountForecast.Line(flows: flows, status: .noRate(currency), shareBp: shareBp)
    }
    let quantiles = shares ?? [.zero, .zero, .zero]
    func inCurrency(_ rubles: AmountE4) -> AmountE4 {
      currency == .rub ? rubles : SubscriptionMath.rounded(rubles.decimal / rate)
    }
    let spending = AccountForecast.Band(
      low: inCurrency(quantiles[0]), middle: inCurrency(quantiles[1]),
      high: inCurrency(quantiles[2]))
    let balance = AccountForecast.Band(
      low: base - spending.high, middle: base - spending.middle, high: base - spending.low)
    func rubles(_ amount: AmountE4) -> AmountE4 {
      currency == .rub ? amount : SubscriptionMath.rounded(amount.decimal * rate)
    }
    return AccountForecast.Line(
      flows: flows, status: .ready, spending: spending, balance: balance,
      balanceRub: AccountForecast.Band(
        low: rubles(balance.low), middle: rubles(balance.middle), high: rubles(balance.high)),
      shareBp: shareBp, mayGoNegative: balance.middle.raw < 0 && now.raw >= 0)
  }
}

/// The balance of every pair at the end of the month, with its interval: the plan of the month
/// (`AccountMonthPlan`) with the forecast of the month's variable spending laid over it.
public struct AccountForecast: Hashable, Sendable {
  /// Three figures of one quantity, `low ≤ middle ≤ high`.
  public struct Band: Hashable, Sendable {
    public var low: AmountE4
    public var middle: AmountE4
    public var high: AmountE4

    public init(low: AmountE4, middle: AmountE4, high: AmountE4) {
      self.low = low
      self.middle = middle
      self.high = high
    }
  }

  public enum Status: Hashable, Sendable {
    case ready
    /// The pair was never counted: its balance is unknown, and so is its end.
    case notCounted
    /// Its currency has no rate today: its share of the spending cannot be converted.
    case noRate(CurrencyCode)
  }

  public struct Line: Hashable, Sendable {
    public var flows: AccountMonthPlan.Flows
    public var status: Status
    /// In the pair's currency: low is the share of the forecast's low figure, high of its high.
    public var spending: Band?
    /// In the pair's currency: low takes the most spending, high the least.
    public var balance: Band?
    /// `balance` in rubles at today's rate.
    public var balanceRub: Band?
    /// The pair's share of all variable spending, basis points; `nil` when it spent nothing.
    public var shareBp: Int?
    /// The middle falls below zero while the balance now is not: a credit card already below
    /// zero is in its normal state.
    public var mayGoNegative: Bool

    public init(
      flows: AccountMonthPlan.Flows, status: Status, spending: Band? = nil,
      balance: Band? = nil, balanceRub: Band? = nil, shareBp: Int? = nil,
      mayGoNegative: Bool = false
    ) {
      self.flows = flows
      self.status = status
      self.spending = spending
      self.balance = balance
      self.balanceRub = balanceRub
      self.shareBp = shareBp
      self.mayGoNegative = mayGoNegative
    }

    public var key: BalanceKey { flows.key }
  }

  public struct Section: Hashable, Sendable {
    public var group: AccountGroup?
    public var inSummary: Bool
    public var lines: [Line]
    /// The ready lines added up in rubles; `nil` when none could be.
    public var totalRub: Band?
    /// Currencies left out of the total for want of a rate, by code.
    public var withoutRate: [CurrencyCode]

    public init(
      group: AccountGroup?, inSummary: Bool, lines: [Line], totalRub: Band?,
      withoutRate: [CurrencyCode]
    ) {
      self.group = group
      self.inSummary = inSummary
      self.lines = lines
      self.totalRub = totalRub
      self.withoutRate = withoutRate
    }
  }

  /// The last day of the month.
  public var through: DateOnly
  /// The day the spending forecast was computed for.
  public var computedFor: DateOnly
  /// The history is short: the interval is a straight line ±50 %.
  public var lowData: Bool
  public var sections: [Section]
  /// The sections in the summary added up; `nil` while no pair of theirs is ready.
  public var inSummaryTotalRub: Band?
  /// Held pairs of live accounts never counted: no forecast for them.
  public var unanchored: [BalanceKey]

  public init(
    through: DateOnly, computedFor: DateOnly, lowData: Bool, sections: [Section],
    inSummaryTotalRub: Band?, unanchored: [BalanceKey]
  ) {
    self.through = through
    self.computedFor = computedFor
    self.lowData = lowData
    self.sections = sections
    self.inSummaryTotalRub = inSummaryTotalRub
    self.unanchored = unanchored
  }

  /// Every line of one account, in its own order of currencies.
  public func lines(of accountId: UUID) -> [Line] {
    sections.flatMap(\.lines).filter { $0.flows.account.id == accountId }
  }

  /// The line of one pair.
  public func line(of key: BalanceKey) -> Line? {
    sections.lazy.flatMap(\.lines).first { $0.key == key }
  }

  /// Some section has a ready line: there is something to show.
  public var hasReadyLine: Bool {
    sections.contains { $0.lines.contains { $0.status == .ready } }
  }
}
