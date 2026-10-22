import AppCore
import AppDatabase
import SwiftUI

/// The sheets of the debts this version brought, opened from the card of a debt.
enum DebtCreditSheet: Identifiable {
  /// «Комиссии и страховка…» of a loan.
  case costs(Debt)
  /// «Запланировать досрочку…».
  case prepay(Debt)
  /// «Вписать платёж из приложения банка…».
  case typeInstalment(Debt)
  /// «Напомнить» a debtor.
  case nudge(Debt, balance: AmountE4)
  /// «Списать…» a pledge that did not come back.
  case writeOffPledge(Debt)
  /// The terms of the account a credit card debt is kept as, before «Оставить только счёт».
  case cardTerms(Debt, account: PaymentMethod)
  /// The questions about old debts (`DebtReviewSheet`).
  case review([DebtReviewItem])
  /// «Записать рефинансирование…»: a new loan paid this one off.
  case refinance(Debt)

  var id: String {
    switch self {
    case .costs(let debt): "costs-\(debt.id)"
    case .prepay(let debt): "prepay-\(debt.id)"
    case .typeInstalment(let debt): "typed-\(debt.id)"
    case .nudge(let debt, _): "nudge-\(debt.id)"
    case .writeOffPledge(let debt): "pledge-\(debt.id)"
    case .cardTerms(let debt, _): "card-\(debt.id)"
    case .review(let items): "review-\(items.map(\.debtId.uuidString).joined())"
    case .refinance(let debt): "refinance-\(debt.id)"
    }
  }
}

/// The further actions of a card, after the ones every debt has (`DebtCardAction`).
enum DebtMoreAction: Hashable, CaseIterable {
  case costs, prepay, typeInstalment, nudge, writeOffPledge, keepOnlyAccount, refinance

  /// What the card of `debt` offers: a loan — its costs, a planned early repayment and a sum
  /// typed from the bank's app; an instalment plan — the sum typed; a debt owed to me — the
  /// polite reminder, a pledge — writing it off; a credit card kept as a debt — keeping only the
  /// account. A closed debt offers none.
  static func offered(for debt: Debt) -> [DebtMoreAction] {
    guard !debt.closed, !debt.isDeleted else { return [] }
    var actions: [DebtMoreAction] = []
    if debt.direction == .iOwe, debt.type == .loan {
      actions += [.costs, .prepay]
    }
    if debt.direction == .iOwe, debt.hasDues { actions.append(.typeInstalment) }
    if debt.direction == .owedToMe { actions.append(.nudge) }
    if debt.pledge { actions.append(.writeOffPledge) }
    if CreditCardDebtMerge.offered(for: debt) { actions.append(.keepOnlyAccount) }
    if debt.direction == .iOwe, debt.type == .loan { actions.append(.refinance) }
    return actions
  }
}

