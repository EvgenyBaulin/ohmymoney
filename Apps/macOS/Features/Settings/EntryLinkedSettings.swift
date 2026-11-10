import AppCore
import SwiftUI

/// The rows of «Ввод» that speak of what is kept elsewhere: «Основной счёт» and «Валюта по
/// умолчанию» show the value of their own sections and lead there — one place keeps each, so
/// the entry never has a main account of its own — and «Карта или счёт», what the first
/// purchase at a new place is made with.
struct EntryLinkedSettings: View {
  @Dependency(\.environment) private var environment
  /// Handed over to the section pushed on an iPhone and an iPad: a pushed view does not take the
  /// dependencies of the one it came from.
  @Environment(\.dependencies) private var dependencies

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      link(
        "settings.entry.mainAccount", value: EntryLinks.mainAccountName(environment) ?? "—",
        to: .accounts)
      link(
        "settings.entry.defaultCurrency", value: EntryLinks.currencyName(environment),
        to: .currencies)
      Picker(
        selection: Binding(
          get: { environment.entryFirstPurchase }, set: { environment.entryFirstPurchase = $0 })
      ) {
        Text(verbatim: t("settings.entry.firstPurchase.card")).tag(FirstPurchasePayment.card)
        Text(verbatim: t("settings.entry.firstPurchase.account")).tag(FirstPurchasePayment.account)
      } label: {
        Text(verbatim: t("settings.entry.firstPurchase"))
      }
      .pickerStyle(.menu)
      .fixedSize()
      .accessibilityIdentifier("settings.entry.firstPurchase")
      Text(verbatim: t("settings.entry.firstPurchaseHint"))
        .appFont(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// A row with the value kept in another section and the way there: on the Mac the section of
  /// the same window, on the iPhone and the iPad the section pushed over this one.
  @ViewBuilder
  private func link(_ key: String, value: String, to section: SettingsSection) -> some View {
    #if os(macOS)
      Button {
        EntryLinks.open(section)
      } label: {
        row(key, value: value)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("\(key).link")
    #else
      NavigationLink {
        PhoneSettingsList.section(section)
          .navigationTitle(environment.language(section.titleKey, table: "Settings"))
          .handingOver(dependencies)
      } label: {
        row(key, value: value)
      }
      .accessibilityIdentifier("\(key).link")
    #endif
  }

  private func row(_ key: String, value: String) -> some View {
    HStack(spacing: 6) {
      Text(verbatim: t(key))
      Spacer(minLength: 8)
      Text(verbatim: value)
        .fontWeight(.medium)
        .foregroundStyle(.tint)
      Image(systemName: "chevron.right")
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
    .contentShape(.rect)
    .accessibilityElement(children: .combine)
  }

  private func t(_ key: String) -> String { environment.language(key, table: EntryLinks.table) }
}

/// What the rows of `EntryLinkedSettings` read and do, apart from the view so a test reads it.
@MainActor
enum EntryLinks {
  static let table = "SettingsAccounts"

  /// The name of the main account, read from where the accounts are kept.
  static func mainAccountName(_ environment: AppEnvironment) -> String? {
    let accounts = (try? environment.accounts?.accounts(includeArchived: false)) ?? []
    return accounts.first { $0.isDefault && !$0.archived }?.name
  }

  /// The default currency by its name in the interface language, else its code.
  static func currencyName(_ environment: AppEnvironment) -> String {
    let code = environment.defaultCurrency
    let language = environment.language.locale.language.languageCode?.identifier ?? "ru"
    if let name = environment.currencyCatalog.name(code, language: language) { return name }
    guard let name = environment.language.locale.localizedString(forCurrencyCode: code.code)
    else { return code.code }
    return name.prefix(1).uppercased() + name.dropFirst()
  }

  /// The section a link leads to, shown in the settings window.
  static func open(_ section: SettingsSection) {
    SettingsNavigation.shared.query = ""
    SettingsNavigation.shared.section = section
  }
}
