import AppCore
import SwiftUI

/// One rule: its conditions («и»), what it does, the problems that keep it from being saved,
/// and a test on the history — how many operations it would match and change, before anything
/// is saved. A rule is a default, never a ban: what the owner chooses by hand beats it.
struct RuleEditorSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Dependency(\.store) private var store
  @Environment(\.dismiss) private var dismiss

  @State var draft: RuleDraft
  @State private var trial: RuleTrial = .waiting
  /// A write the database refused, said under the form.
  @State private var refused = false

  private func t(_ key: String) -> String { RulesText.t(key, environment) }

  var body: some View {
    let dataset = compute.snapshot?.dataset
    let names = dataset.map(RuleNames.init(dataset:)) ?? RuleNames()
    let choices = dataset.map(RuleChoices.init(dataset:)) ?? RuleChoices()
    let book = dataset?.tagBook ?? TagBook()
    let wording = RuleWording(environment: environment, names: names)
    let found = draft.problems(tree: names.tree, book: book)
    VStack(spacing: 0) {
      Form {
        Section {
          TextField(text: $draft.name) {
            Text(verbatim: t("rules.editor.name"))
          }
          .accessibilityIdentifier("rules.editor.name")
          Toggle(isOn: $draft.enabled) { Text(verbatim: t("rules.editor.enabled")) }
        }
        Section {
          ForEach($draft.conditions) { $row in
            conditionRow($row, choices: choices, wording: wording)
          }
          Menu {
            ForEach(ConditionKind.allCases) { kind in
              Button(t(kind.titleKey)) { draft.conditions.append(ConditionRow(kind: kind)) }
            }
          } label: {
            Label(t("rules.editor.addCondition"), systemImage: "plus")
          }
          .accessibilityIdentifier("rules.editor.addCondition")
        } header: {
          Text(verbatim: t("rules.editor.if")).settingsHeaderStyle()
        } footer: {
          Text(verbatim: t("rules.editor.ifHint"))
            .appFont(.callout).foregroundStyle(.secondary)
        }
        Section {
          ForEach($draft.actions) { $row in
            actionRow($row, choices: choices, wording: wording, book: book)
          }
          Menu {
            ForEach(ActionKind.allCases) { kind in
              Button(t(kind.titleKey)) { draft.actions.append(ActionRow(kind: kind)) }
            }
          } label: {
            Label(t("rules.editor.addAction"), systemImage: "plus")
          }
          .accessibilityIdentifier("rules.editor.addAction")
        } header: {
          Text(verbatim: t("rules.editor.then")).settingsHeaderStyle()
        } footer: {
          Text(verbatim: t("rules.editor.thenHint"))
            .appFont(.callout).foregroundStyle(.secondary)
        }
        problemsSection(found, wording: wording)
        Section {
          trialView(wording: wording)
        } header: {
          Text(verbatim: t("rules.trial.title")).settingsHeaderStyle()
        }
      }
      .formStyle(.grouped)
      Divider()
      HStack {
        if refused {
          Label(t("rules.editor.refused"), systemImage: "exclamationmark.octagon")
            .appFont(.callout).foregroundStyle(.red)
        }
        Spacer()
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(environment.language("action.save")) { save(book: book) }
          .keyboardShortcut(.defaultAction)
          .disabled(!(found.core.isEmpty && found.unfinished == 0))
          .accessibilityIdentifier("rules.editor.save")
      }
      .padding(14)
    }
    .sheetFrame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 640)
    .task(id: trialKey(book: book)) { await runTrial(book: book) }
    .accessibilityIdentifier("rules.editor")
  }

  // MARK: Rows

  @ViewBuilder
  private func conditionRow(
    _ row: Binding<ConditionRow>, choices: RuleChoices, wording: RuleWording
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Picker(selection: row.kind) {
        ForEach(ConditionKind.allCases) { kind in Text(verbatim: t(kind.titleKey)).tag(kind) }
      } label: {
        EmptyView()
      }
      .labelsHidden()
      .fixedSize()
      valueField(row, choices: choices, wording: wording)
      Spacer(minLength: 0)
      Button {
        draft.conditions.removeAll { $0.id == row.wrappedValue.id }
      } label: {
        Image(systemName: "minus.circle")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(Text(verbatim: t("rules.editor.remove")))
    }
  }

  @ViewBuilder
  private func valueField(
    _ row: Binding<ConditionRow>, choices: RuleChoices, wording: RuleWording
  ) -> some View {
    switch row.wrappedValue.kind {
    case .text:
      TextField(text: row.text) { Text(verbatim: t("rules.editor.text")) }
    case .place:
      referencePicker(row.reference, choices.places)
    case .account:
      referencePicker(row.reference, choices.accounts)
    case .card:
      referencePicker(row.reference, choices.cards)
    case .category:
      referencePicker(row.reference, choices.conditionCategories)
    case .amountAbove, .amountBelow:
      HStack(spacing: 4) {
        TextField(text: row.amountText) { Text(verbatim: t("rules.editor.amount")) }
          .multilineTextAlignment(.trailing)
          .monospacedDigit()
          .frame(maxWidth: 140)
        Text(verbatim: "₽").foregroundStyle(.secondary)
      }
    case .kind:
      Picker(selection: row.transactionKind) {
        ForEach(TransactionKind.allCases, id: \.self) { kind in
          Text(verbatim: wording.kindName(kind)).tag(kind)
        }
      } label: {
        EmptyView()
      }
      .labelsHidden()
      .fixedSize()
    case .weekdays:
      weekdayToggles(row.weekdays)
    case .time:
      HStack(spacing: 6) {
        minutePicker(row.fromMinute)
        Text(verbatim: t("rules.editor.until")).foregroundStyle(.secondary)
        minutePicker(row.toMinute)
      }
    }
  }

  private func referencePicker(
    _ selection: Binding<UUID?>, _ choices: [RuleChoices.Choice]
  ) -> some View {
    Picker(selection: selection) {
      Text(verbatim: t("rules.editor.choose")).tag(UUID?.none)
      ForEach(choices) { choice in Text(verbatim: choice.title).tag(UUID?.some(choice.id)) }
    } label: {
      EmptyView()
    }
    .labelsHidden()
  }

  /// Seven short toggles, Monday first. The meaning is in the letters, not in the colour.
  private func weekdayToggles(_ days: Binding<Set<Int>>) -> some View {
    HStack(spacing: 4) {
      ForEach(1...7, id: \.self) { day in
        Toggle(
          isOn: Binding(
            get: { days.wrappedValue.contains(day) },
            set: { on in
              if on { days.wrappedValue.insert(day) } else { days.wrappedValue.remove(day) }
            })
        ) {
          Text(verbatim: RuleWording.weekdays([day], environment))
        }
        .toggleStyle(.button)
        .accessibilityIdentifier("rules.editor.weekday.\(day)")
      }
    }
  }

  /// Every quarter of an hour of the day.
  private func minutePicker(_ minute: Binding<Int>) -> some View {
    Picker(selection: minute) {
      ForEach(Array(stride(from: 0, to: 24 * 60, by: 15)), id: \.self) { value in
        Text(verbatim: RuleWording.clock(value)).tag(value)
      }
    } label: {
      EmptyView()
    }
    .labelsHidden()
    .fixedSize()
  }

  @ViewBuilder
  private func actionRow(
    _ row: Binding<ActionRow>, choices: RuleChoices, wording: RuleWording, book: TagBook
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Picker(selection: row.kind) {
        ForEach(ActionKind.allCases) { kind in Text(verbatim: t(kind.titleKey)).tag(kind) }
      } label: {
        EmptyView()
      }
      .labelsHidden()
      .fixedSize()
      switch row.wrappedValue.kind {
      case .category: referencePicker(row.reference, choices.actionCategories)
      case .place: referencePicker(row.reference, choices.places)
      case .person: referencePicker(row.reference, choices.people)
      case .quality:
        Picker(selection: row.quality) {
          ForEach(Quality.allCases, id: \.self) { quality in
            Text(verbatim: wording.qualityName(quality)).tag(quality)
          }
        } label: {
          EmptyView()
        }
        .labelsHidden()
        .fixedSize()
      case .forWhom:
        Picker(selection: row.forWhom) {
          ForEach(ForWhom.allCases, id: \.self) { group in
            Text(verbatim: environment.label(for: group)).tag(group)
          }
        } label: {
          EmptyView()
        }
        .labelsHidden()
        .fixedSize()
      case .tag:
        HStack(spacing: 4) {
          Text(verbatim: "#").foregroundStyle(.secondary)
          TextField(text: row.tagText) { Text(verbatim: t("rules.editor.tag")) }
          if !choices.tags.isEmpty {
            Menu {
              ForEach(choices.tags) { tag in
                Button("#" + tag.title) { row.wrappedValue.tagText = tag.title }
              }
            } label: {
              Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(Text(verbatim: t("rules.editor.existingTags")))
          }
        }
        if let note = newTagNote(row.wrappedValue.tagText, book: book) {
          Text(verbatim: note).appFont(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
      Button {
        draft.actions.removeAll { $0.id == row.wrappedValue.id }
      } label: {
        Image(systemName: "minus.circle")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(Text(verbatim: t("rules.editor.remove")))
    }
  }

  /// «новый тег» beside a name that is no tag yet.
  private func newTagNote(_ text: String, book: TagBook) -> String? {
    guard let name = TagName.normalized(text), book.tag(named: name) == nil else { return nil }
    return t("rules.editor.newTag")
  }

  // MARK: Problems

  @ViewBuilder
  private func problemsSection(
    _ found: (core: [RuleProblem], unfinished: Int), wording: RuleWording
  ) -> some View {
    if !found.core.isEmpty || found.unfinished > 0 {
      Section {
        ForEach(found.core, id: \.self) { problem in
          Label {
            Text(verbatim: wording.problem(problem)).fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "exclamationmark.triangle")
          }
          .foregroundStyle(.orange)
        }
        if found.unfinished > 0 {
          Label {
            Text(verbatim: t("rules.problem.unfinished"))
          } icon: {
            Image(systemName: "exclamationmark.triangle")
          }
          .foregroundStyle(.orange)
        }
      }
      .accessibilityIdentifier("rules.editor.problems")
    }
  }

  // MARK: Trial on the history

  /// What changes the trial: the rule as it builds.
  private func trialKey(book: TagBook) -> RuleTrialKey {
    let built = draft.build(book: book)
    return RuleTrialKey(rule: built.rule, version: compute.snapshot?.version.cacheKey ?? 0)
  }

  private func runTrial(book: TagBook) async {
    guard let snapshot = compute.snapshot else { return }
    let built = draft.build(book: book)
    guard !built.rule.conditions.isEmpty, !built.rule.actions.isEmpty else {
      trial = .waiting
      return
    }
    trial = .working
    // A pause for the keystroke that follows; a newer rule cancels this task.
    try? await Task.sleep(for: .milliseconds(350))
    guard !Task.isCancelled else { return }
    var tried = built.rule
    tried.enabled = true
    guard let plan = try? await compute.analysis.rules.backfillPlan(snapshot, rules: [tried])
    else { return }
    guard !Task.isCancelled else { return }
    trial = .done(RuleTrialResult(plan: plan))
  }

  @ViewBuilder
  private func trialView(wording: RuleWording) -> some View {
    switch trial {
    case .waiting:
      Text(verbatim: t("rules.trial.waiting")).foregroundStyle(.secondary)
    case .working:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text(verbatim: t("rules.trial.working")).foregroundStyle(.secondary)
      }
    case .done(let result):
      VStack(alignment: .leading, spacing: 6) {
        Text(verbatim: result.summary(environment))
          .accessibilityIdentifier("rules.trial.summary")
        ForEach(result.samples, id: \.id) { sample in
          HStack {
            Text(verbatim: sample.title(environment)).lineLimit(1)
            Spacer(minLength: 8)
            Text(verbatim: sample.changes(wording))
              .foregroundStyle(.secondary).lineLimit(1)
          }
          .appFont(.callout)
        }
      }
    }
  }

  // MARK: Save

  private func save(book: TagBook) {
    let built = draft.build(book: book)
    refused = false
    if !built.newTagIds.isEmpty {
      guard store.apply(TagEdit(before: book, after: built.book)) else {
        refused = true
        return
      }
    }
    let written = draft.isNew ? store.addRule(built.rule) : store.updateRule(built.rule)
    guard written else {
      refused = true
      return
    }
    dismiss()
  }
}

/// What the trial depends on: the rule as it builds and the version of the data.
struct RuleTrialKey: Equatable {
  var rule: Rule
  var version: Int
}

enum RuleTrial {
  case waiting
  case working
  case done(RuleTrialResult)
}

/// The dry run of one rule over the history, in the few numbers and lines the editor shows.
struct RuleTrialResult {
  struct Sample {
    var id: UUID
    var note: String?
    var amount: AmountE4
    var currency: CurrencyCode
    var fields: [RuleField]

    @MainActor
    func title(_ environment: AppEnvironment) -> String {
      let words = (note ?? "").trimmingCharacters(in: .whitespaces)
      let text = words.isEmpty ? RulesText.t("rules.trial.noNote", environment) : words
      return text + " · " + environment.money.exact(amount, currency: currency)
    }

    @MainActor
    func changes(_ wording: RuleWording) -> String {
      fields.map(wording.fieldName).joined(separator: ", ")
    }
  }

  var scanned: Int
  var matched: Int
  var changed: Int
  var samples: [Sample]

  static let sampleCount = 5

  init(plan: RuleBackfillPlan) {
    scanned = plan.scanned
    matched = plan.matched
    changed = plan.items.count
    samples = plan.items.prefix(Self.sampleCount).map { item in
      var fields: [RuleField] = []
      for change in item.changes where !fields.contains(change.field) {
        fields.append(change.field)
      }
      return Sample(
        id: item.id, note: item.before.transaction.note, amount: item.before.transaction.amountE4,
        currency: item.before.transaction.currency, fields: fields)
    }
  }

  @MainActor
  func summary(_ environment: AppEnvironment) -> String {
    if matched == 0 { return RulesText.t("rules.trial.none", environment) }
    return environment.format(
      "rules.trial.summary", table: RulesText.table, counts: matched, scanned, changed)
  }
}
