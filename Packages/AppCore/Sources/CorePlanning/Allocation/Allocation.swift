import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// Where a line of the allocation sheet sends money.
public enum AllocationLineKind: Hashable, Sendable {
  case goal(UUID)
  case account(UUID)
  /// The cushion: to this account, or — `nil` — to the one the sheet asks for.
  case cushion(UUID?)
  /// The tax of self-employment: to this account, or — `nil` — only shown.
  case tax(UUID?)
}

/// A line of the allocation sheet the owner may write.
public struct AllocationLine: Hashable, Sendable, Identifiable {
  /// What the sheet says under the line.
  public enum Note: Hashable, Sendable {
    /// The goal is complete: offer to drop its rule.
    case goalCompleteDropRule(UUID)
    /// The goal still lacks this much.
    case goalMissing(AmountE4)
    /// No account is marked as the cushion.
    case noCushionAccount
    /// The cushion still lacks this much.
    case cushionLeft(AmountE4)
  }

  public var id: String
  public var kind: AllocationLineKind
  public var ruleId: UUID?
  /// In the currency of the income.
  public var suggestedE4: AmountE4
  public var targetCurrency: CurrencyCode
  /// The account the money also moves to: of the goal when it says so, of the cushion, of the
  /// tax.
  public var transferTo: UUID?
  public var note: Note?

  public init(
    id: String, kind: AllocationLineKind, ruleId: UUID? = nil, suggestedE4: AmountE4,
    targetCurrency: CurrencyCode, transferTo: UUID? = nil, note: Note? = nil
  ) {
    self.id = id
    self.kind = kind
    self.ruleId = ruleId
    self.suggestedE4 = suggestedE4
    self.targetCurrency = targetCurrency
    self.transferTo = transferTo
    self.note = note
  }
}

/// A line the sheet only shows: money already spoken for until the next income.
public struct AllocationShown: Hashable, Sendable, Identifiable {
  public enum Kind: Hashable, Sendable {
    case scheduled(UUID, due: DateOnly)
    case debt(UUID, due: DateOnly)
    case limitLeft(categoryId: UUID)
    case npdTax
  }

  public var kind: Kind
  public var amountE4: AmountE4

  public init(kind: Kind, amountE4: AmountE4) {
    self.kind = kind
    self.amountE4 = amountE4
  }

  public var id: String {
    switch kind {
    case .scheduled(let id, let due): "scheduled:\(id.uuidString):\(due.iso)"
    case .debt(let id, let due): "debt:\(id.uuidString):\(due.iso)"
    case .limitLeft(let categoryId): "limit:\(categoryId.uuidString)"
    case .npdTax: "npd"
    }
  }
}

/// The allocation of one income, as its sheet shows it.
public struct AllocationSheet: Hashable, Sendable {
  public var incomeId: UUID
  public var currency: CurrencyCode
  public var incomeE4: AmountE4
  /// The tax of self-employment on the income.
  public var taxE4: AmountE4
  /// The income after the tax: what a rule of a percent takes from.
  public var baseE4: AmountE4
  /// Allocated by this income before.
  public var earlierE4: AmountE4
  public var lines: [AllocationLine]
  public var shown: [AllocationShown]
  /// The day the shown lines reach: the next expected income, else the end of the month.
  public var until: DateOnly
  /// The income less what is written and what is shown.
  public var unallocatedE4: AmountE4
  /// «из них показано, но не записано».
  public var shownNotWrittenE4: AmountE4
  /// The income was edited down below what is allocated.
  public var overAllocatedE4: AmountE4?
  public var raise: AllocationRaise?

