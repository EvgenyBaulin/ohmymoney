import AppCore
import Foundation

/// «Такая же операция уже записана»: asked before a new operation that repeats one written a
/// moment ago is written again. «Добавить» writes it, «Не добавлять» leaves the line as it was.
struct RepeatQuestion: Identifiable {
  let entry: TransactionEntry
  var id: UUID { entry.id }

  /// The amount, what it was called, and when it was written.
  @MainActor func message(_ environment: AppEnvironment) -> String {
    let written = entry.transaction
    let money = environment.money.exact(written.amountE4, currency: written.currency)
    let note = written.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return environment.language.format(
      "entry.repeat.message", table: "Entry", note.isEmpty ? money : "\(money) · \(note)",
      environment.dates.time(written.createdAt))
  }
}

/// «Запись или план?»: asked once before an operation dated after today is written. «Записать
/// как есть» writes it on its date, the other button makes a plan of it instead (`OperationAhead`).
struct AheadQuestion: Identifiable {
  let plan: OperationAhead.Plan
  let day: DateOnly
  var id: String { "\(plan)-\(day.iso)" }

  @MainActor func title(_ environment: AppEnvironment) -> String {
    environment.language.format("entry.ahead.title", table: "Entry", environment.dates.longDay(day))
  }

  /// The key of the button that makes the plan.
  var planKey: String {
    plan == .payment ? "entry.ahead.planPayment" : "entry.ahead.planIncome"
  }
}

/// «Выйдет за лимит карты на X»: asked once before spending that takes a credit card past its
/// limit is written. The bank may charge a fee, but the owner can record it all the same.
struct OverLimitQuestion: Identifiable, Equatable {
  let over: AmountE4
  let currency: CurrencyCode
  var id: String { "\(over.raw)-\(currency.code)" }

  @MainActor func title(_ environment: AppEnvironment) -> String {
    environment.language.format(
      "entry.overLimit.title", table: "Entry", environment.money.exact(over, currency: currency))
  }
}

/// «После этого остаток станет X — ниже Y»: asked once before spending that takes an account
/// below the balance its bank asks to keep is written. The bank may take back a rate for the
/// month, but the owner can record it all the same.
struct MinBalanceQuestion: Identifiable, Equatable {
  let warning: MinBalanceWarning
  var id: String { "\(warning.afterE4.raw)-\(warning.minimumE4.raw)" }

  @MainActor func title(_ environment: AppEnvironment) -> String {
    environment.language.format(
      "entry.minBalance.title", table: "Entry",
      environment.money.rounded(warning.afterE4, currency: warning.currency),
      environment.money.rounded(warning.minimumE4, currency: warning.currency))
  }
}

/// «Сверх платежа X — уменьшить срок, платёж или это платёж вперёд?»: asked before a payment of a
/// loan above what its due asks for is written (`DebtPrepayment`). The answer given for the debt
/// the last time comes first, «Это платёж вперёд» too.
struct PrepayQuestion: Identifiable, Equatable {
  let excess: AmountE4
  let currency: CurrencyCode
  let suggested: PrepayChoice
  var id: String { "\(excess.raw)-\(suggested.rawValue)" }

  @MainActor func title(_ environment: AppEnvironment) -> String {
    environment.language.format(
      "entry.prepay.title", table: "Entry", environment.money.exact(excess, currency: currency))
  }

  /// The three answers, the suggested one first.
  var choices: [PrepayChoice] {
    [suggested] + PrepayChoice.allCases.filter { $0 != suggested }
  }

  static func key(of choice: PrepayChoice) -> String {
    switch choice {
    case .term: "entry.prepay.term"
    case .payment: "entry.prepay.payment"
    case .forward: "entry.prepay.forward"
    }
  }
}

/// A refund of a thing bought in instalments, waiting for `InstalmentReturnSheet` to write it.
struct InstalmentReturnRequest: Identifiable {
  let refund: TransactionEntry
  let debt: Debt
  var id: UUID { refund.id }
}

/// What the line says under itself once an operation is written: an offer to allocate an income
/// in «Заработок» (`Allocation.offers`), or — after «смз» with self-employment off and never
/// offered — the one offer to count its tax.
enum EntryAfterSaving {
  @MainActor static func notice(
    for entry: TransactionEntry, saidSelfEmployed: Bool, tree: CategoryTree,
    selfEmployment: SelfEmploymentSettings, allocation: AllocationSettings,
    money: MoneyFormatter
  ) -> EntryLineMessage? {
    guard entry.transaction.kind == .income else { return nil }
    if saidSelfEmployed, !selfEmployment.enabled, !selfEmployment.offered {
      return .offerSelfEmployment
    }
    guard Allocation.offers(entry: entry, tree: tree, settings: allocation) else { return nil }
    return .allocate(
      entry.id, money.rounded(entry.transaction.amountE4, currency: entry.transaction.currency))
  }
}
