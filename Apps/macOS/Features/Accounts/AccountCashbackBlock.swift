import AppCore
import SwiftUI

/// What «Кэшбэк · <месяц>» of an account's screen shows: the account's own line — its rules are
/// the ones every card follows — and each card that keeps rules of its own or was named by a
/// purchase, the cashback the rules promise for the month's purchases next to what was received
/// for the month, exact, per currency, the rules that apply this month, and when the bank pays.
struct AccountCashbackModel: Equatable, Sendable {
  struct Line: Equatable, Sendable, Identifiable {
    /// `nil`: the account's own line — the purchases that name no card.
    var cardId: UUID?
    var cardName: String?
    var expected: [Money]
    var received: [Money]
    /// The rules the line keeps itself that apply in the month: the month's first, then
    /// «always». A card's are only the ones in which it differs from its account.
    var rules: [CashbackRule]
    var id: String { cardId?.uuidString ?? "account" }
  }

  /// The month before, when its cashback was due and nothing came.
  struct Late: Equatable, Sendable {
    var month: MonthKey
    var since: DateOnly
    var expectedRub: AmountE4
  }

  var month: MonthKey
  var lines: [Line]
  /// The account's main currency: an empty side of a line is zero in it.
  var currency: CurrencyCode = .rub
  /// When the bank pays, as the account says; `nil` when it has not said.
  var payout: CashbackPayout?
  /// Where the month's cashback stands against the payout day.
  var status: CashbackPayoutStatus = .unknown
  var late: Late?
  /// The account the cashback comes to as points, by name.
  var pointsAccountName: String?
  /// All the lines together in rubles: what is expected, and of it what the rules gave where no
  /// figure was typed — the part nobody has confirmed, which needs no confirming.
  var expectedRub: AmountE4 = .zero
  var unconfirmedRub: AmountE4 = .zero

  /// No rule applies and nothing was received: the block says so and offers the rules.
  var isEmpty: Bool {
    lines.allSatisfy { $0.rules.isEmpty && $0.received.isEmpty && $0.expected.isEmpty }
  }

  static func build(
    month: MonthKey, accountId: UUID, ledger: Ledger, today: DateOnly
  ) -> AccountCashbackModel {
    let dataset = ledger.dataset
    let book = CashbackRuleBook(
      rules: dataset.cashbackRules, tree: ledger.tree, cards: dataset.cards,
      accounts: dataset.paymentMethods)
    let cards = Dictionary(
      dataset.cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    func money(_ amounts: [CurrencyCode: AmountE4]) -> [Money] {
      amounts.filter { !$0.value.isZero || amounts.count == 1 }
        .map { Money(amount: $0.value, currency: $0.key) }
        .sorted { $0.currency.code < $1.currency.code }
    }
    let cells = AccountCashbackSummary.month(month, accountId: accountId, ledger: ledger)
    let lines = cells.map { cell -> Line in
      let holder: CashbackHolder =
        cell.holder.cardId.map(CashbackHolder.card) ?? .account(accountId)
      let rules = book.rules(of: holder).filter { $0.month == month || $0.month == nil }
        .sorted { ($0.month != nil ? 0 : 1) < ($1.month != nil ? 0 : 1) }
      return Line(
        cardId: cell.holder.cardId, cardName: cell.holder.cardId.flatMap { cards[$0]?.name },
        expected: money(cell.expected), received: money(cell.received), rules: rules)
    }
    let account = dataset.paymentMethods.first { $0.id == accountId }
    let payout = account?.cashbackPayout
    let expectedRub = AmountE4.sum(cells.map(\.expectedRub))
    let status = CashbackSchedule.status(
      of: month, payout: payout, today: today, expectedRub: expectedRub,
      receivedRub: AmountE4.sum(cells.map(\.receivedRub)), calendar: ledger.calendar)

    var late: Late?
    if payout != nil {
      let before = AccountCashbackSummary.month(
        month.previous, accountId: accountId, ledger: ledger)
      let earlier = CashbackSchedule.status(
        of: month.previous, payout: payout, today: today,
        expectedRub: AmountE4.sum(before.map(\.expectedRub)),
        receivedRub: AmountE4.sum(before.map(\.receivedRub)), calendar: ledger.calendar)
      if case .late(let since, let expected) = earlier {
        late = Late(month: month.previous, since: since, expectedRub: expected)
      }
    }
    let points = account?.cashbackPointsAccountId.flatMap { id in
      dataset.paymentMethods.first { $0.id == id }?.name
    }
    return AccountCashbackModel(
      month: month, lines: lines, currency: account?.currency ?? .rub, payout: payout,
      status: status, late: late, pointsAccountName: points, expectedRub: expectedRub,
      unconfirmedRub: AmountE4.sum(cells.map(\.unconfirmedRub)))
  }
}

/// «Кэшбэк · Сентябрь 2026» on an account's screen, under its cards: expected is an
/// expectation, never income — what the rules gave with no figure typed is gray and needs no
/// confirming, and counts in the approximate income —; what was received is income in the
/// cashback category, by the month it is for. «Правила кэшбэка…» opens the rules of the account,
/// how its bank rounds and when it pays.
struct AccountCashbackBlock: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies

  let accountId: UUID