  public init(
    incomeId: UUID, currency: CurrencyCode, incomeE4: AmountE4, taxE4: AmountE4 = .zero,
    baseE4: AmountE4, earlierE4: AmountE4 = .zero, lines: [AllocationLine] = [],
    shown: [AllocationShown] = [], until: DateOnly, unallocatedE4: AmountE4,
    shownNotWrittenE4: AmountE4 = .zero, overAllocatedE4: AmountE4? = nil,
    raise: AllocationRaise? = nil
  ) {
    self.incomeId = incomeId
    self.currency = currency
    self.incomeE4 = incomeE4
    self.taxE4 = taxE4
    self.baseE4 = baseE4
    self.earlierE4 = earlierE4
    self.lines = lines
    self.shown = shown
    self.until = until
    self.unallocatedE4 = unallocatedE4
    self.shownNotWrittenE4 = shownNotWrittenE4
    self.overAllocatedE4 = overAllocatedE4
    self.raise = raise
  }
}

/// What writing an allocation puts in the books, one record: contributions to goals, transfers,
/// and the goals whose «transfer on contribution» the sheet changed.
public struct AllocationWrite: Hashable, Sendable {
  public var contributions: [TransactionEntry]
  public var transfers: [Transfer]
  public var goals: [Goal]

  public init(
    contributions: [TransactionEntry] = [], transfers: [Transfer] = [], goals: [Goal] = []
  ) {
    self.contributions = contributions
    self.transfers = transfers
    self.goals = goals
  }

  public static let empty = AllocationWrite()
}

/// The allocation of income: into goals, to accounts, to the cushion, the tax first.
///
/// * An income in «Заработок» (`AllocationSettings.earningsCategoryId`, else the live income
///   category at the top named «Заработок» or «Earnings»), or under it, is offered for
///   allocation until it is allocated in full or the owner said «Не надо».
/// * The base is the income less the tax of self-employment on it: a rule of N % takes N % of
///   the base, to the kopeck; a fixed sum in another currency counts at the rate of the Bank of
///   Russia of the day of the income.
/// * The sheet writes contributions to goals and transfers (to an account, to the cushion, to
///   the account of the tax); it only shows the payments, the dues of debts, the tax kept on no
///   account and what is left of the limits until the next expected income — the end of the
///   month when none is expected.
/// * Everything an allocation writes carries `alloc:<income>:<uuid>`: the sheet knows what was
///   allocated before, and the deletion of the income can take it along.
public enum Allocation {
  /// The words the category «Заработок» is found by when none is chosen.
  static let earningsNames: Set<String> = ["заработок", "earnings"]

  /// The category the allocation is about: the chosen one while it is a live income category,
  /// else the live income category at the top named «Заработок» or «Earnings».
  public static func earningsCategory(
    tree: CategoryTree, categories: [CoreKit.Category], settings: AllocationSettings
  ) -> UUID? {
    if let chosen = settings.earningsCategoryId, let category = tree.category(chosen),
      category.kind == .income, !category.archived
    {
      return chosen
    }
    return categories.first { category in
      category.parentId == nil && category.kind == .income && !category.archived
        && earningsNames.contains(
          category.name.trimmingCharacters(in: .whitespaces).lowercased())
    }?.id
  }

  /// Whether the category is «Заработок» or under it.
  public static func isEarnings(
    categoryId: UUID?, tree: CategoryTree, settings: AllocationSettings
  ) -> Bool {
    guard let category = tree.category(categoryId), category.kind == .income else {
      return false
    }
    var current: CoreKit.Category? = category
    var seen: Set<UUID> = []
    while let node = current, seen.insert(node.id).inserted {
      if let chosen = settings.earningsCategoryId {
        if node.id == chosen { return true }
      } else if node.parentId == nil, !node.archived,
        earningsNames.contains(node.name.trimmingCharacters(in: .whitespaces).lowercased())
      {
        return true
      }
      current = tree.parent(of: node.id)
    }
    return false
  }

  /// Whether the income is offered for allocation: a live income with a part in «Заработок»
  /// that the owner did not decline. Whether something of it is left to allocate is
  /// `offered(ledger:…)`'s question.
  public static func offers(
    entry: TransactionEntry, tree: CategoryTree, settings: AllocationSettings
  ) -> Bool {
    guard entry.transaction.kind == .income, !entry.transaction.isDeleted,
      !settings.declined.contains(entry.id)
    else { return false }
    return entry.parts.contains {
      isEarnings(categoryId: $0.categoryId, tree: tree, settings: settings)
    }
  }

