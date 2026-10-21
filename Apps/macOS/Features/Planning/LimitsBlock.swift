import AppCore
import AppDatabase
import SwiftUI

// The blocks of the Planning section below the payments. Content, never glass; states in
// words and symbols, never colour alone.

/// The limits running out: the top ones of the one order the lists share — over the limit,
/// then close to it, then by the share spent — as many as Settings → Планирование says. Each
/// with a symbol and a word for the status, «spent / available», a thin bar, the pace and the
/// forecast, and what is carried over. A click on the amount edits it in place; «Все лимиты»
/// opens every one of them in a sheet of this block's own, «Предложить лимиты…» the limits the
/// last months suggest.
struct LimitsBlock: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.planningCardHosted) private var hosted
  @Binding var sheet: PlanningSheet?
  /// A limit asked to be deleted: the confirmation comes first.
  @State private var deleting: Budget?
  /// The limit whose amount is being typed in place, and why its last Enter was refused.
  @State private var editing: UUID?
  @State private var refusal: String?
  @State private var showsAll = false
  @State private var suggests = false

  var body: some View {
    ComputedBlock(
      title: hosted ? nil : t("limits.title"), state: compute.states.data,
      style: hosted ? .plain : .card, fillsHeight: !hosted,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      VStack(alignment: .leading, spacing: 10) {
        let ranked = LimitLists.ranked(snapshot, environment)
        if ranked.total == 0 {
          if hosted {
            PlanningEmptyHint(block: .limits) { sheet = .budget(nil) }
          } else {
            Text(verbatim: t("limits.none")).foregroundStyle(.secondary)
          }
        }
        ForEach(ranked.shown, id: \.budget.id) { line in
          LimitRow(
            line: line, tree: snapshot.ledger.tree,
            editing: LimitAmountEditing(
              editing: $editing, refusal: $refusal,
              save: { budget, text in save(budget, text) }),
            edit: { sheet = .budget($0) }, delete: { deleting = $0 })
        }
        HStack(spacing: 8) {
          if !(hosted && ranked.total == 0) {
            Button(t("limits.add")) { sheet = .budget(nil) }
              .buttonStyle(.bordered)
          }
          Button(t("limits.suggest.open")) {
            editing = nil
            suggests = true
          }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("limits.suggest.open")
          if ranked.total > ranked.shown.count {
            Button(environment.format("limits.all", table: "Planning", counts: ranked.total)) {
              editing = nil
              showsAll = true
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("limits.all")
          }
        }
        .controlSize(.small)
      }
    }
    .confirmationDialog(
      t("limits.deleteTitle"),
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible, presenting: deleting
    ) { budget in
      Button(environment.language("action.delete"), role: .destructive) {
        if let dependencies { PlanningActions(dependencies).delete(budget) }
      }
    }
    // Presented by the block that opens it, over the section — not through the section's
    // own sheet, which holds the forms.
    .sheet(isPresented: $showsAll) {
      AllLimitsSheet()
        .handingOver(dependencies)
    }
    .sheet(isPresented: $suggests) {
      LimitSuggestionsSheet()
        .handingOver(dependencies)
    }
  }

  private func save(_ budget: Budget, _ text: String) -> String? {
    guard let dependencies else { return t("form.notSaved") }
    return LimitWrites.changeAmount(of: budget, typed: text, deps: dependencies).map(t)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

/// One limit in a list of limits: the status line with its amount to edit in place, the bar,
/// the pace, the forecast and the carry, and a menu to open the form or delete it.
struct LimitRow: View {
  @Dependency(\.environment) private var environment
  let line: LimitLine
  let tree: CategoryTree
  let editing: LimitAmountEditing
  let edit: (Budget) -> Void
  let delete: (Budget) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      LimitStatusLine(line: line, tree: tree, editing: editing)
      LimitBar(line: line)
      Text(verbatim: detail)
        .appFont(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      if isEditing, let note = Self.carryNote(line, environment) {
        Text(verbatim: note)
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("limits.amount.carryRestart")
      }
      if let refusal, isEditing {
        Text(verbatim: refusal)
          .appFont(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .contextMenu {
      Button(environment.language("action.edit")) { edit(line.budget) }
      Button(environment.language("action.delete")) { delete(line.budget) }
    }
  }

  private var refusal: String? { editing.refusal.wrappedValue }

  private var isEditing: Bool { editing.editing.wrappedValue == line.budget.id }

  /// Said under a limit while its amount is typed in place: a new amount starts the carry
  /// again, and what is carried now is what it would give up — the button shows the amount
  /// available, the field the monthly limit alone. Nothing when nothing is carried.
  static func carryNote(_ line: LimitLine, _ environment: AppEnvironment) -> String? {
    guard !line.carry.isZero else { return nil }
    return environment.format(
      "limits.amount.carryRestart", table: "Planning", environment.money.rounded(line.carry))
  }

  private var detail: String {
    var pieces: [String] = []
    if let pace = line.paceBp {
      pieces.append(
        environment.format(
          "limits.pace", table: "Planning",
          environment.money.percent(basisPoints: pace, fractionDigits: 0)))
    }
    pieces.append(
      environment.format(
        "limits.forecast", table: "Planning", environment.money.rounded(line.forecast)))
    if !line.carry.isZero {
      pieces.append(
        environment.format(
          "limits.carry", table: "Planning", environment.money.rounded(line.carry)))
    }
    return pieces.joined(separator: " · ")
  }
}

/// Spent against available: the part within the limit in the accent colour, what went over
/// it past the mark in the colour of the status — the status itself is said in words.
private struct LimitBar: View {
  let line: LimitLine

  var body: some View {
    let available = max(line.available.raw, 1)
    let within = min(max(line.spent.raw, 0), available)
    let over = max(line.spent.raw - available, 0)
    let whole = available + over
    Capsule()
      .fill(.quaternary)
      .overlay {
        ProportionalRow(weights: [
          Int(within * 1000 / whole), Int(over * 1000 / whole),
          Int((whole - within - over) * 1000 / whole),
        ]) {
          Capsule().fill(.tint)
          Capsule().fill(PlanningText.statusTint(line.status))
          Color.clear
        }
      }
      .frame(height: 4)
      .accessibilityHidden(true)
  }
}

/// A list of limits whose amounts are edited in place: which one is being typed (one at a
/// time), why its last Enter was refused, and the write — nil when it landed or there was
/// nothing to write, else the refusal in words.
struct LimitAmountEditing {
  var editing: Binding<UUID?>
  var refusal: Binding<String?>
  var save: (Budget, String) -> String?
}

/// The lists of limits: the Planning block, the sheet of all of them and the Overview card
/// read the one order through here.
@MainActor
enum LimitLists {
  /// The limits in the order of `LimitRules.ranked`, the top ones as Settings → Планирование
  /// says (every one with `all`), and how many there are to show. A bad-spending or a «for
  /// whom» limit is named for the order as the lists name it.
  static func ranked(
    _ snapshot: DataSnapshot, _ environment: AppEnvironment, all: Bool = false
  ) -> (shown: [LimitLine], total: Int) {
    let tree = snapshot.ledger.tree
    return LimitRules.ranked(
      snapshot.planning.limits, topN: all ? nil : snapshot.planning.book.settings.limitsTopN,
      tree: tree
    ) { PlanningText.limitName($0.budget, tree: tree, environment) }
  }
}

/// The writes of an amount typed into a limit's field — in place in Planning, in the sheet
/// of all limits, in the row of a category in Settings. Each is one `PlanningChange`, one
/// step of ⌘Z. What they return is nil when the write landed or there was nothing to write,
/// else the key, in the Planning table, of why nothing was written.
@MainActor
enum LimitWrites {
  /// What a limit's field says.
  enum Typed: Equatable {
    /// Nothing typed.
    case empty
    case amount(AmountE4)
    /// Text that is no amount, not even a formula.
    case unreadable
  }

  /// The text of a field read the way amounts are typed everywhere: «1,500», «1500,5», «2k»,
  /// «(1000+600)/2».
  static func read(_ text: String) -> Typed {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
    guard let value = try? ExpressionEvaluator.evaluate(text),
      let amount = try? AmountE4(decimal: value)
    else { return .unreadable }
    return .amount(amount)
  }

  /// What a field shows once what it says is written: the amount the way the app writes
  /// amounts, nothing for an empty field; nil for text that is no amount.
  static func settledText(_ text: String) -> String? {
    switch read(text) {
    case .empty: ""
    case .amount(let amount): AmountField.text(for: amount)
    case .unreadable: nil
    }
  }

  /// The amount typed over a limit's amount in place. An empty field writes nothing — it puts
  /// the amount back, as Esc does; a limit is deleted from its menu, after a question.
  static func changeAmount(
    of budget: Budget, typed text: String, budgets: [Budget], tree: CategoryTree,
    month: MonthKey, store: TransactionsStore, limitless: Set<UUID> = []
  ) -> String? {
    switch read(text) {
    case .empty: return nil
    case .unreadable: return "limits.unreadable"
    case .amount(let amount):
      return apply(
        LimitRules.changingAmount(
          of: budget.id, to: amount, budgets: budgets, tree: tree, in: month,
          limitless: limitless),
        store: store)
    }
  }

  /// The same with what the window has at hand: the book as the database has it now, the
  /// tree of the data on screen, the month of today.
  static func changeAmount(
    of budget: Budget, typed text: String, deps: AppDependencies
  ) -> String? {
    let snapshot = deps.compute.snapshot
    return changeAmount(
      of: budget, typed: text, budgets: budgets(deps.environment, snapshot),
      tree: snapshot?.ledger.tree ?? CategoryTree(), month: deps.environment.today.monthKey,
      store: deps.store, limitless: limitless(deps.environment, snapshot))
  }

  /// The amount typed into the row of a category: an empty field deletes its limit, zero is
  /// refused (`LimitRules.settingCategoryLimit`).
  static func setCategoryLimit(
    _ categoryId: UUID, typed text: String, budgets: [Budget], tree: CategoryTree,
    month: MonthKey, store: TransactionsStore, limitless: Set<UUID> = []
  ) -> String? {
    let amount: AmountE4?
    switch read(text) {
    case .unreadable: return "limits.unreadable"
    case .empty: amount = nil
    case .amount(let typed): amount = typed
    }
    return apply(
      LimitRules.settingCategoryLimit(
        categoryId, to: amount, budgets: budgets, tree: tree, in: month, limitless: limitless),
      store: store)
  }

  /// One change, one write.
  static func apply(_ change: LimitChange, store: TransactionsStore) -> String? {
    switch change {
    case .unchanged:
      return nil
    case .refused(let issue):
      return "limit.issue.\(issue.rawValue)"
    case .save(let budget):
      var rows = PlanningRows.empty
      rows.budgets = [budget]
      return store.apply(PlanningChange(upsert: rows)) ? nil : "form.notSaved"
    case .delete(let budget):
      var ids = PlanningRowIDs.empty
      ids.budgets = [budget.id]
      return store.apply(PlanningChange(delete: ids)) ? nil : "form.notSaved"
    }
  }

  /// The limits as the database has them now — the screen may not have caught up with the
  /// last edit — or as the screen has them when the database cannot be read.
  static func budgets(_ environment: AppEnvironment, _ snapshot: DataSnapshot?) -> [Budget] {
    (try? environment.planning?.budgets()) ?? snapshot?.dataset.planning.budgets ?? []
  }

  /// «Сверка» and its income twin, as the reconciliation remembers them, and the category the
  /// tax of self-employment is paid in — read from the database now, like the limits, or from
  /// the screen when the database cannot be read: no limit on them or on anything under them
  /// (`LimitRules.isLimitless`, `LimitRules.offersLimit(taxCategoryId:)`): the tax is not
  /// spending one could plan less of.
  static func limitless(_ environment: AppEnvironment, _ snapshot: DataSnapshot?) -> Set<UUID> {
    let onScreen = onScreen(snapshot)
    guard let settings = environment.settings else { return onScreen }
    var read = PlanningSettings()
    let tax: UUID?
    do {
      read.reconcileExpenseCategoryId = try settings.string(
        PlanningSettings.reconcileExpenseCategoryKey
      ).flatMap(Self.id)
      read.reconcileIncomeCategoryId = try settings.string(
        PlanningSettings.reconcileIncomeCategoryKey
      ).flatMap(Self.id)
      tax = try settings.string(SelfEmploymentSettings.taxCategoryKey).flatMap(Self.id)
    } catch {
      return onScreen
    }
    return read.limitlessCategoryIds.union(tax.map { [$0] } ?? [])
  }

  /// The same from the data on screen.
  static func onScreen(_ snapshot: DataSnapshot?) -> Set<UUID> {
    var ids = snapshot?.dataset.planning.settings.limitlessCategoryIds ?? []
    if let tax = snapshot?.dataset.selfEmployment.taxCategoryId { ids.insert(tax) }
    return ids
  }

  private static func id(_ text: String) -> UUID? {
    UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}
