import AppCore
import AppDatabase
import SwiftUI

/// How the settings screen reads and writes the settings of self-employment: the switch, the
/// deduction left, the account the tax is kept on and the corrections of the law. Each write is
/// one `PlanningChange` of only the keys whose text changes — one step of ⌘Z, the keys as they
/// were kept for it by the store.
enum SelfEmploymentSettingsForm {
  /// The settings as the database has them now; a key that is missing or does not read is its
  /// default.
  @MainActor
  static func read(_ environment: AppEnvironment) -> SelfEmploymentSettings {
    guard let settings = environment.settings else { return .standard }
    var values: [String: String] = [:]
    for key in SelfEmploymentSettings.storageKeys {
      if let value = (try? settings.string(key)) ?? nil { values[key] = value }
    }
    return SelfEmploymentSettings(storedValues: values)
  }

  /// One write and one step of ⌘Z: only the keys whose stored text changes; `nil` when none.
  static func change(
    from before: SelfEmploymentSettings, to after: SelfEmploymentSettings, at now: Date
  ) -> PlanningChange? {
    let old = before.storedValues
    let new = after.storedValues
    var settings: [String: String?] = [:]
    for key in SelfEmploymentSettings.storageKeys where old[key] != new[key] {
      settings.updateValue(new[key] ?? nil, forKey: key)
    }
    guard !settings.isEmpty else { return nil }
    return PlanningChange(settings: settings, at: now)
  }

  /// «Я самозанятый» switched off: nothing is shown and nothing is counted any more; what the
  /// owner told about the deduction, the account and the law stays for the day it is back on.
  static func disabling(_ settings: SelfEmploymentSettings) -> SelfEmploymentSettings {
    var settings = settings
    settings.enabled = false
    return settings
  }

  // MARK: Typed values

  /// A percent typed into the reference: above zero and no more than a hundred, the separator
  /// as a rate reads it; `nil` — no percent.
  static func percent(_ text: String) -> Decimal? {
    guard let value = RateText.value(text), value > 0, value <= 100 else { return nil }
    return value
  }

  /// An amount of rubles typed into the reference or the deduction: zero or more; `nil` — no
  /// amount.
  static func amount(_ text: String) -> AmountE4? {
    guard let value = TypedNumber.parse(text), value >= 0,
      let amount = try? AmountE4(decimal: value)
    else { return nil }
    return amount
  }

  /// A correction of the law that equals the law is no correction: it is not kept, so the
  /// reference follows the law again when the law changes in a later version.
  static func override<Value: Equatable>(_ value: Value, law: Value) -> Value? {
    value == law ? nil : value
  }

  /// A value of the reference the owner corrects.
  enum ReferenceField: String, CaseIterable, Hashable {
    case individualsRate
    case organizationsRate
    case deduction
    case yearLimit
    case minimumTax

    var titleKey: String { "settings.selfEmployed.reference.\(rawValue)" }
    var isPercent: Bool { self == .individualsRate || self == .organizationsRate }
  }

  /// The settings with `text` typed into `field`, or `nil` when the text says nothing the field
  /// takes: a percent outside 0…100, an amount below zero, a year limit of zero. An empty field
  /// is the law again.
  static func setting(
    _ field: ReferenceField, to text: String, in settings: SelfEmploymentSettings
  ) -> SelfEmploymentSettings? {
    var settings = settings
    let law = NPDReference.law
    let empty = text.trimmingCharacters(in: .whitespaces).isEmpty
    switch field {
    case .individualsRate:
      if empty {
        settings.overrides.individualsRate = nil
      } else {
        guard let value = percent(text) else { return nil }
        settings.overrides.individualsRate = override(value, law: law.individualsRate)
      }
    case .organizationsRate:
      if empty {
        settings.overrides.organizationsRate = nil
      } else {
        guard let value = percent(text) else { return nil }
        settings.overrides.organizationsRate = override(value, law: law.organizationsRate)
      }
    case .deduction:
      if empty {
        settings.overrides.deductionTotalE4 = nil
      } else {
        guard let value = amount(text) else { return nil }
        settings.overrides.deductionTotalE4 = override(value, law: law.deductionTotalE4)
      }
    case .yearLimit:
      if empty {
        settings.overrides.yearLimitE4 = nil
      } else {
        guard let value = amount(text), value.raw > 0 else { return nil }
        settings.overrides.yearLimitE4 = override(value, law: law.yearLimitE4)
      }
    case .minimumTax:
      if empty {
        settings.overrides.minimumTaxE4 = nil
      } else {
        guard let value = amount(text) else { return nil }
        settings.overrides.minimumTaxE4 = override(value, law: law.minimumTaxE4)
      }
    }
    return settings
  }

