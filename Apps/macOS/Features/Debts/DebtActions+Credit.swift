import AppCore
import AppDatabase
import Foundation

/// The actions of the debts this version brought: instalment plans and purchases on credit made
/// from the Debts section, the costs of a loan, the sums typed from the bank's app, a planned
/// early repayment, the ladder, a pledge written off, the polite reminder, the review of old
/// debts and a credit card kept only as an account. One write and one step of ⌘Z each.
extension DebtActions {
  // MARK: A purchase in instalments or on credit

  /// What a purchase made on a plan is: the price, the account and category it is spent from,
  /// and the terms of the plan.
  struct Purchase {
    var name: String
    var price: AmountE4
    var currency: CurrencyCode
    var day: DateOnly
    var categoryId: UUID?
    var account: UUID?
    /// «Рассрочка»: the number of parts; `nil` — a purchase on credit paid monthly.
    var parts: Int?
    /// Days between parts; `nil` — on `paymentDay` of every month.
    var everyDays: Int?
    var paymentDay: Int?
    var markup: AmountE4?
    /// A purchase on credit: what a month asks.
    var monthly: AmountE4?
  }

  /// A purchase made on an instalment plan or on credit: the purchase, spent once at its price
  /// in its category on the plan (`creditDebtId` — no money moves), the debt and its first line
  /// (the price and the markup, `InstalmentPlan.make`, or the price for a purchase on credit).
  /// The debt is written with its terms seen. One write, one step of ⌘Z.
  @discardableResult
  func createPurchase(_ purchase: Purchase) -> Bool {
    let environment = planning.environment
    let name = purchase.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, purchase.price.raw > 0 else { return false }
    let accounts = (snapshot?.dataset.paymentMethods ?? []).filter { !$0.archived }
    let debtId = UUID()
    var draft = TransactionDraft(
      kind: .expense,
      occurredAt: environment.calendar.startOfDay(purchase.day).addingTimeInterval(12 * 3600),
      currency: purchase.currency, amount: purchase.price, note: name,
      paymentMethodId: FormAccounts.account(purchase.account, among: accounts)?.id
        ?? purchase.account,
      creditDebtId: debtId)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = purchase.categoryId
    guard let entry = try? planning.operation(draft, link: nil) else { return false }
    let debt: Debt
    let line: DebtEntry
    if let parts = purchase.parts {
      (debt, line) = InstalmentPlan.make(
        purchase: entry, price: purchase.price, count: parts, everyDays: purchase.everyDays,
        paymentDay: purchase.paymentDay, markup: purchase.markup, name: name, id: debtId,
        calendar: environment.calendar)
    } else {
      debt = Debt(
        id: debtId, direction: .iOwe, type: .installment, name: name,
        currency: purchase.currency,
        monthlyPaymentE4: purchase.monthly.flatMap { $0.raw > 0 ? $0 : nil },
        paymentDay: purchase.monthly == nil ? nil : (purchase.paymentDay ?? purchase.day.day),
        paymentsAreExpenses: false, origin: .purchase, termsReviewed: true)
      guard
        let opening = try? DebtRules.creditPurchaseOpening(
          on: debt, amountE4: purchase.price, date: purchase.day, transactionId: entry.id)
      else { return false }
      line = opening
    }
    var rows = PlanningRows.empty
    rows.debts = [debt]
    rows.debtEntries = [line]
    guard apply(PlanningChange(created: [entry], upsert: rows)) else {
      AppLog.error(
        "debts.instalment.failed", .db, "a purchase on a plan was not written",
        [LogPair("debt", .id(debtId))])
      return false
    }
    AppLog.info(
      "debts.instalment.created", .db, "a purchase on a plan was written",
      [LogPair("debt", .id(debtId)), LogPair("parts", .count(purchase.parts ?? 0))])
    return true
  }

  // MARK: The costs of a loan

  /// The expenses of the costs paid once apart from the loan, added to `rows` with the costs:
  /// insurance in «Страховка» (live at the top, else made), a fee or anything else in the debt's
  /// subcategory of «Кредиты»; each keyed `debtcost:<cost>` and named by its cost
  /// (`transaction_id`). A cost held back from the loan is in its first line instead, and a
  /// periodic cost is not spent ahead.
  func costOperations(
    _ debt: Debt, costs: [DebtCost], account: UUID?, rows: inout PlanningRows
  ) -> [TransactionEntry] {
    let environment = planning.environment
    let accounts = (snapshot?.dataset.paymentMethods ?? []).filter { !$0.archived }
    var written: [TransactionEntry] = []
    for var cost in costs {
      cost.debtId = debt.id
      if cost.every == .once, !cost.inLoan, cost.transactionId == nil {
        let category =
          cost.kind == .insurance
          ? insuranceCategory(rows: &rows)
          : (debt.loansSubcategoryId ?? snapshot?.ledger.tree.systemCategory(.loans)?.id)
        var draft = TransactionDraft(
          kind: .expense,
          occurredAt: environment.calendar.startOfDay(cost.day).addingTimeInterval(12 * 3600),
          currency: debt.currency, amount: cost.amountE4,
          note: DebtRules.cleaned(cost.name) ?? costName(cost.kind, debt: debt),
          paymentMethodId: FormAccounts.account(account, among: accounts)?.id ?? account)
        draft.normalizeSinglePart()
        draft.parts[0].categoryId = category
        draft.parts[0].categorySource = .system
        if var entry = try? planning.operation(draft, link: nil) {
          entry.transaction.externalId = "debtcost:" + cost.id.uuidString.lowercased()
          cost.transactionId = entry.id
          written.append(entry)
        }
      }
      rows.debtCosts.append(cost)
    }
    return written
  }

