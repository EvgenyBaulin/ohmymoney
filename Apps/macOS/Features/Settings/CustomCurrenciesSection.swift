import AppCore
import AppDatabase
import SwiftUI

/// What came of a change of the custom currencies.
enum CustomCurrencyOutcome: Equatable {
  case done
  /// Refused before anything was written; the key, in the Settings table, of why.
  case refused(String)
  /// The database did not take the write.
  case failed
}

/// The changes of the custom currencies the settings make: each is the `PlanningChange` the
/// repository works out, applied through the store — one step of ⌘Z —, and the catalog of the
/// formatter and the entry line read again after it.
@MainActor
struct CustomCurrencyActions {
  let environment: AppEnvironment
  let store: TransactionsStore

  /// A new currency with its first rate, or an edit of one (its code never changes).
  func save(
    _ currency: CustomCurrency, firstRate: (day: DateOnly, rubPerUnit: Decimal)?
  ) -> CustomCurrencyOutcome {
    let outcome = apply { try $0.saving(currency, firstRate: firstRate, at: environment.now()) }
    if outcome == .done {
      AppLog.info(
        "currencies.custom.saved", .db, "a custom currency was written",
        [LogPair("change", .token("save")), LogPair("rate", .flag(firstRate != nil))])
    }
    return outcome
  }

  /// «В архив» and «Вернуть».
  func archive(_ code: CurrencyCode, _ archived: Bool) -> CustomCurrencyOutcome {
    let outcome = apply { try $0.archiving(code, archived: archived, at: environment.now()) }
    if outcome == .done {
      AppLog.info(
        "currencies.custom.saved", .db, "a custom currency went to the archive or came back",
        [LogPair("change", .token(archived ? "archive" : "restore"))])
    }
    return outcome
  }

  /// «Удалить»: only a currency nothing names, with every rate typed for it.
  func delete(_ code: CurrencyCode) -> CustomCurrencyOutcome {
    let outcome = apply { try $0.deleting(code, at: environment.now()) }
    if outcome == .done {
      AppLog.info(
        "currencies.custom.saved", .db, "a custom currency was deleted",
        [LogPair("change", .token("delete"))])
    }
    return outcome
  }

  /// «Выше» / «Ниже»: the currency one place up or down among `all`, in their order.
  func move(_ code: CurrencyCode, by offset: Int, in all: [CustomCurrency]) -> CustomCurrencyOutcome
  {
    guard let order = Self.moved(code, by: offset, in: all.map(\.code)) else { return .done }
    let outcome = apply { try $0.reordering(order, at: environment.now()) }
    if outcome == .done {
      AppLog.info(
        "currencies.custom.saved", .db, "the custom currencies were reordered",
        [LogPair("change", .token("order"))])
    }
    return outcome
  }

  /// «Курс на день…»: the rate of a day, in place of one typed for that day before.
  func saveRate(
    _ code: CurrencyCode, on day: DateOnly, rubPerUnit: Decimal
  )
    -> CustomCurrencyOutcome
  {
    let outcome = apply {
      try $0.savingRate(code, on: day, rubPerUnit: rubPerUnit, at: environment.now())
    }
    if outcome == .done {
      AppLog.info(
        "currencies.rate.saved", .db, "a rate of a custom currency was typed",
        [LogPair("change", .token("save"))])
    }
    return outcome
  }

  /// Takes away the rate typed for the day.
  func removeRate(_ code: CurrencyCode, on day: DateOnly) -> CustomCurrencyOutcome {
    let outcome = apply { try $0.removingRate(code, on: day, at: environment.now()) }
    if outcome == .done {
      AppLog.info(
        "currencies.rate.saved", .db, "a rate of a custom currency was taken away",
        [LogPair("change", .token("remove"))])
    }
    return outcome
  }

  /// The order with `code` moved `offset` places, or `nil` when it cannot move so.
  static func moved(
    _ code: CurrencyCode, by offset: Int, in codes: [CurrencyCode]
  )
    -> [CurrencyCode]?
  {
    guard let index = codes.firstIndex(of: code) else { return nil }
    let target = index + offset
    guard codes.indices.contains(target) else { return nil }
    var order = codes
    order.swapAt(index, target)
    return order
  }