  /// The day of the next month the tax is due, 1…31; the law's day is no correction.
  static func setting(dueDay: Int, in settings: SelfEmploymentSettings) -> SelfEmploymentSettings {
    var settings = settings
    settings.overrides.dueDay = override(min(max(dueDay, 1), 31), law: NPDReference.law.dueDay)
    return settings
  }

  /// Days before the due day the reminder starts, 0…31.
  static func setting(
    remindDays: Int, in settings: SelfEmploymentSettings
  )
    -> SelfEmploymentSettings
  {
    var settings = settings
    settings.overrides.remindDaysBefore = override(
      min(max(remindDays, 0), 31), law: NPDReference.law.remindDaysBefore)
    return settings
  }

  /// «Сколько вычета осталось?»: the amount as of `today`; an empty field — not told, no
  /// deduction is counted until it is. `nil` for text that is no amount.
  static func setting(
    deductionLeft text: String, today: DateOnly, in settings: SelfEmploymentSettings
  ) -> SelfEmploymentSettings? {
    var settings = settings
    if text.trimmingCharacters(in: .whitespaces).isEmpty {
      settings.deductionLeftE4 = nil
      settings.deductionLeftOn = nil
      return settings
    }
    guard let value = amount(text) else { return nil }
    settings.deductionLeftE4 = value
    settings.deductionLeftOn = today
    return settings
  }

  /// The text a field of the reference shows: the owner's correction, empty for the law (the
  /// law is the placeholder).
  static func text(
    of field: ReferenceField, in settings: SelfEmploymentSettings, _ money: MoneyFormatter
  ) -> String {
    let overrides = settings.overrides
    switch field {
    case .individualsRate: return overrides.individualsRate.map { money.number($0) } ?? ""
    case .organizationsRate: return overrides.organizationsRate.map { money.number($0) } ?? ""
    case .deduction: return overrides.deductionTotalE4.map { money.number($0.decimal) } ?? ""
    case .yearLimit: return overrides.yearLimitE4.map { money.number($0.decimal) } ?? ""
    case .minimumTax: return overrides.minimumTaxE4.map { money.number($0.decimal) } ?? ""
    }
  }

  /// What the law says for the field, as its placeholder.
  static func lawText(of field: ReferenceField, _ money: MoneyFormatter) -> String {
    let law = NPDReference.law
    switch field {
    case .individualsRate: return money.number(law.individualsRate)
    case .organizationsRate: return money.number(law.organizationsRate)
    case .deduction: return money.number(law.deductionTotalE4.decimal)
    case .yearLimit: return money.number(law.yearLimitE4.decimal)
    case .minimumTax: return money.number(law.minimumTaxE4.decimal)
    }
  }
}

/// Keys of this Mac the hints of Planning are switched by; read by the screens that show them.
@MainActor
enum PlanningHintSettings {
  /// «Подсказка о выгорании»: on unless switched off — the key «Стоит посмотреть» reads.
  static let burnoutEnabledKey = BurnoutShowing.enabledKey
  /// «Напоминать о кредитной истории»: on unless switched off — the key the reminders read, one
  /// for the whole Mac.
  static let creditHistoryEnabledKey = DebtReminderMarks.creditHistoryEnabledKey

  /// Whether a switch of this Mac is on: a key never written is on.
  static func isOn(_ key: String, in defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
  }

  /// Whether the burnout hint can work at all: it needs at least one category marked
  /// «Необходимая трата» to tell a small treat from groceries.
  static func burnoutNeedsEssentials(_ categories: [CoreKit.Category]) -> Bool {
    let tree = CategoryTree(categories)
    return !categories.contains { $0.kind == .expense && !$0.archived && tree.isEssential($0.id) }
  }
}

