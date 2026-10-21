import AppCore
import SwiftUI

/// The accounts a screen of several accounts is about: a group of the sidebar, or «Всего» —
/// every account of the summary, a group left out of it staying out, as the total of the
/// sidebar row counts them.
enum GroupScope: Hashable, Sendable {
  case group(UUID)
  case summary

  /// What the screen shows of `snapshot`; `nil` for a group that is gone.
  func content(in snapshot: AccountsSnapshot) -> GroupContent? {
    switch self {
    case .group(let id):
      guard let section = snapshot.sections.first(where: { $0.group?.id == id }) else {
        return nil
      }
      return GroupContent(
        group: section.group, accounts: section.accounts, inSummary: section.inSummary,
        totalRub: section.totalRub, withoutRate: section.withoutRate)
    case .summary:
      return GroupContent(
        group: nil, accounts: snapshot.sections.filter(\.inSummary).flatMap(\.accounts),
        inSummary: true, totalRub: snapshot.inSummaryTotalRub,
        withoutRate: snapshot.inSummaryWithoutRate)
    }
  }
}

/// A group's screen, or that of «Всего»: the group (none for «Всего»), its accounts, whether it
/// counts in the summary, its total in rubles and the currencies left out of it for want of a
/// rate.
struct GroupContent {
  var group: AccountGroup?
  var accounts: [AccountsSnapshot.AccountLine]
  var inSummary: Bool
  var totalRub: AmountE4?
  var withoutRate: [CurrencyCode]

  var accountIds: Set<UUID> { Set(accounts.map(\.account.id)) }
}

/// What is planned for a group's accounts: the payments and subscriptions paid from them, by
/// the next due date — the rule of an account's screen (`AccountPayments.on`), a payment that
/// names no account being the main account's —, and the incomes expected to them, by the next
/// due date still waiting: to the account chosen for one, else to the account its latest income
/// came to, else to the main one (`ExpectedIncomeRules.account`); an account archived or deleted
/// since stands for the main one, as in the forecast of the balances.
struct GroupPlanModel: Equatable {
  struct Payment: Equatable, Identifiable {
    var status: ScheduledStatus
    /// The account of the group it is paid from.
    var accountId: UUID
    var id: UUID { status.id }
  }

  struct Income: Equatable, Identifiable {
    var income: ExpectedIncome
    /// The next due date still waiting; `nil` for a one-off income without a date.
    var due: DateOnly?
    /// What is still to come for it, in the currency of the income.
    var remaining: AmountE4
    var isOverdue: Bool
    var accountId: UUID
    var id: UUID { income.id }
  }

  var payments: [Payment]
  var incomes: [Income]

  init(accountIds: Set<UUID>, planning: PlanningSnapshot, ledger: Ledger) {
    let dataset = ledger.dataset
    let mainId = dataset.paymentMethods.first { $0.isDefault && !$0.archived }?.id
    var payer: [UUID: UUID] = [:]
    for accountId in accountIds {
      for status in AccountPayments.on(
        accountId, statuses: planning.scheduled, mainAccountId: mainId)
      {
        payer[status.id] = payer[status.id] ?? accountId
      }
    }
    // The statuses come soonest first, then by name: their order is kept.
    payments = planning.scheduled.compactMap { status in
      payer[status.id].map { Payment(status: status, accountId: $0) }
    }

    let live = Set(dataset.paymentMethods.filter { !$0.archived }.map(\.id))
    incomes = planning.expected.compactMap { status -> Income? in
      guard !status.isFulfilled else { return nil }
      var account = ExpectedIncomeRules.account(
        of: status.income, links: dataset.planning.expectedLinks, ledger: ledger, mainId: mainId)
      if let chosen = account, !live.contains(chosen) { account = mainId }
      guard let account, accountIds.contains(account) else { return nil }
      let next = status.occurrences.first { !$0.isFulfilled }
      return Income(
        income: status.income, due: next?.due, remaining: next?.remaining ?? status.remaining,
        isOverdue: next.map { $0.due < planning.today } ?? false, accountId: account)
    }
    .sorted { left, right in
      switch (left.due, right.due) {
      case (let l?, let r?) where l != r: return l < r
      case (.some, nil): return true
      case (nil, .some): return false
      default:
        if left.income.name != right.income.name { return left.income.name < right.income.name }
        return left.id.uuidString < right.id.uuidString
      }
    }
  }

  var isEmpty: Bool { payments.isEmpty && incomes.isEmpty }
}