  private func apply(
    _ build: (CurrencyRepository) throws -> PlanningChange
  ) -> CustomCurrencyOutcome {
    guard let repository = environment.currencies else { return .failed }
    let change: PlanningChange
    do {
      change = try build(repository)
    } catch let error as CustomCurrencyWriteError {
      return .refused(CustomCurrencyText.key(of: error))
    } catch {
      return .failed
    }
    guard store.apply(change) else { return .failed }
    environment.refreshCurrencyCatalog()
    environment.refreshVocabulary()
    return .done
  }
}

/// The words of the custom currencies: why one cannot be written, keys of the Settings table.
enum CustomCurrencyText {
  static func key(of refusal: CustomCurrencyRefusal) -> String {
    switch refusal {
    case .notThreeCapitalLetters: "currencies.custom.refusal.code"
    case .isoCode: "currencies.custom.refusal.iso"
    case .alreadyThere: "currencies.custom.refusal.taken"
    case .emptyName: "currencies.custom.refusal.name"
    case .fractionDigits: "currencies.custom.refusal.digits"
    case .symbolOfBankCurrency: "currencies.custom.refusal.bankSymbol"
    case .symbolTaken: "currencies.custom.refusal.symbolTaken"
    case .symbolNotASign: "currencies.custom.refusal.symbolNotASign"
    }
  }

  static func key(of error: CustomCurrencyWriteError) -> String {
    switch error {
    case .refused(let refusal): key(of: refusal)
    case .notThere: "currencies.custom.refusal.notThere"
    case .notCustom: "currencies.custom.refusal.notCustom"
    case .rateNotPositive: "currencies.custom.refusal.rate"
    case .inUse: "currencies.custom.refusal.inUse"
    case .isDefault: "currencies.custom.refusal.default"
    }
  }

  /// Every key a refusal can be said with.
  static let refusalKeys: [String] =
    [
      CustomCurrencyRefusal.notThreeCapitalLetters, .isoCode, .alreadyThere, .emptyName,
      .fractionDigits, .symbolOfBankCurrency, .symbolTaken, .symbolNotASign,
    ].map(key(of:)) + [
      key(of: .notThere(.rub)), key(of: .notCustom(.rub)), key(of: .rateNotPositive),
      key(of: .inUse(.rub)), key(of: .isDefault(.rub)),
    ]
}

