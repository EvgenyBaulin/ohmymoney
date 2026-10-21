import AppCore
import AppDatabase
import Foundation

extension DebtActions {
  /// «Добавить транш…»: a part of the loan drawn on `day` — a day still to come is a planned
  /// one. A tranche is spent the day it is drawn, on tuition: an expense in «Образование» on the
  /// loan the way a purchase on credit is (`creditDebtId`), so it is spending once and moves no
  /// money, and the line of the journal that grows the debt by it, naming that operation
  /// (`DebtRules.tranche`). «Образование» is the live expense category of that name — at the top
  /// first —, made in the same write when there is none. The operation is on `account` while it
  /// is live, else on the main one. One write, one step of ⌘Z.
  @discardableResult
  func addTranche(
    _ debt: Debt, amount: AmountE4, on day: DateOnly, account: UUID?, note: String? = nil
  ) -> Bool {
    guard !debt.closed, debt.direction == .iOwe, amount.raw > 0 else { return false }
    let environment = planning.environment
    var rows = PlanningRows.empty
    let category = educationCategory(rows: &rows)
    let accounts = (snapshot?.dataset.paymentMethods ?? []).filter { !$0.archived }
    let cleaned = DebtRules.cleaned(note)
    var draft = TransactionDraft(
      kind: .expense,
      occurredAt: environment.calendar.startOfDay(day).addingTimeInterval(12 * 3600),
      currency: debt.currency, amount: amount, note: cleaned ?? debt.name,
      paymentMethodId: FormAccounts.account(account, among: accounts)?.id ?? account,
      creditDebtId: debt.id)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = category
    draft.parts[0].categorySource = .system
    guard let entry = try? planning.operation(draft, link: nil),
      let line = try? DebtRules.tranche(
        on: debt, amount: amount, date: day, transactionId: entry.id)
    else {
      AppLog.error(
        "debts.tranche.failed", .db, "a tranche was not written", [LogPair("debt", .id(debt.id))])
      return false
    }
    var described = line
    described.description = cleaned
    rows.debtEntries = [described]
    guard apply(PlanningChange(created: [entry], upsert: rows)) else {
      AppLog.error(
        "debts.tranche.failed", .db, "a tranche was not written", [LogPair("debt", .id(debt.id))])
      return false
    }
    AppLog.info(
      "debts.tranche.added", .db, "a tranche was added",
      [
        LogPair("debt", .id(debt.id)), LogPair("line", .id(line.id)),
        LogPair("operation", .id(entry.id)),
      ])
    return true
  }

  /// The category a tranche is spent in: the live expense category «Образование» («Education»)
  /// — one at the top before a subcategory —, else a new one at the top, «хорошая» like the one a
  /// new base starts with, added to `rows`.
  func educationCategory(rows: inout PlanningRows) -> UUID {
    let categories =
      (try? planning.environment.references?.categories())
      ?? snapshot?.dataset.categories ?? []
    if let found = Self.education(among: categories) { return found.id }
    let made = CoreKit.Category(
      kind: .expense,
      name: planning.environment.language("tranche.category", table: "Debts"),
      quality: .good)
    rows.categories.append(made)
    return made.id
  }

  /// The live expense category called «Образование» or «Education», one at the top first.
  nonisolated static func education(among categories: [CoreKit.Category]) -> CoreKit.Category? {
    let names: Set<String> = [NameKey.fold("Образование"), NameKey.fold("Education")]
    let named = categories.filter {
      $0.kind == .expense && !$0.archived && $0.systemRole == nil
        && names.contains(NameKey.fold($0.name))
    }
    return named.first { $0.parentId == nil } ?? named.first
  }
}