/// Settings → Планирование, «Самозанятость»: the switch — on, through the sheet of the
/// categories of self-employment over the settings —, and while it is on, how much of the
/// deduction is left, the account the tax is kept on and the reference of the law with the
/// owner's corrections. Each change is one step of ⌘Z.
struct SelfEmploymentSettingsSection: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @State private var values = SelfEmploymentSettings.standard
  @State private var accounts: [PaymentMethod] = []
  @State private var setsUp = false
  /// A write the database refused; the alert says so.
  @State private var refused = false

  /// `showing` is what the section shows before it reads the database: how a test lays it out
  /// with self-employment on.
  init(showing values: SelfEmploymentSettings = .standard) {
    _values = State(initialValue: values)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Settings") }

  var body: some View {
    Section {
      Toggle(isOn: Binding(get: { values.enabled }, set: switchTo)) {
        Text(verbatim: t("settings.selfEmployed.enabled"))
        Text(verbatim: t("settings.selfEmployed.enabledHint"))
      }
      .accessibilityIdentifier("settings.selfEmployed.enabled")
      if values.enabled {
        deductionRow
        Picker(selection: Binding(get: { values.taxAccountId }, set: setTaxAccount)) {
          Text(verbatim: t("settings.selfEmployed.taxAccount.none")).tag(UUID?.none)
          ForEach(accountChoices, id: \.id) { account in
            Text(verbatim: account.name).tag(UUID?.some(account.id))
          }
        } label: {
          Text(verbatim: t("settings.selfEmployed.taxAccount"))
          Text(verbatim: t("settings.selfEmployed.taxAccountHint"))
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("settings.selfEmployed.taxAccount")
      }
    } header: {
      Text(verbatim: t("settings.selfEmployed"))
        .settingsHeaderStyle()
    }
    .sheet(isPresented: $setsUp, onDismiss: load) {
      SelfEmploymentSetupSheet().handingOver(dependencies)
    }
    .task { load() }
    .onChange(of: compute.generation) { load() }
    .refusedWriteAlert($refused, environment)

    if values.enabled {
      referenceSection
    }
  }

  /// «Сколько вычета осталось?» — asked once; until it is answered the tax is counted without
  /// the deduction, a little more put aside rather than less.
  private var deductionRow: some View {
    VStack(alignment: .leading, spacing: 4) {
      SettingValueField(
        title: t("settings.selfEmployed.deductionLeft"),
        shown: values.deductionLeftE4.map { environment.money.number($0.decimal) } ?? "",
        placeholder: t("settings.selfEmployed.deductionLeft.unknown"),
        identifier: "settings.selfEmployed.deductionLeft",
        refusal: t("settings.selfEmployed.refusal.amount"),
        commit: { text in
          guard
            let next = SelfEmploymentSettingsForm.setting(
              deductionLeft: text, today: environment.today, in: values)
          else { return false }
          write(next)
          return true
        })
      Text(verbatim: deductionCaption)
        .appFont(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var deductionCaption: String {
    guard let left = values.deductionLeftE4, let day = values.deductionLeftOn else {
      return t("settings.selfEmployed.deductionLeft.hint")
    }
    var caption = environment.format(
      "settings.selfEmployed.deductionLeft.asOf", table: "Settings",
      environment.money.rounded(left), environment.dates.longDay(day))
    if let now = compute.snapshot?.planning.npd?.deductionLeftE4, now != left {
      caption +=
        " · "
        + environment.format(
          "settings.selfEmployed.deductionLeft.now", table: "Settings",
          environment.money.rounded(now))
    }
    return caption
  }

  /// «Справочник»: the rates, the deduction, the limit of a year, the due day, the smallest tax
  /// and the days of the reminder — the law as the app knows it, each correctable when the law
  /// changes before the app does.
  private var referenceSection: some View {
    Section {
      ForEach(SelfEmploymentSettingsForm.ReferenceField.allCases, id: \.self) { field in
        SettingValueField(
          title: t(field.titleKey),
          shown: SelfEmploymentSettingsForm.text(of: field, in: values, environment.money),
          placeholder: SelfEmploymentSettingsForm.lawText(of: field, environment.money),
          identifier: "settings.selfEmployed.reference.\(field.rawValue)",
          refusal: t(
            field.isPercent
              ? "settings.selfEmployed.refusal.percent" : "settings.selfEmployed.refusal.amount"),
          commit: { text in
            guard let next = SelfEmploymentSettingsForm.setting(field, to: text, in: values)
            else { return false }
            write(next)
            return true
          })
      }
      Stepper(
        value: Binding(
          get: { values.reference.dueDay },
          set: { write(SelfEmploymentSettingsForm.setting(dueDay: $0, in: values)) }),
        in: 1...31
      ) {
        Text(
          verbatim: environment.format(
            "settings.selfEmployed.reference.dueDay", table: "Settings",
            counts: values.reference.dueDay))
      }
      .accessibilityIdentifier("settings.selfEmployed.reference.dueDay")
      Stepper(
        value: Binding(
          get: { values.reference.remindDaysBefore },
          set: { write(SelfEmploymentSettingsForm.setting(remindDays: $0, in: values)) }),
        in: 0...31
      ) {
        Text(
          verbatim: environment.format(
            "settings.selfEmployed.reference.remindDays", table: "Settings",
            counts: values.reference.remindDaysBefore))
      }
      .accessibilityIdentifier("settings.selfEmployed.reference.remindDays")
    } header: {
      Text(verbatim: t("settings.selfEmployed.reference"))
        .settingsHeaderStyle()
    } footer: {
      VStack(alignment: .leading, spacing: 6) {
        Text(verbatim: t("settings.selfEmployed.referenceHint"))
          .fixedSize(horizontal: false, vertical: true)
        Button(t("settings.selfEmployed.referenceReset")) {
          var next = values
          next.overrides = .none
          write(next)
        }
        .disabled(values.overrides == .none)
        .accessibilityIdentifier("settings.selfEmployed.referenceReset")
      }
      .appFont(.callout)
      .foregroundStyle(.secondary)
    }
  }

  /// The live accounts the tax can be kept on, and the chosen one even when it is archived — so
  /// the picker never shows a choice nobody made.
  private var accountChoices: [PaymentMethod] {
    accounts.filter { !$0.archived || $0.id == values.taxAccountId }
  }

  private func switchTo(_ isOn: Bool) {
    if isOn {
      setsUp = true
    } else {
      write(SelfEmploymentSettingsForm.disabling(values))
    }
  }

  private func setTaxAccount(_ id: UUID?) {
    var next = values
    next.taxAccountId = id
    write(next)
  }

  /// One step of ⌘Z; a refused write is read back, so the controls show what the database has.
  private func write(_ next: SelfEmploymentSettings) {
    guard
      let change = SelfEmploymentSettingsForm.change(
        from: values, to: next, at: environment.now())
    else { return }
    values = next
    if !store.apply(change) { refused = true }
    load()
  }

  private func load() {
    values = SelfEmploymentSettingsForm.read(environment)
    accounts = (try? environment.accounts?.accounts(includeArchived: true)) ?? []
  }
}

/// A value typed into a row of the settings — an amount, a percent — written when Return is
/// pressed or the field is left; what does not read is not written and is said under the field.
struct SettingValueField: View {
  let title: String
  /// What the setting holds now, as the field shows it.
  let shown: String
  let placeholder: String
  let identifier: String
  /// The words under the field when the text was not taken.
  let refusal: String
  /// Writes the text; false — it was not taken.
  let commit: (String) -> Bool
  @State private var draft: String?
  @State private var refused = false
  @FocusState private var focused: Bool

  var body: some View {
    LabeledContent {
      VStack(alignment: .trailing, spacing: 2) {
        TextField(
          text: Binding(get: { draft ?? shown }, set: { draft = $0 }),
          prompt: Text(verbatim: placeholder)
        ) {
          Text(verbatim: title)
        }
        .labelsHidden()
        .multilineTextAlignment(.trailing)
        .frame(width: 140)
        .focused($focused)
        .onSubmit(send)
        .accessibilityIdentifier(identifier)
        if refused {
          Text(verbatim: refusal)
            .appFont(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    } label: {
      Text(verbatim: title)
    }
    .onChange(of: focused) { _, isFocused in
      if !isFocused { send() }
    }
  }

  private func send() {
    guard let text = draft, text != shown else {
      draft = nil
      return
    }
    if commit(text) {
      draft = nil
      refused = false
    } else {
      refused = true
    }
  }
}
