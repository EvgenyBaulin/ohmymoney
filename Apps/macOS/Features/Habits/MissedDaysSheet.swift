import AppCore
import AppDatabase
import SwiftUI

/// What the wizard of the days missed writes: one operation per line, typed by hand, on its day
/// and account, in one write and one step of ⌘Z. The write expects every balance to be what the
/// wizard read: an operation written meanwhile refuses it, and the owner counts again.
@MainActor
enum MissedDaysWrite {
  /// The categories a line may take: live expense categories, «Не помню» included, without the
  /// other categories of the app (goals, loans, the count); a child after its parent, named
  /// «Родитель → Подкатегория».
  static func categoryChoices(_ categories: [CoreKit.Category]) -> [(id: UUID, title: String)] {
    let tree = CategoryTree(categories)
    func allowed(_ category: CoreKit.Category) -> Bool {
      guard category.kind == .expense, !category.archived else { return false }
      let role = tree.systemRole(of: category.id)
      return role == nil || role == .unknown
    }
    let byId = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    func title(_ category: CoreKit.Category) -> String {
      guard let parent = category.parentId.flatMap({ byId[$0] }) else { return category.name }
      return parent.name + " → " + category.name
    }
    var result: [(id: UUID, title: String)] = []
    let parents = categories.filter { $0.parentId == nil && allowed($0) }
      .sorted { ($0.sort, $0.name) < ($1.sort, $1.name) }
    for parent in parents {
      result.append((parent.id, title(parent)))
      for child in categories.filter({ $0.parentId == parent.id && allowed($0) })
        .sorted(by: { ($0.sort, $0.name) < ($1.sort, $1.name) })
      {
        result.append((child.id, title(child)))
      }
    }
    return result
  }

  /// «Не помню» of the expenses.
  static func unknownCategory(_ categories: [CoreKit.Category]) -> UUID? {
    let tree = CategoryTree(categories)
    return categories.first {
      $0.kind == .expense && !$0.archived && tree.systemRole(of: $0.id) == .unknown
    }?.id
  }

  /// The change of the lines: each an expense at noon of its day, from its account in its
  /// currency, with the quality of its category.
  static func change(
    lines: [MissedDayLine], expected: [BalanceKey: AmountE4], categories: [CoreKit.Category],
    environment: AppEnvironment, now: Date = Date()
  ) throws -> PlanningChange {
    let tree = CategoryTree(categories)
    let calendar = environment.calendar
    var created: [TransactionEntry] = []
    for line in lines {
      let decision = QualityResolver.resolve(categoryId: line.categoryId, categories: tree)
      let note = line.note.trimmingCharacters(in: .whitespacesAndNewlines)
      var draft = TransactionDraft(
        kind: .expense, occurredAt: calendar.noon(of: line.day), currency: line.key.currency,
        amount: line.amountE4, note: note.isEmpty ? nil : note,
        paymentMethodId: line.key.accountId,
        parts: [
          PartDraft(
            categoryId: line.categoryId, quality: decision.quality,
            qualitySource: decision.source, amount: line.amountE4)
        ])
      environment.applyRate(to: &draft)
      created.append(
        try draft.materialize(
          now: now, timeZone: calendar.timeZone,
          rublesConverter: environment.rublesConverter(for: draft)))
    }
    let keys = Set(lines.map(\.key))
    return PlanningChange(
      created: created, at: now, expectingBalances: expected.filter { keys.contains($0.key) })
  }
}

