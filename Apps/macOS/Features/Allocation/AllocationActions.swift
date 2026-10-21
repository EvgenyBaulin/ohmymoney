import AppCore
import AppDatabase
import Foundation

/// The words of the allocation and of self-employment, from their own table.
@MainActor
enum AllocationText {
  static let table = "Allocation"

  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: table)
  }

  static func format(
    _ key: String, _ environment: AppEnvironment, _ arguments: CVarArg...
  ) -> String {
    String(
      format: environment.language(key, table: table), locale: environment.language.locale,
      arguments: arguments)
  }
}

/// What opens the sheet of an income: «Распределить…» under the entry line, in the menu of a
/// row, in «Стоит посмотреть». `.sheet(item:)` with `AllocationSheetView(request:)`.
struct AllocationRequest: Identifiable, Hashable {
  var incomeId: UUID
  var id: UUID { incomeId }
}

/// The actions of the allocation of income. Each asks the rules of the core what to write
/// (`Allocation`, `MonthRest`) and hands it to the store as one `PlanningChange`: one write,
/// one step of ⌘Z. The rules that make a change are static, so a test can read them alone.
@MainActor
struct AllocationActions {
  let environment: AppEnvironment
  let store: TransactionsStore
  let snapshot: DataSnapshot?

  init(_ deps: AppDependencies) {
    environment = deps.environment
    store = deps.store
    snapshot = deps.compute.snapshot
  }

  /// How long a declined income is remembered: past it, it is no longer offered anyway.
  static let declinedDays = 60

  // MARK: Rules

  /// The income as the allocation writes from it: on the main account when it names none.
  static func incomeWithAccount(
    _ entry: TransactionEntry, accounts: [PaymentMethod]
  )
    -> TransactionEntry
  {
    guard entry.transaction.paymentMethodId == nil else { return entry }
    var copy = entry
    copy.transaction.paymentMethodId = accounts.first { $0.isDefault && !$0.archived }?.id
    return copy
  }

  /// The sheet of an income from a snapshot, with the raise worked out over its ledger; `nil`
  /// for what is not a live income.
  static func sheet(for incomeId: UUID, snapshot: DataSnapshot) -> AllocationSheet? {
    guard let entry = snapshot.ledger.entry(incomeId), entry.transaction.kind == .income,
      !entry.transaction.isDeleted
    else { return nil }
    let planning = snapshot.planning
    var sheet = Allocation.sheet(
      income: entry, dataset: snapshot.dataset, planning: planning,
      npd: planning.npd ?? .empty(today: snapshot.today), dayRates: snapshot.context.dayRates,
      today: snapshot.today)
    sheet.raise = AllocationRaise.detect(
      income: entry, ledger: snapshot.ledger, links: planning.book.expectedLinks)
    return sheet
  }

  /// «Разложить разницу»: the difference of a raise over the lines of rules, in proportion to
  /// what each suggests; the last line takes what rounding leaves.
  static func spreading(_ difference: AmountE4, over lines: [AllocationLine]) -> [String: AmountE4]
  {
    let ruled = lines.filter { $0.ruleId != nil && $0.suggestedE4.raw > 0 }
    let total = AmountE4.sum(ruled.map(\.suggestedE4))
    guard total.raw > 0 else { return [:] }
    var result: [String: AmountE4] = [:]
    var given = AmountE4.zero
    for (index, line) in ruled.enumerated() {
      let share: AmountE4
      if index == ruled.count - 1 {
        share = difference - given
      } else {
        share = InterestMath.cents(
          difference.decimal * line.suggestedE4.decimal / total.decimal)
      }
      given += share
      result[line.id] = share
    }
    return result
  }

