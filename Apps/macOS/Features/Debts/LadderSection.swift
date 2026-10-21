import AppCore
import AppDatabase
import SwiftUI

/// The payoff ladder in «Долги»: «Сверх платежей: [10,000] (в среднем у вас остаётся 12,000)»,
/// the avalanche or the snowball, when the debts are paid off and the interest, the difference
/// between the two, the order with the month each debt is free, and the debts on it. The money
/// above is written to the database (`debts.ladder.extra`); the method chosen is this Mac's
/// (`debts.ladder.method`). The ladder is worked out again on every read.
struct LadderSection: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @AppStorage(LadderSection.methodKey) private var methodRaw = LadderMethod.avalanche.rawValue
  @State private var extra: AmountE4 = .zero
  @State private var loaded = false

  static let methodKey = "debts.ladder.method"

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text(verbatim: t("ladder.title")).appFont(.title2)
        Text(verbatim: t("ladder.hint"))
          .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
          Text(verbatim: t("ladder.extra"))
          AmountField(amount: $extra)
            .frame(maxWidth: 160)
            .onSubmit(saveExtra)
          Button(t("ladder.apply"), action: saveExtra)
            .controlSize(.small)
        }
        if let suggested = suggestedExtra {
          Text(
            verbatim: environment.format(
              "ladder.suggested", table: "Debts", environment.money.rounded(suggested))
          )
          .appFont(.caption).foregroundStyle(.secondary)
        }
        Picker(t("ladder.method"), selection: $methodRaw) {
          Text(verbatim: t("ladder.avalanche")).tag(LadderMethod.avalanche.rawValue)
          Text(verbatim: t("ladder.snowball")).tag(LadderMethod.snowball.rawValue)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("debts.ladder.method")
        Text(verbatim: t("ladder.\(method.rawValue).hint"))
          .appFont(.caption).foregroundStyle(.secondary).fixedSize(
            horizontal: false, vertical: true)
        if let comparison = comparison {
          plan(comparison)
        } else {
          Text(verbatim: t("ladder.empty")).foregroundStyle(.secondary)
        }
      }
      .padding(20)
    }
    .onAppear {
      guard !loaded else { return }
      loaded = true
      extra = compute.snapshot?.dataset.debtSettings.ladderExtraE4 ?? .zero
    }
  }

  private var method: LadderMethod { LadderMethod(rawValue: methodRaw) ?? .avalanche }

  /// The ladder with the money above as it is typed: worked out here, so a sum not saved yet is
  /// tried at once.
  private var comparison: LadderComparison? {
    guard let snapshot = compute.snapshot else { return nil }
    let candidates = Self.candidates(snapshot)
    guard !candidates.isEmpty else { return nil }
    return DebtLadder.compare(candidates, extraRub: extra, start: environment.today.monthKey)
  }

  static func candidates(_ snapshot: DataSnapshot) -> [LadderDebt] {
    let planning = snapshot.planning
    var states: [UUID: DebtDueState] = [:]
    var balances: [UUID: AmountE4] = [:]
    for line in planning.debts.iOwe {
      states[line.debt.id] = line.dues
      balances[line.debt.id] = line.balance
    }
    return DebtLadder.candidates(
      debts: snapshot.dataset.debts, states: states, balances: balances,
      accounts: planning.accounts, settings: snapshot.dataset.debtSettings,
      rubPerUnit: snapshot.context.rubPerUnit)
  }

  private var suggestedExtra: AmountE4? {
    guard let snapshot = compute.snapshot else { return nil }
    return DebtLadder.suggestedExtra(ledger: snapshot.ledger, today: environment.today)
  }

  @ViewBuilder
  private func plan(_ comparison: LadderComparison) -> some View {
    let chosen = method == .avalanche ? comparison.avalanche : comparison.snowball
    let money = environment.money
    VStack(alignment: .leading, spacing: 6) {
      if let free = chosen.freeFrom, let months = chosen.months {
        Text(
          verbatim: environment.format(
            "ladder.free", table: "Debts", environment.dates.monthTitle(free),
            environment.language.format("advice.months", table: "Planning", counts: months))
        )
        .appFont(.headline)
      } else {
        Label(t("ladder.never"), systemImage: "exclamationmark.triangle").appFont(.headline)
      }
      Text(
        verbatim: environment.format(
          "ladder.interest", table: "Debts", money.rounded(chosen.interestRub)))
      if let saved = comparison.interestSavedRub, let months = comparison.monthsSaved,
        saved.raw != 0 || months != 0
      {
        Text(
          verbatim: environment.format(
            "ladder.difference", table: "Debts", money.rounded(saved.magnitude),
            environment.language.format("advice.months", table: "Planning", counts: abs(months)))
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      Divider()
      let names = Dictionary(
        Self.candidates(compute.snapshot!).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
      ForEach(Array(chosen.order.enumerated()), id: \.element) { index, id in
        if let debt = names[id] {
          HStack {
            Text(verbatim: "\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
            Text(verbatim: debt.name)
            Text(verbatim: money.rate(debt.ratePercent)).foregroundStyle(.secondary)
            Spacer()
            Text(verbatim: money.rounded(debt.balanceRub)).monospacedDigit()
            if let month = chosen.payoff[id] {
              Text(verbatim: environment.dates.monthTitle(month))
                .foregroundStyle(.secondary)
            }
          }
          .appFont(.callout)
        }
      }
    }
    .accessibilityIdentifier("debts.ladder.plan")
  }

  private func saveExtra() {
    guard let dependencies else { return }
    var settings = compute.snapshot?.dataset.debtSettings ?? .standard
    settings.ladderExtraE4 = extra.raw > 0 ? extra : nil
    guard settings != compute.snapshot?.dataset.debtSettings else { return }
    DebtActions(dependencies).saveSettings(settings)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}