  /// Days an income stays offered in «Стоит посмотреть».
  public static let offeredDays = 30

  /// The incomes «Стоит посмотреть» offers to allocate: offered (`offers`), dated in the last
  /// `offeredDays` days through today, and not allocated in full yet — newest first.
  public static func offered(ledger: Ledger, today: DateOnly) -> [UUID] {
    let settings = ledger.dataset.allocationSettings
    let start = today.adding(days: -(offeredDays - 1))
    var found: [(day: DateOnly, id: UUID)] = []
    var seen: Set<UUID> = []
    for row in ledger.rows(in: DayRange(start, today))
    where row.kind == .income && seen.insert(row.transactionId).inserted {
      guard let entry = ledger.entry(row.transactionId),
        offers(entry: entry, tree: ledger.tree, settings: settings)
      else { continue }
      let done = distributed(
        incomeId: entry.id, ledger: ledger, transfers: ledger.dataset.transfers)
      guard done < entry.transaction.amountE4 else { continue }
      found.append((row.day, entry.id))
    }
    return found.sorted { $0.day > $1.day }.map(\.id)
  }

  /// The day the shown lines reach: the earliest due date after today of an expectation that
  /// is not closed — a one-off one already linked to an income is done —, else the end of
  /// today's month.
  public static func until(
    today: DateOnly, expected: [ExpectedIncome], links: [ExpectedIncomeLink]
  ) -> DateOnly {
    let linked = Set(links.map(\.expectedIncomeId))
    let horizon = today.adding(months: 3)
    var best: DateOnly?
    for income in expected where !income.closed {
      let dues: [DateOnly]
      switch income.kind {
      case .oneOff:
        guard !linked.contains(income.id) else { continue }
        dues = income.dueDate.map { [$0] } ?? []
      case .recurring:
        dues = ExpectedIncomeRules.dueDates(
          of: income, freq: income.freq ?? .monthly, through: horizon, today: today)
      }
      if let next = dues.filter({ $0 > today }).min(), best.map({ next < $0 }) ?? true {
        best = next
      }
    }
    return best ?? today.monthKey.lastDay
  }