  /// The change that writes what the sheet chose, or `nil` when nothing is chosen. A goal
  /// without its subcategory gets it in the same change; the account of the cushion the owner
  /// picked is remembered with it (`allocation.cushionAccount`).
  static func change(
    sheet: AllocationSheet, chosen: [String: AmountE4], snapshot: DataSnapshot,
    cushionAccount: UUID?, at moment: Date, ids: () -> UUID = { UUID() }
  ) -> PlanningChange? {
    guard let entry = snapshot.ledger.entry(sheet.incomeId) else { return nil }
    let income = incomeWithAccount(entry, accounts: snapshot.dataset.paymentMethods)
    var goals = snapshot.dataset.goals
    var categories: [CoreKit.Category] = []
    var tree = snapshot.ledger.tree
    for index in goals.indices where goals[index].subcategoryId == nil {
      guard sheet.lines.contains(where: { $0.kind == .goal(goals[index].id) }),
        let made = SystemSubcategories.goalSubcategory(for: goals[index], tree: tree)
      else { continue }
      goals[index].subcategoryId = made.id
      categories.append(made)
      tree = CategoryTree(snapshot.dataset.categories + categories)
    }
    var lines = sheet
    if let cushionAccount {
      for index in lines.lines.indices where lines.lines[index].kind == .cushion(nil) {
        lines.lines[index].kind = .cushion(cushionAccount)
        lines.lines[index].transferTo = cushionAccount
      }
    }
    let write = Allocation.write(
      sheet: lines, chosen: chosen, income: income, goals: goals, ids: ids)
    guard !write.contributions.isEmpty || !write.transfers.isEmpty || !write.goals.isEmpty
    else { return nil }
    var allocation = write
    // A goal that got its subcategory now is written with it, whatever else changed of it.
    for goal in goals where categories.contains(where: { $0.id == goal.subcategoryId }) {
      if let index = allocation.goals.firstIndex(where: { $0.id == goal.id }) {
        allocation.goals[index].subcategoryId = goal.subcategoryId
      } else {
        allocation.goals.append(goal)
      }
    }
    var settings: [String: String?] = [:]
    if let cushionAccount {
      settings.updateValue(cushionAccount.uuidString, forKey: AllocationSettings.cushionAccountKey)
    }
    return AllocationRepository.change(
      for: allocation, categories: categories, settings: settings, at: moment)
  }

  /// The settings after «Не надо» for `incomeId`: it joins the declined ones, and those whose
  /// income is gone or older than `declinedDays` days are let go.
  static func declining(
    _ incomeId: UUID, settings: AllocationSettings, ledger: Ledger, today: DateOnly
  ) -> AllocationSettings {
    var settings = settings
    let oldest = today.adding(days: -declinedDays)
    settings.declined = (settings.declined + [incomeId]).filter { id in
      guard let entry = ledger.entry(id) else { return id == incomeId }
      return ledger.calendar.day(of: entry.transaction.occurredAt) >= oldest
    }
    var seen: Set<UUID> = []
    settings.declined = settings.declined.filter { seen.insert($0).inserted }
    return settings
  }

  /// What the rest of the month writes: a transfer to the cushion's account, or a contribution
  /// to the goal (with its transfer when the goal asks), from the main account, now; the month
  /// marked done and the place remembered. `nil` when there is nowhere to put it.
  static func monthRestChange(
    _ offer: MonthRestOffer, to target: MonthRestTarget, amount: AmountE4,
    cushionAccount: UUID?, snapshot: DataSnapshot, at moment: Date, ids: () -> UUID = { UUID() }
  ) -> PlanningChange? {
    guard amount.raw > 0,
      let main = snapshot.dataset.paymentMethods.first(where: { $0.isDefault && !$0.archived })
    else { return nil }
    var settings = snapshot.dataset.allocationSettings
    settings.monthRestDone = offer.month
    settings.monthRestTarget = target
    let key = Allocation.externalId(incomeId: offer.month.firstDay.monthRestId, uuid: ids())
    switch target {
    case .cushion:
      guard let account = cushionAccount, account != main.id else { return nil }
      let transfer = Transfer(
        occurredAt: moment, fromAccountId: main.id, fromCurrency: main.mainCurrency,
        fromAmountE4: amount, toAccountId: account, toCurrency: main.mainCurrency,
        toAmountE4: amount, createdAt: moment, updatedAt: moment, externalId: key)
      settings.cushionAccountId = account
      return PlanningChange(
        upsert: PlanningRows(transfers: [transfer]), settings: settings.storedValues, at: moment)
    case .goal(let goalId):
      guard var goal = snapshot.dataset.goals.first(where: { $0.id == goalId && !$0.archived })
      else { return nil }
      var categories: [CoreKit.Category] = []
      if goal.subcategoryId == nil,
        let made = SystemSubcategories.goalSubcategory(for: goal, tree: snapshot.ledger.tree)
      {
        goal.subcategoryId = made.id
        categories.append(made)
      }
      let id = ids()
      let decision = QualityResolver.resolve(goalId: goal.id, categoryId: goal.subcategoryId)
      let contribution = TransactionEntry(
        transaction: Transaction(
          id: id, kind: .expense, occurredAt: moment, currency: .rub, amountE4: amount,
          paymentMethodId: main.id, externalId: key, createdAt: moment, updatedAt: moment),
        parts: [
          TransactionPart(
            transactionId: id, categoryId: goal.subcategoryId, categorySource: .system,
            quality: decision.quality, qualitySource: decision.source, amountE4: amount,
            goalId: goal.id)
        ])
      var rows = PlanningRows.empty
      rows.categories = categories
      if !categories.isEmpty { rows.goals = [goal] }
      if goal.transfersOnContribution, let account = goal.accountId, account != main.id {
        rows.transfers = [
          Transfer(
            occurredAt: moment, fromAccountId: main.id, fromCurrency: .rub, fromAmountE4: amount,
            toAccountId: account, toCurrency: .rub, toAmountE4: amount, createdAt: moment,
            updatedAt: moment, externalId: key)
        ]
      }
      return PlanningChange(
        created: [contribution], upsert: rows, settings: settings.storedValues, at: moment)
    }
  }