/// «Восстановить пропущенные дни»: first the balances — what is on each account now; the app
/// says how much went unwritten —, then that money laid out over the days, each line with a
/// category («Не помню» too). Only the accounts in «Всего» that were counted at least once are
/// asked about, and while the hidden accounts are covered they are not among them.
struct MissedDaysSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  let gap: MissedDays

  private enum Step { case balances, days }

  @State private var step = Step.balances
  @State private var balances: [MissedDaysBalance] = []
  @State private var actual: [BalanceKey: AmountE4] = [:]
  @State private var lines: [MissedDayLine] = []
  @State private var categories: [CoreKit.Category] = []
  @State private var failure: String?
  @State private var loaded = false

  private func t(_ key: String) -> String { HabitText.t(key, environment) }
  private var money: MoneyFormatter { environment.money }

  private var missing: [BalanceKey: AmountE4] {
    var result: [BalanceKey: AmountE4] = [:]
    for balance in balances {
      let shortfall = MissedDaysWizard.shortfall(
        expected: balance.expected, actual: actual[balance.key] ?? balance.expected)
      if shortfall.raw > 0 { result[balance.key] = shortfall }
    }
    return result
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t("missed.title")).appFont(.headline)
      Text(verbatim: subtitle)
        .appFont(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Text(verbatim: t(step == .balances ? "missed.step.balances" : "missed.step.days"))
        .appFont(.subheadline.weight(.semibold))
      Form {
        switch step {
        case .balances: balancesStep
        case .days: daysStep
        }
      }
      .formStyle(.grouped)
      if let failure {
        Label {
          Text(verbatim: failure).fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.octagon")
        }
        .appFont(.callout).foregroundStyle(.red)
      }
      buttons
    }
    .padding(20)
    .sheetFrame(width: 600, height: 600)
    .onAppear(perform: load)
    .accessibilityIdentifier("missed.sheet")
  }

  private var subtitle: String {
    let first = gap.days.first ?? gap.today
    return HabitText.f(
      "missed.subtitle", environment, environment.dates.dayAndMonth(first),
      environment.dates.dayAndMonth(gap.today))
  }

  // MARK: Step 1: balances

  @ViewBuilder private var balancesStep: some View {
    if balances.isEmpty {
      Text(verbatim: t("missed.balances.noAccounts"))
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    } else {
      Section {
        ForEach(balances) { balance in balanceRow(balance) }
      } footer: {
        Text(verbatim: t("missed.balances.hint")).appFont(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func balanceRow(_ balance: MissedDaysBalance) -> some View {
    let typed = actual[balance.key] ?? balance.expected
    let shortfall = MissedDaysWizard.shortfall(expected: balance.expected, actual: typed)
    let currency = balance.key.currency
    return VStack(alignment: .leading, spacing: 4) {
      LabeledContent {
        HStack {
          AmountField(
            amount: Binding(
              get: { actual[balance.key] ?? balance.expected },
              set: { actual[balance.key] = $0 }),
            locale: environment.language.locale)
          Text(verbatim: currency.code).foregroundStyle(.secondary)
        }
      } label: {
        Text(verbatim: balance.account.name)
      }
      Group {
        if shortfall.raw > 0 {
          Text(
            verbatim: HabitText.f(
              "missed.balances.missing", environment,
              money.exact(balance.expected, currency: currency),
              money.exact(shortfall, currency: currency)))
        } else if shortfall.raw < 0 {
          Text(verbatim: t("missed.balances.more"))
        } else {
          Text(
            verbatim: HabitText.f(
              "missed.balances.expected", environment,
              money.exact(balance.expected, currency: currency)))
        }
      }
      .appFont(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }
    .accessibilityIdentifier("missed.balance")
  }

  // MARK: Step 2: days

  @ViewBuilder private var daysStep: some View {
    let missing = self.missing
    if missing.isEmpty {
      Text(verbatim: t("missed.balances.none")).foregroundStyle(.secondary)
    } else {
      ForEach(balances.filter { missing[$0.key] != nil }) { balance in
        let left = MissedDaysWizard.left(
          missing[balance.key] ?? .zero, lines: lines, key: balance.key)
        Section {
          ForEach($lines.filter { $0.wrappedValue.key == balance.key }) { line in
            lineRow(line)
          }
          Button(t("missed.days.add")) { addLine(balance.key, amount: max(left, .zero)) }
            .buttonStyle(.borderless)
        } header: {
          Text(verbatim: balance.account.name + " · " + balance.key.currency.code)
        } footer: {
          Text(
            verbatim: left.isZero
              ? t("missed.days.done")
              : HabitText.f(
                "missed.days.left", environment, money.exact(left, currency: balance.key.currency))
          )
          .appFont(.caption.monospacedDigit())
          .foregroundStyle(left.isZero ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
        }
      }
      Section {
        Button(t("missed.days.allUnknown")) { fillUnknown() }
          .disabled(MissedDaysWrite.unknownCategory(categories) == nil)
      } footer: {
        Text(verbatim: t("missed.days.hint")).appFont(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func lineRow(_ line: Binding<MissedDayLine>) -> some View {
    let choices = MissedDaysWrite.categoryChoices(categories)
    return VStack(alignment: .leading, spacing: 6) {
      HStack {
        Picker("", selection: line.day) {
          ForEach(gap.days, id: \.self) { day in
            Text(verbatim: environment.dates.dayAndMonth(day)).tag(day)
          }
        }
        .labelsHidden()
        .frame(maxWidth: 150)
        AmountField(amount: line.amountE4, locale: environment.language.locale)
        Button {
          lines.removeAll { $0.id == line.wrappedValue.id }
        } label: {
          Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text(verbatim: t("missed.days.remove")))
      }
      Picker(t("missed.days.category"), selection: line.categoryId) {
        Text(verbatim: "—").tag(UUID?.none)
        ForEach(choices, id: \.id) { choice in
          Text(verbatim: choice.title).tag(UUID?.some(choice.id))
        }
      }
      TextField(t("missed.days.note"), text: line.note)
    }
    .accessibilityIdentifier("missed.line")
  }

  // MARK: Buttons

  private var buttons: some View {
    HStack {
      Button(t("missed.cancel")) { dismiss() }
        .keyboardShortcut(.cancelAction)
      Spacer()
      if step == .days {
        Button(t("missed.back")) { step = .balances }
      }
      if step == .balances {
        Button(t("missed.next")) { toDays() }
          .keyboardShortcut(.defaultAction)
          .disabled(balances.isEmpty)
      } else {
        Button(t("missed.save")) { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(missing.isEmpty)
          .accessibilityIdentifier("missed.save")
      }
    }
  }

  // MARK: Work

  private func load() {
    guard !loaded, let snapshot = compute.snapshot else { return }
    loaded = true
    balances = MissedDaysWizard.balances(snapshot.planning.accounts)
    categories = snapshot.dataset.categories
  }

  /// From the balances to the days: each balance with money missing gets it spread evenly over
  /// the days, the lines the owner already laid out for it kept while they still fit.
  private func toDays() {
    failure = nil
    let missing = self.missing
    lines.removeAll { missing[$0.key] == nil }
    for (key, amount) in missing.sorted(by: { $0.key < $1.key })
    where !lines.contains(where: { $0.key == key }) {
      lines += MissedDaysWizard.spread(amount, over: gap.days, key: key)
    }
    step = .days
  }

  private func addLine(_ key: BalanceKey, amount: AmountE4) {
    lines.append(MissedDayLine(day: gap.days.last ?? gap.today, key: key, amountE4: amount))
  }

  private func fillUnknown() {
    guard let unknown = MissedDaysWrite.unknownCategory(categories) else { return }
    for index in lines.indices where lines[index].categoryId == nil {
      lines[index].categoryId = unknown
    }
  }

  private func save() {
    failure = nil
    let missing = self.missing
    if let problem = MissedDaysWizard.problem(lines: lines, missing: missing) {
      failure = text(of: problem)
      return
    }
    guard let dependencies else { return }
    let expected = Dictionary(
      balances.map { ($0.key, $0.expected) }, uniquingKeysWith: { first, _ in first })
    do {
      let change = try MissedDaysWrite.change(
        lines: lines, expected: expected, categories: categories, environment: environment)
      guard dependencies.store.apply(change) else {
        failure = t("missed.changed")
        return
      }
      AppLog.info(
        "habits.missedRestored", .db, "the days missed were restored from the balances",
        [LogPair("operations", .count(lines.count)), LogPair("days", .count(gap.days.count))])
      dismiss()
    } catch {
      failure = t("missed.notSaved")
    }
  }

  private func text(of problem: MissedDaysWizard.Problem) -> String {
    switch problem {
    case .noLines, .notLaidOut: t("missed.problem.left")
    case .lineWithoutCategory: t("missed.problem.category")
    case .lineNotPositive: t("missed.problem.amount")
    }
  }
}
