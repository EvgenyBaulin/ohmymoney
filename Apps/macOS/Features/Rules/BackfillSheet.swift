import AppCore
import AppDatabase
import SwiftUI

/// What one operation of the preview would become, in lines the row shows. Pure: it reads the
/// operation as it is and as the rules would leave it.
@MainActor
enum BackfillRowText {
  static func lines(
    _ item: RuleBackfillItem, names: RuleNames, wording: RuleWording
  ) -> [String] {
    let environment = wording.environment
    var lines: [String] = []
    let fields = Set(item.changes.map(\.field))
    if fields.contains(.category) {
      // The first part that changed stands for the operation.
      let index = item.after.parts.indices.first { index in
        item.before.parts.indices.contains(index)
          && item.before.parts[index].categoryId != item.after.parts[index].categoryId
      }
      if let index {
        let from = item.before.parts[index].categoryId.map(names.category) ?? "—"
        let to = item.after.parts[index].categoryId.map(names.category) ?? "—"
        lines.append(RulesText.format("backfill.line.category", environment, from, to))
      }
    }
    if fields.contains(.quality), let quality = item.after.parts.first?.quality {
      lines.append(
        RulesText.format(
          "backfill.line.quality", environment,
          environment.language(Palette.qualityKey(quality))))
    }
    if fields.contains(.forWhom), let part = item.after.parts.first {
      let who =
        part.forPersonId.flatMap { names.people[$0] } ?? environment.label(for: part.forWhom)
      lines.append(RulesText.format("backfill.line.forWhom", environment, who))
    }
    if fields.contains(.place) {
      let place = item.after.transaction.placeId.flatMap { names.places[$0] } ?? "—"
      lines.append(RulesText.format("backfill.line.place", environment, place))
    }
    let tagIds = item.addedTags.map(\.tagId)
    if !tagIds.isEmpty {
      var seen: Set<UUID> = []
      let words = tagIds.filter { seen.insert($0).inserted }.map { "#" + (names.tags[$0] ?? "?") }
      lines.append(words.joined(separator: " "))
    }
    return lines
  }
}

