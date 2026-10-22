import AppCore
import AppDatabase
import SwiftUI

struct CurrenciesSettingsView: View {
  @Dependency(\.environment) private var environment
  @State private var enabled: [CurrencyCode] = []
  /// The currency of everything new (`currencies.default`).
  @State private var defaultCurrency: CurrencyCode = .rub
  /// The live accounts, for the currencies they hold.
  @State private var accounts: [PaymentMethod] = []
  /// What the latest table of the bank in the cache lacks (`CurrencyCheck`); empty while the
  /// cache holds none — the check of the first launch fills it.
  @State private var notPublished: Set<CurrencyCode> = []
  /// A write the database refused; the alert says so (`AppEnvironment.attempt`).
  @State private var refused = false

  /// The currencies of the bank a checkbox is offered for: everything the Bank of Russia
  /// publishes, plus the ruble — the ones on a fresh install first — and any other code of the
  /// bank switched on elsewhere. As many as the owner likes can be on.
  private var offered: [CurrencyCode] {
    Self.offered(enabled: enabled, catalog: environment.currencyCatalog)
  }

  /// The codes the Bank of Russia publishes in its daily table besides the ten of a fresh
  /// install, the usual ones first.
  static let published: [CurrencyCode] = [
    "GBP", "JPY", "CHF", "PLN", "UAH", "BYN", "KGS", "UZS", "AZN", "RSD", "AUD", "DZD", "BHD",
    "BGN", "BOB", "BRL", "HUF", "VND", "HKD", "DKK", "EGP", "INR", "IDR", "IRR", "CAD", "QAR",
    "CUP", "MDL", "MNT", "NGN", "NZD", "NOK", "OMR", "SAR", "RON", "XDR", "SGD", "TJS", "BDT",
    "TMT", "CZK", "SEK", "ETB", "ZAR", "KRW", "MMK",
  ].map(CurrencyCode.init)

  /// What the checkboxes offer: the currencies of a fresh install, the others the bank
  /// publishes, then any code of the bank switched on that is in neither list. A custom
  /// currency is never a checkbox: it has a section of its own.
  static func offered(enabled: [CurrencyCode], catalog: CurrencyCatalog) -> [CurrencyCode] {
    var seen = Set<CurrencyCode>()
    var all: [CurrencyCode] = []
    for code in CurrencyCode.defaultEnabled + published + enabled
    where !catalog.isCustom(code) && seen.insert(code).inserted {
      all.append(code)
    }
    return all
  }

  /// Why a currency that is on stays on.
  enum Lock: Equatable {
    /// The ruble: every total, limit and report is in it.
    case base
    /// The currency of everything new.
    case defaultCurrency
    /// Live accounts hold it, named here.
    case held([String])
  }

  /// Why `currency` cannot be switched off, or nil when it can. A currency that is off has
  /// nothing to lose, the ruble aside, which is always on.
  static func lock(
    for currency: CurrencyCode, isOn: Bool, defaultCurrency: CurrencyCode,
    accounts: [PaymentMethod]
  ) -> Lock? {
    if currency == .rub { return .base }
    guard isOn else { return nil }
    if currency == defaultCurrency { return .defaultCurrency }
    let holders = accounts.filter { !$0.archived && $0.holds(currency) }.map(\.name)
    return holders.isEmpty ? nil : .held(holders)
  }