  /// The sheet of `income`. `raise` is left for the caller, who holds the ledger
  /// (`AllocationRaise.detect`).
  public static func sheet(
    income: TransactionEntry, dataset: Dataset, planning: PlanningSnapshot, npd: NPDState,
    dayRates: DayRates, today: DateOnly
  ) -> AllocationSheet {
    let transaction = income.transaction
    let currency = transaction.currency
    let day = transaction.rateDate ?? today
    let tree = CategoryTree(dataset.categories)
    let converter = Converter(
      day: day, dayRates: dayRates, rubPerUnit: planning.rubPerUnit, income: transaction)

    // The tax first.
    var taxE4 = AmountE4.zero
    if let tax = NPDTax.tax(
      of: income, tree: tree, settings: dataset.selfEmployment, dayRates: dayRates,
      deductionLeft: npd.deductionLeftE4)
    {
      taxE4 = converter.convert(tax.taxE4, from: .rub, to: currency) ?? .zero
    }
    let incomeE4 = transaction.amountE4
    let base = max(.zero, incomeE4 - taxE4)
    let earlier = distributed(
      incomeId: income.id, entries: dataset.entries, transfers: dataset.transfers)

    var lines: [AllocationLine] = []
    var shown: [AllocationShown] = []
    let liveGoals = Dictionary(
      dataset.goals.filter { !$0.archived }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let statuses = Dictionary(
      planning.goals.map { ($0.goal.id, $0) }, uniquingKeysWith: { a, _ in a })
    let accounts = Dictionary(
      dataset.paymentMethods.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var goalsWithRule: Set<UUID> = []
    var hasCushionRule = false
    let cushionAccount = cushionAccount(
      dataset: dataset, settings: dataset.allocationSettings, cushion: planning.cushion)
    let cushionMissing = planning.cushion.goal.flatMap { $0.reached ? nil : $0.missingRub }

    func targetCurrency(of accountId: UUID?) -> CurrencyCode {
      guard let accountId, let account = accounts[accountId] else { return currency }
      return account.holds(currency) ? currency : account.mainCurrency
    }

    for rule in dataset.allocationRules.filter(\.active).sorted(by: { $0.sort < $1.sort }) {
      let amount =
        Self.amount(
          of: rule, base: base, incomeCurrency: currency, day: day, dayRates: dayRates)
        ?? .zero
      switch rule.target {
      case .goal(let goalId):
        guard let goal = liveGoals[goalId] else { continue }
        goalsWithRule.insert(goalId)
        var suggested = amount
        var note: AllocationLine.Note?
        if let status = statuses[goalId],
          let missing = converter.convert(status.remaining, from: goal.currency, to: currency),
          missing <= amount
        {
          suggested = missing
          note = .goalCompleteDropRule(rule.id)
        }
        lines.append(
          AllocationLine(
            id: "goal:\(goalId.uuidString)", kind: .goal(goalId), ruleId: rule.id,
            suggestedE4: suggested, targetCurrency: goal.currency,
            transferTo: goal.transfersOnContribution ? goal.accountId : nil, note: note))
      case .account(let accountId):
        guard let account = accounts[accountId], !account.archived else { continue }
        lines.append(
          AllocationLine(
            id: "account:\(accountId.uuidString)", kind: .account(accountId), ruleId: rule.id,
            suggestedE4: amount, targetCurrency: targetCurrency(of: accountId),
            transferTo: accountId))
      case .cushion(let chosen):
        hasCushionRule = true
        let target =
          chosen.flatMap { accounts[$0]?.archived == false ? $0 : nil } ?? cushionAccount
        lines.append(
          cushionLine(
            ruleId: rule.id, amount: amount, account: target,
            missing: cushionMissing.flatMap { converter.convert($0, from: .rub, to: currency) },
            currency: targetCurrency(of: target)))
      }
    }

    // The cushion with a goal and no rule: what the goal asks per month.
    if !hasCushionRule, let goal = planning.cushion.goal, !goal.reached {
      let perMonth = goal.perMonthRub ?? goal.defaultPerMonthRub
      let amount = converter.convert(min(perMonth, goal.missingRub), from: .rub, to: currency)
      lines.append(
        cushionLine(
          ruleId: nil, amount: amount ?? .zero, account: cushionAccount,
          missing: converter.convert(goal.missingRub, from: .rub, to: currency),
          currency: targetCurrency(of: cushionAccount)))
    }

    // Goals with a plan this month still to make, and no rule: their plan as a hint.
    for item in planning.planned.items where item.kind == .goal {
      guard !goalsWithRule.contains(item.id), let goal = liveGoals[item.id], item.amount.raw > 0
      else { continue }
      let amount = converter.convert(item.amount, from: item.currency, to: currency) ?? .zero
      lines.append(
        AllocationLine(
          id: "goal:\(goal.id.uuidString)", kind: .goal(goal.id), suggestedE4: amount,
          targetCurrency: goal.currency,
          transferTo: goal.transfersOnContribution ? goal.accountId : nil,
          note: .goalMissing(item.amount)))
    }

    // The tax: to its account when there is one, else only shown.
    if taxE4.raw > 0 {
      if let taxAccount = dataset.selfEmployment.taxAccountId,
        accounts[taxAccount]?.archived == false
      {
        lines.insert(
          AllocationLine(
            id: "tax", kind: .tax(taxAccount), suggestedE4: taxE4,
            targetCurrency: targetCurrency(of: taxAccount), transferTo: taxAccount),
          at: 0)
      } else {
        shown.append(AllocationShown(kind: .npdTax, amountE4: taxE4))
      }
    }

    // What is spoken for until the next income.
    let until = until(
      today: today, expected: planning.book.expected, links: planning.book.expectedLinks)
    for status in planning.scheduled {
      let dues = status.dueDates.filter {
        $0 >= today && $0 <= until && status.matchedDues[$0] == nil
      }
      for due in dues {
        guard
          let amount = converter.convert(
            SubscriptionMath.price(of: status.payment, on: due, prices: planning.book.prices),
            from: status.payment.currency, to: currency), amount.raw > 0
        else { continue }
        shown.append(
          AllocationShown(kind: .scheduled(status.payment.id, due: due), amountE4: amount))
      }
    }
    for line in planning.debts.iOwe where line.debt.hasDues {
      guard let due = line.nextPayment, due >= today, due <= until else { continue }
      let owed = line.dues.knowing(line.debt).owed(due)
      guard let amount = converter.convert(owed, from: line.debt.currency, to: currency),
        amount.raw > 0
      else { continue }
      shown.append(AllocationShown(kind: .debt(line.debt.id, due: due), amountE4: amount))
    }
    let monthEnd = today.monthKey.lastDay
    let daysLeft = max(1, DayRange(today, monthEnd).dayCount)
    let daysShown = DayRange(today, min(until, monthEnd)).dayCount
    for line in planning.limits where line.budget.scope == .category {
      guard let categoryId = line.budget.categoryId, line.remaining.raw > 0 else { continue }
      let share = line.remaining.decimal * Decimal(daysShown) / Decimal(daysLeft)
      guard let amount = converter.convert(InterestMath.cents(share), from: .rub, to: currency),
        amount.raw > 0
      else { continue }
      shown.append(AllocationShown(kind: .limitLeft(categoryId: categoryId), amountE4: amount))
    }

    let shownTotal = AmountE4.sum(shown.map(\.amountE4))
    return AllocationSheet(
      incomeId: income.id, currency: currency, incomeE4: incomeE4, taxE4: taxE4, baseE4: base,
      earlierE4: earlier, lines: lines, shown: shown, until: until,
      unallocatedE4: incomeE4 - earlier - shownTotal, shownNotWrittenE4: shownTotal,
      overAllocatedE4: earlier > incomeE4 ? earlier - incomeE4 : nil)
  }

  private static func cushionLine(
    ruleId: UUID?, amount: AmountE4, account: UUID?, missing: AmountE4?, currency: CurrencyCode
  ) -> AllocationLine {
    guard let account else {
      return AllocationLine(
        id: "cushion", kind: .cushion(nil), ruleId: ruleId, suggestedE4: .zero,
        targetCurrency: currency, note: .noCushionAccount)
    }
    return AllocationLine(
      id: "cushion", kind: .cushion(account), ruleId: ruleId, suggestedE4: amount,
      targetCurrency: currency, transferTo: account,
      note: missing.flatMap { $0.raw > 0 ? .cushionLeft($0) : nil })
  }

  /// The account the cushion's share goes to: the one the owner chose while it is still a live
  /// account of the cushion, else the only live account of the cushion; `nil` with none or
  /// several — the sheet asks.
  public static func cushionAccount(
    dataset: Dataset, settings: AllocationSettings, cushion: CushionStatus
  ) -> UUID? {
    let live = dataset.paymentMethods.filter { $0.cushion && !$0.archived }.map(\.id)
    if let chosen = settings.cushionAccountId, live.contains(chosen) { return chosen }
    return live.count == 1 ? live[0] : nil
  }

  /// What `rule` takes of `base`, in the currency of the income; `nil` — no rate for a fixed
  /// sum in another currency.
  public static func amount(
    of rule: AllocationRule, base: AmountE4, incomeCurrency: CurrencyCode, day: DateOnly,
    dayRates: DayRates
  ) -> AmountE4? {
    switch rule.amount {
    case .percent(let percent):
      return InterestMath.cents(base.decimal * percent / 100)
    case .fixed(let amount, let currency):
      guard currency != incomeCurrency else { return amount }
      guard let from = dayRates.perUnit(currency, on: day),
        let to = dayRates.perUnit(incomeCurrency, on: day), to > 0
      else { return nil }
      return InterestMath.cents(amount.decimal * from / to)
    }
  }

  /// What the income allocated so far, in its currency: its contributions less what came back
  /// out of them, and its transfers.
  public static func distributed(
    incomeId: UUID, ledger: Ledger, transfers: [Transfer]
  ) -> AmountE4 {
    distributed(incomeId: incomeId, entries: Array(ledger.entries), transfers: transfers)
  }

  public static func distributed(
    incomeId: UUID, entries: [TransactionEntry], transfers: [Transfer]
  ) -> AmountE4 {
    var total = AmountE4.zero
    var contributionKeys: Set<String> = []
    for entry in entries
    where !entry.transaction.isDeleted && belongs(entry.transaction.externalId, to: incomeId) {
      if let key = entry.transaction.externalId { contributionKeys.insert(key) }
      switch entry.transaction.kind {
      case .expense: total += entry.transaction.amountE4
      case .refund: total = total - entry.transaction.amountE4
      case .income, .reimbursement: break
      }
    }
    // A transfer that moved the money of a contribution carries the contribution's own key:
    // the money is allocated once.
    for transfer in transfers where belongs(transfer.externalId, to: incomeId) {
      if let key = transfer.externalId, contributionKeys.contains(key) { continue }
      total += transfer.fromAmountE4
    }
    return total
  }

  /// The contributions and transfers the allocation of the income wrote.
  public static func linked(
    incomeId: UUID, ledger: Ledger, transfers: [Transfer]
  ) -> (contributions: [UUID], transfers: [UUID]) {
    linked(incomeId: incomeId, entries: Array(ledger.entries), transfers: transfers)
  }

  public static func linked(
    incomeId: UUID, entries: [TransactionEntry], transfers: [Transfer]
  ) -> (contributions: [UUID], transfers: [UUID]) {
    let contributions = entries.filter {
      !$0.transaction.isDeleted && belongs($0.transaction.externalId, to: incomeId)
    }.map(\.id)
    let moved = transfers.filter { belongs($0.externalId, to: incomeId) }.map(\.id)
    return (
      contributions.sorted { $0.uuidString < $1.uuidString },
      moved.sorted { $0.uuidString < $1.uuidString }
    )
  }

  /// `alloc:<income>:<uuid>`.
  public static func externalId(incomeId: UUID, uuid: UUID) -> String {
    "alloc:\(incomeId.uuidString):\(uuid.uuidString)"
  }

  /// The income an `alloc:` key names; `nil` for anything else.
  public static func income(ofKey externalId: String?) -> UUID? {
    guard let externalId, externalId.hasPrefix("alloc:") else { return nil }
    let fields = externalId.split(separator: ":")
    guard fields.count == 3 else { return nil }
    return UUID(uuidString: String(fields[1]))
  }

  static func belongs(_ externalId: String?, to incomeId: UUID) -> Bool {
    income(ofKey: externalId) == incomeId
  }

  /// The contributions and transfers of the lines chosen, `chosen` by line id; a line not
  /// chosen, or chosen at zero or less, writes nothing. A line of a goal writes a contribution
  /// from the account of the income — the goal's own subcategory, `good`, at the rate of the
  /// income —, and a transfer to `transferTo` when the line has one; a goal whose «transfer on
  /// contribution» the line says otherwise comes back changed, to be written in the same
  /// record. Every other line writes a transfer to its account, none to the account of the
  /// income itself. The caller gives the income its account (the main one when it names none).
  /// Everything is dated a second after the income and carries `alloc:<income>:<uuid>`; the
  /// transfer that moves the money of a contribution carries the contribution's own key.
  public static func write(
    sheet: AllocationSheet, chosen: [String: AmountE4], income: TransactionEntry, goals: [Goal],
    ids: () -> UUID
  ) -> AllocationWrite {
    let transaction = income.transaction
    let at = transaction.occurredAt.addingTimeInterval(1)
    let from = transaction.paymentMethodId
    var result = AllocationWrite()
    func rubles(_ amount: AmountE4) -> AmountE4 {
      guard transaction.amountE4.raw != 0 else { return amount }
      return InterestMath.cents(
        amount.decimal * transaction.amountRubE4.decimal / transaction.amountE4.decimal)
    }
    func transfer(
      _ amount: AmountE4, to account: UUID, currency: CurrencyCode, key: String? = nil
    ) {
      guard let from, from != account || currency != transaction.currency else { return }
      let toAmount: AmountE4
      let toCurrency: CurrencyCode
      if currency == transaction.currency {
        (toAmount, toCurrency) = (amount, currency)
      } else if currency == .rub {
        (toAmount, toCurrency) = (rubles(amount), .rub)
      } else {
        (toAmount, toCurrency) = (amount, transaction.currency)
      }
      result.transfers.append(
        Transfer(
          id: ids(), occurredAt: at, fromAccountId: from, fromCurrency: transaction.currency,
          fromAmountE4: amount, toAccountId: account, toCurrency: toCurrency,
          toAmountE4: toAmount, createdAt: at, updatedAt: at,
          externalId: key ?? externalId(incomeId: income.id, uuid: ids())))
    }
    for line in sheet.lines {
      guard let amount = chosen[line.id], amount.raw > 0 else { continue }
      switch line.kind {
      case .goal(let goalId):
        guard var goal = goals.first(where: { $0.id == goalId }) else { continue }
        let id = ids()
        let decision = QualityResolver.resolve(goalId: goal.id, categoryId: goal.subcategoryId)
        var contribution = Transaction(
          id: id, kind: .expense, occurredAt: at, currency: transaction.currency,
          amountE4: amount, rate: transaction.rate, rateDate: transaction.rateDate,
          rateSource: transaction.rateSource, rateProvisional: transaction.rateProvisional,
          amountRubE4: rubles(amount), paymentMethodId: from,
          externalId: externalId(incomeId: income.id, uuid: ids()), createdAt: at, updatedAt: at)
        if let accountCurrency = transaction.accountCurrency,
          let moved = transaction.accountAmountE4, transaction.amountE4.raw != 0
        {
          contribution.accountCurrency = accountCurrency
          contribution.accountAmountE4 = InterestMath.cents(
            moved.decimal * amount.decimal / transaction.amountE4.decimal)
        }
        let part = TransactionPart(
          transactionId: id, categoryId: goal.subcategoryId, categorySource: .system,
          quality: decision.quality, qualitySource: decision.source, amountE4: amount,
          amountRubE4: contribution.amountRubE4, goalId: goal.id)
        result.contributions.append(TransactionEntry(transaction: contribution, parts: [part]))
        if let account = line.transferTo {
          // The contribution's key: the transfer moves the money of the contribution.
          transfer(
            amount, to: account, currency: line.targetCurrency, key: contribution.externalId)
        }
        let wantsTransfer = line.transferTo != nil
        if goal.accountId != nil, wantsTransfer != goal.transfersOnContribution {
          goal.transfersOnContribution = wantsTransfer
          result.goals.append(goal)
        }
      case .account(let account), .cushion(.some(let account)), .tax(.some(let account)):
        transfer(amount, to: account, currency: line.targetCurrency)
      case .cushion(.none), .tax(.none):
        continue
      }
    }
    return result
  }
}

/// Amounts of one sheet between currencies: at the rate of the Bank of Russia of the day of
/// the income, else at the last rate known, else — for the income's own currency against the
/// ruble — at the rate the income was written at.
private struct Converter {
  var day: DateOnly
  var dayRates: DayRates
  var rubPerUnit: [CurrencyCode: Decimal]
  var income: Transaction

  func rate(_ currency: CurrencyCode) -> Decimal? {
    if currency == .rub { return 1 }
    if let rate = dayRates.perUnit(currency, on: day), rate > 0 { return rate }
    if let rate = rubPerUnit[currency], rate > 0 { return rate }
    if currency == income.currency, income.amountE4.raw != 0 {
      return income.amountRubE4.decimal / income.amountE4.decimal
    }
    return nil
  }

  func convert(_ amount: AmountE4, from: CurrencyCode, to: CurrencyCode) -> AmountE4? {
    guard from != to else { return amount }
    guard let fromRate = rate(from), let toRate = rate(to), toRate > 0 else { return nil }
    return InterestMath.cents(amount.decimal * fromRate / toRate)
  }
}
