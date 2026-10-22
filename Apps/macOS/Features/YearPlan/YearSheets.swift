import AppCore
import SwiftUI

// The editors of the page «Год», one sheet at a time. Each is system `Form`, no glass of its own.
// «Save» writes one call of the store — one step of ⌘Z — and closes the sheet only over a write
// that landed (`FormButtons`).

// MARK: - A limit for one month

/// «На декабрь — 20 000»: the limit of one month, which returns to its usual amount after it.
struct MonthLimitSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  let budget: UUID?
  let month: MonthKey?
  @State private var chosenBudget: UUID?
  @State private var chosenMonth = MonthKey(year: 2000, month: 1)
  @State private var amount: AmountE4 = .zero
  @State private var loaded = false

  var body: some View {
    let budgets = liveBudgets
    VStack(alignment: .leading) {
      Text(verbatim: YearText.t("year.limit.form.title", environment)).appFont(.headline)
      Form {
        Picker(YearText.t("year.limit.form.limit", environment), selection: $chosenBudget) {
          Text(verbatim: "—").tag(UUID?.none)
          ForEach(budgets) { budget in
            Text(verbatim: name(of: budget)).tag(Optional(budget.id))
          }
        }
        Picker(YearText.t("year.limit.form.month", environment), selection: $chosenMonth) {
          ForEach(months, id: \.self) { month in
            Text(verbatim: environment.dates.monthTitle(month)).tag(month)
          }
        }
        LabeledContent(YearText.t("year.limit.form.amount", environment)) {
          AmountField(amount: $amount)
        }
        if let usual = usual(in: budgets) {
          Text(
            verbatim: YearText.f(
              "year.limit.form.usual", environment, environment.money.rounded(usual)
            )
          )
          .appFont(.caption)
          .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      FormButtons(
        title: environment.language("action.save"),
        enabled: chosenBudget != nil && amount.raw > 0
      ) {
        guard let dependencies, let chosenBudget else { return false }
        return YearActions(dependencies).setMonthLimit(
          amount, budget: chosenBudget, month: chosenMonth)
      }
    }
    .padding(20)
    .sheetFrame(width: 460, height: 340)
    .onAppear {
      guard !loaded else { return }
      loaded = true
      let today = environment.today.monthKey
      chosenMonth = month ?? today.next
      chosenBudget = budget ?? budgets.first?.id
      if let exception = compute.snapshot?.dataset.yearPlan.monthExceptions.last(where: {
        $0.budgetId == chosenBudget && $0.month == chosenMonth
      }) {
        amount = exception.amountE4
      } else if let usual = usual(in: budgets) {
        amount = usual
      }
    }
  }

  /// The limits on a category: the only ones that have a month to raise them in.
  private var liveBudgets: [Budget] {
    (compute.snapshot?.dataset.planning.budgets ?? []).filter { $0.scope == .category }
  }

  /// This month and the eleven after it.
  private var months: [MonthKey] {
    let first = environment.today.monthKey
    return (0..<12).map { first.adding(months: $0) }
  }

  private func name(of budget: Budget) -> String {
    PlanningText.limitName(
      budget, tree: compute.snapshot?.ledger.tree ?? CategoryTree(), environment)
  }

  private func usual(in budgets: [Budget]) -> AmountE4? {
    budgets.first { $0.id == chosenBudget }?.amountE4
  }
}

// MARK: - The buffer

/// The sum set aside for the unexpected; 0 switches it off. The income of the month is noted with
/// it, so the offer to raise it comes only when income grows.
struct BufferSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @State private var amount: AmountE4 = .zero
  @State private var loaded = false

  var body: some View {
    VStack(alignment: .leading) {
      Text(verbatim: YearText.t("year.buffer.form.title", environment)).appFont(.headline)
      Form {
        LabeledContent(YearText.t("year.buffer.form.amount", environment)) {
          AmountField(amount: $amount)
        }
        Text(verbatim: YearText.t("year.buffer.form.hint", environment))
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .formStyle(.grouped)
      FormButtons(title: environment.language("action.save"), enabled: true) {
        guard let dependencies, let snapshot = compute.snapshot else { return false }
        return YearActions(dependencies).saveBuffer(
          amount, income: YearPlanInputs.incomeNow(snapshot))
      }
    }
    .padding(20)
    .sheetFrame(width: 440, height: 280)
    .onAppear {
      guard !loaded else { return }
      loaded = true
      amount = compute.snapshot?.dataset.yearPlan.buffer.amount ?? .zero
    }
  }
}

/// «Отметить траты из буфера»: the expenses of this month the buffer paid. The marks of other
/// months stay as they are.
struct BufferMarksSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @State private var chosen: Set<UUID> = []
  @State private var loaded = false

  /// The most expenses listed.
  static let limit = 150

  var body: some View {
    let rows = Self.expenses(compute.snapshot, limit: Self.limit)
    VStack(alignment: .leading) {
      Text(verbatim: YearText.t("year.buffer.marks.title", environment)).appFont(.headline)
      Text(verbatim: YearText.t("year.buffer.marks.hint", environment))
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if rows.isEmpty {
        Text(verbatim: YearText.t("year.buffer.marks.none", environment))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      List(rows) { row in
        Toggle(isOn: binding(row.id)) {
          HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 0) {
              Text(verbatim: row.title).lineLimit(1)
              Text(verbatim: environment.dates.dayAndMonth(row.day))
                .appFont(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(verbatim: environment.money.rounded(row.amount)).monospacedDigit()
          }
        }
      }
      FormButtons(title: environment.language("action.save"), enabled: true) {
        guard let dependencies, let snapshot = compute.snapshot else { return false }
        let listed = Set(rows.map(\.id))
        let kept = snapshot.dataset.yearPlan.bufferMarks.subtracting(listed)
        return YearActions(dependencies).setMarks(kept.union(chosen.intersection(listed)))
      }
    }
    .padding(20)
    .sheetFrame(width: 520, height: 520)
    .onAppear {
      guard !loaded else { return }
      loaded = true
      chosen = compute.snapshot?.dataset.yearPlan.bufferMarks ?? []
    }
  }

  private func binding(_ id: UUID) -> Binding<Bool> {
    Binding(
      get: { chosen.contains(id) },
      set: { isOn in
        if isOn { chosen.insert(id) } else { chosen.remove(id) }
      })
  }

  struct Row: Identifiable {
    var id: UUID
    var day: DateOnly
    var title: String
    var amount: AmountE4
  }

  /// My expenses from the 1st of this month through today, newest first: one row per operation.
  static func expenses(_ snapshot: DataSnapshot?, limit: Int) -> [Row] {
    guard let snapshot else { return [] }
    let ledger = snapshot.ledger
    var seen: Set<UUID> = []
    var rows: [Row] = []
    for row in ledger.rows(in: DayRange(snapshot.today.monthKey.firstDay, snapshot.today))
      .reversed()
    where row.contribution.raw > 0 && !row.isGoalContribution && row.debtId == nil
      && row.systemRole == nil
    {
      guard seen.insert(row.transactionId).inserted else { continue }
      let entry = ledger.entry(row.transactionId)
      let title =
        entry?.transaction.note.flatMap { $0.isEmpty ? nil : $0 }
        ?? ledger.tree.category(row.categoryId)?.name ?? "—"
      let total = AmountE4.sum(
        ledger.rows(in: DayRange(row.day, row.day)).filter { $0.transactionId == row.transactionId }
          .map(\.contribution))
      rows.append(Row(id: row.transactionId, day: row.day, title: title, amount: total))
      if rows.count >= limit { break }
    }
    return rows
  }
}

// MARK: - Events

/// The articles of an event's budget: a name and a planned sum each, in the owner's order. The
/// sums are a plan and need not add up to the budget; the sheet says what they come to.
struct EventItemsSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  let event: Event
  @State private var items: [EventBudgetItem] = []
  @State private var loaded = false

  var body: some View {
    VStack(alignment: .leading) {
      Text(verbatim: YearText.f("year.items.title", environment, event.name)).appFont(.headline)
      List {
        ForEach($items) { $item in
          HStack(spacing: 8) {
            TextField(YearText.t("year.items.name", environment), text: $item.title)
            AmountField(amount: $item.plannedE4)
              .frame(maxWidth: 130)
            Button(role: .destructive) {
              items.removeAll { $0.id == item.id }
            } label: {
              Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(verbatim: environment.language("action.delete")))
          }
        }
        .onMove { items.move(fromOffsets: $0, toOffset: $1) }
      }
      Button(YearText.t("year.items.add", environment)) {
        items.append(
          EventBudgetItem(eventId: event.id, title: "", plannedE4: .zero, sort: items.count))
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .accessibilityIdentifier("year.items.add")
      Text(verbatim: totalLine)
        .appFont(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      FormButtons(title: environment.language("action.save"), enabled: valid) {
        guard let dependencies else { return false }
        return YearActions(dependencies).setItems(
          items.map { item in
            var item = item
            item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return item
          }, event: event.id)
      }
    }
    .padding(20)
    .sheetFrame(width: 520, height: 480)
    .onAppear {
      guard !loaded else { return }
      loaded = true
      items = compute.snapshot?.dataset.yearPlan.items(of: event.id) ?? []
    }
  }

  private var valid: Bool {
    items.allSatisfy {
      !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.plannedE4.raw >= 0
    }
  }

  /// «Статьи — 150 000 ₽ из бюджета 150 000 ₽»: what the articles come to against the budget.
  private var totalLine: String {
    let sum = AmountE4.sum(items.map(\.plannedE4))
    guard let budget = event.budgetE4 else {
      return YearText.f("year.items.total", environment, environment.money.rounded(sum))
    }
    return YearText.f(
      "year.items.totalOf", environment, environment.money.rounded(sum),
      environment.money.rounded(budget))
  }
}

/// «Новое событие из шаблона»: the event with a budget and its articles, from one of the four
/// ready templates or one of the owner's own.
struct EventFromTemplateSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @State private var templateId = EventTemplates.builtIn.first?.id ?? ""
  @State private var name = ""
  @State private var start: DateOnly?
  @State private var end: DateOnly?
  @State private var budget: AmountE4 = .zero
  @State private var loaded = false

  var body: some View {
    let templates = self.templates
    let template = templates.first { $0.id == templateId }
    VStack(alignment: .leading) {
      Text(verbatim: YearText.t("year.template.title", environment)).appFont(.headline)
      Form {
        Picker(YearText.t("year.template.pick", environment), selection: $templateId) {
          ForEach(templates) { template in
            Text(verbatim: YearText.templateName(template, environment)).tag(template.id)
          }
        }
        .onChange(of: templateId) { applyTemplate() }
        TextField(YearText.t("year.template.name", environment), text: $name)
        if let start, let end {
          EventDaysFields(
            owner: nil,
            start: Binding(get: { self.start ?? start }, set: { self.start = $0 }),
            end: Binding(get: { self.end ?? end }, set: { self.end = $0 }),
            startLabel: YearText.t("year.template.start", environment),
            endLabel: YearText.t("year.template.end", environment))
        }
        LabeledContent(YearText.t("year.template.budget", environment)) {
          AmountField(amount: $budget)
        }
        if let template {
          Section(YearText.t("year.template.items", environment)) {
            ForEach(
              YearText.localizedItems(template, event: UUID(), total: budget, environment)
            ) { item in
              HStack {
                Text(verbatim: item.title)
                Spacer(minLength: 8)
                Text(verbatim: environment.money.rounded(item.plannedE4)).monospacedDigit()
              }
              .appFont(.callout)
            }
          }
        }
      }
      .formStyle(.grouped)
      HStack {
        if let template, !template.isBuiltIn {
          Button(YearText.t("year.template.delete", environment), role: .destructive) {
            if let dependencies, YearActions(dependencies).deleteTemplate(template) {
              templateId = EventTemplates.builtIn.first?.id ?? ""
              applyTemplate()
            }
          }
          .buttonStyle(.borderless)
        }
        Spacer()
      }
      FormButtons(
        title: YearText.t("year.template.create", environment),
        enabled: template != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty
          && budget.raw > 0 && start != nil
      ) {
        guard let dependencies, let template, let start, let end else { return false }
        return YearActions(dependencies).createEvent(
          from: template, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
          start: start, end: end, budget: budget)
      }
    }
    .padding(20)
    .sheetFrame(width: 520, height: 640)
    .onAppear {
      guard !loaded else { return }
      loaded = true
      start = environment.today
      end = environment.today
      applyTemplate()
    }
  }

  /// The ready templates first, then the owner's own.
  private var templates: [EventTemplate] {
    EventTemplates.builtIn + (compute.snapshot?.dataset.yearPlan.eventTemplates ?? [])
  }

  /// A template picked: its name and its starting budget are offered, the owner changes them.
  private func applyTemplate() {
    guard let template = templates.first(where: { $0.id == templateId }) else { return }
    name = YearText.templateName(template, environment)
    budget = template.totalE4
  }
}

/// «Сохранить как шаблон»: the articles of an event, kept as a template of the owner's own that
/// «Новое событие из шаблона» offers next time.
struct SaveTemplateSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  let event: Event
  @State private var name = ""
  @State private var loaded = false

  var body: some View {
    VStack(alignment: .leading) {
      Text(verbatim: YearText.t("year.template.save.title", environment)).appFont(.headline)
      Form {
        TextField(YearText.t("year.template.name", environment), text: $name)
        Text(verbatim: YearText.t("year.template.save.hint", environment))
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .formStyle(.grouped)
      FormButtons(
        title: environment.language("action.save"),
        enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty
      ) {
        guard let dependencies else { return false }
        let items = compute.snapshot?.dataset.yearPlan.items(of: event.id) ?? []
        return YearActions(dependencies).saveTemplate(
          name: name.trimmingCharacters(in: .whitespacesAndNewlines), items: items)
      }
    }
    .padding(20)
    .sheetFrame(width: 440, height: 260)
    .onAppear {
      guard !loaded else { return }
      loaded = true
      name = event.name
    }
  }
}
