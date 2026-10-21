import AppCore
import SwiftUI

/// What the owner typed in «Кэшбэк» of the ↓ panel, and what the save writes.
struct CashbackFieldState: Equatable {
  var text: String = ""

  /// An amount, a percent, or what does not read; `nil` for an empty field.
  var input: CashbackInput? { CashbackInput.read(text) }

  /// What the operation keeps: a typed amount in the money that moves on the account, a typed
  /// percent of that money rounded the way the account's bank rounds; `nil` when the field is
  /// empty or does not read — an unreadable figure never stops the save, the rules then say what
  /// to expect.
  func value(on draft: TransactionDraft, rounding: CashbackRounding = .standard) -> Money? {
    switch input {
    case .amount(let amount):
      return Money(amount: amount, currency: CashbackMath.movedMoney(of: draft).currency)
    case .percent(let percent):
      return CashbackMath.amount(of: percent, on: draft, rounding: rounding)
    case .unreadable, nil:
      return nil
    }
  }

  /// A typed percent that «Запомнить» can turn into a rule.
  var typedPercent: CashbackPercent? {
    if case .percent(let percent) = input { return percent }
    return nil
  }
}

extension CashbackFieldState {
  /// The field of an operation opened again: the figure kept with it, written out as typed, so
  /// that a save of any other change keeps it. Empty for no figure and for one below zero; empty
  /// too, when `draft` is given, for a figure in money the account no longer moves — it says
  /// nothing about the operation, and the save leaves it out as a write would.
  init(kept: Money?, on draft: TransactionDraft? = nil) {
    self.init()
    guard let kept, !kept.amount.isNegative else { return }
    if let draft, CashbackMath.movedMoney(of: draft).currency != kept.currency { return }
    text = NumberText.plain(kept.amount.decimal)
  }
}

/// What the field needs to know of the operation: whose rules price it, its month and category.
struct CashbackFieldContext: Equatable {
  var holder: CashbackHolder?
  /// «Black», «Т-Банк › Black»: named in the captions.
  var holderName: String?
  var month: MonthKey
  /// The one category of every part; `nil` when there is none or the parts differ.
  var categoryId: UUID?
  var accountId: UUID?
  var movedCurrency: CurrencyCode
  /// The parts are filed under different categories: a rule of one category cannot be meant.
  var mixedCategories: Bool = false
  /// The rules that price the holder: its own and, for a card, its account's — to say which one
  /// priced the operation.
  var rules: [CashbackRule] = []
  /// The rules the holder keeps itself: a card's own, which differ from its account's.
  var ownRules: [CashbackRule] = []
  /// How the bank of the account rounds, for a typed percent.
  var rounding: CashbackRounding = .standard
  /// The names of the categories, for the captions.
  var categoryNames: [UUID: String] = [:]
  /// The operation's year is not this one: «только в сентябре 2025».
  var thisYear: Int? = nil

  /// The account a rule is written for: an account holder names itself, a card holder its
  /// account.
  private var ruleAccountId: UUID? {
    if case .account(let id) = holder { return id }
    return accountId
  }

  /// The rule «Запомнить» writes for `percent`: always, or only in the operation's month. It is
  /// the account's rule — the card follows it —, except where the card already keeps a rule of
  /// its own for that month and category: that one would hide the account's, so it is the one
  /// that changes.
  func rule(_ percent: CashbackPercent, onlyThisMonth: Bool) -> CashbackRule? {
    guard holder != nil, let accountId = ruleAccountId, let categoryId, !mixedCategories else {
      return nil
    }
    let month = onlyThisMonth ? self.month : nil
    var cardId: UUID?
    if case .card(let id) = holder,
      ownRules.contains(where: { $0.month == month && $0.categoryId == categoryId })
    {
      cardId = id
    }
    return CashbackRule(
      accountId: accountId, cardId: cardId, categoryId: categoryId, month: month,
      percent: percent)
  }

  /// Why «Запомнить» is off, as a key of Entry; `nil` when it is on. It is on only when a rule
  /// can be written: a holder whose account is known, and one category.
  var rememberRefusalKey: String? {
    if holder == nil || ruleAccountId == nil { return "entry.cashback.noAccount" }
    if mixedCategories { return "entry.cashback.rememberSplit" }
    if categoryId == nil { return "entry.cashback.rememberNoCategory" }
    return nil
  }
}

/// The row «Кэшбэк» of the ↓ panel: a field for an amount («45») or a percent («5%») in the
/// money that moves on the account, with what the rules expect as its placeholder, and one
/// caption that says where the figure comes from — a rule, the owner, or nothing — with a
/// symbol, never by colour alone. A typed percent may become a rule of the card with
/// «Запомнить»: always, or only in the operation's month.
struct CashbackField: View {
  @Dependency(\.environment) private var environment
  @Binding var state: CashbackFieldState
  let draft: TransactionDraft
  let expectation: CashbackExpectation?
  let context: CashbackFieldContext
  let remember: (CashbackRule) -> Void
  /// The field as wide as it is given and the caption under it from the leading edge — the form
  /// at the side of the window —, rather than both at the trailing edge of the ↓ panel.
  let leading: Bool