/// «Применить к прошлым»: what the rules would change in the history, every operation with its
/// tick, and one write with one ⌘Z. The operations the owner edited by hand after writing them
/// start unticked: their decision is worth more than a rule. Nothing is written before
/// «Применить», and what is written is exactly what the preview showed.
struct BackfillSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Dependency(\.store) private var store
  @Environment(\.dismiss) private var dismiss

  enum Phase {
    case planning
    case ready(RuleBackfillPlan)
    case failed
  }

  @State private var phase: Phase = .planning
  @State private var selection: Set<UUID> = []
  @State private var applying = false
  @State private var result: BackfillResult?

  private func t(_ key: String) -> String { RulesText.t(key, environment) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t("backfill.title")).appFont(.headline)
      Text(verbatim: t("backfill.hint"))
        .appFont(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      content
      footer
    }
    .padding(20)
    .sheetFrame(minWidth: 560, idealWidth: 620, minHeight: 480, idealHeight: 600)
    .task(id: compute.snapshot?.version.cacheKey) { await plan() }
    .accessibilityIdentifier("backfill.sheet")
  }

  @ViewBuilder
  private var content: some View {
    if let result {
      resultView(result)
    } else {
      switch phase {
      case .planning:
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(verbatim: t("backfill.planning")).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed:
        Label(t("backfill.failed"), systemImage: "exclamationmark.octagon")
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .ready(let plan):
        planView(plan)
      }
    }
  }

  @ViewBuilder
  private func planView(_ plan: RuleBackfillPlan) -> some View {
    let dataset = compute.snapshot?.dataset
    let names = dataset.map(RuleNames.init(dataset:)) ?? RuleNames()
    let wording = RuleWording(environment: environment, names: names)
    Text(verbatim: summary(plan)).accessibilityIdentifier("backfill.summary")
    if plan.items.isEmpty {
      Text(verbatim: t("backfill.nothing"))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      HStack {
        Button(t("backfill.selectAll")) { selection = Set(plan.items.map(\.id)) }
        Button(t("backfill.selectNone")) { selection = [] }
        Spacer()
        Text(
          verbatim: environment.format(
            "backfill.ticked", table: RulesText.table, counts: selection.count, plan.items.count)
        )
        .foregroundStyle(.secondary).monospacedDigit()
      }
      .buttonStyle(.link)
      List {
        ForEach(plan.items) { item in
          row(item, names: names, wording: wording)
        }
      }
      .listStyle(.inset)
      .frame(minHeight: 220)
    }
    if plan.conflicts > 0 {
      Label(
        environment.format("backfill.conflicts", table: RulesText.table, counts: plan.conflicts),
        systemImage: "arrow.triangle.branch"
      )
      .appFont(.callout).foregroundStyle(.secondary)
    }
  }

  private func summary(_ plan: RuleBackfillPlan) -> String {
    environment.format(
      "backfill.summary", table: RulesText.table, counts: plan.scanned, plan.matched,
      plan.items.count, plan.unchanged)
  }

  private func row(_ item: RuleBackfillItem, names: RuleNames, wording: RuleWording) -> some View {
    let transaction = item.before.transaction
    let ticked = Binding(
      get: { selection.contains(item.id) },
      set: { on in
        if on { selection.insert(item.id) } else { selection.remove(item.id) }
      })
    return Toggle(isOn: ticked) {
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(verbatim: Self.title(transaction, names: names, environment: environment))
            .lineLimit(1)
          Spacer(minLength: 8)
          Text(
            verbatim: environment.money.exact(transaction.amountE4, currency: transaction.currency)
          )
          .monospacedDigit()
        }
        ForEach(BackfillRowText.lines(item, names: names, wording: wording), id: \.self) { line in
          Text(verbatim: line).appFont(.callout).foregroundStyle(.secondary).lineLimit(2)
        }
        if item.editedByHand {
          Label(t("backfill.editedByHand"), systemImage: "pencil")
            .appFont(.caption).foregroundStyle(.secondary)
        }
        ForEach(item.kept, id: \.self) { reason in
          Label(wording.skip(reason), systemImage: "lock")
            .appFont(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .toggleStyle(.checkbox)
    .accessibilityIdentifier("backfill.row")
  }

  /// «12 окт. · Пятёрочка»: the day and what the operation is called.
  static func title(
    _ transaction: CoreKit.Transaction, names: RuleNames, environment: AppEnvironment
  ) -> String {
    let day = transaction.occurredAt.formatted(
      .dateTime.day().month(.abbreviated).locale(environment.language.locale))
    let place = transaction.placeId.flatMap { names.places[$0] }
    let words = (place ?? transaction.note ?? "").trimmingCharacters(in: .whitespaces)
    return words.isEmpty ? day : day + " · " + words
  }

  @ViewBuilder
  private func resultView(_ result: BackfillResult) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(result.text(environment), systemImage: result.symbol)
        .accessibilityIdentifier("backfill.result")
      if result.stale > 0 {
        Text(
          verbatim: environment.format(
            "backfill.stale", table: RulesText.table, counts: result.stale)
        )
        .appFont(.callout).foregroundStyle(.secondary)
      }
      Text(verbatim: t("backfill.undoHint")).appFont(.callout).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  @ViewBuilder
  private var footer: some View {
    HStack {
      if let result, result.written > 0 || result.links > 0, !result.undone {
        Button(t("backfill.undo")) {
          store.undo()
          self.result?.undone = true
        }
        .disabled(!store.canUndo)
        .accessibilityIdentifier("backfill.undo")
      }
      Spacer()
      if result == nil {
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(applyTitle) { apply() }
          .keyboardShortcut(.defaultAction)
          .disabled(!canApply)
          .accessibilityIdentifier("backfill.apply")
      } else {
        Button(environment.language("action.ok")) { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
    }
  }

  private var canApply: Bool {
    guard case .ready(let plan) = phase, !applying else { return false }
    return plan.items.contains { selection.contains($0.id) }
  }

  private var applyTitle: String {
    environment.format("backfill.apply", table: RulesText.table, counts: selection.count)
  }

  // MARK: Work

  private func plan() async {
    guard result == nil, let snapshot = compute.snapshot else { return }
    do {
      let plan = try await compute.analysis.rules.backfillPlan(snapshot)
      guard !Task.isCancelled else { return }
      // The ticks the owner already set stay; a plan of new data starts from the default ones.
      if case .ready = phase {
        selection.formIntersection(plan.items.map(\.id))
      } else {
        selection = plan.defaultSelection
      }
      phase = .ready(plan)
    } catch is CancellationError {
      return
    } catch {
      phase = .failed
    }
  }

  private func apply() {
    guard case .ready(let plan) = phase, !applying else { return }
    applying = true
    let commit = plan.commit(selection: selection)
    guard store.applyBackfill(commit) else {
      applying = false
      phase = .failed
      return
    }
    Task { @MainActor in
      // A large write lands off the main thread: wait for it, up to a few seconds.
      for _ in 0..<80 where store.lastBackfill == nil {
        try? await Task.sleep(for: .milliseconds(100))
      }
      let applied = store.lastBackfill
      result = BackfillResult(
        written: applied?.written ?? 0, links: applied?.linksAdded ?? 0,
        stale: applied?.stale.count ?? 0, landed: applied != nil)
      applying = false
    }
  }
}

/// What «Применить» did, in words.
struct BackfillResult: Equatable {
  var written: Int
  var links: Int
  var stale: Int
  var landed: Bool
  var undone = false

  var symbol: String {
    if undone { return "arrow.uturn.backward.circle" }
    return landed ? "checkmark.circle" : "hourglass"
  }

  @MainActor
  func text(_ environment: AppEnvironment) -> String {
    if undone { return RulesText.t("backfill.undone", environment) }
    if !landed { return RulesText.t("backfill.notLanded", environment) }
    if written == 0 && links == 0 { return RulesText.t("backfill.wroteNothing", environment) }
    return environment.format(
      "backfill.wrote", table: RulesText.table, counts: written, links)
  }
}
