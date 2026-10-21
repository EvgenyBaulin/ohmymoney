import AppCore
import SwiftUI

/// The one offer to count the tax of self-employment, asked by the main window after an income
/// in a category named as self-employment (`SelfEmploymentOffer`): «Включить…» goes on to the
/// categories of self-employment (`SelfEmploymentSetupSheet`), «Не сейчас» closes. Either way
/// it is not offered again — «Я самозанятый» stays in «Настройки → Планирование».
struct SelfEmploymentOfferSheet: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dismiss) private var dismiss
  @State private var settingUp = false

  var body: some View {
    if settingUp {
      SelfEmploymentSetupSheet()
    } else {
      VStack(alignment: .leading, spacing: 12) {
        Text(verbatim: t("selfEmployed.offer.title")).appFont(.headline)
        Text(verbatim: t("selfEmployed.offer.text"))
          .fixedSize(horizontal: false, vertical: true)
        Text(verbatim: t("selfEmployed.offer.later"))
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        HStack {
          Spacer()
          Button(t("selfEmployed.offer.notNow")) { dismiss() }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("selfEmployed.offer.notNow")
          Button(t("selfEmployed.offer.enable")) { settingUp = true }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("selfEmployed.offer.enable")
        }
      }
      .padding(20)
      .sheetFrame(width: 440)
    }
  }

  /// The offer is made once: `selfEmployed.offered` is written as it shows. A write the
  /// database refused leaves the offer for the next launch, and the journal says why.
  @discardableResult
  static func markOffered(_ environment: AppEnvironment) -> Bool {
    environment.attempt("selfEmployed.offered", on: environment.settings) {
      try $0.set(SelfEmploymentSettings.offeredKey, to: "1")
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }

  /// Every key of the sheet, so a test finds each in both languages.
  static let keys = [
    "selfEmployed.offer.title", "selfEmployed.offer.text", "selfEmployed.offer.later",
    "selfEmployed.offer.notNow", "selfEmployed.offer.enable",
  ]
}