  @State private var model: AccountCashbackModel?
  @State private var editsRules = false

  private func t(_ key: String) -> String { environment.language(key, table: CardText.table) }

  private var month: MonthKey { environment.today.monthKey }

  private var state: BlockState<AccountCashbackModel> {
    guard let model, model.month == month else { return .calculating }
    return .ready(model, at: environment.now())
  }

  var body: some View {
    ComputedBlock(
      title: environment.format(
        "account.screen.cashback", table: CardText.table, environment.dates.monthTitle(month)),
      state: state, retry: nil
    ) { model in
      VStack(alignment: .leading, spacing: 8) {
        if model.isEmpty {
          Text(verbatim: t("account.screen.cashbackNone")).foregroundStyle(.secondary)
        } else {
          ForEach(model.lines) { line in
            lineView(line, currency: model.currency)
          }
          approximateIncome(model)
        }
        notes(model)
        Button(t("cashback.rules")) { editsRules = true }
          .accessibilityIdentifier("account.cashback.rules")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityIdentifier("account.cashback")
    .task(id: CashbackKey(account: accountId, month: month, generation: compute.generation)) {
      guard let ledger = compute.snapshot?.ledger else { return }
      let month = self.month
      let accountId = self.accountId
      let today = environment.today
      model = await Task.detached(priority: .userInitiated) {
        AccountCashbackModel.build(month: month, accountId: accountId, ledger: ledger, today: today)
      }.value
    }
    .sheet(isPresented: $editsRules) {
      CashbackRulesSheet(accountId: accountId) { editsRules = false }
        .handingOver(dependencies)
    }
  }

  private func lineView(_ line: AccountCashbackModel.Line, currency: CurrencyCode) -> some View {
    let names = Dictionary(
      (compute.snapshot?.dataset.categories ?? []).map { ($0.id, $0.name) },
      uniquingKeysWith: { first, _ in first })
    return VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: line.cardId == nil ? "building.columns" : "creditcard")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(verbatim: line.cardName ?? t("account.screen.cashbackAccountLine"))
          .fontWeight(.medium)
        Spacer()
        // What is expected is an expectation: gray, with «≈» and the words, never by colour alone.
        Text(
          verbatim: environment.format(
            "account.screen.cashbackExpected", table: CardText.table,
            amounts(line.expected, currency: currency))
        )
        .foregroundStyle(.secondary)
        .monospacedDigit()
        Text(
          verbatim: environment.format(
            "account.screen.cashbackReceived", table: CardText.table,
            amounts(line.received, currency: currency))
        )
        .monospacedDigit()
      }
      if !line.rules.isEmpty {
        Text(
          verbatim: line.rules.map { CardText.ruleLine($0, categories: names, environment) }
            .joined(separator: " · ")
        )
        .appFont(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  /// «Примерный доход: ≈ 280 ₽, из них по правилам, без подтверждения, — 240 ₽».
  @ViewBuilder
  private func approximateIncome(_ model: AccountCashbackModel) -> some View {
    if model.expectedRub > .zero {
      let key =
        model.unconfirmedRub > .zero
        ? "account.screen.cashbackApproximate" : "account.screen.cashbackApproximateTyped"
      Text(
        verbatim: environment.format(
          key, table: CardText.table, environment.money.exact(model.expectedRub),
          environment.money.exact(model.unconfirmedRub))
      )
      .appFont(.caption)
      .foregroundStyle(.secondary)
      .accessibilityIdentifier("account.cashback.approximate")
    }
  }

  /// When the bank pays, where the points go, and what is late from the month before.
  @ViewBuilder
  private func notes(_ model: AccountCashbackModel) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      switch model.status {
      case .immediately:
        note("bolt", t("account.screen.cashbackPayoutImmediately"))
      case .due(let day), .paid(let day):
        note(
          "calendar",
          environment.format(
            "account.screen.cashbackPayoutDue", table: CardText.table,
            environment.dates.dayAndMonth(day)))
      case .unknown, .late:
        EmptyView()
      }
      if let points = model.pointsAccountName {
        note(
          "star.circle",
          environment.format("account.screen.cashbackPoints", table: CardText.table, points))
      }
      if let late = model.late {
        note(
          "exclamationmark.triangle",
          environment.format(
            "account.screen.cashbackLate", table: CardText.table,
            environment.monthIn(late.month), environment.money.exact(late.expectedRub),
            environment.dates.dayAndMonth(late.since)),
          tint: .orange)
      }
    }
    .appFont(.caption)
  }

  private func note(_ symbol: String, _ text: String, tint: Color = .secondary) -> some View {
    Label {
      Text(verbatim: text)
    } icon: {
      Image(systemName: symbol).foregroundStyle(tint)
    }
    .foregroundStyle(.secondary)
  }

  /// «280.55 ₽», «100 ₸, 18.50 ₽»; nothing — zero in the account's currency, «0.00 ₸».
  private func amounts(_ values: [Money], currency: CurrencyCode) -> String {
    guard !values.isEmpty else { return environment.money.exact(.zero, currency: currency) }
    return values.map { environment.money.exact($0.amount, currency: $0.currency) }
      .joined(separator: ", ")
  }
}

private struct CashbackKey: Hashable {
  var account: UUID
  var month: MonthKey
  var generation: Int
}