  init(
    state: Binding<CashbackFieldState>, draft: TransactionDraft,
    expectation: CashbackExpectation?, context: CashbackFieldContext, leading: Bool = false,
    remember: @escaping (CashbackRule) -> Void
  ) {
    _state = state
    self.draft = draft
    self.expectation = expectation
    self.context = context
    self.leading = leading
    self.remember = remember
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Entry") }

  var body: some View {
    VStack(alignment: leading ? .leading : .trailing, spacing: 4) {
      HStack(spacing: 4) {
        TextField(text: $state.text) {
          Text(verbatim: placeholder)
        }
        .labelsHidden()
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
        .frame(width: leading ? nil : 140)
        .accessibilityLabel(Text(verbatim: t("entry.cashback")))
        .accessibilityIdentifier("entry.cashback")
        Text(verbatim: environment.money.symbol(for: context.movedCurrency))
          .foregroundStyle(.secondary)
      }
      caption
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(leading ? .leading : .trailing)
        .fixedSize(horizontal: false, vertical: leading)
    }
  }

  /// «≈ 35» from the rules of an account that rounds to whole units, «≈ 35.50» to the kopeck or
  /// from a figure typed for the operation, «—» without.
  private var placeholder: String {
    guard let expectation else { return "—" }
    var whole = context.rounding.precision == .whole
    if case .override = expectation.source { whole = false }
    let digits = whole ? 0...0 : 2...2
    return "≈ " + NumberText.decimal(expectation.money.amount.decimal, fractionDigits: digits)
  }

  @ViewBuilder
  private var caption: some View {
    switch state.input {
    case .unreadable(let problem):
      note("exclamationmark.triangle", problemText(problem) + " " + t("entry.cashback.ignored"))
    case .amount:
      HStack(spacing: 6) {
        note("pencil", t("entry.cashback.typed"))
        Button {
          state.text = ""
        } label: {
          Label {
            Text(verbatim: t("entry.cashback.clear"))
          } icon: {
            Image(systemName: "xmark.circle")
          }
        }
        .buttonStyle(.borderless)
      }
    case .percent(let percent):
      HStack(spacing: 6) {
        note("percent", typedPercentLine(percent))
        rememberMenu(percent)
      }
    case nil:
      rulesCaption
    }
  }

  @ViewBuilder
  private var rulesCaption: some View {
    if case .override = expectation?.source {
      // The placeholder shows the figure kept with the operation, not what the rules give.
      note("pencil", t("entry.cashback.typed"))
    } else if let expectation, case .rules(let ids) = expectation.source {
      let used = context.rules.filter { ids.contains($0.id) }
      if used.count == 1, let rule = used.first {
        note("checkmark.circle", ruleText(rule))
      } else {
        note(
          "checkmark.circle",
          environment.format("entry.cashback.byRules", table: "Entry", context.holderName ?? ""))
      }
    } else {
      note(
        "info.circle",
        environment.format("entry.cashback.noRules", table: "Entry", context.holderName ?? ""))
    }
  }

  /// «7 % от 1,000.00 ₽ = 70.00 ₽».
  private func typedPercentLine(_ percent: CashbackPercent) -> String {
    let moved = CashbackMath.movedMoney(of: draft)
    let result =
      CashbackMath.amount(of: percent, on: draft, rounding: context.rounding)
      ?? Money(amount: .zero, currency: moved.currency)
    return environment.format(
      "entry.cashback.ofBase", table: "Entry", environment.money.percent(percent),
      environment.money.exact(moved.amount.magnitude, currency: moved.currency),
      environment.money.exact(result.amount, currency: result.currency))
  }

  private func rememberMenu(_ percent: CashbackPercent) -> some View {
    let refusal = context.rememberRefusalKey
    let category = context.categoryId.flatMap { context.categoryNames[$0] } ?? ""
    let value = environment.money.percent(percent)
    return Menu {
      Button(
        environment.format("entry.cashback.rememberAlways", table: "Entry", value, category)
      ) {
        if let rule = context.rule(percent, onlyThisMonth: false) { remember(rule) }
      }
      Button(
        environment.format(
          "entry.cashback.rememberMonth", table: "Entry", monthIn(context.month), value, category)
      ) {
        if let rule = context.rule(percent, onlyThisMonth: true) { remember(rule) }
      }
    } label: {
      Text(verbatim: t("entry.cashback.remember"))
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .disabled(refusal != nil)
    .help(refusal.map(t) ?? "")
    .accessibilityIdentifier("entry.cashback.remember")
  }

  /// «10 % — «Кафе и рестораны», только в сентябре».
  private func ruleText(_ rule: CashbackRule) -> String {
    CardText.ruleLine(rule, categories: context.categoryNames, environment)
  }

  private func monthIn(_ month: MonthKey) -> String {
    environment.dates.monthIn(
      month, thisYear: context.thisYear ?? environment.today.year,
      words: environment.language(DateFormatting.monthInKey(month)))
  }

  private func problemText(_ problem: CashbackInput.Problem) -> String {
    switch problem {
    case .percentAboveHundred: t("entry.cashback.percentAboveHundred")
    case .percentTooPrecise: t("entry.cashback.percentTooPrecise")
    case .malformed, .negative, .tooLarge: t("entry.cashback.unreadable")
    }
  }

  private func note(_ symbol: String, _ text: String) -> some View {
    Label {
      Text(verbatim: text)
    } icon: {
      Image(systemName: symbol)
    }
  }
}
