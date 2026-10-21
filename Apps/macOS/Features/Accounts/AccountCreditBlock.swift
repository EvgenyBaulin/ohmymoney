import AppCore
import SwiftUI

/// Everything the screen of a credit card says, worked out once from the data: the card today,
/// its statements, the interest of each and the cash and transfers of the open period.
struct CreditCardOutlook: Equatable, Sendable {
  var accountId: UUID
  var currency: CurrencyCode
  var terms: CreditCardTerms
  /// The card was counted: without a balance there are no statements.
  var counted: Bool
  var now: CreditCardNow
  var statements: [CreditStatement]
  /// Oldest first; recorded sums replace their estimates.
  var estimates: [CreditInterestEstimate]
  /// Cash and transfers since the latest statement, newest first.
  var cashLike: [CreditMovement]

  /// The outlook of `accountId` in the data of `snapshot`, as every screen works it out; `nil`
  /// for an account that is not a credit card.
  static func build(of accountId: UUID, snapshot: DataSnapshot) -> CreditCardOutlook? {
    let dataset = snapshot.dataset
    guard let account = dataset.paymentMethods.first(where: { $0.id == accountId }),
      let terms = account.credit
    else { return nil }
    let ledger = snapshot.ledger
    let balances = snapshot.planning.accounts.balances
    let key = BalanceKey(accountId: accountId, currency: account.mainCurrency)
    let movements = CreditStatements.movements(
      account: account, ledger: ledger, transfers: dataset.transfers)
    let statements = CreditStatements.statements(
      account: account, terms: terms, movements: movements, balances: balances,
      through: snapshot.today, calendar: ledger.calendar)
    let now = CreditStatements.now(
      account: account, terms: terms, statements: statements, movements: movements,
      balances: balances, today: snapshot.today, calendar: ledger.calendar)
    let estimates = CreditInterest.estimates(
      terms: terms, statements: statements,
      movements: CreditStatements.withOpening(
        movements, account: account, balances: balances, calendar: ledger.calendar),
      recorded: CreditInterest.recorded(of: accountId, entries: dataset.entries),
      through: snapshot.today)
    let since = statements.last?.closesOn
    let cash = movements.filter { movement in
      movement.kind == .cashLike && !movement.isFee
        && since.map { movement.day > $0 } ?? true
    }
    return CreditCardOutlook(
      accountId: accountId, currency: account.mainCurrency, terms: terms,
      counted: !balances.anchors(key).isEmpty, now: now, statements: statements,
      estimates: estimates, cashLike: Array(cash.reversed()))
  }
}

/// What «Кредитная карта» of an account's screen says, in the words of the interface, built
/// without a view so it can be checked in both languages. Interest is an estimate: «≈» and grey
/// until the owner records what the statement says.
struct CreditCardLines: Equatable {
  /// A statement whose interest can be recorded, with «Записать проценты…».
  struct Ask: Equatable, Identifiable {
    var text: String
    var statementDay: DateOnly
    /// The estimate the form starts with.
    var amount: AmountE4
    var recorded: Bool
    var id: DateOnly { statementDay }
  }

  /// «Доступно 120,000 ₽ из 150,000 ₽».
  var available: String
  /// «Долг 30,000 ₽», or that there is none.
  var debt: String
  /// «Внести до 30 ноября: 30,000 ₽, чтобы не платить проценты · минимальный платёж 2,400 ₽».
  var toPay: String?
  /// The grace period is lost: what stops the interest.
  var graceLost: String?
  /// «Следующая выписка 5 декабря».
  var nextStatement: String?
  /// «Проценты к выписке 5 декабря ≈ 1,205.01 ₽».
  var estimate: String?
  /// «Сверьте счёт — без остатка выписки не посчитать».
  var notCounted: String?
  /// Statements whose interest can be recorded, newest first.
  var asks: [Ask]
  /// «Снятие 15 октября: 5,000 ₽ — проценты пойдут сразу».
  var cashLike: [String]
}

