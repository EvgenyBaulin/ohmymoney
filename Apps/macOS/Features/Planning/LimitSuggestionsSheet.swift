import AppCore
import SwiftUI

/// «Предложить лимиты…»: the top-level categories spent on in the last three full months that
/// have no limit, each with a monthly amount — a usual month, or a usual month less 10 %. Every
/// row is kept by default; its amount can be typed over. «Добавить N лимитов» writes the kept
/// ones as one write and one step of ⌘Z.
struct LimitSuggestionsSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss

  @State private var basis: LimitSuggestionBasis = .usual
  /// The suggestions as the sheet opened: what the owner unticks and types stays on its row.
  @State private var suggestions: [LimitSuggestion]?
  /// The rows unticked.
  @State private var left: Set<UUID> = []
  /// What was typed over a row's amount; a row not typed into follows the basis.
  @State private var typed: [UUID: String] = [:]
  @State private var failed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t("limits.suggest.title")).appFont(.headline)
      Text(verbatim: t("limits.suggest.subtitle"))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      let rows = suggestions ?? []
      if rows.isEmpty {
        Text(verbatim: t("limits.suggest.none"))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("limits.suggest.none")
      } else {
        Picker(t("limits.suggest.basis"), selection: $basis) {
          Text(verbatim: t("limits.suggest.basis.usual")).tag(LimitSuggestionBasis.usual)
          Text(verbatim: t("limits.suggest.basis.tenPercentLess"))
            .tag(LimitSuggestionBasis.tenPercentLess)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("limits.suggest.basis")
        ScrollView {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(rows) { suggestion in
              row(suggestion)
              Divider()
            }
          }
          .padding(.trailing, 8)
        }
        .frame(minHeight: 160, maxHeight: 400)
      }
      HStack {
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Spacer()
        if !rows.isEmpty {
          let chosen = chosen(rows)
          Button(environment.format("limits.suggest.add", table: "Planning", counts: chosen.count))
          {
            // Read the rows again: the label was laid out before the last typed amount arrived.
            add(self.chosen(rows))
          }
          .keyboardShortcut(.defaultAction)
          .disabled(chosen.isEmpty || hasUnreadableAmount(rows))
          .accessibilityIdentifier("limits.suggest.add")
        }
      }
    }
    .padding(20)
    .sheetFrame(width: 520)
    .onAppear {
      if suggestions == nil, let dependencies {
        suggestions = PlanningActions(dependencies).suggestedLimits()
      }
    }
    .refusedWriteAlert($failed, environment)
  }

  @ViewBuilder
  private func row(_ suggestion: LimitSuggestion) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Toggle(isOn: kept(suggestion.id)) {
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: name(of: suggestion))
          Text(
            verbatim: environment.format(
              "limits.suggest.usualMonth", table: "Planning",
              environment.money.rounded(suggestion.median))
          )
          .appFont(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        }
      }
      .toggleStyle(.checkbox)
      Spacer()
      TextField(t("limits.suggest.amount"), text: amountText(suggestion))
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
        .frame(width: 110)
        .disabled(left.contains(suggestion.id))
        .accessibilityLabel(
          environment.format("limits.suggest.amountOf", table: "Planning", name(of: suggestion)))
      Text(verbatim: "₽").foregroundStyle(.secondary)
    }
  }

  private func kept(_ id: UUID) -> Binding<Bool> {
    Binding(
      get: { !left.contains(id) },
      set: { on in
        if on { left.remove(id) } else { left.insert(id) }
      })
  }

  private func amountText(_ suggestion: LimitSuggestion) -> Binding<String> {
    Binding(
      get: { typed[suggestion.id] ?? AmountField.text(for: suggestion.amount(basis)) },
      set: { typed[suggestion.id] = $0 })
  }

  private func amount(of suggestion: LimitSuggestion) -> LimitWrites.Typed {
    guard let text = typed[suggestion.id] else { return .amount(suggestion.amount(basis)) }
    return LimitWrites.read(text)
  }

  /// The kept rows with an amount above zero, in the order of the sheet.
  private func chosen(_ rows: [LimitSuggestion]) -> [(categoryId: UUID, amount: AmountE4)] {
    rows.compactMap { suggestion in
      guard !left.contains(suggestion.id),
        case .amount(let amount) = amount(of: suggestion), amount.raw > 0
      else { return nil }
      return (suggestion.categoryId, amount)
    }
  }

  /// A kept row whose field says no amount: nothing is written until it is fixed or unticked.
  private func hasUnreadableAmount(_ rows: [LimitSuggestion]) -> Bool {
    rows.contains { suggestion in
      guard !left.contains(suggestion.id) else { return false }
      switch amount(of: suggestion) {
      case .amount(let amount): return amount.raw <= 0
      case .empty, .unreadable: return true
      }
    }
  }

  private func add(_ chosen: [(categoryId: UUID, amount: AmountE4)]) {
    guard let dependencies, PlanningActions(dependencies).addSuggestedLimits(chosen) != nil else {
      failed = true
      return
    }
    dismiss()
  }

  private func name(of suggestion: LimitSuggestion) -> String {
    compute.snapshot?.ledger.tree.category(suggestion.categoryId)?.name ?? ""
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}