/// Settings → Валюты, «Свои валюты»: currencies the Bank of Russia does not publish — a token, a
/// game's points — each with a code of three capital Latin letters that is no ISO code, a name,
/// a symbol, digits after the point, and rates typed by hand with their history. The ones in
/// the archive are read and not offered; one nothing names can be deleted. Each change is one
/// step of ⌘Z; every editor is a sheet over the settings.
struct CustomCurrenciesSection: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @State private var currencies: [CustomCurrency] = []
  /// The latest rate of each, for the caption of its row.
  @State private var latest: [CurrencyCode: Rate] = [:]
  @State private var sheet: Sheet?
  /// Why the last change was refused, said under the list.
  @State private var refusal: String?
  @State private var failed = false

  /// `showing` is what the section shows before it reads the database: how a test lays it out
  /// with currencies in it.
  init(showing currencies: [CustomCurrency] = []) {
    _currencies = State(initialValue: currencies)
  }

  enum Sheet: Identifiable {
    case editor(CustomCurrency?)
    case rates(CustomCurrency)

    var id: String {
      switch self {
      case .editor(let currency): "editor.\(currency?.code.code ?? "new")"
      case .rates(let currency): "rates.\(currency.code.code)"
      }
    }
  }

  private var actions: CustomCurrencyActions {
    CustomCurrencyActions(environment: environment, store: store)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Settings") }

  var body: some View {
    Section {
      ForEach(currencies) { currency in
        row(currency)
      }
      if currencies.isEmpty {
        Text(verbatim: t("currencies.custom.empty"))
          .foregroundStyle(.secondary)
      }
      if let refusal {
        Text(verbatim: t(refusal))
          .appFont(.callout)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .onTapGesture { self.refusal = nil }
          .accessibilityIdentifier("currencies.custom.refusal")
      }
      Button(t("currencies.custom.add")) { sheet = .editor(nil) }
        .accessibilityIdentifier("currencies.custom.add")
    } header: {
      Text(verbatim: t("currencies.custom"))
        .settingsHeaderStyle()
    } footer: {
      Text(verbatim: t("currencies.custom.hint"))
        .appFont(.callout)
        .foregroundStyle(.secondary)
    }
    .sheet(item: $sheet, onDismiss: reload) { sheet in
      sheetContent(sheet).handingOver(dependencies)
    }
    .task { reload() }
    .onChange(of: compute.generation) { reload() }
    .refusedWriteAlert($failed, environment)
  }

  private func row(_ currency: CustomCurrency) -> some View {
    HStack(spacing: 8) {
      Image(systemName: currency.archived ? "archivebox" : "dollarsign.circle")
        .foregroundStyle(.secondary)
        .frame(width: 18)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: Self.title(currency))
        Text(verbatim: caption(currency))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Menu {
        menuItems(currency)
      } label: {
        Image(systemName: "ellipsis.circle")
          .accessibilityLabel(
            Text(verbatim: SettingsRowMenu.label(currency.code.code, environment)))
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }
    .contextMenu { menuItems(currency) }
    .accessibilityIdentifier("currencies.custom.row.\(currency.code.code)")
  }

  /// «UST · Tether · ₮».
  static func title(_ currency: CustomCurrency) -> String {
    [currency.code.code, currency.name, currency.symbol].compactMap { $0 }
      .filter { !$0.isEmpty }.joined(separator: " · ")
  }

  /// «1 UST = 95.5 ₽ с 12 октября», «нет курса», and «в архиве».
  private func caption(_ currency: CustomCurrency) -> String {
    var parts: [String] = []
    if let rate = latest[currency.code] {
      parts.append(
        environment.format(
          "currencies.custom.rateFrom", table: "Settings", currency.code.code,
          environment.money.rate(rate.rubPerUnit / Decimal(max(rate.nominal, 1))),
          environment.dates.longDay(rate.date)))
    } else {
      parts.append(t("currencies.custom.noRate"))
    }
    if currency.archived { parts.append(t("currencies.custom.archived")) }
    return parts.joined(separator: " · ")
  }

  @ViewBuilder
  private func menuItems(_ currency: CustomCurrency) -> some View {
    Button(environment.language("action.edit")) { sheet = .editor(currency) }
    Button(t("currencies.custom.rates")) { sheet = .rates(currency) }
    Divider()
    let index = currencies.firstIndex { $0.code == currency.code }
    Button(t("currencies.custom.moveUp")) {
      perform(actions.move(currency.code, by: -1, in: currencies))
    }
    .disabled(index.map { $0 == 0 } ?? true)
    Button(t("currencies.custom.moveDown")) {
      perform(actions.move(currency.code, by: 1, in: currencies))
    }
    .disabled(index.map { $0 == currencies.count - 1 } ?? true)
    Divider()
    if currency.archived {
      Button(t("currencies.custom.restore")) { perform(actions.archive(currency.code, false)) }
    } else {
      Button(t("currencies.custom.archive")) { perform(actions.archive(currency.code, true)) }
    }
    Button(t("currencies.custom.delete"), role: .destructive) {
      perform(actions.delete(currency.code))
    }
  }

  @ViewBuilder
  private func sheetContent(_ sheet: Sheet) -> some View {
    switch sheet {
    case .editor(let currency):
      CustomCurrencyEditor(previous: currency, existing: currencies) { saved in
        if saved { self.sheet = nil }
      }
    case .rates(let currency):
      CustomCurrencyRatesSheet(currency: currency)
    }
  }

  private func perform(_ outcome: CustomCurrencyOutcome) {
    switch outcome {
    case .done: refusal = nil
    case .refused(let key): refusal = key
    case .failed: failed = true
    }
    reload()
  }

  private func reload() {
    currencies = (try? environment.currencies?.customCurrencies()) ?? []
    var rates: [CurrencyCode: Rate] = [:]
    for currency in currencies {
      if let first = (try? environment.currencies?.rates(of: currency.code))?.first {
        rates[currency.code] = first
      }
    }
    latest = rates
  }
}

