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
        Toggle(isOn: flag(\.regretEnabled)) {
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
