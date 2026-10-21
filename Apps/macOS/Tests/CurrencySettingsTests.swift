import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Settings → Валюты: «Валюта по умолчанию», the currency of everything new, and the currencies
/// that cannot be switched off — the ruble, the default one and the ones live accounts hold.
/// (The list itself — no limit, the ruble always on — is `CurrencySettingsTests`.)
@MainActor
final class DefaultCurrencySettingsTests: XCTestCase {
  private var environment: AppEnvironment!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  private let kzt = CurrencyCode("KZT")
  private let eur = CurrencyCode("EUR")

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-currencies-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
  }

  override func tearDown() async throws {
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private var settings: SettingsRepository { environment.settings! }

  private func enabled() throws -> [CurrencyCode] { try settings.enabledCurrencies() }

  // MARK: The default currency

  /// A new default is written to the database, switched on, and read by the window at once:
  /// the next thing made is in it. Rubles until one is chosen.
  func testTheDefaultCurrencyIsWrittenAndTakenAtOnce() throws {
    XCTAssertEqual(environment.defaultCurrency, .rub)
    XCTAssertTrue(
      CurrenciesSettingsView.switchCurrency(kzt, on: false, enabled: try enabled(), in: environment)
    )
    XCTAssertFalse(try enabled().contains(kzt))

    XCTAssertTrue(CurrenciesSettingsView.chooseDefault(kzt, in: environment))
    XCTAssertEqual(try settings.defaultCurrency(), kzt, "kept in the database, with the archive")
    XCTAssertEqual(environment.defaultCurrency, kzt, "the window still makes things in rubles")
    XCTAssertTrue(try enabled().contains(kzt), "the default currency is on")
  }

  /// The default currency cannot be switched off, neither by the checkbox — it is grey, with a
  /// lock and a tooltip — nor by a write that tries: the database refuses and nothing changes.
  func testTheDefaultCurrencyCannotBeSwitchedOff() throws {
    XCTAssertTrue(CurrenciesSettingsView.chooseDefault(kzt, in: environment))
    XCTAssertEqual(
      CurrenciesSettingsView.lock(
        for: kzt, isOn: true, defaultCurrency: kzt, accounts: []),
      .defaultCurrency)

    let before = try enabled()
    XCTAssertFalse(
      CurrenciesSettingsView.switchCurrency(kzt, on: false, enabled: before, in: environment))
    XCTAssertEqual(try enabled(), before)
    XCTAssertEqual(environment.defaultCurrency, kzt)
  }

  /// A currency a live account holds stays on and names the account; once the account is in
  /// the archive, the currency can go.
  func testACurrencyALiveAccountHoldsStaysOn() throws {
    let references = try XCTUnwrap(environment.references)
    XCTAssertTrue(
      CurrenciesSettingsView.switchCurrency(eur, on: true, enabled: try enabled(), in: environment))
    var freedom = PaymentMethod(
      name: "Freedom", currency: kzt, isDefault: true, otherCurrencies: [eur])
    XCTAssertTrue(CurrenciesSettingsView.chooseDefault(kzt, in: environment))
    try references.save(freedom)
    XCTAssertTrue(CurrenciesSettingsView.chooseDefault(.rub, in: environment))

    XCTAssertEqual(
      CurrenciesSettingsView.lock(
        for: eur, isOn: true, defaultCurrency: .rub, accounts: [freedom]),
      .held(["Freedom"]))
    XCTAssertFalse(
      CurrenciesSettingsView.switchCurrency(eur, on: false, enabled: try enabled(), in: environment)
    )
    XCTAssertTrue(try enabled().contains(eur))

    try references.save(PaymentMethod(name: "Сбер", isDefault: true))
    freedom.isDefault = false
    freedom.archived = true
    try references.save(freedom)
    XCTAssertNil(
      CurrenciesSettingsView.lock(for: eur, isOn: true, defaultCurrency: .rub, accounts: [freedom]),
      "an archived account holds nothing on")
    XCTAssertTrue(
      CurrenciesSettingsView.switchCurrency(eur, on: false, enabled: try enabled(), in: environment)
    )
    XCTAssertFalse(try enabled().contains(eur))
  }

  /// An account brought back from the archive by «Добавить…» of the ↓ panel holds its
  /// currencies again, so they are switched on with it — and locked — as every live account's
  /// are: the entry line knows them and the bank's table is checked for them. When that would
  /// make more than ten, the account stays in the archive and the sheet says why.
  func testAnAccountBroughtBackFromThePanelSwitchesItsCurrenciesOn() throws {
    let references = try XCTUnwrap(environment.references)
    let store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
    try references.save(PaymentMethod(name: "Сбер", isDefault: true))
    let freedom = PaymentMethod(name: "Freedom", currency: eur, archived: true)
    try references.save(freedom)
    XCTAssertTrue(
      CurrenciesSettingsView.switchCurrency(eur, on: false, enabled: try enabled(), in: environment)
    )
    XCTAssertFalse(try enabled().contains(eur))

    let model = EntryDraftModel(
      references: references, transactions: environment.transactions, calendar: .utc)
    model.reload()
    var sheet = NewRecordForm(kind: .paymentMethod, model: model, today: environment.today)
    sheet.name = "freedom"
    XCTAssertNil(
      sheet.commit(
        into: model, today: environment.today, context: .app(environment, store: store)))
    XCTAssertEqual(model.draft.paymentMethodId, freedom.id)
    XCTAssertTrue(try enabled().contains(eur), "a live account holds a currency that is off")
    XCTAssertEqual(
      CurrenciesSettingsView.lock(
        for: eur, isOn: true, defaultCurrency: .rub,
        accounts: try XCTUnwrap(environment.accounts).accounts()),
      .held(["Freedom"]))

    let full = ["RUB", "USD", "EUR", "CNY", "KZT", "TRY", "GEL", "AMD", "GBP", "JPY"]
      .map(CurrencyCode.init)
    let kaspi = PaymentMethod(name: "Kaspi", currency: CurrencyCode("UZS"), archived: true)
    try references.save(kaspi)
    try settings.setEnabledCurrencies(full)
    XCTAssertEqual(try enabled().count, 10)
    var another = NewRecordForm(kind: .paymentMethod, model: model, today: environment.today)
    another.name = "Kaspi"
    // There is no limit of ten any more: the account comes back and switches its currency on.
    XCTAssertNil(
      another.commit(
        into: model, today: environment.today, context: .app(environment, store: store)))
    XCTAssertEqual(
      try references.paymentMethods(includeArchived: true).first { $0.id == kaspi.id }?.archived,
      false, "the account came back")
    XCTAssertTrue(try enabled().contains(CurrencyCode("UZS")))
    XCTAssertEqual(try enabled().count, 11)
  }

  /// The ruble is always on; a currency that is off has nothing to keep it; one on that no
  /// account holds and that is not the default can be switched off.
  func testWhatLocksACurrency() {
    let card = PaymentMethod(name: "Карта")
    XCTAssertEqual(
      CurrenciesSettingsView.lock(for: .rub, isOn: true, defaultCurrency: kzt, accounts: [card]),
      .base)
    XCTAssertNil(
      CurrenciesSettingsView.lock(for: kzt, isOn: false, defaultCurrency: .rub, accounts: []))
    XCTAssertNil(
      CurrenciesSettingsView.lock(for: .usd, isOn: true, defaultCurrency: .rub, accounts: [card]))
    XCTAssertEqual(
      CurrenciesSettingsView.lock(
        for: .usd, isOn: true, defaultCurrency: .rub,
        accounts: [
          PaymentMethod(name: "Freedom", otherCurrencies: [.usd]),
          PaymentMethod(name: "Kaspi", currency: .usd),
        ]),
      .held(["Freedom", "Kaspi"]))
  }

  /// A new currency goes on last, and there is no limit: an eleventh and more go on too —
  /// fifteen currencies of the bank are on without a refusal.
  func testACurrencyIsSwitchedOnLastWithoutALimit() throws {
    XCTAssertEqual(try enabled().count, 10, "ten are on from the start")
    let gbp = CurrencyCode("GBP")
    XCTAssertTrue(
      CurrenciesSettingsView.switchCurrency(gbp, on: true, enabled: try enabled(), in: environment))
    XCTAssertEqual(try enabled().last, gbp)
    XCTAssertEqual(try enabled().count, 11, "an eleventh currency was refused")

    for code in ["JPY", "CHF", "PLN", "HKD"] {
      XCTAssertTrue(
        CurrenciesSettingsView.switchCurrency(
          CurrencyCode(code), on: true, enabled: try enabled(), in: environment))
    }
    XCTAssertEqual(try enabled().count, 15)
    XCTAssertEqual(try enabled().suffix(5).map(\.code), ["GBP", "JPY", "CHF", "PLN", "HKD"])
  }

  /// The checkboxes offer every currency the bank publishes, the ones of a fresh install first,
  /// a code of the bank switched on elsewhere too, and never a custom currency.
  func testTheListOffersEveryCurrencyOfTheBankAndNoCustomOne() {
    let tether = CustomCurrency(code: CurrencyCode("UST"), name: "Tether")
    let offered = CurrenciesSettingsView.offered(
      enabled: CurrencyCode.defaultEnabled + [CurrencyCode("MUR"), tether.code],
      catalog: CurrencyCatalog(custom: [tether]))
    XCTAssertEqual(Array(offered.prefix(10)), CurrencyCode.defaultEnabled)
    for code in ["GBP", "HKD", "XDR", "MMK", "MUR"] {
      XCTAssertTrue(offered.contains(CurrencyCode(code)), code)
    }
    XCTAssertFalse(offered.contains(tether.code))
    XCTAssertEqual(Set(offered).count, offered.count, "a currency offered twice")
    XCTAssertGreaterThanOrEqual(offered.count, 50)
  }

  // MARK: Words

  /// The picker, its hint and the reasons a currency stays on have words in both languages.
  func testTheCurrencyTabHasItsWords() {
    let keys = [
      "settings.currencies.default", "settings.currencies.defaultHint",
      "currencies.caption.default", "currencies.lock.base", "currencies.lock.default",
      "currencies.lock.held", "settings.tab.accounts",
    ]
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      for key in keys {
        let text = environment.language(key, table: "Settings")
        XCTAssertNotEqual(text, key, "\(key) has no words in \(choice)")
        XCTAssertFalse(text.isEmpty)
      }
      let held = environment.format("currencies.caption.heldOne", table: "Settings", "Freedom")
      XCTAssertTrue(held.contains("Freedom"), held)
    }
    environment.language.choice = .russian
    XCTAssertEqual(
      environment.language("settings.currencies.default", table: "Settings"),
      "Валюта по умолчанию")
  }
}