/// «Добавить валюту…» and «Изменить»: the code (only of a new one), the name, the symbol, the
/// digits after the point and — for a new one — its first rate from a day on. What cannot be
/// written is said under the field while it is typed, and «Сохранить» waits.
struct CustomCurrencyEditor: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Environment(\.dismiss) private var dismiss
  let previous: CustomCurrency?
  let existing: [CustomCurrency]
  let done: (Bool) -> Void
  @State private var code: String
  @State private var name: String
  @State private var symbol: String
  @State private var digits: Int
  @State private var rateText = ""
  @State private var rateDay = Date()
  @State private var refusal: String?
  @State private var failed = false

  init(previous: CustomCurrency?, existing: [CustomCurrency], done: @escaping (Bool) -> Void) {
    self.previous = previous
    self.existing = existing
    self.done = done
    _code = State(initialValue: previous?.code.code ?? "")
    _name = State(initialValue: previous?.name ?? "")
    _symbol = State(initialValue: previous?.symbol ?? "")
    _digits = State(initialValue: previous?.fractionDigits ?? 2)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Settings") }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t(previous == nil ? "currencies.custom.new" : "currencies.custom.edit"))
        .appFont(.headline)
      Form {
        TextField(text: $code, prompt: Text(verbatim: "UST")) {
          Text(verbatim: t("currencies.custom.code"))
        }
        .disabled(previous != nil)
        .accessibilityIdentifier("currencies.custom.code")
        TextField(text: $name, prompt: Text(verbatim: "Tether")) {
          Text(verbatim: t("currencies.custom.name"))
        }
        .accessibilityIdentifier("currencies.custom.name")
        TextField(text: $symbol, prompt: Text(verbatim: "₮")) {
          Text(verbatim: t("currencies.custom.symbol"))
        }
        .accessibilityIdentifier("currencies.custom.symbol")
        Stepper(value: $digits, in: CustomCurrency.fractionDigitsRange) {
          Text(
            verbatim: environment.format(
              "currencies.custom.digits", table: "Settings", counts: digits))
        }
        .accessibilityIdentifier("currencies.custom.digits")
        if previous == nil {
          Section {
            TextField(text: $rateText, prompt: Text(verbatim: "95.5")) {
              Text(verbatim: t("currencies.custom.firstRate"))
            }
            .accessibilityIdentifier("currencies.custom.firstRate")
            DatePicker(selection: $rateDay, displayedComponents: .date) {
              Text(verbatim: t("currencies.custom.rateDay"))
            }
          } footer: {
            Text(verbatim: t("currencies.custom.firstRateHint"))
              .foregroundStyle(.secondary)
          }
        }
      }
      .formStyle(.grouped)
      if let key = live ?? refusal {
        Text(verbatim: t(key))
          .appFont(.callout)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("currencies.custom.editorRefusal")
      }
      HStack {
        Spacer()
        Button(environment.language("action.cancel")) {
          done(false)
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        Button(environment.language("action.save"), action: save)
          .keyboardShortcut(.defaultAction)
          .disabled(live != nil)
      }
    }
    .padding(20)
    .sheetFrame(width: 440)
    .refusedWriteAlert($failed, environment)
  }

  /// The currency as typed.
  private var draft: CustomCurrency {
    var currency =
      previous
      ?? CustomCurrency(code: CurrencyCode(code.trimmingCharacters(in: .whitespaces)), name: "")
    currency.name = name
    currency.symbol = symbol.trimmingCharacters(in: .whitespaces).isEmpty ? nil : symbol
    currency.fractionDigits = digits
    return currency
  }

  /// Why what is typed cannot be written, checked on the fly; `nil` — it can.
  private var live: String? {
    Self.refusal(
      code: code, name: name, symbol: symbol, digits: digits, rateText: rateText,
      previous: previous, existing: existing)
  }

  /// The key of why a currency typed so cannot be written, or `nil`. The code as typed («usd» is
  /// not three capital letters), then the rest of the currency, then the first rate, which may
  /// be left empty — a currency without a rate has none until one is typed.
  static func refusal(
    code: String, name: String, symbol: String, digits: Int, rateText: String,
    previous: CustomCurrency?, existing: [CustomCurrency]
  ) -> String? {
    if previous == nil,
      let refusal = CurrencyCatalog.refusal(newCode: code, existing: existing)
    {
      return CustomCurrencyText.key(of: refusal)
    }
    var currency =
      previous
      ?? CustomCurrency(code: CurrencyCode(code.trimmingCharacters(in: .whitespaces)), name: "")
    currency.name = name
    currency.symbol = symbol.trimmingCharacters(in: .whitespaces).isEmpty ? nil : symbol
    currency.fractionDigits = digits
    if let refusal = CurrencyCatalog.refusal(for: currency, existing: existing) {
      return CustomCurrencyText.key(of: refusal)
    }
    if previous == nil, !rateText.trimmingCharacters(in: .whitespaces).isEmpty,
      RateText.rate(rateText) == nil
    {
      return CustomCurrencyText.key(of: .rateNotPositive)
    }
    return nil
  }

  private func save() {
    guard live == nil else { return }
    let rate = previous == nil ? RateText.rate(rateText) : nil
    let firstRate = rate.map {
      (day: environment.calendar.day(of: rateDay), rubPerUnit: $0)
    }
    switch CustomCurrencyActions(environment: environment, store: store).save(
      draft, firstRate: firstRate)
    {
    case .done:
      done(true)
      dismiss()
    case .refused(let key): refusal = key
    case .failed: failed = true
    }
  }
}

