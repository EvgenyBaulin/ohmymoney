import AppCore
import Foundation

/// What the page of the year needs on top of the calculations of `AnalysisFacade+Later`: the plan
/// itself with its inputs read from the snapshot the way the planning screens read them, the
/// yearly expenses and the property taxes found in the spending of the ledger.
extension YearAnalysisFacade {
  /// The plan of the twelve months of `window`: payments, expected income (through the end of the
  /// window, not only of this month), the plans of goals and the budgets of events. The six
  /// complete months before today give the grey guess of an income nothing is expected for.
  func plan(_ snapshot: DataSnapshot, window: YearWindow) async throws -> YearPlan {
    try await core.cached("year.plan|\(window)", snapshot) {
      YearPlanInputs.plan(snapshot, window: window)
    }
  }

  /// «Похоже, в марте снова страховка» — the yearly expenses coming within two months, without
  /// those a goal already saves for and those put off.
  func yearlyExpenses(
    _ snapshot: DataSnapshot, dismissed: Set<String> = []
  ) async throws -> [YearlyExpense] {
    try await core.cached("year.yearly|\(dismissed.sorted())", snapshot) {
      YearPlanInputs.yearlyExpenses(snapshot, dismissed: dismissed)
    }
  }

  /// «В прошлом году был налог 8 000 ₽ — запланировать?» in November.
  func propertyTax(
    _ snapshot: DataSnapshot, dismissed: Set<String> = []
  ) async throws -> [PropertyTaxHint] {
    try await core.cached("year.tax|\(dismissed.sorted())", snapshot) {
      YearPlanInputs.propertyTax(snapshot, dismissed: dismissed)
    }
  }
}

/// The reading of a snapshot into the inputs of the year rules. Pure functions of the snapshot,
/// so a test builds the same values the screen shows.
enum YearPlanInputs {
  static func plan(_ snapshot: DataSnapshot, window: YearWindow) -> YearPlan {
    let ledger = snapshot.ledger
    let today = snapshot.today
    let rates = snapshot.context.rubPerUnit
    let book = snapshot.dataset.planning
    let last = window.months.last?.lastDay ?? today.monthKey.lastDay
    let expected = ExpectedIncomeRules.statuses(
      book: book, ledger: ledger, today: today, rubPerUnit: rates, through: last)
    let start = IncomeEstimate.historyStart(firstDay: ledger.firstDay)
    // The complete months of income the guess is the median of: up to six, none before the first
    // day of the history.
    let current = today.monthKey
    var history: [MonthKey] = []
    if let start, start < current {
      history = MonthKey.range(
        max(start, current.adding(months: -YearPlan.estimateMonths)), through: current.previous)
    }
    var income: [MonthKey: AmountE4] = [:]
    for month in history { income[month] = ledger.income(attributedTo: [month]) }
    let inputs = YearPlan.Inputs(
      scheduled: book.scheduled, prices: book.prices, expected: expected,
      goals: snapshot.planning.goals,
      events: EventPlanning.plans(ledger: ledger, today: today), incomeByMonth: income,
      historyStart: start,
      receivedThisMonth: ledger.income(attributedTo: [today.monthKey], notAfter: today),
      rubPerUnit: rates)
    return YearPlan.build(window: window, today: today, inputs: inputs)
  }

  /// My spending, one record per row, in rubles: what the history of the year counts.
  static func yearlyRecords(_ ledger: Ledger) -> [YearlyRecord] {
    ledger.rows.compactMap { row in
      guard row.contribution.raw > 0, !row.isGoalContribution, row.debtId == nil,
        row.systemRole == nil, row.link?.isBookkeeping != true
      else { return nil }
      return YearlyRecord(
        day: row.day, amount: row.contribution, categoryId: row.categoryId, placeId: row.placeId,
        title: ledger.entry(row.transactionId)?.transaction.note ?? "")
    }
  }

  /// The expenses a goal already saves for: a live goal of the same name with its date in the
  /// month the expense is expected in.
  static func covered(by goals: [Goal], expenses: [YearlyExpense]) -> Set<YearlyKey> {
    var keys: Set<YearlyKey> = []
    for expense in expenses {
      let name = NameKey.fold(expense.title)
      guard !name.isEmpty else { continue }
      let saving = goals.contains { goal in
        !goal.archived && NameKey.fold(goal.name) == name
          && goal.targetDate?.monthKey == expense.expectedDate.monthKey
      }
      if saving { keys.insert(expense.key) }
    }
    return keys
  }

  static func yearlyExpenses(
    _ snapshot: DataSnapshot, dismissed: Set<String>
  ) -> [YearlyExpense] {
    let records = yearlyRecords(snapshot.ledger)
    let found = YearlyExpenseFinder.find(records: records)
    return YearlyExpenseFinder.suggestions(
      records: records, today: snapshot.today,
      covered: covered(by: snapshot.dataset.goals, expenses: found), dismissed: dismissed)
  }

  /// The category the property taxes are filed under, whichever language it is named in.
  static let taxesNames: Set<String> = [
    NameKey.fold("Налоги и сборы"), NameKey.fold("Taxes & fees"),
  ]

  /// Payments under «Налоги и сборы»; the self-employed tax (the category the app pays it in, and
  /// the operations it keyed `npd:` and `tax:`) is no property tax and stays out.
  static func taxRecords(_ ledger: Ledger) -> [TaxRecord] {
    let tree = ledger.tree
    let own = ledger.dataset.selfEmployment.taxCategoryId
    return ledger.rows.compactMap { row in
      guard row.contribution.raw > 0, row.categoryId != own,
        let root = tree.root(of: row.categoryId), taxesNames.contains(NameKey.fold(root.name))
      else { return nil }
      let key = ledger.entry(row.transactionId)?.transaction.externalId ?? ""
      guard !key.hasPrefix("npd:"), !key.hasPrefix("tax:") else { return nil }
      return TaxRecord(
        day: row.day, amount: row.contribution, categoryId: row.categoryId,
        title: ledger.entry(row.transactionId)?.transaction.note
          ?? tree.category(row.categoryId)?.name ?? "")
    }
  }

  static func propertyTax(_ snapshot: DataSnapshot, dismissed: Set<String>) -> [PropertyTaxHint] {
    PropertyTaxHints.hints(
      records: taxRecords(snapshot.ledger), today: snapshot.today,
      planned: snapshot.dataset.planning.scheduled, dismissed: dismissed)
  }

  /// The free sum to the end of the month, with the buffer that is left already held back (it is
  /// a line of the free sum, like the budget of an event); `nil` while no account is counted.
  static func freeToMonthEnd(_ snapshot: DataSnapshot) -> AmountE4? {
    let free = snapshot.planning.freeMoney(
      until: snapshot.today.monthKey.lastDay, ledger: snapshot.ledger)
    return free.grey ?? free.main
  }

  /// «Свободно на эту неделю»: what is left of the free sum shared over the weeks that remain in
  /// the month (the weeks start on the one day the whole app starts them on).
  static func week(_ snapshot: DataSnapshot, firstWeekday: Int) -> WeekBudget? {
    guard let free = freeToMonthEnd(snapshot) else { return nil }
    return WeekBudget.compute(
      freeToMonthEnd: free, today: snapshot.today, firstWeekday: firstWeekday)
  }

  /// The income of this month, received and still expected: the figure the buffer is judged
  /// against («доход вырос больше чем на 10 %»).
  static func incomeNow(_ snapshot: DataSnapshot) -> AmountE4 {
    let estimate = snapshot.planning.income
    return estimate.value ?? (estimate.received + estimate.expectedRemaining)
  }
}