  var body: some View {
    Form {
      Section {
        Picker(selection: defaultBinding) {
          ForEach(environment.currencyCatalog.choices(enabled: enabled), id: \.code) { currency in
            Text(verbatim: "\(currency.code)  \(environment.money.symbol(for: currency))")
              .tag(currency)
          }
        } label: {
          Text(verbatim: t("settings.currencies.default"))
        }
      } footer: {
        Text(verbatim: t("settings.currencies.defaultHint"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }

      Section {
        ForEach(offered, id: \.code) { currency in
          let lock = Self.lock(
            for: currency, isOn: enabled.contains(currency), defaultCurrency: defaultCurrency,
            accounts: accounts)
          Toggle(isOn: binding(for: currency)) {
            HStack(spacing: 8) {
              Text(verbatim: currency.code)
              Text(verbatim: environment.money.symbol(for: currency))
                .appFont(.callout)
                .foregroundStyle(.secondary)
              if let lock, let caption = caption(lock) {
                Label {
                  Text(verbatim: caption)
                } icon: {
                  Image(systemName: "lock")
                }
                .appFont(.callout)
                .foregroundStyle(.secondary)
              }
              if notPublished.contains(currency) {
                // The daily table of the bank does not carry this currency, so an
                // operation in it will have to use a rate typed by hand.
                Label {
                  Text(verbatim: t("currencies.notAtCBR"))
                } icon: {
                  Image(systemName: "exclamationmark.triangle")
                }
                .appFont(.callout)
                .foregroundStyle(.orange)
              }
            }
          }
          .toggleStyle(.checkbox)
          .disabled(lock != nil)
          .help(lock.map(tooltip) ?? "")
        }
      } header: {
        Text(verbatim: t("settings.currencies.enabled"))
          .settingsHeaderStyle()
      } footer: {
        Text(
          verbatim: environment.format(
            "settings.currencies.countOn", table: "Settings",
            counts: enabled.filter { !environment.currencyCatalog.isCustom($0) }.count)
        )
        .appFont(.callout)
        .foregroundStyle(.secondary)
      }

      CustomCurrenciesSection()
    }
    .formStyle(.grouped)
    .padding()
    .onAppear(perform: reload)
    .refusedWriteAlert($refused, environment)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Settings") }

  /// The word beside a locked currency: the tooltip says the rest. The ruble needs none.
  private func caption(_ lock: Lock) -> String? {
    switch lock {
    case .base: nil
    case .defaultCurrency: t("currencies.caption.default")
    case .held(let names) where names.count == 1:
      environment.format("currencies.caption.heldOne", table: "Settings", names[0])
    case .held(let names):
      environment.format(
        "currencies.caption.heldMany", table: "Settings", names.joined(separator: ", "))
    }
  }

  private func tooltip(_ lock: Lock) -> String {
    switch lock {
    case .base: t("currencies.lock.base")
    case .defaultCurrency: t("currencies.lock.default")
    case .held: t("currencies.lock.held")
    }
  }

  /// A new default is one of the enabled currencies.
  private var defaultBinding: Binding<CurrencyCode> {
    Binding(
      get: { defaultCurrency },
      set: { currency in
        guard currency != defaultCurrency else { return }
        if !Self.chooseDefault(currency, in: environment) { refused = true }
        reload()
      })
  }

  private func binding(for currency: CurrencyCode) -> Binding<Bool> {
    Binding(
      get: { enabled.contains(currency) },
      set: { isOn in
        if !Self.switchCurrency(currency, on: isOn, enabled: enabled, in: environment) {
          refused = true
        }
        reload()
      })
  }

  /// Makes `currency` the currency of everything new. The window reads the account settings
  /// again at once, so the next thing made takes it. False when the database refused.
  static func chooseDefault(_ currency: CurrencyCode, in environment: AppEnvironment) -> Bool {
    let written = environment.attempt(
      "currencies.default", on: environment.settings, { try $0.setDefaultCurrency(currency) })
    environment.refreshAccountSettings()
    environment.refreshVocabulary()
    return written
  }

  /// Switches `currency` on — last — or off; there is no limit to how many are on. The ruble always
  /// stays; the default currency and a currency a live account holds stay too: the database
  /// refuses to drop them (`SettingsWriteError.currencyInUse`), whatever the checkbox did. True
  /// when there was nothing to do or the write landed.
  static func switchCurrency(
    _ currency: CurrencyCode, on isOn: Bool, enabled: [CurrencyCode],
    in environment: AppEnvironment
  ) -> Bool {
    var updated = enabled.filter { $0 != currency }
    if isOn {
      updated.append(currency)
    }
    // The ruble is the base currency and cannot be switched off.
    if !updated.contains(.rub) {
      updated.insert(.rub, at: 0)
    }
    let written = environment.attempt(
      "settings.currencies", on: environment.settings, { try $0.setEnabledCurrencies(updated) })
    environment.refreshAccountSettings()
    environment.refreshVocabulary()
    return written
  }

  private func reload() {
    enabled = (try? environment.settings?.enabledCurrencies()) ?? CurrencyCode.defaultEnabled
    defaultCurrency = environment.defaultCurrency
    accounts = (try? environment.accounts?.accounts()) ?? []
    notPublished = Set(
      CurrencyCheck.notPublished(offered, in: (try? environment.rates?.allRates()) ?? []))
  }
}