@MainActor
enum CreditCardText {
  private static let table = AccountText.table

  /// «≈ 1,205.01 ₽».
  static func approximately(
    _ amount: AmountE4, _ currency: CurrencyCode, _ environment: AppEnvironment
  ) -> String {
    "≈\u{00A0}" + environment.money.exact(amount, currency: currency)
  }

  /// Everything the block says of `outlook` on `today`.
  static func lines(
    _ outlook: CreditCardOutlook, today: DateOnly, _ environment: AppEnvironment
  ) -> CreditCardLines {
    func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }
    let money = environment.money
    let dates = environment.dates
    let currency = outlook.currency
    let now = outlook.now
    var lines = CreditCardLines(
      available: environment.format(
        "account.credit.available", table: AccountText.table,
        money.exact(now.availableE4, currency: currency),
        money.exact(outlook.terms.limitE4, currency: currency)),
      debt: now.debtE4.isZero
        ? t("account.credit.noDebt")
        : environment.format(
          "account.credit.debt", table: AccountText.table,
          money.exact(now.debtE4, currency: currency)),
      toPay: nil, graceLost: nil, nextStatement: nil, estimate: nil, notCounted: nil, asks: [],
      cashLike: [])
    guard outlook.counted else {
      lines.notCounted = t("account.credit.notCounted")
      return lines
    }
    if now.graceKept, let payBy = now.payBy, now.toPayNoInterestE4.raw > 0 {
      var text = environment.format(
        "account.credit.toPay", table: AccountText.table, dates.dayAndMonth(payBy),
        money.exact(now.toPayNoInterestE4, currency: currency))
      if let minimum = now.minimumE4, minimum.raw > 0 {
        text +=
          " · "
          + environment.format(
            "account.credit.minimum", table: AccountText.table,
            money.exact(minimum, currency: currency))
      }
      lines.toPay = text
    } else if !now.graceKept, now.debtE4.raw > 0 {
      var text = environment.format(
        "account.credit.graceLost", table: AccountText.table,
        money.exact(now.toPayNoInterestE4, currency: currency))
      if let minimum = now.minimumE4, minimum.raw > 0 {
        text +=
          " · "
          + environment.format(
            "account.credit.minimum", table: AccountText.table,
            money.exact(minimum, currency: currency))
      }
      lines.graceLost = text
    }
    if let next = now.nextStatement {
      lines.nextStatement = environment.format(
        "account.credit.nextStatement", table: AccountText.table, dates.dayAndMonth(next))
    }
    if let estimate = now.estimate, !estimate.shownE4.isZero {
      lines.estimate = environment.format(
        "account.credit.estimate", table: AccountText.table,
        dates.dayAndMonth(estimate.statementDay),
        approximately(estimate.shownE4, currency, environment))
    }
    lines.asks = outlook.estimates.filter { $0.statementDay <= today }.suffix(3).reversed().map {
      estimate in
      if let recorded = estimate.recordedE4 {
        return CreditCardLines.Ask(
          text: environment.format(
            "account.credit.recorded", table: AccountText.table,
            dates.dayAndMonth(estimate.statementDay),
            money.exact(recorded, currency: currency)),
          statementDay: estimate.statementDay, amount: recorded, recorded: true)
      }
      return CreditCardLines.Ask(
        text: environment.format(
          "account.credit.statementInterest", table: AccountText.table,
          dates.dayAndMonth(estimate.statementDay),
          approximately(estimate.shownE4, currency, environment)),
        statementDay: estimate.statementDay, amount: estimate.shownE4, recorded: false)
    }
    if outlook.terms.cashWithoutGrace {
      lines.cashLike = outlook.cashLike.map { movement in
        environment.format(
          "account.credit.cashNow", table: AccountText.table, dates.dayAndMonth(movement.day),
          money.exact(movement.amountE4.magnitude, currency: currency))
      }
    }
    return lines
  }
}