/// The lines of a debt's card this version added: an instalment plan's parts and markup, the
/// dues ahead, the costs and true cost of a loan, the planned early repayment, a pledge's day,
/// «В лестнице», and the further actions.
struct DebtCardExtras: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  /// Which of the two halves the card shows: the facts above the actions, or the further
  /// actions themselves. The cards of a debt put them in different places.
  enum Part { case all, details, more }

  let line: DebtLine
  var part: Part = .all
  @Binding var sheet: DebtCreditSheet?
  @State private var keepFailed = false

  var body: some View {
    let debt = line.debt
    VStack(alignment: .leading, spacing: 6) {
      if part != .more { details(debt) }
      if part != .details { moreActions(debt) }
    }
    .alert(t("keepOnlyAccount.failed"), isPresented: $keepFailed) {
      Button(environment.language("action.ok")) {}
    }
  }

  @ViewBuilder
  private func details(_ debt: Debt) -> some View {
    Group {
      ForEach(
        DebtPlanText.lines(
          line, language: environment.language, money: environment.money, dates: environment.dates),
        id: \.self
      ) {
        Text(verbatim: $0).appFont(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let planned = debt.plannedPrepay {
        Label {
          Text(
            verbatim: environment.format(
              "prepay.planned", table: "Debts", environment.dates.longDay(planned.day),
              environment.money.exact(planned.amountE4, currency: debt.currency)))
        } icon: {
          Image(systemName: "calendar.badge.clock")
        }
        .appFont(.callout)
      }
      if debt.pledge, let returnBy = debt.returnBy {
        Label {
          Text(
            verbatim: environment.format(
              "pledge.returnByOn", table: "Debts", environment.dates.longDay(returnBy)))
        } icon: {
          Image(systemName: returnBy < environment.today ? "exclamationmark.circle" : "key")
        }
        .appFont(.callout)
      }
      DebtDuesAhead(line: line)
      if debt.direction == .iOwe, !debt.closed {
        Toggle(t("ladder.inLadder"), isOn: inLadder)
          .accessibilityIdentifier("debts.inLadder")
      }
    }
  }

  @ViewBuilder
  private func moreActions(_ debt: Debt) -> some View {
    let more = DebtMoreAction.offered(for: debt)
    if !more.isEmpty {
      FlowButtons {
        ForEach(more, id: \.self) { action in button(action) }
      }
    }
  }

  private var inLadder: Binding<Bool> {
    Binding(
      get: { line.debt.inLadder != false },
      set: { value in
        guard let dependencies else { return }
        DebtActions(dependencies).setInLadder(line.debt, value)
      })
  }

  private func button(_ action: DebtMoreAction) -> some View {
    let debt = line.debt
    switch action {
    case .costs:
      return Button(t("costs.action")) { sheet = .costs(debt) }
    case .prepay:
      return Button(t("prepay.action")) { sheet = .prepay(debt) }
    case .typeInstalment:
      return Button(t("typed.action")) { sheet = .typeInstalment(debt) }
    case .nudge:
      return Button(t("nudge.action")) { sheet = .nudge(debt, balance: line.balance) }
    case .writeOffPledge:
      return Button(t("pledge.writeOff")) { sheet = .writeOffPledge(debt) }
    case .keepOnlyAccount:
      return Button(t("keepOnlyAccount.action")) { keepOnlyAccount() }
    case .refinance:
      return Button(t("refinance.action")) { sheet = .refinance(debt) }
    }
  }

  /// «Оставить только счёт»: the account the debt is named like; one without terms gets them in
  /// its editor first, and the debt goes once they are there.
  private func keepOnlyAccount() {
    guard let dependencies, let account = Self.account(for: line.debt, in: compute.snapshot) else {
      keepFailed = true
      return
    }
    if account.credit == nil {
      sheet = .cardTerms(line.debt, account: account)
    } else if !DebtActions(dependencies).keepOnlyAccount(line.debt, account: account) {
      keepFailed = true
    }
  }

  /// The live account a credit card debt is named like (`DebtNaming`).
  static func account(for debt: Debt, in snapshot: DataSnapshot?) -> PaymentMethod? {
    let dataset = snapshot?.dataset
    let accounts = dataset?.paymentMethods ?? []
    guard
      let match = DebtNaming.accountAnswering(
        to: debt.name, accounts: accounts, cards: dataset?.cards ?? [])
    else { return nil }
    return accounts.first { !$0.archived && $0.name == match.accountName }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}

/// The words of an instalment plan on its card: «Рассрочка: 4 части раз в 2 недели · оплачено 1
/// из 4», «Переплата 600 ₽ всего, 150 ₽ в каждом платеже».
@MainActor
enum DebtPlanText {
  static func lines(
    _ line: DebtLine, language: AppLanguage, money: MoneyFormatter, dates: DateFormatting
  ) -> [String] {
    let debt = line.debt
    guard debt.isInstalmentPlan, let parts = debt.parts else { return [] }
    let paid = min(line.dues.paidCount, parts)
    let every =
      debt.steps.map {
        language.format("plan.every.days", table: "Debts", String($0.everyDays))
      } ?? language("plan.every.month", table: "Debts")
    var lines = [
      language.format("plan.parts", table: "Debts", String(parts), every, String(paid))
    ]
    if let markup = debt.markupE4, markup.raw > 0 {
      let each = InstalmentPlan.markupShares(markup: markup, count: parts).first ?? .zero
      lines.append(
        language.format(
          "plan.markup", table: "Debts", money.exact(markup, currency: debt.currency),
          money.exact(each, currency: debt.currency)))
    }
    return lines
  }
}

/// The dues ahead of a debt with dues: the next few days and sums — the first less what was paid
/// toward it — and early repayments told by what they chose.
struct DebtDuesAhead: View {
  @Dependency(\.environment) private var environment
  let line: DebtLine

  var body: some View {
    let dues = Self.ahead(line, today: environment.today)
    if !dues.isEmpty {
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: t("dues.ahead")).appFont(.subheadline.weight(.semibold))
        ForEach(dues, id: \.day) { due in
          HStack {
            Text(verbatim: environment.dates.longDay(due.day)).monospacedDigit()
              .foregroundStyle(.secondary)
            if due.typed {
              Text(verbatim: t("dues.typed")).appFont(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(verbatim: environment.money.exact(due.amount, currency: line.debt.currency))
              .monospacedDigit()
          }
          .appFont(.callout)
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("debts.duesAhead")
    }
  }

  /// The first unpaid due and the ones after it, at most six, with what each still asks.
  static func ahead(
    _ line: DebtLine, today: DateOnly
  ) -> [(day: DateOnly, amount: AmountE4, typed: Bool)] {
    let dues = line.dues.knowing(line.debt)
    guard !line.debt.closed, line.debt.direction == .iOwe, let first = dues.firstUnpaid else {
      return []
    }
    return dues.unpaid(through: first.adding(days: 2_000)).prefix(6).map { day in
      (day, dues.owed(day), false)
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}
