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
  /// Every rate in the cache, for the line under each currency.
  @State private var rates: [Rate] = []
  /// The search over countries, codes and names.
  @State private var query = ""
  /// The list shows every currency of the bank, not only the enabled ones.
  @State private var showsAll = false
  @State private var showsCustom = false

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
    #if os(macOS)
      macLayout
    #else
      formLayout
    #endif
  }

  private var formLayout: some View {
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
        TextField(text: $query, prompt: Text(verbatim: t("currencies.search.prompt"))) {
          Text(verbatim: t("currencies.search.prompt"))
        }
        .accessibilityIdentifier("currencies.search")
        ForEach(listed, id: \.code) { currency in
          let row = self.row(currency)
          Toggle(isOn: binding(for: currency)) {
            CurrencyRowLabel(
              row: row, subtitle: subtitle(row), warning: warning(row),
              rate: rateText(row.rate, of: currency), compact: true)
          }
          .toggleStyle(.checkbox)
          .disabled(row.lock != nil || currency == .rub || row.entry.isCustom)
          .help(row.lock.map(tooltip) ?? "")
        }
      } header: {
        Text(verbatim: asOfText)
          .settingsHeaderStyle()
      } footer: {
        Text(verbatim: t("currencies.directory.hint"))
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

  // MARK: What the list says about a currency

  /// One currency of the list: who it is, its rate, and why it cannot be switched off.
  struct Row {
    let entry: CurrencyEntry
    let rate: Rate?
    let lock: Lock?
    let isOn: Bool
    let notPublished: Bool
  }

  private var languageCode: String {
    environment.language.locale.language.languageCode?.identifier ?? "en"
  }

  private var listed: [CurrencyCode] {
    CurrencyDirectory.listed(
      enabled: enabled, offered: offered, catalog: environment.currencyCatalog, query: query,
      showsAll: showsAll, language: languageCode)
  }

  private func row(_ currency: CurrencyCode) -> Row {
    let entry = CurrencyDirectory.entry(
      for: currency, catalog: environment.currencyCatalog, language: languageCode)
    let isOn = entry.isCustom || enabled.contains(currency)
    return Row(
      entry: entry, rate: CurrencyRateInfo.latest(for: currency, in: rates),
      lock: entry.isCustom
        ? nil
        : Self.lock(
          for: currency, isOn: isOn, defaultCurrency: defaultCurrency, accounts: accounts),
      isOn: isOn, notPublished: notPublished.contains(currency))
  }

  /// «Курс к рублю на 3 ноября»: the day of the latest table of the bank in the cache.
  private var asOfText: String {
    guard let table = CurrencyCheck.latestTable(in: rates, notAfter: nil) else {
      return t("currencies.asOf.none")
    }
    return environment.format(
      "currencies.asOf", table: "Settings", environment.dates.dayMonth(table.day))
  }

  /// «Казахстан · ЦБ, 3 ноября», «Своя валюта · свой курс, 1 ноября», «США · нет курса».
  func subtitle(_ row: Row) -> String {
    var parts: [String] = []
    if let country = row.entry.country {
      parts.append(country)
    } else if row.entry.isCustom {
      parts.append(t("currencies.customKind"))
    }
    if row.entry.code == .rub {
      parts.append(t("currencies.baseCaption"))
    } else if let rate = row.rate {
      let source: String =
        switch CurrencyRateInfo.origin(of: rate.source) {
        case .bank: t("currencies.source.bank")
        case .network: t("currencies.source.network")
        case .manual: t("currencies.source.manual")
        case .imported: t("currencies.source.imported")
        }
      parts.append("\(source), \(environment.dates.dayMonth(rate.date))")
    } else {
      parts.append(t("currencies.custom.noRate"))
    }
    if let lock = row.lock, let caption = caption(lock) { parts.append(caption) }
    return parts.joined(separator: " · ")
  }

  private func warning(_ row: Row) -> String? {
    row.notPublished ? t("currencies.notAtCBR") : nil
  }

  /// «94,20 ₽»: the rate of one unit; more digits the smaller it is.
  private func rateText(_ rate: Rate?, of currency: CurrencyCode) -> String {
    if currency == .rub { return environment.money.symbol(for: .rub) }
    guard let rate else { return "—" }
    return Self.rateText(rate, money: environment.money)
  }

  static func rateText(_ rate: Rate, money: MoneyFormatter) -> String {
    let perUnit = rate.perUnit
    let digits: ClosedRange<Int> =
      perUnit >= 1000
      ? 0...0 : perUnit >= 1 ? 2...2 : perUnit >= Decimal(string: "0.01")! ? 2...4 : 4...6
    return "\(money.number(perUnit, fractionDigits: digits)) ₽"
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
    rates = (try? environment.rates?.allRates()) ?? []
    notPublished = Set(
      CurrencyCheck.notPublished(offered, in: rates))
  }

  #if os(macOS)
    @Environment(\.themeSurfaces) private var surfaces
    @Environment(\.dependencies) private var dependencies

    /// The section as the design draws it (Figma «Содержимое / Валюты», 68:16050): the day of
    /// the table, the search, a card of rows — flag in a 32-point tile, name over «country ·
    /// source, day», the rate at the right —, a hint and the button of the own currencies. The
    /// default currency and the switches, which the frame leaves out, stand in the rows and in
    /// a card of their own under the list.
    fileprivate var macLayout: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          Text(verbatim: asOfText)
            .appFont(AppFont.system(size: 13))
            .foregroundStyle(surfaces.secondary)
            .padding(.top, CurrenciesMetrics.asOfTop)
          searchField
            .padding(.top, CurrenciesMetrics.searchTop)
          listCard
            .padding(.top, CurrenciesMetrics.listTop)
          SettingsCard {
            SettingsCardRow(
              title: t("settings.currencies.default"),
              hint: t("settings.currencies.defaultHint"), showsDivider: false
            ) {
              Picker(selection: defaultBinding) {
                ForEach(environment.currencyCatalog.choices(enabled: enabled), id: \.code) {
                  currency in
                  Text(verbatim: "\(currency.code)  \(environment.money.symbol(for: currency))")
                    .tag(currency)
                }
              } label: {
                Text(verbatim: t("settings.currencies.default"))
              }
              .labelsHidden()
              .fixedSize()
              .accessibilityIdentifier("currencies.default")
            }
          }
          .padding(.top, CurrenciesMetrics.listTop)
          Text(verbatim: t("currencies.directory.hint"))
            .appFont(AppFont.system(size: 12))
            .foregroundStyle(surfaces.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, CurrenciesMetrics.hintTop)
          HStack(spacing: 10) {
            Button(t("currencies.custom.manage")) { showsCustom = true }
              .buttonStyle(SettingsActionButtonStyle())
              .accessibilityIdentifier("currencies.custom.manage")
            Button(t(showsAll ? "currencies.showEnabled" : "currencies.showAll")) {
              showsAll.toggle()
            }
            .buttonStyle(SettingsActionButtonStyle())
            .accessibilityIdentifier("currencies.showAll")
          }
          .padding(.top, CurrenciesMetrics.buttonTop)
        }
        .padding(.horizontal, SettingsChromeMetrics.contentInset)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .onAppear(perform: reload)
      .refusedWriteAlert($refused, environment)
      .sheet(isPresented: $showsCustom, onDismiss: reload) {
        CustomCurrenciesSheet { showsCustom = false }.handingOver(dependencies)
      }
    }

    private var searchField: some View {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 12))  // font-fixed: 14 pt symbol of the field
          .foregroundStyle(surfaces.secondary)
          .frame(width: 14, height: 14)
          .accessibilityHidden(true)
        TextField(text: $query, prompt: Text(verbatim: t("currencies.search.prompt"))) {
          Text(verbatim: t("currencies.search.prompt"))
        }
        .labelsHidden()
        .textFieldStyle(.plain)
        .appFont(.callout)
        .accessibilityIdentifier("currencies.search")
      }
      .padding(.horizontal, CurrenciesMetrics.searchHorizontal)
      .frame(height: CurrenciesMetrics.searchHeight)
      .background(surfaces.card, in: .rect(cornerRadius: CurrenciesMetrics.searchRadius))
      .overlay(
        RoundedRectangle(cornerRadius: CurrenciesMetrics.searchRadius)
          .strokeBorder(surfaces.cardBorder, lineWidth: SettingsCardMetrics.hairline))
    }

    @ViewBuilder
    private var listCard: some View {
      let codes = listed
      if codes.isEmpty {
        SettingsCard {
          Text(verbatim: t("currencies.search.none"))
            .appFont(AppFont.system(size: 13))
            .foregroundStyle(surfaces.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SettingsCardMetrics.rowHorizontal)
        }
      } else {
        SettingsCard {
          ForEach(Array(codes.enumerated()), id: \.element.code) { index, currency in
            macRow(currency, isLast: index == codes.count - 1)
          }
        }
      }
    }

    private func macRow(_ currency: CurrencyCode, isLast: Bool) -> some View {
      let row = self.row(currency)
      return VStack(spacing: 0) {
        HStack(spacing: CurrenciesMetrics.rowGap) {
          CurrencyRowLabel(
            row: row, subtitle: subtitle(row), warning: warning(row),
            rate: rateText(row.rate, of: currency), compact: false)
          Toggle(isOn: binding(for: currency)) { Text(verbatim: currency.code) }
            .labelsHidden().toggleStyle(.switch)
            .disabled(row.lock != nil || currency == .rub || row.entry.isCustom)
            .help(row.lock.map(tooltip) ?? "")
            .frame(width: SettingsCardMetrics.compactSwitchWidth)
            .accessibilityLabel(
              Text(verbatim: "\(currency.code), \(row.entry.name), \(subtitle(row))")
            )
            .accessibilityIdentifier("currencies.toggle.\(currency.code)")
        }
        .padding(.horizontal, CurrenciesMetrics.rowHorizontal)
        .padding(.vertical, CurrenciesMetrics.rowVertical)
        if !isLast {
          Rectangle().fill(surfaces.cardBorder.opacity(0.6))
            .frame(height: SettingsCardMetrics.hairline)
        }
      }
      .accessibilityIdentifier("currencies.row.\(currency.code)")
    }
  #endif
}