/// «Кредитная карта» on the screen of an account with the terms of one: what is available and
/// owed, what to pay by when not to pay interest and the minimum payment, the next statement,
/// the interest likely charged — grey, with «≈» —, the statements whose interest can be
/// recorded («Записать проценты…»), and the cash and transfers of the open period, whose
/// interest runs at once. «Доступно» is said only here.
struct AccountCreditBlock: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies

  let accountId: UUID

  @State private var outlook: CreditCardOutlook?
  @State private var loaded = false
  @State private var recording: CreditInterestPrefill?

  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }

  /// The account is a credit card by its terms in the data.
  private var isCredit: Bool {
    compute.snapshot?.dataset.paymentMethods.first { $0.id == accountId }?.credit != nil
  }

  var body: some View {
    Group {
      if isCredit {
        ComputedBlock(title: t("account.credit.title"), state: state, retry: nil) { outlook in
          content(outlook)
        }
        .accessibilityIdentifier("account.credit")
      }
    }
    .task(id: CreditKey(account: accountId, generation: compute.generation)) {
      guard let snapshot = compute.snapshot else { return }
      let accountId = self.accountId
      outlook = await Task.detached(priority: .userInitiated) {
        CreditCardOutlook.build(of: accountId, snapshot: snapshot)
      }.value
      loaded = true
    }
    .sheet(item: $recording) { prefill in
      CreditInterestRecordSheet(prefill: prefill) { recording = nil }
        .handingOver(dependencies)
    }
  }

  private var state: BlockState<CreditCardOutlook> {
    guard loaded, let outlook else { return .calculating }
    return .ready(outlook, at: environment.now())
  }

  private func content(_ outlook: CreditCardOutlook) -> some View {
    let lines = CreditCardText.lines(outlook, today: environment.today, environment)
    return VStack(alignment: .leading, spacing: 6) {
      Text(verbatim: lines.available)
        .fontWeight(.medium)
        .monospacedDigit()
        .accessibilityIdentifier("account.credit.available")
      Text(verbatim: lines.debt)
        .monospacedDigit()
      if let notCounted = lines.notCounted {
        Label {
          Text(verbatim: notCounted)
        } icon: {
          Image(systemName: "hourglass")
        }
        .foregroundStyle(.secondary)
      }
      if let toPay = lines.toPay {
        Label {
          Text(verbatim: toPay).monospacedDigit()
        } icon: {
          Image(systemName: "calendar.badge.clock")
        }
        .accessibilityIdentifier("account.credit.toPay")
      }
      if let lost = lines.graceLost {
        Label {
          Text(verbatim: lost).monospacedDigit()
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .accessibilityIdentifier("account.credit.graceLost")
      }
      if let next = lines.nextStatement {
        Text(verbatim: next)
          .appFont(.caption)
          .foregroundStyle(.secondary)
      }
      // Estimates: grey, with «≈» in the words — never colour alone.
      if let estimate = lines.estimate {
        Text(verbatim: estimate)
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("account.credit.estimate")
      }
      ForEach(lines.asks) { ask in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: ask.recorded ? "checkmark.circle" : "percent")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
          Text(verbatim: ask.text)
            .monospacedDigit()
            .foregroundStyle(.secondary)
          Spacer(minLength: 6)
          if !ask.recorded {
            Button(t("account.credit.record")) {
              recording = CreditInterestPrefill(
                accountId: outlook.accountId, currency: outlook.currency,
                statementDay: ask.statementDay, amount: ask.amount)
            }
            .controlSize(.small)
            .accessibilityIdentifier("account.credit.record")
          }
        }
        .accessibilityElement(children: .combine)
      }
      ForEach(lines.cashLike, id: \.self) { line in
        Label {
          Text(verbatim: line).monospacedDigit()
        } icon: {
          Image(systemName: "banknote")
        }
        .appFont(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct CreditKey: Hashable {
  var account: UUID
  var generation: Int
}
