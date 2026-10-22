import AppCore
import AppDatabase
import SwiftUI

/// Settings of planning and reconciliation («Сверка: напоминание раз в N дней (по умолчанию
/// 14)», «Сбережения: целевая доля (по умолчанию 10%)», how the money of a foreign-currency
/// goal counts in rubles, how many limits the lists of limits show). The values live in the
/// `settings` table under `PlanningSettings` keys, so they travel with the archive and the
/// pipeline reads them with the rest of the data: a change here reaches the numbers through
/// the observation of the database, like any other write.
struct PlanningSettingsView: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @State private var values = PlanningSettings()
  /// One setting for all seven anomaly rules. It lives beside the cashback category, under an
  /// `AnalyticsSettings` key, because the rules read it with the rest of the data.
  @State private var sensitivity = AnomalySensitivity.standard
  /// The settings of the safety cushion that live here: how many months its obligatory spending
  /// is taken over, and whether its money stays out of the free sum. Its goal is set on
  /// «Капитал» (`CushionGoalForm`).
  @State private var cushion = CapitalSettings.standard
  /// A write the database refused; the alert says so (`AppEnvironment.attempt`).
  @State private var refused = false
  /// The layout of the Planning screen on this Mac, kept in `UserDefaults`, not in the database.
  var layout: PlanningLayoutStore = .shared

  var body: some View {
    Form {
      screenSection

      // Self-employment, the allocation of an income and the hints of 1.9: each its own
      // section, written as steps of ⌘Z (the database) or switches of this Mac (the hints).
      SelfEmploymentSettingsSection()
      AllocationSettingsSection()
      IncomeSavingsSettingsSection()
      PlanningHintsSection()
      SpendingAnalysisSettingsSection()

      Section {
        Stepper(
          value: Binding(
            get: { values.reconcileEveryDays }, set: { save(\.reconcileEveryDays, $0) }),
          in: 1...90
        ) {
          Text(
            verbatim: environment.format(
              "settings.planning.reconcileEvery", table: "Settings",
              counts: values.reconcileEveryDays))
        }
      } header: {
        Text(verbatim: t("settings.planning.reconciliation"))
          .settingsHeaderStyle()
      }

      Section {
        Stepper(
          value: Binding(
            get: { values.savingsTargetBp / 100 }, set: { save(\.savingsTargetBp, $0 * 100) }),
          in: 0...90
        ) {
          Text(
            verbatim: environment.format(
              "settings.planning.savingsTarget", table: "Settings",
              counts: values.savingsTargetBp / 100))
        }
        Toggle(
          isOn: Binding(get: { values.reserveGoalPlan }, set: { save(\.reserveGoalPlan, $0) })
        ) {
          Text(verbatim: t("settings.planning.reserve"))
          Text(verbatim: t("settings.planning.reserveHint"))
        }
        Toggle(
          isOn: Binding(
            get: { values.reserveEventBudgets }, set: { save(\.reserveEventBudgets, $0) })
        ) {
          Text(verbatim: t("settings.planning.reserveEvents"))
          Text(verbatim: t("settings.planning.reserveEventsHint"))
        }
        .accessibilityIdentifier("settings.planning.reserveEvents")
        // Where the money saved in goals is kept. On an account counted in the summary, the free
        // sum takes it off what can be spent now; on an account outside the summary it is not in
        // the balance, and taking it off would count it twice.
        Toggle(
          isOn: Binding(
            get: { values.reconcileIncludesGoalSavings },
            set: { save(\.reconcileIncludesGoalSavings, $0) })
        ) {
          Text(verbatim: t("settings.planning.includesGoals"))
          Text(verbatim: t("settings.planning.includesGoalsHint"))
        }
        .accessibilityIdentifier("settings.planning.goalMoney")
        // How the money of a goal in another currency counts in rubles: at today's rate when it
        // is kept in that currency, at what the contributions cost when it is kept in rubles.
        Picker(
          selection: Binding(
            get: { values.goalSavingsValuation }, set: { save(\.goalSavingsValuation, $0) })
        ) {
          ForEach(GoalSavingsValuation.allCases, id: \.self) { valuation in
            Text(verbatim: t("settings.planning.goalValuation.\(valuation.rawValue)"))
              .tag(valuation)
          }
        } label: {
          Text(verbatim: t("settings.planning.goalValuation"))
          Text(verbatim: t("settings.planning.goalValuationHint"))
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("settings.planning.goalValuation")
      } header: {
        Text(verbatim: t("settings.planning.savings"))
          .settingsHeaderStyle()
      }

      Section {
        Stepper(
          value: Binding(
            get: { cushion.historyMonths }, set: { save(cushion: \.historyMonths, $0) }),
          in: CapitalSettings.historyMonthsRange
        ) {
          Text(
            verbatim: environment.format(
              "settings.planning.cushionHistory", table: "Settings",
              counts: cushion.historyMonths))
        }
        .accessibilityIdentifier("settings.planning.cushionHistory")
        Toggle(
          isOn: Binding(
            get: { cushion.outOfFreeMoney }, set: { save(cushion: \.outOfFreeMoney, $0) })
        ) {
          Text(verbatim: t("settings.planning.cushionOut"))
          Text(verbatim: t("settings.planning.cushionOutHint"))
        }
        .accessibilityIdentifier("settings.planning.cushionOut")
      } header: {
        Text(verbatim: t("settings.planning.cushion"))
          .settingsHeaderStyle()
      } footer: {
        Text(verbatim: t("settings.planning.cushionHint"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }

      Section {
        Picker(
          selection: Binding(get: { values.limitsTopN }, set: { save(\.limitsTopN, $0) })
        ) {
          ForEach(Self.limitsTopNChoices(including: values.limitsTopN), id: \.self) { count in
            Text(verbatim: Self.choiceTitle(count, environment.money)).tag(Int?.some(count))
          }
          Text(verbatim: t("settings.planning.limitsTopN.all")).tag(Int?.none)
        } label: {
          Text(verbatim: t("settings.planning.limitsTopN"))
        }
        .accessibilityIdentifier("settings.planning.limitsTopN")
      } header: {
        Text(verbatim: t("settings.planning.limits"))
          .settingsHeaderStyle()
      } footer: {
        Text(verbatim: t("settings.planning.limitsHint"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }

      Section {
        Picker(
          selection: Binding(get: { sensitivity }, set: { save(sensitivity: $0) })
        ) {
          ForEach(AnomalySensitivity.allCases, id: \.self) { level in
            Text(verbatim: t("settings.anomalies.\(level.rawValue)")).tag(level)
          }
        } label: {
          Text(verbatim: t("settings.anomalies.sensitivity"))
        }
        .pickerStyle(.segmented)
      } header: {
        Text(verbatim: t("settings.anomalies"))
          .settingsHeaderStyle()
      } footer: {
        Text(verbatim: t("settings.anomalies.hint"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .padding()
    .task { load() }
    .refusedWriteAlert($refused, environment)
    // The reserve switch also lives on the Planning screen: after any write, read again, so
    // this tab never shows (or writes back) a value older than the database.
    .onChange(of: compute.generation) { load() }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Settings") }

  /// «Экран «Планирование»»: how many of the nearest items the long blocks show, and the order
  /// of the blocks. Habits of this Mac (`PlanningLayoutStore`), written at once, no step of ⌘Z.
  private var screenSection: some View {
    Section {
      Picker(selection: Binding(get: { layout.length }, set: { layout.setLength($0) })) {
        ForEach(PlanningListLength.choices, id: \.self) { length in
          Text(verbatim: PlanningBlockText.lengthTitle(length, environment)).tag(length)
        }
      } label: {
        Text(verbatim: t("settings.planning.listLength"))
        Text(verbatim: t("settings.planning.listLengthHint"))
      }
      .pickerStyle(.menu)
      .accessibilityIdentifier("settings.planning.listLength")
      PlanningBlockOrderRows(layout: layout)
    } header: {
      Text(verbatim: t("settings.planning.screen"))
        .accessibilityIdentifier("settings.planning.screen")
    } footer: {
      VStack(alignment: .leading, spacing: 6) {
        Text(verbatim: t("settings.planning.blockOrderHint"))
          .fixedSize(horizontal: false, vertical: true)
        Button(t("settings.planning.blockOrderReset")) { layout.resetOrder() }
          .disabled(PlanningBlocks.isStandard(layout.order))
      }
      .appFont(.callout)
      .foregroundStyle(.secondary)
    }
  }

  private func load() {
    guard let settings = environment.settings else { return }
    var stored: [String: String] = [:]
    for key in PlanningSettings.storageKeys {
      if let value = try? settings.string(key) { stored[key] = value }
    }
    // The storage layer's own reading: one format for the app, the pipeline and the archive.
    values = PlanningSettings(storedValues: stored)
    cushion = CushionGoalForm.read(environment)
    sensitivity =
      ((try? settings.string(AnalyticsSettings.anomalySensitivityKey)) ?? nil)
      .flatMap(AnomalySensitivity.init(rawValue:)) ?? .standard
  }

  /// A refused setting is read back, so the control shows what the database still has.
  private func save(sensitivity level: AnomalySensitivity) {
    sensitivity = level
    guard
      environment.attempt(
        "settings.planning", on: environment.settings,
        { try $0.set(AnalyticsSettings.anomalySensitivityKey, to: level.rawValue) })
    else {
      refused = true
      load()
      return
    }
  }

  private func save<Value>(_ keyPath: WritableKeyPath<PlanningSettings, Value>, _ value: Value) {
    let before = values.storedValues
    values[keyPath: keyPath] = value
    // A setting, not an action: no step of ⌘Z. The observation of the database carries it to
    // the numbers. Only the key that changed is written: the others may have been changed
    // elsewhere since this tab read them (the reserve switch, the dismissed reminders).
    let stored = values.storedValues
    let written = environment.attempt("settings.planning", on: environment.settings) { settings in
      for key in Self.changedKeys(before: before, after: stored) {
        if let text = stored[key] ?? nil { try settings.set(key, to: text) }
      }
    }
    if !written {
      refused = true
      load()
    }
  }

  /// A setting of the cushion, as the others here: no step of ⌘Z, only the key that changed.
  private func save<Value>(cushion keyPath: WritableKeyPath<CapitalSettings, Value>, _ value: Value)
  {
    let before = cushion.storedValues
    cushion[keyPath: keyPath] = value
    let stored = cushion.storedValues
    let written = environment.attempt("settings.planning", on: environment.settings) { settings in
      for key in Self.changedKeys(before: before, after: stored) {
        if let text = stored[key] ?? nil { try settings.set(key, to: text) }
      }
    }
    if !written {
      refused = true
      load()
    }
  }

  /// A number of limits to show as the picker writes it: as every other number, thousands
  /// grouped.
  static func choiceTitle(_ count: Int, _ money: MoneyFormatter) -> String {
    money.count(Int64(count))
  }

  /// How many limits the lists can be set to show, fewest first: the usual choices, and the
  /// number stored when it is none of them — written by another version or by hand, it is
  /// still shown as it is rather than as a choice nobody made.
  static func limitsTopNChoices(including current: Int?) -> [Int] {
    let usual = [3, 5, 10, 20]
    guard let current, !usual.contains(current) else { return usual }
    return (usual + [current]).sorted()
  }

  /// The storage keys whose text differs between two readings.
  static func changedKeys(before: [String: String?], after: [String: String?]) -> [String] {
    after.keys.filter { before[$0] != after[$0] }.sorted()
  }
}

/// Settings → Планирование, «Распределение дохода»: the rules an income is allocated by, on a
/// sheet over the settings — the same sheet the allocation of an income opens.
struct AllocationSettingsSection: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @State private var showsRules = false

  private func t(_ key: String) -> String { environment.language(key, table: "Settings") }

  var body: some View {
    Section {
      LabeledContent {
        Button(t("settings.allocation.rules.open")) { showsRules = true }
          .accessibilityIdentifier("settings.allocation.rules.open")
      } label: {
        Text(verbatim: t("settings.allocation.rules"))
        Text(
          verbatim: Self.caption(
            rules: compute.snapshot?.dataset.allocationRules ?? [], environment))
      }
    } header: {
      Text(verbatim: t("settings.allocation"))
        .settingsHeaderStyle()
    } footer: {
      Text(verbatim: t("settings.allocation.hint"))
        .appFont(.callout)
        .foregroundStyle(.secondary)
    }
    .sheet(isPresented: $showsRules) {
      AllocationRulesSheet().handingOver(dependencies)
    }
  }

  /// «Правил: 3 · включено: 2», or «Правил нет».
  @MainActor
  static func caption(rules: [AllocationRule], _ environment: AppEnvironment) -> String {
    guard !rules.isEmpty else {
      return environment.language("settings.allocation.rules.none", table: "Settings")
    }
    return environment.format(
      "settings.allocation.rules.count", table: "Settings", rules.count,
      rules.filter(\.active).count)
  }
}

/// Settings → Планирование, «Подсказки»: the hint about many small purchases and the reminder
/// to ask for the credit history twice a year. Switches of this Mac, written at once, no step
/// of ⌘Z; both are on until switched off.
struct PlanningHintsSection: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @AppStorage(PlanningHintSettings.burnoutEnabledKey) private var burnout = true
  @AppStorage(PlanningHintSettings.creditHistoryEnabledKey) private var creditHistory = true

  private func t(_ key: String) -> String { environment.language(key, table: "Settings") }

  var body: some View {
    Section {
      VStack(alignment: .leading, spacing: 4) {
        Toggle(isOn: $burnout) {
          Text(verbatim: t("settings.hints.burnout"))
          Text(verbatim: t("settings.hints.burnoutHint"))
        }
        .accessibilityIdentifier("settings.hints.burnout")
        if burnout, needsEssentials {
          // Without a category marked necessary the hint would count groceries as treats:
          // it stays silent, and says here why.
          Label {
            Text(verbatim: t("settings.hints.burnoutNeedsEssentials"))
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "info.circle")
          }
          .appFont(.callout)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("settings.hints.burnoutNeedsEssentials")
        }
      }
      Toggle(isOn: $creditHistory) {
        Text(verbatim: t("settings.hints.creditHistory"))
        Text(verbatim: t("settings.hints.creditHistoryHint"))
      }
      .accessibilityIdentifier("settings.hints.creditHistory")
    } header: {
      Text(verbatim: t("settings.hints"))
        .settingsHeaderStyle()
    }
  }

  private var needsEssentials: Bool {
    guard let snapshot = compute.snapshot else { return false }
    if case .needsEssentials = snapshot.burnout { return true }
    return PlanningHintSettings.burnoutNeedsEssentials(snapshot.dataset.categories)
  }
}
