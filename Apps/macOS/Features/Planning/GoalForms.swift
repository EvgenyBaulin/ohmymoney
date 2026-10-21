import AppCore
import AppDatabase
import SwiftUI

// The forms of the Planning section, one sheet at a time on the root of the section. A form
// is content: system `Form`, no glass of its own. «Save» writes one `PlanningChange` — one
// step of ⌘Z — and closes the sheet only over a write that landed.

// MARK: - A goal

struct GoalForm: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  let original: Goal?
  @State private var goal = Goal(name: "", targetE4: .zero)
  @State private var hasDate = false
  @State private var loaded = false
  /// Every goal, the archived ones too, read when the form opens and after a deletion: a new
  /// goal is not saved over an archived one of its name.
  @State private var goals: [Goal] = []
  /// «Удалить старую…» asked about this archived goal.
  @State private var deleting: Goal?
  /// Why the archived goal was not deleted, as a key of the Planning table.
  @State private var deletionNote: String?

  var body: some View {
    let namesake = Self.namesake(of: goal, isNew: original == nil, among: goals)
    let taken = Self.liveNamesake(of: goal, among: goals)
    VStack(alignment: .leading) {
      Text(verbatim: t(original == nil ? "form.goal.new" : "form.goal.edit")).appFont(.headline)
      Form {
        TextField(t("form.name"), text: $goal.name)
          .onChange(of: goal.name) { _, _ in deletionNote = nil }
        if taken != nil {
          Label {
            Text(verbatim: t("form.goal.liveNamesake"))
          } icon: {
            Image(systemName: "exclamationmark.circle")
          }
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("goal.liveNamesake")
        } else if let namesake {
          namesakeRow(namesake)
        }
        LabeledContent(t("form.goal.target")) {
          HStack {
            AmountField(amount: $goal.targetE4, locale: environment.language.locale)
            CurrencyMenu(
              currencies: currencies, label: environment.language("entry.currency", table: "Entry"),
              selection: Binding(
                get: { goal.currency },
                set: {
                  goal = Self.inCurrency(
                    goal, $0, saved: original != nil,
                    rubPerUnit: compute.snapshot?.context.rubPerUnit ?? [:])
                }))
          }
        }
        Toggle(t("form.goal.hasDate"), isOn: $hasDate)
          .onChange(of: hasDate) { _, on in
            if on, goal.targetDate == nil { goal.targetDate = environment.today }
          }
        if hasDate {
          DatePicker(
            t("form.goal.date"),
            selection: Binding(
              get: { environment.calendar.startOfDay(goal.targetDate ?? environment.today) },
              set: { goal.targetDate = environment.calendar.day(of: $0) }),
            displayedComponents: .date)
        }
        LabeledContent(t("form.goal.plan")) {
          HStack {
            AmountField(
              amount: Binding(
                get: { goal.monthlyPlanE4 ?? .zero },
                set: { goal.monthlyPlanE4 = $0.isZero ? nil : $0 }),
              locale: environment.language.locale)
            Text(verbatim: goal.currency.code).foregroundStyle(.secondary)
          }
        }
        if let start = planStart {
          // Where the plan counts from, and what a month paid ahead does: the free sum's grey
          // line credits it to the months after.
          Text(
            verbatim: environment.format(
              "form.goal.planHint", table: "Planning", environment.dates.monthTitle(start))
          )
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
        GoalAccountFields(goal: $goal)
      }
      .formStyle(.grouped)
      FormButtons(
        title: environment.language("action.save"),
        enabled: !goal.name.trimmingCharacters(in: .whitespaces).isEmpty && goal.targetE4.raw > 0
          && namesake == nil && taken == nil
      ) {
        guard let dependencies else { return false }
        return Self.save(
          Self.saving(goal, hasDate: hasDate, original: original, today: environment.today),
          isNew: original == nil, with: PlanningActions(dependencies),
          references: environment.references)
      }
    }
    .padding(20)
    .sheetFrame(width: 460, height: 520)
    .onAppear {
      guard !loaded else { return }
      loaded = true
      goal = original ?? Self.newGoal(defaultCurrency: environment.defaultCurrency)
      hasDate = goal.targetDate != nil
      reloadGoals()
    }
    .confirmationDialog(
      environment.format("form.goal.delete.title", table: "Planning", deleting?.name ?? ""),
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible
    ) {
      Button(environment.language("action.delete"), role: .destructive) {
        if let deleting { delete(deleting) }
        deleting = nil
      }
      Button(environment.language("action.cancel"), role: .cancel) { deleting = nil }
    } message: {
      Text(verbatim: t("form.goal.delete.message"))
    }
  }

  /// Under the name of a new goal an archived goal has: «Такая цель есть в архиве», with
  /// «Вернуть» — that goal back as it was, the form closed — and «Удалить старую…», until the
  /// goal is found not deletable: then only «Вернуть» stays.
  @ViewBuilder
  private func namesakeRow(_ namesake: Goal) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label {
        Text(verbatim: t("form.goal.archivedNamesake"))
      } icon: {
        Image(systemName: "archivebox")
      }
      .foregroundStyle(.secondary)
      HStack {
        Button(environment.language("goals.restore", table: "Settings")) { restore(namesake) }
        if Self.offersDeletion(after: deletionNote) {
          Button(t("form.goal.deleteOld")) { askToDelete(namesake) }
        }
      }
      if let deletionNote {
        Text(verbatim: t(deletionNote))
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  /// The month the plan counts from as it will be saved; nil without a plan.
  private var planStart: MonthKey? {
    guard (goal.monthlyPlanE4 ?? .zero) > .zero else { return nil }
    return GoalRules.withPlanStart(goal, previous: original, today: environment.today)
      .planStartMonth ?? environment.today.monthKey
  }

  private func reloadGoals() {
    goals = (try? environment.references?.goals(includeArchived: true)) ?? []
  }

  private func restore(_ namesake: Goal) {
    guard let dependencies else { return }
    if GoalsBlock.restore(
      namesake.id, with: PlanningActions(dependencies), references: environment.references)
    {
      dismiss()
    }
  }

  /// The goal is not deleted when it has a contribution outside «Цели»: said under the buttons
  /// instead of asked.
  private func askToDelete(_ namesake: Goal) {
    guard let dependencies else { return }
    switch PlanningActions(dependencies).deletion(of: namesake) {
    case .failure(.contributionsOutsideGoals(let count)):
      deletionNote = Self.deletionNote(refusedBy: .contributionsOutsideGoals(count))
    case .failure(.notArchived), .none:
      deletionNote = Self.deletionNote(refusedBy: nil)
      reloadGoals()
    case .success:
      deletionNote = nil
      deleting = namesake
    }
  }

  /// «Удалить»: one step of ⌘Z; the form stays open with what was typed, and «Сохранить» is on.
  private func delete(_ namesake: Goal) {
    guard let dependencies else { return }
    switch PlanningActions(dependencies).deleteArchived(namesake) {
    case .deleted: deletionNote = nil
    case .refused(let refusal): deletionNote = Self.deletionNote(refusedBy: refusal)
    case .notWritten: deletionNote = Self.deletionNote(refusedBy: nil)
    }
    reloadGoals()
  }

  /// What is said under the buttons when the archived goal was not deleted, as a key of the
  /// Planning table: a contribution filed outside «Цели» keeps it for good; anything else — the
  /// goal no longer archived, a write that did not land — is «not saved» and may be tried again.
  static func deletionNote(refusedBy refusal: GoalRules.DeletionRefusal?) -> String {
    if case .contributionsOutsideGoals = refusal { return "form.goal.delete.outsideGoals" }
    return "form.notSaved"
  }

  /// Whether «Удалить старую…» is offered: not once the goal was found to have a contribution
  /// outside «Цели», since pressing it again could only repeat the refusal. Typing another name
  /// clears the note and brings the button back for the goal that name finds.
  static func offersDeletion(after note: String?) -> Bool {
    note != deletionNote(refusedBy: .contributionsOutsideGoals(1))
  }

  /// The goal the archive holds under the name of a new goal; nil for an edit, and while a live
  /// goal has the name.
  static func namesake(of goal: Goal, isNew: Bool, among goals: [Goal]) -> Goal? {
    guard isNew else { return nil }
    return GoalRules.archivedNamesake(of: goal.name, among: goals)
  }

  /// The live goal that already has the name the form holds — for a new goal, a rename and a
  /// goal brought back alike; the goal itself is never its own namesake. «Такая цель уже есть».
  static func liveNamesake(of goal: Goal, among goals: [Goal]) -> Goal? {
    GoalRules.liveNamesake(of: goal.name, excluding: goal.id, among: goals)
  }

  /// The goal as «Сохранить» writes it: no date unless it has one, and the month its plan
  /// counts from — this month for a plan that appears, none for a plan removed, the stored one
  /// otherwise (`GoalRules.withPlanStart`).
  static func saving(_ goal: Goal, hasDate: Bool, original: Goal?, today: DateOnly) -> Goal {
    var saved = goal
    if !hasDate { saved.targetDate = nil }
    return GoalRules.withPlanStart(saved, previous: original, today: today)
  }

  /// «Сохранить» of the form, one step of ⌘Z. A name the archive holds is never made a second
  /// time: a new goal named as an archived one — compared the way the entry line compares
  /// names — is not saved; the form offers to bring that goal back or to delete it first. A name
  /// a live goal has is refused by the write itself (`PlanningActions.save`).
  @discardableResult
  static func save(
    _ goal: Goal, isNew: Bool, with actions: PlanningActions, references: ReferenceRepository?
  ) -> Bool {
    if isNew, archivedGoal(named: goal.name, references: references) != nil { return false }
    return actions.save(goal)
  }

  /// The goal in the archive a new goal named `name` repeats; nil when none is there, or when
  /// a live goal is already called that.
  static func archivedGoal(named name: String, references: ReferenceRepository?) -> Goal? {
    guard let all = try? references?.goals(includeArchived: true) else { return nil }
    return GoalRules.archivedNamesake(of: name, among: all)
  }

  /// A new goal counts in the default currency until another is picked.
  static func newGoal(defaultCurrency: CurrencyCode) -> Goal {
    Goal(name: "", targetE4: .zero, currency: defaultCurrency)
  }

  /// The goal in `currency`. A saved goal has its target and its plan worked out in it at
  /// today's rate, to the cent — its progress stays what it was, since what was put in counts
  /// in the new currency at the rate of its day; the fields stay editable, and without a rate
  /// for either currency the figures stay. A new goal's figures are being typed in the currency
  /// picked, and stay as typed.
  static func inCurrency(
    _ goal: Goal, _ currency: CurrencyCode, saved: Bool, rubPerUnit: [CurrencyCode: Decimal]
  ) -> Goal {
    var goal = goal
    let from = goal.currency
    goal.currency = currency
    guard saved, from != currency else { return goal }
    func perUnit(_ code: CurrencyCode) -> Decimal? {
      code == .rub ? 1 : rubPerUnit[code].flatMap { $0 > 0 ? $0 : nil }
    }
    guard let fromRate = perUnit(from), let toRate = perUnit(currency) else { return goal }
    func converted(_ amount: AmountE4) -> AmountE4 {
      (try? AmountE4(decimal: DecimalMath.round(amount.decimal * fromRate / toRate, scale: 2)))
        ?? amount
    }
    goal.targetE4 = converted(goal.targetE4)
    goal.monthlyPlanE4 = goal.monthlyPlanE4.map(converted)
    return goal
  }

  /// The currencies offered: the enabled ones, and the goal's own when it is not among them.
  private var currencies: [CurrencyCode] {
    let enabled = PlanningChoices(compute, environment).currencies
    return enabled.contains(goal.currency) ? enabled : enabled + [goal.currency]
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

// MARK: - Where the money of a goal lies

/// «Где лежат деньги цели» — the account the money of the goal is kept on, or none — and «И
/// переводить на этот счёт при распределении»: ticked, a contribution from the sheet of an
/// allocation is a contribution and a transfer to that account in one step of ⌘Z; the sheet
/// may untick it for one line, and remembers it. A contribution never moves money by itself.
struct GoalAccountFields: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Binding var goal: Goal

  var body: some View {
    let accounts = Self.offered(
      compute.snapshot?.dataset.paymentMethods ?? [], keeping: goal.accountId)
    let locale = environment.language.locale
    let items = AccountCardChoices.items(
      accounts: FormAccounts.offered(accounts, locale: locale), cards: [],
      banks: compute.snapshot?.dataset.banks ?? [], among: accounts, locale: locale)
    Picker(
      t("form.goal.account"),
      selection: Binding(
        get: { goal.accountId }, set: { goal = Self.withAccount(goal, $0) })
    ) {
      Text(verbatim: t("form.goal.account.none")).tag(UUID?.none)
      ForEach(items) { Text(verbatim: $0.name).tag(Optional($0.id)) }
    }
    .accessibilityIdentifier("goal.account")
    Toggle(t("form.goal.transfers"), isOn: $goal.transfersOnContribution)
      .disabled(goal.accountId == nil)
      .accessibilityIdentifier("goal.transfers")
    Text(verbatim: t(goal.accountId == nil ? "form.goal.account.hint" : "form.goal.transfers.hint"))
      .appFont(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  /// The live accounts, and the goal's own when it was archived since — a form never drops what
  /// the goal holds.
  static func offered(_ accounts: [PaymentMethod], keeping kept: UUID?) -> [PaymentMethod] {
    accounts.filter { !$0.archived || $0.id == kept }
  }

  /// The goal with `accountId`; without an account there is nothing to transfer to, so the
  /// tick goes too.
  static func withAccount(_ goal: Goal, _ accountId: UUID?) -> Goal {
    var goal = goal
    goal.accountId = accountId
    if accountId == nil { goal.transfersOnContribution = false }
    return goal
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }

  static let keys = [
    "form.goal.account", "form.goal.account.none", "form.goal.transfers",
    "form.goal.account.hint", "form.goal.transfers.hint",
  ]
}

struct GoalMoveForm: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  let status: GoalStatus
  let withdraw: Bool
  @State private var amount: AmountE4 = .zero
  @State private var currency: CurrencyCode = .rub
  @State private var date = Date()
  @State private var method: UUID?
  @State private var loaded = false
  /// The bank's rates, read once when the form opens.
  @State private var rates = RateTable()

  var body: some View {
    let choices = PlanningChoices(compute, environment)
    let check =
      withdraw
      ? Self.withdrawal(
        amount, currency: currency, on: date, from: status, table: rates,
        calendar: environment.calendar) : .fits
    VStack(alignment: .leading) {
      Text(
        verbatim: environment.format(
          withdraw ? "form.withdraw.title" : "form.contribute.title", table: "Planning",
          status.goal.name)
      )
      .appFont(.headline)
      Form {
        LabeledContent(t("form.amount")) {
          HStack {
            AmountField(amount: $amount, locale: environment.language.locale)
            CurrencyMenu(
              currencies: currencies(choices),
              label: environment.language("entry.currency", table: "Entry"), selection: $currency)
          }
        }
        if currency != status.currency {
          // Counted in the goal at the rate of its own day.
          Text(
            verbatim: environment.format(
              "form.goal.otherCurrency", table: "Planning", status.currency.code)
          )
          .appFont(.caption).foregroundStyle(.secondary)
        }
        if amount.raw > 0, check == .tooMuch {
          Text(
            verbatim: environment.format(
              "form.withdraw.tooMuch", table: "Planning",
              environment.money.exact(status.saved, currency: status.currency))
          )
          .appFont(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        } else if amount.raw > 0, check == .noRate {
          Label {
            Text(
              verbatim: environment.format(
                "form.withdraw.noRate", table: "Planning", status.currency.code, currency.code))
          } icon: {
            Image(systemName: "hourglass")
          }
          .appFont(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
        DatePicker(t("form.date"), selection: $date)
        // A contribution names the account the money is set aside on; it moves no money on
        // it, so nothing is charged apart.
        AccountPicker(title: t("form.method"), accounts: choices.methods, selection: $method)
        if !withdraw, let needed = status.neededMonthly {
          Text(
            verbatim: environment.format(
              "goals.needed", table: "Planning",
              environment.money.rounded(needed, currency: status.currency))
          )
          .appFont(.caption).foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      FormButtons(
        title: t(withdraw ? "goals.withdraw" : "goals.contribute"),
        enabled: amount.raw > 0 && check == .fits,
        failure: {
          guard let dependencies else { return "" }
          return environment.format(
            PlanningActions(dependencies).goalFailureKey(currency: currency, on: date),
            table: "Planning", currency.code)
        }
      ) {
        guard let dependencies else { return false }
        return PlanningActions(dependencies).move(
          status.goal, amount: amount, currency: currency, on: date, account: method,
          withdraw: withdraw)
      }
    }
    .padding(20)
    .sheetFrame(width: 420, height: 320)
    .onAppear {
      guard !loaded else { return }
      loaded = true
      let start = Self.start(of: status, withdraw: withdraw)
      amount = start.amount
      currency = start.currency
      method = FormAccounts.account(nil, among: choices.methods)?.id
      rates = (try? environment.rates?.table()) ?? RateTable()
    }
  }

  /// Whether «Забрать» can take `amount` out of the goal.
  enum Withdrawal: Equatable {
    case fits
    /// More than the goal holds.
    case tooMuch
    /// In another currency, with no rate to count it in the goal's.
    case noRate
  }

  /// «Забрать» takes no more than is saved: `amount` of `currency` counted in the goal's
  /// currency as the goal will count it — the operation's rubles at the rate it is saved with,
  /// in the goal's currency at the rate of its day (`GoalMath`). Without a rate it is not let
  /// out: nothing would say how much of the goal it takes.
  static func withdrawal(
    _ amount: AmountE4, currency: CurrencyCode, on moment: Date, from status: GoalStatus,
    table: RateTable, calendar: CalendarContext
  ) -> Withdrawal {
    guard currency != status.currency else { return amount <= status.saved ? .fits : .tooMuch }
    var draft = TransactionDraft(occurredAt: moment, currency: currency, amount: amount)
    AppEnvironment.applyRate(to: &draft, from: table, calendar: calendar)
    let rubles: Decimal
    if currency == .rub {
      rubles = amount.decimal
    } else {
      guard let rate = draft.rate, rate > 0 else { return .noRate }
      rubles = amount.decimal * rate
    }
    guard
      let perUnit = FormAccounts.dayRates(table).perUnit(
        status.currency, on: calendar.day(of: moment)), perUnit > 0,
      let inGoal = try? AmountE4(decimal: rubles / perUnit)
    else { return .noRate }
    return inGoal <= status.saved ? .fits : .tooMuch
  }

  /// What the form opens with: the goal's currency, and for a contribution its monthly plan.
  static func start(of status: GoalStatus, withdraw: Bool) -> Money {
    Money(
      amount: withdraw ? .zero : (status.goal.monthlyPlanE4 ?? .zero), currency: status.currency)
  }

  private func currencies(_ choices: PlanningChoices) -> [CurrencyCode] {
    choices.currencies.contains(status.currency)
      ? choices.currencies : [status.currency] + choices.currencies
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

/// A currency menu beside an amount field; `label` is what VoiceOver says of it.
struct CurrencyMenu: View {
  let currencies: [CurrencyCode]
  let label: String
  @Binding var selection: CurrencyCode

  var body: some View {
    Picker(selection: $selection) {
      ForEach(currencies, id: \.self) { Text(verbatim: $0.code).tag($0) }
    } label: {
      EmptyView()
    }
    .labelsHidden()
    .fixedSize()
    .accessibilityLabel(Text(verbatim: label))
  }
}

// MARK: - Contribute and withdraw in a currency

extension PlanningActions {
  /// Why a contribution or a withdrawal in `currency` on `day` did not land: no rate to count
  /// it in rubles — the form has no field for one — or anything else. A key of the Planning
  /// table.
  func goalFailureKey(currency: CurrencyCode, on day: Date) -> String {
    environment.knowsRate(currency, on: day) ? "form.notSaved" : "form.rateMissing.goal"
  }

  /// «Contribute» — a good expense in the goal's subcategory — or «Withdraw» — a refund in it,
  /// which lowers the progress — of `amount` in `currency`: the goal's own, or another counted
  /// at the rate of its day. On `account` — the one chosen while live, else the main account —
  /// with nothing charged apart: money set aside for a goal does not leave the account. A goal
  /// without its subcategory yet gets it in the same write. One write, one step of ⌘Z.
  @discardableResult
  func move(
    _ goal: Goal, amount: AmountE4, currency: CurrencyCode, on day: Date, account: UUID?,
    withdraw: Bool
  ) -> Bool {
    var rows = PlanningRows.empty
    var goal = goal
    if goal.subcategoryId == nil {
      // The goal as the database has it now: a second click before the screen caught up must
      // not make a second subcategory.
      goal.subcategoryId =
        (try? environment.references?.goals(includeArchived: true))?
        .first { $0.id == goal.id }?.subcategoryId
      if goal.subcategoryId == nil, let tree,
        let made = SystemSubcategories.goalSubcategory(for: goal, tree: tree)
      {
        goal.subcategoryId = made.id
        rows.categories = [made]
        rows.goals = [goal]
      }
    }
    guard let subcategoryId = goal.subcategoryId else { return false }
    let accounts =
      (try? environment.references?.paymentMethods(includeArchived: true))
      ?? snapshot?.dataset.paymentMethods ?? []
    let accountId = FormAccounts.account(account, among: accounts)?.id ?? account
    let draft =
      withdraw
      ? GoalRules.withdrawalDraft(
        goal: goal, subcategoryId: subcategoryId, amount: amount, occurredAt: day,
        paymentMethodId: accountId, currency: currency)
      : GoalRules.contributionDraft(
        goal: goal, subcategoryId: subcategoryId, amount: amount, occurredAt: day,
        paymentMethodId: accountId, currency: currency)
    guard let entry = try? operation(draft, link: nil) else { return false }
    return apply(PlanningChange(created: [entry], upsert: rows))
  }
}
