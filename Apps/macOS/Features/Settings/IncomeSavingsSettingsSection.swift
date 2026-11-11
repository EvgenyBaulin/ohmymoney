import AppCore
import SwiftUI

/// Settings → Планирование, «Доход и сбережения»: the proportions of the budget (50 / 30 / 20 or
/// the owner's own), whether the savings norm counts only earnings, and whether the line
/// «spending follows income» may appear in «Стоит посмотреть». They live in the `settings` table
/// (`IncomeSavingsSettings`), so they travel with the archive, and are written at once; like
/// every setting they are no step of ⌘Z.
struct IncomeSavingsSettingsSection: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @State private var values = IncomeSavingsSettings.standard

  private func t(_ key: String) -> String { IncomeSavingsText.t(key, environment) }

  var body: some View {
    #if os(macOS)
      macBody
    #else
      formBody
    #endif
  }

  private var formBody: some View {
    Section {
      Stepper(value: needs, in: IncomeProportionsDraft.needsRange(wants: values.proportions)) {
        Text(
          verbatim: IncomeSavingsText.f(
            "income.settings.needs", environment, values.proportions.needsPercent))
      }
      .accessibilityIdentifier("settings.income.needs")
      Stepper(value: wants, in: IncomeProportionsDraft.wantsRange(needs: values.proportions)) {
        Text(
          verbatim: IncomeSavingsText.f(
            "income.settings.wants", environment, values.proportions.wantsPercent))
      }
      .accessibilityIdentifier("settings.income.wants")
      LabeledContent {
        Text(verbatim: "\(values.proportions.savingsPercent) %")
          .monospacedDigit()
      } label: {
        Text(verbatim: t("income.settings.savings"))
        Text(verbatim: t("income.settings.savingsHint"))
      }
      .accessibilityIdentifier("settings.income.savings")
      if values.proportions != .rule503020 {
        Button(t("income.settings.reset")) {
          save { $0.proportions = .rule503020 }
        }
        .accessibilityIdentifier("settings.income.reset")
      }
      Toggle(
        isOn: Binding(
          get: { values.earningsOnly }, set: { value in save { $0.earningsOnly = value } })
      ) {
        Text(verbatim: t("income.settings.earningsOnly"))
        Text(verbatim: t("income.settings.earningsOnlyHint"))
      }
      .accessibilityIdentifier("settings.income.earningsOnly")
      Toggle(
        isOn: Binding(
          get: { values.trendNudgeEnabled },
          set: { value in save { $0.trendNudgeEnabled = value } })
      ) {
        Text(verbatim: t("income.settings.trendNudge"))
        Text(verbatim: t("income.settings.trendNudgeHint"))
      }
      .accessibilityIdentifier("settings.income.trendNudge")
    } header: {
      Text(verbatim: t("income.settings.title"))
        .settingsHeaderStyle()
    } footer: {
      Text(verbatim: t("income.settings.footer"))
        .appFont(.callout)
        .foregroundStyle(.secondary)
    }
    .task(id: compute.generation) {
      if let stored = compute.snapshot?.dataset.incomeSavings { values = stored }
    }
  }

  #if os(macOS)
    /// The design's card (Figma 61:56916): the title 13 semibold, rows of 16 × 11 with the value
    /// at the right — «Нужное 50 %», «Желания 30 %», «Сбережения 20 %» — «Вернуть 50 / 30 / 20»
    /// in the accent, two switches with their hints, and the footer 12.
    private var macBody: some View {
      Section {
        VStack(alignment: .leading, spacing: SettingsControlMetrics.blockGap) {
          Text(verbatim: t("income.settings.title"))
            .appFont(AppFont.system(size: 13, weight: .semibold))
          SettingsCard {
            percentRow(
              t("income.settings.needsLabel"), values.proportions.needsPercent, binding: needs,
              range: IncomeProportionsDraft.needsRange(wants: values.proportions), id: "needs")
            percentRow(
              t("income.settings.wantsLabel"), values.proportions.wantsPercent, binding: wants,
              range: IncomeProportionsDraft.wantsRange(needs: values.proportions), id: "wants")
            SettingsCardRow(
              title: t("income.settings.savings"), hint: t("income.settings.savingsHint"),
              compact: true
            ) {
              Text(verbatim: "\(values.proportions.savingsPercent) %")
                .appFont(AppFont.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("settings.income.savings")
            if values.proportions != .rule503020 {
              Button {
                save { $0.proportions = .rule503020 }
              } label: {
                Text(verbatim: t("income.settings.reset"))
                  .appFont(AppFont.system(size: 13, weight: .medium))
                  .foregroundStyle(Color.accentColor)
              }
              .buttonStyle(.plain)
              .padding(.horizontal, SettingsCardMetrics.rowHorizontal)
              .padding(.vertical, SettingsCardMetrics.compactVertical)
              .frame(maxWidth: .infinity, alignment: .leading)
              .accessibilityIdentifier("settings.income.reset")
              Divider().opacity(0.6)
            }
            SettingsCardRow(
              title: t("income.settings.earningsOnly"), hint: t("income.settings.earningsOnlyHint"),
              compact: true
            ) {
              Toggle(
                isOn: Binding(
                  get: { values.earningsOnly }, set: { value in save { $0.earningsOnly = value } })
              ) { Text(verbatim: t("income.settings.earningsOnly")) }
              .labelsHidden().toggleStyle(.switch)
              .accessibilityIdentifier("settings.income.earningsOnly")
            }
            SettingsCardRow(
              title: t("income.settings.trendNudge"), hint: t("income.settings.trendNudgeHint"),
              showsDivider: false, compact: true
            ) {
              Toggle(
                isOn: Binding(
                  get: { values.trendNudgeEnabled },
                  set: { value in save { $0.trendNudgeEnabled = value } })
              ) { Text(verbatim: t("income.settings.trendNudge")) }
              .labelsHidden().toggleStyle(.switch)
              .accessibilityIdentifier("settings.income.trendNudge")
            }
          }
          Text(verbatim: t("income.settings.footer"))
            .appFont(AppFont.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, SettingsChromeMetrics.contentInset)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets())
      .task(id: compute.generation) {
        if let stored = compute.snapshot?.dataset.incomeSavings { values = stored }
      }
    }

    private func percentRow(
      _ title: String, _ percent: Int, binding: Binding<Int>, range: ClosedRange<Int>, id: String
    ) -> some View {
      SettingsCardRow(title: title, compact: true) {
        HStack(spacing: 8) {
          Text(verbatim: "\(percent) %")
            .appFont(AppFont.system(size: 13, weight: .semibold).monospacedDigit())
            .foregroundStyle(.secondary)
          Stepper("", value: binding, in: range).labelsHidden()
        }
      }
      .accessibilityIdentifier("settings.income.\(id)")
    }
  #endif

  private var needs: Binding<Int> {
    Binding(
      get: { values.proportions.needsPercent },
      set: { value in
        guard let next = IncomeProportionsDraft.setting(needs: value, in: values.proportions)
        else { return }
        save { $0.proportions = next }
      })
  }

  private var wants: Binding<Int> {
    Binding(
      get: { values.proportions.wantsPercent },
      set: { value in
        guard let next = IncomeProportionsDraft.setting(wants: value, in: values.proportions)
        else { return }
        save { $0.proportions = next }
      })
  }

  private func save(_ change: (inout IncomeSavingsSettings) -> Void) {
    var updated = values
    change(&updated)
    guard updated != values else { return }
    values = updated
    environment.saveIncomeSavings(updated)
  }
}

/// The two steppers of the proportions: needs and wants are typed, savings are what is left to
/// make a hundred, so the three always add up and a rule that is not one cannot be saved.
enum IncomeProportionsDraft {
  /// What needs may be, given wants: up to the rest after them.
  static func needsRange(wants proportions: BudgetProportions) -> ClosedRange<Int> {
    0...(100 - proportions.wantsPercent)
  }

  static func wantsRange(needs proportions: BudgetProportions) -> ClosedRange<Int> {
    0...(100 - proportions.needsPercent)
  }

  /// The proportions with needs set; `nil` when they would not fit in a hundred. Savings take
  /// what is left.
  static func setting(needs: Int, in proportions: BudgetProportions) -> BudgetProportions? {
    BudgetProportions(
      needs: needs, wants: proportions.wantsPercent,
      savings: 100 - needs - proportions.wantsPercent)
  }

  static func setting(wants: Int, in proportions: BudgetProportions) -> BudgetProportions? {
    BudgetProportions(
      needs: proportions.needsPercent, wants: wants,
      savings: 100 - proportions.needsPercent - wants)
  }
}
