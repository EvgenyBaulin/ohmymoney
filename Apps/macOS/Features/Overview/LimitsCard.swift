import AppCore
import SwiftUI

/// The limits of the month in the one order of the lists of limits (`LimitLists`) — over the
/// limit, then close to it, then by the share spent — as many as the Planning block shows but
/// never more than five, each with its symbol and word; then what is left: how many are
/// within, or how many more there are in Planning.
struct LimitsCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: OverviewTileText.name(of: .limits, environment), state: compute.states.data,
      fillsHeight: true,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      let lines = Self.lines(snapshot, environment)
      if lines.shown.isEmpty, lines.rest.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text(verbatim: t("overview.limitsNone"))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Button(t("overview.limitsOpen"), action: openPlanning)
            .buttonStyle(.link)
        }
      } else {
        let rest = lines.rest
        VStack(alignment: .leading, spacing: 6) {
          ForEach(lines.shown, id: \.budget.id) { line in
            LimitStatusLine(line: line, tree: snapshot.ledger.tree)
          }
          if !rest.isEmpty {
            if rest.allSatisfy({ $0.status == .ok }) {
              Label {
                Text(
                  verbatim: environment.language.format(
                    "overview.limitsWithin", table: "Planning", counts: rest.count))
              } icon: {
                Image(systemName: PlanningText.statusSymbol(.ok))
              }
              .appFont(.caption)
              .foregroundStyle(.secondary)
            } else {
              // Some of the ones not shown are running out too: said as a count, with the way
              // to all of them.
              Button(
                environment.language.format(
                  "overview.limitsMore", table: "Planning", counts: rest.count),
                action: openPlanning
              )
              .buttonStyle(.link)
              .appFont(.caption)
            }
          }
        }
      }
    }
  }

  /// The most the card lists, whatever Planning shows: the card shares a row of Overview with
  /// others, and they grow with it — with «all» and eighteen limits, eighteen lines high.
  static let most = 5

  /// The limits the card lists — the top of the one order, as many as Planning shows, `most`
  /// at most — and the ones after them.
  static func lines(
    _ snapshot: DataSnapshot, _ environment: AppEnvironment
  ) -> (shown: [LimitLine], rest: [LimitLine]) {
    let all = LimitLists.ranked(snapshot, environment, all: true).shown
    let count = max(min(snapshot.planning.book.settings.limitsTopN ?? most, most), 0)
    return (Array(all.prefix(count)), Array(all.dropFirst(count)))
  }

  private func openPlanning() {
    NotificationCenter.default.post(name: .selectSection, object: 2)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

/// One limit: its status as a symbol and a word — never colour alone — its name and
/// «spent / available». Given `editing`, the amount is a button that turns into a field in
/// place: Enter saves (one step of ⌘Z), Esc or leaving the field puts it back.
struct LimitStatusLine: View {
  @Dependency(\.environment) private var environment
  let line: LimitLine
  let tree: CategoryTree
  var editing: LimitAmountEditing?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: PlanningText.statusSymbol(line.status))
        .foregroundStyle(PlanningText.statusTint(line.status))
        .accessibilityHidden(true)
      // The status in words too, never by colour and symbol alone. In a narrow card the name
      // goes on to a second line rather than being cut down to the status word.
      Text(verbatim: "\(PlanningText.statusWord(line.status, environment)): \(name)")
        .lineLimit(2)
      Spacer(minLength: 6)
      // The amounts are never wrapped: a long name gives way and is cut short instead.
      Group {
        if let editing {
          LimitAmountField(line: line, name: name, editing: editing)
        } else {
          Text(
            verbatim:
              "\(environment.money.rounded(line.spent)) / \(environment.money.rounded(line.available))"
          )
          .monospacedDigit()
        }
      }
      .fixedSize()
    }
    .appFont(.callout)
    // Read as one line, unless there is a button in it to reach.
    .accessibilityElement(children: editing == nil ? .combine : .contain)
  }

  private var name: String { PlanningText.limitName(line.budget, tree: tree, environment) }
}

/// «spent / available» with the available amount as a button; clicked, a field with the
/// limit's monthly amount — what a new amount replaces, the carry aside.
private struct LimitAmountField: View {
  @Dependency(\.environment) private var environment
  let line: LimitLine
  let name: String
  let editing: LimitAmountEditing
  @State private var text = ""
  @FocusState private var focused: Bool

  private var isEditing: Bool { editing.editing.wrappedValue == line.budget.id }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
      Text(verbatim: "\(environment.money.rounded(line.spent)) /")
        .monospacedDigit()
      if isEditing {
        TextField(text: $text) {
          Text(verbatim: t("limits.amount.placeholder"))
        }
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .appFont(.callout.monospacedDigit())
        .frame(width: 104)
        .focused($focused)
        .accessibilityIdentifier("limits.amount.field")
        .onAppear {
          text = AmountField.text(for: line.amount)
          editing.refusal.wrappedValue = nil
          Task { @MainActor in focused = true }
        }
        .onSubmit(commit)
        .onExitCommand(perform: close)
        .onChange(of: focused) { _, now in
          if !now { close() }
        }
      } else {
        Button {
          editing.refusal.wrappedValue = nil
          editing.editing.wrappedValue = line.budget.id
        } label: {
          Text(verbatim: environment.money.rounded(line.available))
            .monospacedDigit()
            .underline(pattern: .dot)
        }
        .buttonStyle(.plain)
        .help(t("limits.amount.help"))
        .accessibilityLabel(environment.format("limits.amount.edit", table: "Planning", name))
        .accessibilityIdentifier("limits.amount")
      }
    }
  }

  /// Enter: the write lands and the field closes, or the refusal is said under the line and
  /// the field stays with what was typed.
  private func commit() {
    if let refusal = editing.save(line.budget, text) {
      editing.refusal.wrappedValue = refusal
    } else {
      close()
    }
  }

  private func close() {
    guard isEditing else { return }
    editing.refusal.wrappedValue = nil
    editing.editing.wrappedValue = nil
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}
