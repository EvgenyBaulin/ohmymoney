import AppCore
import SwiftUI

/// «Правила распределения»: how an income is usually allocated — N % of it (after the tax of
/// self-employment) or a fixed sum, into a goal, to an account or to the safety cushion; one rule
/// per goal and one for the cushion. Rules only suggest: the sheet of an income fills its lines
/// from them, and nothing is written without «Записать» there. Each save is one step of ⌘Z.
/// Opened from the sheet of an income and from «Настройки → Планирование».
struct AllocationRulesSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  @State private var editing: AllocationRule?

  var body: some View {
    let snapshot = compute.snapshot
    let rules = (snapshot?.dataset.allocationRules ?? []).sorted { $0.sort < $1.sort }
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: AllocationText.t("rules.title", environment))
        .appFont(.headline)
      Text(verbatim: AllocationText.t("rules.hint", environment))
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      List {
        if rules.isEmpty {
          Text(verbatim: AllocationText.t("rules.empty", environment))
            .foregroundStyle(.secondary)
        }
        ForEach(rules) { rule in
          HStack {
            Toggle(
              isOn: Binding(
                get: { rule.active },
                set: { active in
                  var copy = rule
                  copy.active = active
                  save([copy])
                })
            ) {
              VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: AllocationRulesText.target(rule.target, snapshot, environment))
                Text(verbatim: AllocationRulesText.amount(rule.amount, environment))
                  .appFont(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            Spacer()
            Button(AllocationText.t("rules.edit", environment)) { editing = rule }
              .buttonStyle(.borderless)
            Button {
              guard let dependencies else { return }
              AllocationActions(dependencies).save(rules: [], deleting: [rule.id])
            } label: {
              Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(verbatim: environment.language("action.delete")))
          }
        }
        .onMove { from, to in
          var ordered = rules
          ordered.move(fromOffsets: from, toOffset: to)
          save(
            ordered.enumerated().map { index, rule in
              var copy = rule
              copy.sort = index
              return copy
            })
        }
      }
      .frame(minHeight: 180)
      HStack {
        Button(AllocationText.t("rules.add", environment)) {
          editing = AllocationRule(
            target: .cushion(nil), amount: .percent(10), sort: (rules.last?.sort ?? -1) + 1)
        }
        .accessibilityIdentifier("allocation.rules.add")
        Spacer()
        Button(environment.language("action.ok")) { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .sheetFrame(minWidth: 440, idealWidth: 480, minHeight: 360)
    .sheet(item: $editing) { rule in
      AllocationRuleForm(rule: rule)
        .handingOver(dependencies)
    }
  }

  private func save(_ rules: [AllocationRule]) {
    guard let dependencies else { return }
    AllocationActions(dependencies).save(rules: rules)
  }
}

/// The words of a rule.
@MainActor
enum AllocationRulesText {
  static func target(
    _ target: AllocationTarget, _ snapshot: DataSnapshot?, _ environment: AppEnvironment
  ) -> String {
    switch target {
    case .goal(let id):
      let name = snapshot?.dataset.goals.first { $0.id == id }?.name ?? ""
      return AllocationText.format("rules.target.goal", environment, name)
    case .account(let id):
      let name = snapshot?.dataset.paymentMethods.first { $0.id == id }?.name ?? ""
      return AllocationText.format("rules.target.account", environment, name)
    case .cushion:
      return AllocationText.t("allocation.line.cushion", environment)
    }
  }

  static func amount(_ amount: AllocationAmount, _ environment: AppEnvironment) -> String {
    switch amount {
    case .percent(let percent):
      return AllocationText.format(
        "rules.amount.percent", environment, environment.money.number(percent))
    case .fixed(let amount, let currency):
      return environment.money.rounded(amount, currency: currency)
    }
  }

  /// A percent typed by hand, 0 < p ≤ 100; `nil` for anything else.
  nonisolated static func percent(_ text: String) -> Decimal? {
    guard let value = DecimalMath.parse(text), value > 0, value <= 100 else { return nil }
    return value
  }

  /// What keeps a rule from being saved: a goal that has a rule already, a second rule of the
  /// cushion, an account not chosen, an amount of nothing. `nil` — it may be saved.
  nonisolated static func refusal(
    _ rule: AllocationRule, among rules: [AllocationRule]
  ) -> String? {
    let others = rules.filter { $0.id != rule.id }
    switch rule.target {
    case .goal(let id):
      if others.contains(where: { $0.target == .goal(id) }) { return "rules.refusal.goalTaken" }
    case .cushion:
      if others.contains(where: {
        if case .cushion = $0.target { return true }
        return false
      }) {
        return "rules.refusal.cushionTaken"
      }
    case .account:
      break
    }
    switch rule.amount {
    case .percent(let percent): if percent <= 0 || percent > 100 { return "rules.refusal.amount" }
    case .fixed(let amount, _): if amount.raw <= 0 { return "rules.refusal.amount" }
    }
    return nil
  }
}

/// One rule: where to and how much.
struct AllocationRuleForm: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  let rule: AllocationRule

  enum Kind: String, Hashable { case goal, account, cushion }

  @State private var kind: Kind = .cushion
  @State private var goalId: UUID?
  @State private var accountId: UUID?
  @State private var byPercent = true
  @State private var percentText = "10"
  @State private var fixed: AmountE4 = .zero
  @State private var currency: CurrencyCode = .rub
  @State private var started = false

  var body: some View {
    let snapshot = compute.snapshot
    let goals = (snapshot?.dataset.goals ?? []).filter { !$0.archived }
    let accounts = (snapshot?.dataset.paymentMethods ?? []).filter { !$0.archived }
    let draft = self.draft
    let refusal = draft.flatMap {
      AllocationRulesText.refusal($0, among: snapshot?.dataset.allocationRules ?? [])
    }
    VStack(alignment: .leading) {
      Text(verbatim: AllocationText.t("rules.form.title", environment))
        .appFont(.headline)
      Form {
        Picker(AllocationText.t("rules.form.target", environment), selection: $kind) {
          Text(verbatim: AllocationText.t("rules.form.goal", environment)).tag(Kind.goal)
          Text(verbatim: AllocationText.t("rules.form.account", environment)).tag(Kind.account)
          Text(verbatim: AllocationText.t("allocation.line.cushion", environment))
            .tag(Kind.cushion)
        }
        switch kind {
        case .goal:
          Picker(AllocationText.t("rules.form.goal", environment), selection: $goalId) {
            ForEach(goals) { goal in Text(verbatim: goal.name).tag(UUID?.some(goal.id)) }
          }
        case .account:
          Picker(AllocationText.t("rules.form.account", environment), selection: $accountId) {
            ForEach(accounts) { account in
              Text(verbatim: account.name).tag(UUID?.some(account.id))
            }
          }
        case .cushion:
          Text(verbatim: AllocationText.t("rules.form.cushionHint", environment))
            .appFont(.caption)
            .foregroundStyle(.secondary)
        }
        Picker(AllocationText.t("rules.form.how", environment), selection: $byPercent) {
          Text(verbatim: AllocationText.t("rules.form.percent", environment)).tag(true)
          Text(verbatim: AllocationText.t("rules.form.fixed", environment)).tag(false)
        }
        .pickerStyle(.segmented)
        if byPercent {
          LabeledContent(AllocationText.t("rules.form.percentOfBase", environment)) {
            HStack {
              TextField(text: $percentText) { Text(verbatim: "10") }
                .frame(width: 80)
              Text(verbatim: "%").foregroundStyle(.secondary)
            }
          }
        } else {
          LabeledContent(AllocationText.t("rules.form.sum", environment)) {
            HStack {
              AmountField(amount: $fixed).frame(width: 120)
              Text(verbatim: environment.money.symbol(for: currency))
                .foregroundStyle(.secondary)
            }
          }
        }
        if let refusal {
          Text(verbatim: AllocationText.t(refusal, environment))
            .appFont(.caption)
            .foregroundStyle(.red)
        }
      }
      .formStyle(.grouped)
      FormButtons(
        title: environment.language("action.save"), enabled: draft != nil && refusal == nil
      ) {
        guard let dependencies, let draft else { return false }
        return AllocationActions(dependencies).save(rules: [draft])
      }
    }
    .padding(20)
    .sheetFrame(width: 440, height: 400)
    .onAppear {
      guard !started else { return }
      started = true
      currency = snapshot?.dataset.accountSettings.defaultCurrency ?? .rub
      switch rule.target {
      case .goal(let id): kind = .goal; goalId = id
      case .account(let id): kind = .account; accountId = id
      case .cushion: kind = .cushion
      }
      switch rule.amount {
      case .percent(let percent):
        byPercent = true
        percentText = environment.money.number(percent)
      case .fixed(let amount, let code):
        byPercent = false
        fixed = amount
        currency = code
      }
    }
  }

  /// The rule as the form says it; `nil` while a goal or an account is not chosen or the
  /// percent does not read.
  private var draft: AllocationRule? {
    var draft = rule
    switch kind {
    case .goal:
      guard let goalId else { return nil }
      draft.target = .goal(goalId)
    case .account:
      guard let accountId else { return nil }
      draft.target = .account(accountId)
    case .cushion:
      if case .cushion = rule.target {} else { draft.target = .cushion(nil) }
    }
    if byPercent {
      guard let percent = AllocationRulesText.percent(percentText) else { return nil }
      draft.amount = .percent(percent)
    } else {
      draft.amount = .fixed(fixed, currency)
    }
    return draft
  }
}