/// «Курсы…» of a custom currency: the rates typed for it, latest day first, each removable, and
/// «Курс на день…» — rubles for one unit from a day on, in place of one typed for that day.
/// A rate holds from its day until the next one typed; before the first there is none.
struct CustomCurrencyRatesSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Environment(\.dismiss) private var dismiss
  let currency: CustomCurrency
  @State private var rates: [Rate] = []
  @State private var rateText = ""
  @State private var day = Date()
  @State private var refusal: String?
  @State private var failed = false

  private var actions: CustomCurrencyActions {
    CustomCurrencyActions(environment: environment, store: store)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Settings") }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(
        verbatim: environment.format(
          "currencies.custom.ratesTitle", table: "Settings", currency.code.code)
      )
      .appFont(.headline)
      List {
        if rates.isEmpty {
          Text(verbatim: t("currencies.custom.noRate"))
            .foregroundStyle(.secondary)
        }
        ForEach(rates, id: \.date) { rate in
          HStack {
            Text(verbatim: environment.dates.longDay(rate.date))
            Spacer()
            Text(verbatim: environment.money.rate(rate.rubPerUnit / Decimal(max(rate.nominal, 1))))
              .monospacedDigit()
            Button {
              perform(actions.removeRate(currency.code, on: rate.date))
            } label: {
              Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(verbatim: environment.language("action.delete")))
          }
        }
      }
      .frame(minHeight: 160)
      Text(verbatim: t("currencies.custom.rateOnDay"))
        .appFont(.subheadline)
      HStack {
        DatePicker(selection: $day, displayedComponents: .date) { EmptyView() }
          .labelsHidden()
        TextField(text: $rateText, prompt: Text(verbatim: "95.5")) {
          Text(verbatim: t("currencies.custom.rate"))
        }
        .frame(width: 120)
        .onSubmit(addRate)
        .accessibilityIdentifier("currencies.custom.rate")
        Text(verbatim: "₽")
          .foregroundStyle(.secondary)
        Button(t("currencies.custom.rateSave"), action: addRate)
          .disabled(RateText.rate(rateText) == nil)
      }
      Text(verbatim: t(refusal ?? "currencies.custom.ratesHint"))
        .appFont(.callout)
        .foregroundStyle(refusal == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button(environment.language("action.ok")) { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .sheetFrame(width: 440)
    .task { reload() }
    .refusedWriteAlert($failed, environment)
  }

  private func addRate() {
    guard let value = RateText.rate(rateText) else {
      refusal = CustomCurrencyText.key(of: .rateNotPositive)
      return
    }
    perform(
      actions.saveRate(
        currency.code, on: environment.calendar.day(of: day), rubPerUnit: value))
    if refusal == nil { rateText = "" }
  }

  private func perform(_ outcome: CustomCurrencyOutcome) {
    switch outcome {
    case .done: refusal = nil
    case .refused(let key): refusal = key
    case .failed: failed = true
    }
    reload()
  }

  private func reload() {
    rates = (try? environment.currencies?.rates(of: currency.code)) ?? []
  }
}