/// The measures of the list of currencies, as the design draws them (Figma 68:16050): the day
/// 12 under the title, the search 30 tall rounded 8 with 10 at the sides, the rows 48 tall
/// with a 32-point tile and 10 to the text.
enum CurrenciesMetrics {
  static let asOfTop: CGFloat = 0
  static let searchTop: CGFloat = 12
  static let searchHeight: CGFloat = 30
  static let searchRadius: CGFloat = 8
  static let searchHorizontal: CGFloat = 10
  static let listTop: CGFloat = 12
  static let hintTop: CGFloat = 12
  static let buttonTop: CGFloat = 12
  static let rowHorizontal: CGFloat = 15
  static let rowVertical: CGFloat = 8
  static let rowGap: CGFloat = 10
  static let tile: CGFloat = 32
  static let tileRadius: CGFloat = 8
  static let flagSize: CGFloat = 20
  static let titleSize: CGFloat = 13
  static let subtitleSize: CGFloat = 11
  static let textGap: CGFloat = 1
}

/// The left of a row: the country's flag (or the sign of an own currency) in a tile, the full
/// name over «country · source, day», and the rate at the right.
struct CurrencyRowLabel: View {
  @Environment(\.themeSurfaces) private var surfaces
  let row: CurrenciesSettingsView.Row
  let subtitle: String
  let warning: String?
  let rate: String
  /// A row of a form (iPhone, iPad): no tile fill.
  let compact: Bool