/// «Планы счетов» of a group's screen and of «Всего»: the payments and subscriptions paid from
/// the accounts and the incomes expected to them, each with its date — «просрочен» when it
/// passed —, its name, the account when the screen has more than one, and its amount. A
/// double click opens the payment's form.
struct GroupPlanBlock: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies

  let accountIds: Set<UUID>

  @State private var sheet: PlanningSheet?

  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }

  private var model: GroupPlanModel? {
    guard let snapshot = compute.snapshot else { return nil }
    return GroupPlanModel(
      accountIds: accountIds, planning: snapshot.planning, ledger: snapshot.ledger)
  }

  private var names: [UUID: String] {
    Dictionary(
      (compute.snapshot?.dataset.paymentMethods ?? []).map { ($0.id, $0.name) },
      uniquingKeysWith: { first, _ in first })
  }

  var body: some View {
    let model = self.model
    let names = self.names
    let showsAccount = accountIds.count > 1
    VStack(alignment: .leading, spacing: 8) {
      Text(verbatim: t("group.screen.plan"))
        .appFont(.headline)
        .accessibilityAddTraits(.isHeader)
      Text(verbatim: t("group.screen.payments"))
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .accessibilityAddTraits(.isHeader)
      if let model, model.payments.isEmpty {
        Text(verbatim: t("group.screen.paymentsNone")).foregroundStyle(.secondary)
      }
      ForEach(model?.payments ?? []) { payment in
        line(
          due: payment.status.nextUnpaid, overdue: payment.status.isOverdue,
          name: payment.status.payment.name,
          account: showsAccount ? names[payment.accountId] : nil,
          amount: environment.money.exact(
            payment.status.amountNext, currency: payment.status.payment.currency),
          edit: { sheet = .payment(payment.status.payment) })
      }
      Divider()
      Text(verbatim: t("group.screen.incomes"))
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .accessibilityAddTraits(.isHeader)
      if let model, model.incomes.isEmpty {
        Text(verbatim: t("group.screen.incomesNone")).foregroundStyle(.secondary)
      }
      ForEach(model?.incomes ?? []) { income in
        line(
          due: income.due, overdue: income.isOverdue, name: income.income.name,
          account: showsAccount ? names[income.accountId] : nil,
          amount: "+" + environment.money.exact(income.remaining, currency: income.income.currency),
          edit: nil)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentCard()
    .accessibilityIdentifier("group.plan")
    .sheet(item: $sheet) { sheet in
      PlanningSheetView(sheet: sheet).handingOver(dependencies)
    }
  }

  private func line(
    due: DateOnly?, overdue: Bool, name: String, account: String?, amount: String,
    edit: (() -> Void)?
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      if overdue {
        Label {
          Text(verbatim: PlanningText.t("planning.overdue", environment))
        } icon: {
          Image(systemName: "exclamationmark.circle")
        }
        .appFont(.caption)
        .foregroundStyle(.secondary)
      }
      Text(verbatim: due.map(dayText) ?? "—")
        .monospacedDigit()
        .foregroundStyle(overdue ? .primary : .secondary)
        .frame(minWidth: 52, alignment: .leading)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: name).lineLimit(1)
        if let account {
          Text(verbatim: account)
            .appFont(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer()
      Text(verbatim: amount)
        .monospacedDigit()
    }
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { edit?() }
    .accessibilityElement(children: .combine)
  }

  private func dayText(_ day: DateOnly) -> String {
    day.year == environment.today.year
      ? environment.dates.dayAndMonth(day) : environment.dates.longDay(day)
  }
}

extension AccountText {
  /// «Последняя операция добавлена 22.09, 14:05» — the moment of writing, not the day the
  /// operation names; «Операций ещё не добавляли» when there is none.
  @MainActor
  static func lastRecord(_ moment: Date?, _ environment: AppEnvironment) -> String {
    guard let moment else {
      return environment.language("account.screen.lastRecordNone", table: table)
    }
    return environment.format(
      "account.screen.lastRecord", table: table, environment.dates.moment(moment))
  }
}

/// The line under the title of an account's or a group's screen: when an operation was last
/// added there.
struct LastRecordCaption: View {
  @Dependency(\.environment) private var environment
  /// `nil` while the history is not built yet: nothing is said.
  let history: AccountHistory?

  var body: some View {
    if let history {
      Label {
        Text(verbatim: AccountText.lastRecord(history.lastRecordedAt, environment))
      } icon: {
        Image(systemName: "clock")
      }
      .appFont(.caption)
      .foregroundStyle(.secondary)
      .accessibilityIdentifier("account.lastRecord")
    }
  }
}