  // MARK: Actions

  /// «Записать».
  @discardableResult
  func write(sheet: AllocationSheet, chosen: [String: AmountE4], cushionAccount: UUID?) -> Bool {
    guard let snapshot,
      let change = Self.change(
        sheet: sheet, chosen: chosen, snapshot: snapshot, cushionAccount: cushionAccount,
        at: environment.now())
    else { return false }
    guard store.apply(change) else { return false }
    AppLog.info(
      "allocation.written", .db, "an income was allocated",
      [
        LogPair("income", .id(sheet.incomeId)),
        LogPair("contributions", .count(change.created.count)),
        LogPair("transfers", .count(change.upsert.transfers.count)),
      ])
    return true
  }

  /// «Не надо»: the income is no longer offered. A setting of the database, one step of ⌘Z
  /// like every setting of the planning.
  @discardableResult
  func decline(_ incomeId: UUID) -> Bool {
    guard let snapshot else { return false }
    let settings = Self.declining(
      incomeId, settings: snapshot.dataset.allocationSettings, ledger: snapshot.ledger,
      today: environment.today)
    guard store.apply(PlanningChange(settings: settings.storedValues, at: environment.now()))
    else { return false }
    AppLog.info(
      "allocation.declined", .db, "an income is not to be allocated",
      [LogPair("income", .id(incomeId))])
    return true
  }

  /// A rule saved or several at once (the order of the list).
  @discardableResult
  func save(rules: [AllocationRule], deleting: [UUID] = []) -> Bool {
    guard store.apply(AllocationRepository.rules(saving: rules, deleting: deleting)) else {
      return false
    }
    AppLog.info(
      "allocation.rules.saved", .db, "the rules of allocation changed",
      [LogPair("saved", .count(rules.count)), LogPair("deleted", .count(deleting.count))])
    return true
  }

  /// «Цель собрана — убрать правило?»
  @discardableResult
  func dropRule(_ ruleId: UUID) -> Bool { save(rules: [], deleting: [ruleId]) }

  /// The rest of the month put where the owner said.
  @discardableResult
  func allocate(
    _ offer: MonthRestOffer, to target: MonthRestTarget, amount: AmountE4, cushionAccount: UUID?
  ) -> Bool {
    guard let snapshot,
      let change = Self.monthRestChange(
        offer, to: target, amount: amount, cushionAccount: cushionAccount, snapshot: snapshot,
        at: environment.now())
    else { return false }
    guard store.apply(change) else { return false }
    AppLog.info(
      "allocation.written", .db, "the rest of a month was allocated",
      [
        LogPair("contributions", .count(change.created.count)),
        LogPair("transfers", .count(change.upsert.transfers.count)),
      ])
    return true
  }

  /// «Не надо» of the rest of the month.
  @discardableResult
  func decline(_ offer: MonthRestOffer) -> Bool {
    guard let snapshot else { return false }
    var settings = snapshot.dataset.allocationSettings
    settings.monthRestDone = offer.month
    guard store.apply(PlanningChange(settings: settings.storedValues, at: environment.now()))
    else { return false }
    AppLog.info("allocation.declined", .db, "the rest of a month is not to be allocated", [])
    return true
  }
}

extension DateOnly {
  /// The id the allocation of the rest of a month is keyed by: a stable id of its month, so
  /// what one month's rest wrote can be found again.
  fileprivate var monthRestId: UUID {
    let text = String(format: "00000000-0000-4000-8000-%04d%02d000000", year, month)
    return UUID(uuidString: text) ?? UUID()
  }
}