  var body: some View {
    HStack(spacing: CurrenciesMetrics.rowGap) {
      tile
      VStack(alignment: .leading, spacing: CurrenciesMetrics.textGap) {
        Text(verbatim: row.entry.name)
          .appFont(AppFont.system(size: 14, weight: .medium))
          .foregroundStyle(surfaces.primary)
          .lineLimit(1)
        Text(verbatim: subtitle)
          .appFont(AppFont.system(size: CurrenciesMetrics.subtitleSize))
          .foregroundStyle(surfaces.secondary)
          .lineLimit(1)
        if let warning {
          Label {
            Text(verbatim: warning)
          } icon: {
            Image(systemName: "exclamationmark.triangle")
          }
          .appFont(AppFont.system(size: CurrenciesMetrics.subtitleSize))
          .foregroundStyle(.orange)
        }
      }
      Spacer(minLength: 8)
      Text(verbatim: rate)
        .appFont(AppFont.system(size: 14, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(surfaces.primary)
        .lineLimit(1)
    }
    .accessibilityElement(children: .combine)
  }

  private var tile: some View {
    ZStack {
      RoundedRectangle(cornerRadius: CurrenciesMetrics.tileRadius)
        .fill(compact ? Color.clear : surfaces.background)
      if let flag = row.entry.flag {
        // A flag is an emoji, drawn by the system at its own colours.
        Text(verbatim: flag)
          .font(.system(size: CurrenciesMetrics.flagSize))  // font-fixed: emoji flag in a tile
      } else {
        Text(verbatim: row.entry.badge)
          .appFont(AppFont.system(size: 15, weight: .medium))
          .foregroundStyle(surfaces.secondary)
      }
    }
    .frame(width: CurrenciesMetrics.tile, height: CurrenciesMetrics.tile)
    .accessibilityHidden(true)
  }
}

#if os(macOS)
  /// «Свои валюты…»: the own currencies — a coin, points — with their rates, in a sheet over the
  /// settings.
  struct CustomCurrenciesSheet: View {
    @Dependency(\.environment) private var environment
    let done: () -> Void

    var body: some View {
      VStack(spacing: 0) {
        Form { CustomCurrenciesSection() }
          .formStyle(.grouped)
        HStack {
          Spacer()
          Button(environment.language("action.close"), action: done)
            .keyboardShortcut(.defaultAction)
        }
        .padding(12)
      }
      .sheetFrame(width: 520)
    }
  }
#endif
