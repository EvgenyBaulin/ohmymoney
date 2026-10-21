import AppCore
import AppDatabase
import SwiftUI

/// The goal of the cushion as the form holds it: N months of obligatory spending, the month
/// to be done by if the owner names one, and whether the cushion stays out of the free sum.
struct CushionGoalDraft: Equatable {
  /// The months a new goal starts with.
  static let defaultMonths = 6
  /// How far ahead «Собрать к» offers months.
  static let monthsAhead = 60

  var months: Int
  /// `nil`: no month named.
  var byMonth: MonthKey?
  var outOfFreeMoney: Bool

  init(_ settings: CapitalSettings) {
    months = settings.targetMonths ?? Self.defaultMonths
    byMonth = settings.targetMonth
    outOfFreeMoney = settings.outOfFreeMoney
  }

  /// The months «Собрать к» offers: from this month on, and the month stored even if it is
  /// past, so it shows as it is rather than as another choice.
  static func monthChoices(today: DateOnly, including stored: MonthKey?) -> [MonthKey] {
    let first = today.monthKey
    var months = (0..<monthsAhead).map { first.firstDay.adding(months: $0).monthKey }
    if let stored, !months.contains(stored) {
      months.append(stored)
      months.sort()
    }
    return months
  }

  /// The settings the form writes over `settings`, the history of the spending untouched;
  /// `removingGoal` takes the goal and its month away.
  func settings(over settings: CapitalSettings, removingGoal: Bool = false) -> CapitalSettings {
    var result = settings
    result.targetMonths =
      removingGoal
      ? nil
      : min(
        max(months, CapitalSettings.targetMonthsRange.lowerBound),
        CapitalSettings.targetMonthsRange.upperBound)
    result.targetMonth = removingGoal ? nil : byMonth
    result.outOfFreeMoney = outOfFreeMoney
    return result
  }

  /// One write and one step of ⌘Z: only the keys whose stored text changes; `nil` when none.
  static func change(
    from before: CapitalSettings, to after: CapitalSettings, at now: Date
  )
    -> PlanningChange?
  {
    let old = before.storedValues
    let new = after.storedValues
    var settings: [String: String?] = [:]
    for key in [
      CapitalSettings.targetMonthsKey, CapitalSettings.targetMonthKey,
      CapitalSettings.outOfFreeMoneyKey,
    ] where old[key] != new[key] {
      settings.updateValue(new[key] ?? nil, forKey: key)
    }
    guard !settings.isEmpty else { return nil }
    return PlanningChange(settings: settings, at: now)
  }
}

/// «Цель подушки»: «Подушка на N месяцев» (1…24), «Собрать к» a month if wanted, and «Не считать
/// подушку в свободной сумме». «Сохранить» is one step of ⌘Z.
struct CushionGoalForm: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store

  let finish: () -> Void

  @State private var stored = CapitalSettings.standard
  @State private var draft = CushionGoalDraft(.standard)
  @State private var loaded = false
  @State private var failed = false

  private func t(_ key: String) -> String { CushionText.t(key, environment) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t("cushion.goal.title"))
        .appFont(.headline)
      Form {
        Stepper(value: $draft.months, in: CapitalSettings.targetMonthsRange) {
          Text(
            verbatim: environment.format(
              "cushion.goal.months", table: CushionText.table, counts: draft.months))
        }
        .accessibilityIdentifier("cushion.goal.months")
        Toggle(
          isOn: Binding(
            get: { draft.byMonth != nil },
            set: { on in
              draft.byMonth =
                on
                ? (draft.byMonth
                  ?? environment.today.monthKey.firstDay
                  .adding(months: 12).monthKey) : nil
            })
        ) {
          Text(verbatim: t("cushion.goal.byMonthToggle"))
        }
        if draft.byMonth != nil {
          Picker(selection: $draft.byMonth) {
            ForEach(
              CushionGoalDraft.monthChoices(
                today: environment.today, including: stored.targetMonth),
              id: \.self
            ) { month in
              Text(verbatim: environment.dates.monthTitle(month)).tag(MonthKey?.some(month))
            }
          } label: {
            Text(verbatim: t("cushion.goal.month"))
          }
        }
        Toggle(isOn: $draft.outOfFreeMoney) {
          Text(verbatim: environment.language("settings.planning.cushionOut", table: "Settings"))
          Text(
            verbatim: environment.language("settings.planning.cushionOutHint", table: "Settings"))
        }
        .accessibilityIdentifier("cushion.goal.outOfFree")
      }
      .formStyle(.grouped)
      HStack {
        if stored.targetMonths != nil {
          Button(t("cushion.goal.remove"), role: .destructive) { save(removingGoal: true) }
        }
        Spacer()
        Button(environment.language("action.cancel"), role: .cancel) { finish() }
          .keyboardShortcut(.cancelAction)
        Button(environment.language("action.save")) { save(removingGoal: false) }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(!loaded || store.isWritingInBackground)
          .accessibilityIdentifier("cushion.goal.save")
      }
    }
    .padding(20)
    .sheetFrame(width: 440)
    .task { load() }
    .refusedWriteAlert($failed, environment)
  }

  private func load() {
    guard !loaded else { return }
    stored = Self.read(environment)
    draft = CushionGoalDraft(stored)
    loaded = true
  }

  /// The settings as the database has them now.
  static func read(_ environment: AppEnvironment) -> CapitalSettings {
    guard let settings = environment.settings else { return .standard }
    var values: [String: String] = [:]
    for key in CapitalSettings.storageKeys {
      if let value = (try? settings.string(key)) ?? nil { values[key] = value }
    }
    return CapitalSettings(storedValues: values)
  }

  private func save(removingGoal: Bool) {
    if Self.save(
      draft, over: stored, removingGoal: removingGoal, store: store, now: environment.now())
    {
      finish()
    } else {
      failed = true
    }
  }

  /// Writes the goal as one step of ⌘Z and says so in the journal; nothing changed is nothing
  /// written. Returns whether the form may close.
  static func save(
    _ draft: CushionGoalDraft, over stored: CapitalSettings, removingGoal: Bool = false,
    store: TransactionsStore, now: Date
  ) -> Bool {
    let after = draft.settings(over: stored, removingGoal: removingGoal)
    guard let change = CushionGoalDraft.change(from: stored, to: after, at: now) else {
      return true
    }
    guard store.apply(change) else { return false }
    AppLog.info(
      "cushion.goal.set", .db, "the goal of the safety cushion was set",
      [
        LogPair("months", .count(after.targetMonths ?? 0)),
        LogPair("byMonth", .flag(after.targetMonth != nil)),
        LogPair("outOfFree", .flag(after.outOfFreeMoney)),
      ])
    return true
  }
}