  /// «Добавить комиссии и страховку» of a loan written before: the costs, and the expenses of
  /// those paid once apart. A cost held back from the loan grows its debt by an `adjustment`.
  /// With `savingDebt` the debt is written too, in the same step — its full cost of credit.
  @discardableResult
  func addCosts(
    _ debt: Debt, costs: [DebtCost], account: UUID? = nil, savingDebt: Bool = false
  ) -> Bool {
    guard !costs.isEmpty || savingDebt else { return false }
    var rows = PlanningRows.empty
    if savingDebt { rows.debts = [debt] }
    let created = costOperations(debt, costs: costs, account: account, rows: &rows)
    for cost in rows.debtCosts where cost.inLoan && cost.every == .once {
      if let line = try? DebtRules.growth(
        on: debt, amountE4: cost.amountE4, date: cost.day,
        description: DebtRules.cleaned(cost.name) ?? costName(cost.kind, debt: debt))
      {
        rows.debtEntries.append(line)
      }
    }
    guard apply(PlanningChange(created: created, upsert: rows)) else { return false }
    AppLog.info(
      "debts.costs.saved", .db, "the costs of a loan were saved",
      [LogPair("debt", .id(debt.id)), LogPair("costs", .count(costs.count))])
    return true
  }

  /// A cost taken away; the expense of one paid once goes with it.
  @discardableResult
  func removeCost(_ cost: DebtCost) -> Bool {
    var delete = PlanningRowIDs.empty
    delete.debtCosts = [cost.id]
    return apply(
      PlanningChange(
        delete: delete, softDeleted: cost.transactionId.map { [$0] } ?? []))
  }

  /// The words of a cost without a name of its own.
  func costName(_ kind: DebtCostKind, debt: Debt) -> String {
    planning.environment.format("costs.kind.\(kind.rawValue).note", table: "Debts", debt.name)
  }

  /// «Страховка»: the live expense category of that name at the top, else a new one added to
  /// `rows`.
  func insuranceCategory(rows: inout PlanningRows) -> UUID {
    let categories =
      (try? planning.environment.references?.categories()) ?? snapshot?.dataset.categories ?? []
    let names: Set<String> = [NameKey.fold("Страховка"), NameKey.fold("Insurance")]
    if let found = categories.first(where: {
      $0.kind == .expense && !$0.archived && $0.systemRole == nil && $0.parentId == nil
        && names.contains(NameKey.fold($0.name))
    }) {
      return found.id
    }
    if let made = rows.categories.first(where: { names.contains(NameKey.fold($0.name)) }) {
      return made.id
    }
    let made = CoreKit.Category(
      kind: .expense,
      name: planning.environment.language("costs.category.insurance", table: "Debts"),
      quality: .neutral)
    rows.categories.append(made)
    return made.id
  }

  // MARK: Sums typed from the bank's app, a planned early repayment, the terms

  /// «Вписать платёж из приложения банка…»: what the due of index `fromIndex` and the ones after
  /// it ask, as the bank says. A step on the same due is replaced; an amount of nothing takes the
  /// typed step away.
  @discardableResult
  func typeInstalment(_ debt: Debt, fromIndex: Int, amount: AmountE4?) -> Bool {
    let existing = (snapshot?.dataset.debtInstalments ?? []).filter {
      $0.debtId == debt.id && $0.fromIndex == fromIndex
    }
    var rows = PlanningRows.empty
    var delete = PlanningRowIDs.empty
    if let amount, amount.raw >= 0 {
      rows.debtInstalments = [
        DebtInstalmentStep(
          id: existing.first?.id ?? UUID(), debtId: debt.id, fromIndex: max(0, fromIndex),
          amountE4: amount)
      ]
    } else {
      guard !existing.isEmpty else { return false }
      delete.debtInstalments = existing.map(\.id)
    }
    return apply(PlanningChange(upsert: rows, delete: delete))
  }

  /// «Запланировать досрочку…»: the day and the sum, or none. Not money — a reminder to file the
  /// application and a step of the ladder.
  @discardableResult
  func planPrepay(_ debt: Debt, _ planned: PlannedPrepay?, noticeDays: Int?) -> Bool {
    var changed = debt
    changed.plannedPrepay = planned
    changed.prepayNoticeDays = noticeDays.map { min(max($0, 0), 90) }
    return save(changed)
  }

