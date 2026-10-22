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
  @Environment(\.themeSurfaces) private var surfaces
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
        Picker(t("ladder.method"), selection: $methodRaw) {
          Text(verbatim: t("ladder.avalanche")).tag(LadderMethod.avalanche.rawValue)
          Text(verbatim: t("ladder.snowball")).tag(LadderMethod.snowball.rawValue)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(t("ladder.method"))
        .accessibilityIdentifier("debts.ladder.method")
        Text(verbatim: t("ladder.\(method.rawValue).hint"))
          .appFont(.caption).foregroundStyle(.secondary).fixedSize(
            horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 6) {
          Text(verbatim: t("ladder.extra")).appFont(.caption).foregroundStyle(.secondary)
          HStack {
            AmountField(amount: $extra)
              .onSubmit(saveExtra)
              .padding(.horizontal, 12).padding(.vertical, 8)
              .background(surfaces.card, in: .rect(cornerRadius: 10))
              .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(surfaces.cardBorder))
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
        }
        if let comparison = comparison {
          plan(comparison)
        } else {
          Text(verbatim: t("ladder.empty")).foregroundStyle(.secondary)
        }
      }
      .padding(20)
    }
    .themedWindowBackground()
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
    let candidates = Dictionary(
      Self.candidates(compute.snapshot!).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 8) {
        Text(verbatim: t("ladder.order")).appFont(.headline)
          .accessibilityAddTraits(.isHeader)
        ForEach(Array(chosen.order.enumerated()), id: \.element) { index, id in
          if let debt = candidates[id] {
            HStack(spacing: 10) {
              Text(verbatim: String(index + 1))
                .appFont(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(surfaces.onAccent)
                .frame(width: 22, height: 22)
                .background(surfaces.accent, in: .circle)
              VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: debt.name).appFont(.callout)
                Text(
                  verbatim:
                    "\(environment.format("debts.rate.row", table: "Debts", money.rate(debt.ratePercent))) · \(money.rounded(debt.balanceRub))"
                )
                .appFont(.caption).foregroundStyle(.secondary).monospacedDigit()
              }
              Spacer(minLength: 8)
              if let month = chosen.payoff[id] {
                Text(verbatim: environment.dates.monthTitle(month))
                  .appFont(.caption).foregroundStyle(.secondary)
              }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(surfaces.background, in: .rect(cornerRadius: 8))
            .accessibilityElement(children: .combine)
          }
        }
      }
      .contentCard()
      VStack(alignment: .leading, spacing: 6) {
        Text(verbatim: t("ladder.result")).appFont(.headline)
          .accessibilityAddTraits(.isHeader)
        if let free = chosen.freeFrom, let months = chosen.months {
          DebtFactRow(
            label: t("ladder.free.label"), value: environment.dates.monthTitle(free), bold: true
          )
          .accessibilityHint(
            environment.language.format("advice.months", table: "Planning", counts: months))
        } else {
          Label(t("ladder.never"), systemImage: "exclamationmark.triangle").appFont(.callout)
        }
        DebtFactRow(
          label: t("ladder.interest.label"), value: "≈ \(money.rounded(chosen.interestRub))")
        if let saved = comparison.interestSavedRub, let months = comparison.monthsSaved,
          saved.raw != 0 || months != 0
        {
          Text(
            verbatim: environment.format(
              "ladder.difference", table: "Debts", money.rounded(saved.magnitude),
              environment.language.format("advice.months", table: "Planning", counts: abs(months)))
          )
          .appFont(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
      .contentCard()
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
