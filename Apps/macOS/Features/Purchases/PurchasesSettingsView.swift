import AppCore
import SwiftUI

/// Settings → «Покупки»: the pause before a big purchase and how big is big, the question
/// «Не пожалели?» and when it is put, and whether a fill-up asks for the mileage. They live in the
/// `settings` table (`PurchaseSettings`), so they travel with the archive, and are written at
/// once; like every setting they are no step of ⌘Z.
struct PurchasesSettingsView: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @State private var values = PurchaseSettings()

  private func t(_ key: String) -> String { PurchasesText.t(key, environment) }

  var body: some View {
    #if os(macOS)
      macLayout
        .task(id: compute.generation) {
          if let stored = try? environment.purchaseSettings?.settings() { values = stored }
        }
    #else
      formLayout
    #endif
  }

  private var formLayout: some View {
    Form {
      Section {
        Toggle(isOn: flag(\.pauseEnabled)) {
          Text(verbatim: t("purchases.settings.pause"))
          Text(verbatim: t("purchases.settings.pauseHint"))
        }
        .accessibilityIdentifier("settings.purchases.pause")
        if values.pauseEnabled {
          Stepper(value: pausePercent, in: 5...100, step: 5) {
            Text(
              verbatim: PurchasesText.f(
                "purchases.settings.pausePercent", environment,
                PurchasesText.percent(values.pausePercent, environment)))
          }
          .accessibilityIdentifier("settings.purchases.pausePercent")
        }
      } header: {
        Text(verbatim: t("purchases.settings.title")).settingsHeaderStyle()
      } footer: {
        Text(verbatim: t("purchases.settings.pauseFooter"))
          .appFont(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Section {
        Toggle(isOn: regretEnabled) {
          Text(verbatim: t("purchases.settings.regret"))
          Text(verbatim: t("purchases.settings.regretHint"))
        }
        .accessibilityIdentifier("settings.purchases.regret")
        if values.regretEnabled {
          Stepper(value: askAfterDays, in: 0...30) {
            Text(
              verbatim: PurchasesText.count(
                "purchases.settings.askAfter", environment, values.regretAskAfterDays))
          }
          .accessibilityIdentifier("settings.purchases.askAfter")
        }
      }
      Section {
        Toggle(isOn: flag(\.fuelAskMileage)) {
          Text(verbatim: t("purchases.settings.mileage"))
          Text(verbatim: t("purchases.settings.mileageHint"))
        }
        .accessibilityIdentifier("settings.purchases.mileage")
      }
    }
    .formStyle(.grouped)
    .task(id: compute.generation) {
      if let stored = try? environment.purchaseSettings?.settings() { values = stored }
    }
  }

  private func flag(_ path: WritableKeyPath<PurchaseSettings, Bool>) -> Binding<Bool> {
    Binding(
      get: { values[keyPath: path] },
      set: { value in save { $0[keyPath: path] = value } })
  }

  /// Turning the question on remembers the day: purchases made before it are never asked about.
  private var regretEnabled: Binding<Bool> {
    Binding(
      get: { values.regretEnabled },
      set: { value in
        let today = environment.today
        save { PurchasesSettingsView.turnRegret(value, in: &$0, today: today) }
      })
  }

  static func turnRegret(_ on: Bool, in settings: inout PurchaseSettings, today: DateOnly) {
    if on && !settings.regretEnabled { settings.regretEnabledOn = today }
    settings.regretEnabled = on
  }

  private var pausePercent: Binding<Int> {
    Binding(get: { values.pausePercent }, set: { value in save { $0.pausePercent = value } })
  }

  private var askAfterDays: Binding<Int> {
    Binding(
      get: { values.regretAskAfterDays }, set: { value in save { $0.regretAskAfterDays = value } })
  }

  private func save(_ change: (inout PurchaseSettings) -> Void) {
    var next = values
    change(&next)
    guard next != values else { return }
    if environment.attempt(
      "purchases.settings", on: environment.purchaseSettings, { try $0.save(next) })
    {
      values = next
    }
  }
}

#if os(macOS)
  /// The Mac's «Покупки» in the design's measures (Figma 61:56468): one card of rows — a switch
  /// with its hint, or a title and the value at the right — and the line of what the threshold
  /// is, 12 under it.
  extension PurchasesSettingsView {
    fileprivate var macLayout: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: SettingsControlMetrics.blockGap) {
          SettingsCard {
            switchRow(
              "purchases.settings.pause", hint: "purchases.settings.pauseHint",
              flag(\.pauseEnabled), id: "pause")
            if values.pauseEnabled {
              SettingsCardRow(
                title: PurchasesText.f(
                  "purchases.settings.pausePercent", environment,
                  PurchasesText.percent(values.pausePercent, environment)),
                compact: true
              ) {
                Stepper("", value: pausePercent, in: 5...100, step: 5).labelsHidden()
                  .accessibilityIdentifier("settings.purchases.pausePercent")
              }
            }
            switchRow(
              "purchases.settings.regret", hint: "purchases.settings.regretHint",
              regretEnabled, id: "regret")
            if values.regretEnabled {
              SettingsCardRow(
                title: PurchasesText.count(
                  "purchases.settings.askAfter", environment, values.regretAskAfterDays),
                compact: true
              ) {
                Stepper("", value: askAfterDays, in: 0...30).labelsHidden()
                  .accessibilityIdentifier("settings.purchases.askAfter")
              }
            }
            switchRow(
              "purchases.settings.mileage", hint: "purchases.settings.mileageHint",
              flag(\.fuelAskMileage), id: "mileage", last: true)
          }
          Text(verbatim: t("purchases.settings.pauseFooter"))
            .appFont(AppFont.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, SettingsChromeMetrics.contentInset)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }

    private func switchRow(
      _ title: String, hint: String, _ isOn: Binding<Bool>, id: String, last: Bool = false
    ) -> some View {
      SettingsCardRow(title: t(title), hint: t(hint), showsDivider: !last, compact: true) {
        Toggle(isOn: isOn) { Text(verbatim: t(title)) }
          .labelsHidden().toggleStyle(.switch)
          .accessibilityIdentifier("settings.purchases.\(id)")
      }
    }
  }
#endif