  /// The debt with the terms of this version the owner answered, and seen: «Сохранить» and «Не
  /// нужно» of the review, one step of ⌘Z each, with the costs answered.
  @discardableResult
  func review(_ debt: Debt, costs: [DebtCost] = []) -> Bool {
    var seen = debt
    seen.termsReviewed = true
    var rows = PlanningRows.empty
    rows.debts = [seen]
    let created = costOperations(seen, costs: costs, account: nil, rows: &rows)
    guard apply(PlanningChange(created: created, upsert: rows)) else { return false }
    AppLog.info(
      "debts.review.answered", .db, "an old debt was reviewed", [LogPair("debt", .id(debt.id))])
    return true
  }

  /// «Это рассрочка частями?» answered for a purchase on credit: its parts, step and markup. The
  /// markup grows the debt (`adjustment`); the debt is seen.
  @discardableResult
  func makeInstalmentPlan(
    _ debt: Debt, parts: Int, everyDays: Int?, firstDue: DateOnly, markup: AmountE4?
  ) -> Bool {
    var plan = debt
    plan.parts = min(max(parts, 2), 120)
    plan.steps = everyDays.map { DebtSteps(everyDays: max(1, $0), firstDue: firstDue) }
    if everyDays != nil { plan.paymentDay = nil }
    plan.markupE4 = markup.flatMap { $0.raw > 0 ? $0 : nil }
    plan.termsReviewed = true
    var rows = PlanningRows.empty
    rows.debts = [plan]
    if let markup = plan.markupE4,
      let line = try? DebtRules.growth(on: plan, amountE4: markup, date: firstDue)
    {
      rows.debtEntries = [line]
    }
    return apply(PlanningChange(upsert: rows))
  }

  // MARK: Pledges

  /// «Списать…» a pledge that did not come back: closed with what is left, and the loss spent in
  /// `categoryId` on `day` (`pledgeloss:<debt>`), one write and one step of ⌘Z.
  @discardableResult
  func writeOffPledge(_ debt: Debt, categoryId: UUID, on day: DateOnly) -> Bool {
    guard debt.pledge, !debt.closed, let left = balance(of: debt), left.raw > 0 else {
      return false
    }
    let environment = planning.environment
    let (closed, line, loss) = DebtRules.writeOff(
      debt: debt, balance: left, categoryId: categoryId, day: day, calendar: environment.calendar)
    var draft = TransactionDraft(
      kind: .expense, occurredAt: loss.transaction.occurredAt, currency: debt.currency,
      amount: left, note: environment.format("pledge.loss.note", table: "Debts", debt.name),
      creditDebtId: debt.id)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = categoryId
    guard var entry = try? planning.operation(draft, link: nil) else { return false }
    entry.transaction.externalId = loss.transaction.externalId
    var rows = PlanningRows.empty
    rows.debts = [closed]
    rows.debtEntries = [line]
    guard apply(PlanningChange(created: [entry], upsert: rows)) else { return false }
    AppLog.info(
      "debts.pledge.writtenOff", .db, "a pledge was written off", [LogPair("debt", .id(debt.id))])
    return true
  }

  // MARK: Settings of the debts

  /// The settings of the debts written to the database: the ladder's money above, the cards kept
  /// out of it, the template of the polite reminder. One step of ⌘Z.
  @discardableResult
  func saveSettings(_ settings: DebtSettings) -> Bool {
    apply(PlanningChange(settings: settings.storedValues))
  }

  /// «В лестнице» of a debt.
  @discardableResult
  func setInLadder(_ debt: Debt, _ inLadder: Bool) -> Bool {
    var changed = debt
    changed.inLadder = inLadder ? nil : false
    return save(changed)
  }

  // MARK: A credit card kept only as an account

  /// «Оставить только счёт»: the debt of a credit card deleted softly, its rate the rate of
  /// purchases of `account` when that is empty (`CreditCardDebtMerge`). The account must have
  /// its terms — the owner gives them in its editor first. One step of ⌘Z.
  @discardableResult
  func keepOnlyAccount(_ debt: Debt, account: PaymentMethod) -> Bool {
    guard CreditCardDebtMerge.offered(for: debt), account.credit != nil else { return false }
    let merged = CreditCardDebtMerge.keepOnlyAccount(debt: debt, account: account)
    var rows = PlanningRows.empty
    rows.debts = [merged.debtDeleted]
    if merged.account != account { rows.paymentMethods = [merged.account] }
    guard apply(PlanningChange(upsert: rows)) else { return false }
    AppLog.info(
      "debts.cardKeptAsAccount", .db, "a credit card was kept only as an account",
      [LogPair("debt", .id(debt.id)), LogPair("account", .id(account.id))])
    return true
  }
}
