import AppCore
import AppDatabase
import SwiftUI
import XCTest

@testable import OhMyMoney

/// What VoiceOver hears in the new controls of Settings and of the accounts: a field for a
/// balance says which balance, an accent circle says its colour, and the chosen accent is said
/// in words, never by the ring alone. Read from the accessibility tree the window builds, the
/// way VoiceOver reads it; a runner without an assistive client builds none and skips.
@MainActor
final class SettingsAccessibilityTests: XCTestCase {
  private var environment: AppEnvironment!
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private var windows: [NSWindow] = []

  override func setUp() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-settings-ax-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
  }

  override func tearDown() async throws {
    for window in windows { window.close() }
    windows = []
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  /// The field for the balance now of a new account, one per currency, is named by the
  /// balance it holds — «Остаток сейчас, USD» —, not by its empty-state word «не считать»,
  /// which says nothing about which currency the number goes to.
  func testTheBalanceFieldOfAnAccountSaysWhichCurrencyItCounts() throws {
    let store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
    let deps = AppDependencies(
      environment: environment, store: store, compute: ComputeStore(calendar: .system))
    let window = show(
      AccountEditor(previous: nil, defaultCurrency: CurrencyCode("USD"), finish: { _ in })
        .appDependencies(deps),
      size: CGSize(width: 480, height: 620))
    let expected = environment.format("account.editor.balanceNow", table: "Accounts", "USD")
    waitFor { !Self.elements(in: window, role: "AXTextField").isEmpty }
    // The field of the name, and the field of the balance once the books are read.
    waitFor { Self.elements(in: window, role: "AXTextField").count >= 2 }
    let fields = Self.elements(in: window, role: "AXTextField")
    let names = fields.map(Self.spoken)
    XCTAssertTrue(
      names.contains { $0.contains(expected) },
      "no field says «\(expected)»; VoiceOver hears \(names)")
  }

  /// The accent circles: one button for each accent, named in the language of the interface,
  /// and the chosen accent is written in words beside them.
  func testEveryAccentCircleIsAButtonNamedByItsColourAndTheChoiceIsSaidInWords() {
    let deps = AppDependencies(
      environment: environment, store: TransactionsStore(),
      compute: ComputeStore(calendar: .system))
    let window = show(
      AppearanceSettingsView().appDependencies(deps), size: CGSize(width: 620, height: 460))
    let names = AppTheme.Accent.allCases.map {
      AppearanceSettingsView.accentTitle($0, environment)
    }
    waitFor { Self.elements(in: window, role: "AXButton").count >= names.count }
    let buttons = Self.elements(in: window, role: "AXButton").map(Self.spoken)
    for name in names {
      XCTAssertTrue(buttons.contains { $0.contains(name) }, "no circle says «\(name)»: \(buttons)")
    }
    let chosen = AppearanceSettingsView.accentTitle(environment.theme.accent, environment)
    let texts = Self.elements(in: window, role: "AXStaticText").map(Self.spoken)
    XCTAssertTrue(
      texts.contains { $0.contains(chosen) }, "the chosen accent is not said in words: \(texts)")
  }

  /// Settings → Планирование, «Деньги целей лежат на счетах в сводке»: on until the owner
  /// says otherwise, pressed it writes its own key and nothing else — the tab read the others
  /// when it opened, and they may have changed elsewhere since —, and pressed again it is on.
  func testTheSwitchOfGoalMoneyWritesOnlyItsOwnKey() throws {
    let settings = try XCTUnwrap(environment.settings)
    let deps = AppDependencies(
      environment: environment, store: TransactionsStore(),
      compute: ComputeStore(calendar: .system))
    let window = show(
      PlanningSettingsView().appDependencies(deps), size: CGSize(width: 620, height: 720))
    var toggle: AnyObject?
    waitFor {
      toggle = Self.control(identified: "settings.planning.goalMoney", in: window)
      return toggle != nil
    }
    let control = try XCTUnwrap(toggle, "no switch of goal money")
    XCTAssertEqual(Self.isOn(control), true, "the switch is not on before the owner turns it off")
    var before: [String: String] = [:]
    for key in PlanningSettings.storageKeys {
      if let value = try settings.string(key) { before[key] = value }
    }
    XCTAssertNotEqual(before[PlanningSettings.reconcileIncludesGoalSavingsKey], "0")

    _ = control.accessibilityPerformPress?()
    waitFor { (try? settings.string(PlanningSettings.reconcileIncludesGoalSavingsKey)) == "0" }
    XCTAssertEqual(try settings.string(PlanningSettings.reconcileIncludesGoalSavingsKey), "0")
    for key in PlanningSettings.storageKeys
    where key != PlanningSettings.reconcileIncludesGoalSavingsKey {
      XCTAssertEqual(
        try settings.string(key), before[key], "\(key) was written by the switch of goal money")
    }

    _ = control.accessibilityPerformPress?()
    waitFor { (try? settings.string(PlanningSettings.reconcileIncludesGoalSavingsKey)) == "1" }
    XCTAssertEqual(try settings.string(PlanningSettings.reconcileIncludesGoalSavingsKey), "1")
  }

  /// A ⇄ row of an account's days is one element for VoiceOver, and it says in words what the
  /// symbol only shows: that it is a transfer, between which accounts, and how much left the
  /// account on screen — with its minus, not by a colour.
  func testATransferRowSaysItIsATransferAndHowMuchLeftTheAccount() throws {
    let deps = AppDependencies(
      environment: environment, store: TransactionsStore(),
      compute: ComputeStore(calendar: .system))
    let from = UUID()
    let transfer = Transfer(
      occurredAt: Date(), fromAccountId: from, fromCurrency: .rub,
      fromAmountE4: AmountE4(raw: 15_000_000), toAccountId: UUID(), toCurrency: .rub,
      toAmountE4: AmountE4(raw: 15_000_000))
    let window = show(
      VStack {
        AccountTransferRow(
          transfer: transfer, fee: nil, accountIds: [from], edit: {}, delete: {})
      }
      .padding()
      .appDependencies(deps),
      size: CGSize(width: 560, height: 200))
    let unknown = environment.language("transfer.unknownAccount", table: "Accounts")
    let title = AccountTransferRow.title(
      transfer, names: [:], unknown: unknown, language: environment.language)
    let amount = AccountHistory.amountText(
      transfer, accountIds: [from], money: environment.money)
    XCTAssertTrue(amount.hasPrefix("\u{2212}"), amount)
    var heard: [String] = []
    waitFor {
      heard = Self.everything(in: window).map(Self.spoken)
      return heard.contains { $0.contains(title) }
    }
    XCTAssertTrue(heard.contains { $0.contains(title) }, "«\(title)» is not heard: \(heard)")
    XCTAssertTrue(
      heard.contains { $0.contains(title) && $0.contains(amount) },
      "the row does not say «\(title)» with «\(amount)» as one: \(heard)")
  }

  /// Settings → Шаблоны: the pin of a row says what pressing it does — «Открепить» on a pinned
  /// template, «Закрепить» on another — to the pointer and to VoiceOver. Told only by a filled
  /// or hollow pin, a pinned template read as «pin.fill» and offered «Закрепить» on hover.
  func testThePinOfATemplateSaysWhetherItPinsOrUnpins() throws {
    let references = try XCTUnwrap(environment.references)
    try references.save(Template(text: "кофе", pinned: true, useCount: 7))
    try references.save(Template(text: "такси", useCount: 3))
    let deps = AppDependencies(
      environment: environment, store: TransactionsStore(),
      compute: ComputeStore(calendar: .system))
    let window = show(
      TemplatesSettingsView().appDependencies(deps), size: CGSize(width: 620, height: 420))
    let pin = environment.language("templates.pin", table: "Settings")
    let unpin = environment.language("templates.unpin", table: "Settings")
    XCTAssertNotEqual(unpin, "templates.unpin", "«Открепить» is not in the table of Settings")
    var buttons: [String] = []
    waitFor {
      buttons = Self.elements(inRowsOf: window, role: "AXButton").map(Self.spoken)
      return buttons.contains { $0.contains(pin) || $0.contains(unpin) }
    }
    XCTAssertEqual(
      buttons.filter { $0.contains(unpin) }.count, 1, "the pinned template: \(buttons)")
    XCTAssertEqual(
      buttons.filter { $0.contains(pin) && !$0.contains(unpin) }.count, 1,
      "the template that is not pinned: \(buttons)")
  }

  /// Settings → Категории: the «…» of a row names the category it acts on, like the «…» of
  /// every row of Справочники — «Действия с «Кофейни»». Without a label VoiceOver read the
  /// name of its symbol, the same for every row.
  func testTheMenuOfACategoryRowNamesItsCategory() throws {
    let references = try XCTUnwrap(environment.references)
    let cafes = CoreKit.Category(kind: .expense, name: "Кофейни", sort: 5_000, quality: .neutral)
    try references.save(cafes)
    let deps = AppDependencies(
      environment: environment, store: TransactionsStore(),
      compute: ComputeStore(calendar: .system))
    let window = show(
      CategoriesSettingsView().appDependencies(deps), size: CGSize(width: 760, height: 560))
    let expected = environment.format("references.rowMenu", table: "Settings", "Кофейни")
    var menus: [String] = []
    waitFor {
      menus = Self.elements(inRowsOf: window) {
        Self.attribute($0, "accessibilityIdentifier") as? String == "categories.row.menu"
      }
      .map(Self.spoken)
      return !menus.isEmpty
    }
    XCTAssertFalse(menus.isEmpty, "no «…» in the rows of the categories")
    XCTAssertTrue(
      menus.contains { $0.contains(expected) }, "no «…» says «\(expected)»: \(menus)")
  }

  /// The first setup: each field for the balance now of an account says its currency — two
  /// currencies, two different names —, not its placeholder «0».
  func testEveryBalanceFieldOfTheSetupSaysItsCurrency() throws {
    let card = PaymentMethod(
      name: "Kaspi", kind: .card, currency: CurrencyCode("KZT"), isDefault: true,
      otherCurrencies: [.rub])
    try XCTUnwrap(environment.references).save(card)
    let store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
    let deps = AppDependencies(
      environment: environment, store: store, compute: ComputeStore(calendar: .system))
    let window = show(
      AccountSetupSheet().appDependencies(deps), size: CGSize(width: 720, height: 700))
    let expected = ["KZT", "RUB"].map {
      environment.format("onboarding.balance", table: "Onboarding", $0)
    }
    var heard: [String] = []
    waitFor {
      heard = Self.elements(in: window, role: "AXTextField").map(Self.spoken)
      return expected.allSatisfy { name in heard.contains { $0.contains(name) } }
    }
    for name in expected {
      XCTAssertTrue(heard.contains { $0.contains(name) }, "no field says «\(name)»: \(heard)")
    }
  }

  /// Settings → Счета: the main account is told in words in its row, «основной», not by the
  /// star alone; the others are not.
  func testTheMainAccountIsToldInWordsInItsRow() throws {
    let references = try XCTUnwrap(environment.references)
    try references.save(PaymentMethod(name: "Сбер", kind: .card, currency: .rub, isDefault: true))
    try references.save(PaymentMethod(name: "Наличные", kind: .cash, currency: .rub))
    let store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
    let deps = AppDependencies(
      environment: environment, store: store, compute: ComputeStore(calendar: .system))
    let window = show(
      AccountsSettingsView().appDependencies(deps), size: CGSize(width: 700, height: 560))
    let main = environment.language("accounts.main", table: "Accounts")
    var texts: [String] = []
    waitFor {
      texts = Self.elements(inRowsOf: window, role: "AXStaticText").map(Self.spoken)
      return texts.contains { $0.contains("Наличные") }
    }
    XCTAssertTrue(texts.contains { $0.contains("Сбер") }, "\(texts)")
    XCTAssertEqual(texts.filter { $0.contains(main) }.count, 1, "«\(main)» once: \(texts)")
  }

  /// No tab of Settings, and not the first setup, shows a key of a catalog or a placeholder of
  /// a format, in either language: every text, label and value VoiceOver can reach is read,
  /// the rows of the lists included. `check-strings` sees only keys written as literals; this
  /// sees what a key built at run time, or looked up in the wrong table, puts on screen.
  func testNoTabOfSettingsShowsARawKeyInEitherLanguage() throws {
    let references = try XCTUnwrap(environment.references)
    try references.save(PaymentMethod(name: "Сбер", kind: .card, currency: .rub, isDefault: true))
    try references.save(
      PaymentMethod(name: "Старая карта", kind: .card, currency: .rub, archived: true))
    try references.save(Person(name: "Аня", relation: .partner))
    try references.save(Template(text: "кофе 250", pinned: true, useCount: 4))
    try references.save(Template(text: "такси", useCount: 2, archived: true))
    let store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
    let deps = AppDependencies(
      environment: environment, store: store, compute: ComputeStore(calendar: .system))
    let tabs: [(String, AnyView)] = [
      ("general", AnyView(GeneralSettingsView())),
      ("appearance", AnyView(AppearanceSettingsView())),
      ("currencies", AnyView(CurrenciesSettingsView())),
      ("accounts", AnyView(AccountsSettingsView())),
      ("categories", AnyView(CategoriesSettingsView())),
      ("references", AnyView(ReferenceBooksView())),
      ("templates", AnyView(TemplatesSettingsView())),
      ("planning", AnyView(PlanningSettingsView())),
      ("setup", AnyView(AccountSetupSheet())),
    ]
    let key = try NSRegularExpression(pattern: "^[a-z][A-Za-z0-9]*(\\.[A-Za-z0-9-]+){1,}$")
    let placeholder = try NSRegularExpression(pattern: "%([0-9]+\\$)?(@|lld|ld|d)")
    let before = environment.language.choice
    defer { environment.language.choice = before }
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      for (name, view) in tabs {
        let window = show(view.appDependencies(deps), size: CGSize(width: 840, height: 700))
        settle(0.4)
        let texts = Set(
          (Self.everything(in: window) + Self.elements(inRowsOf: window) { _ in true })
            .flatMap(Self.words))
        XCTAssertGreaterThan(texts.count, 3, "\(name) shows nothing in \(choice.rawValue)")
        for text in texts {
          let range = NSRange(text.startIndex..., in: text)
          XCTAssertNil(
            key.firstMatch(in: text, range: range),
            "\(name), \(choice.rawValue): a raw key on screen — «\(text)»")
          XCTAssertNil(
            placeholder.firstMatch(in: text, range: range),
            "\(name), \(choice.rawValue): a placeholder on screen — «\(text)»")
        }
        window.close()
      }
    }
  }

  /// Settings → Валюты: the checkbox of the default currency is out of reach, and why is said
  /// in words on its row — not by the grey of a disabled control alone; a currency nothing
  /// holds stays within reach and says nothing of the kind.
  func testTheDefaultCurrencySaysInWordsWhyItStaysOn() throws {
    let kzt = CurrencyCode("KZT")
    XCTAssertTrue(CurrenciesSettingsView.chooseDefault(kzt, in: environment))
    let deps = AppDependencies(
      environment: environment, store: TransactionsStore(),
      compute: ComputeStore(calendar: .system))
    let window = show(
      CurrenciesSettingsView().appDependencies(deps), size: CGSize(width: 700, height: 900))
    let why = environment.language("currencies.caption.default", table: "Settings")
    var boxes: [NSObject] = []
    waitFor {
      boxes = Self.elements(in: window, role: "AXCheckBox")
      return boxes.contains { Self.spoken($0).contains("KZT") }
    }
    let box = try XCTUnwrap(
      boxes.first { Self.spoken($0).contains("KZT") },
      "no checkbox of KZT: \(boxes.map(Self.spoken))")
    XCTAssertEqual(Self.attribute(box, "isAccessibilityEnabled") as? Bool, false)
    XCTAssertTrue(Self.spoken(box).contains(why), "«\(why)» is not said: \(Self.spoken(box))")
    let usd = try XCTUnwrap(boxes.first { Self.spoken($0).contains("USD") })
    XCTAssertEqual(Self.attribute(usd, "isAccessibilityEnabled") as? Bool, true)
    XCTAssertFalse(Self.spoken(usd).contains(why), Self.spoken(usd))
  }

  /// Settings → Шаблоны with «Показывать архив» on: an archived template is said to be in the
  /// archive — the box beside it has words —, and «Вернуть» is there to bring it back.
  func testAnArchivedTemplateIsSaidToBeInTheArchiveAndCanBeBroughtBack() throws {
    let references = try XCTUnwrap(environment.references)
    try references.save(Template(text: "кофе", useCount: 7))
    let taxi = Template(text: "такси", useCount: 3, archived: true)
    try references.save(taxi)
    let deps = AppDependencies(
      environment: environment, store: TransactionsStore(),
      compute: ComputeStore(calendar: .system))
    let window = show(
      TemplatesSettingsView().appDependencies(deps), size: CGSize(width: 620, height: 420))
    let showArchive = environment.language("templates.showArchive", table: "Settings")
    var box: NSObject?
    waitFor {
      box = Self.elements(in: window, role: "AXCheckBox").first {
        Self.spoken($0).contains(showArchive)
      }
      return box != nil
    }
    let checkbox = try XCTUnwrap(box, "no «\(showArchive)»")
    _ = (checkbox as AnyObject).accessibilityPerformPress?()
    let inArchive = environment.language("templates.inArchive", table: "Settings")
    let restore = environment.language("templates.restore", table: "Settings")
    var heard: [String] = []
    waitFor {
      heard = Self.elements(inRowsOf: window) { _ in true }.flatMap(Self.words)
      return heard.contains(inArchive)
    }
    XCTAssertTrue(heard.contains(inArchive), "«\(inArchive)» is not said: \(heard)")
    let back = try XCTUnwrap(
      Self.elements(inRowsOf: window, role: "AXButton").first { Self.spoken($0) == restore },
      "no «\(restore)»: \(heard)")
    _ = (back as AnyObject).accessibilityPerformPress?()
    waitFor { (try? references.templates().first { $0.id == taxi.id }?.archived) == false }
    XCTAssertEqual(try references.templates().first { $0.id == taxi.id }?.archived, false)
  }

  /// Settings → Шаблоны: the «…» of a template names the template it acts on — «Действия с
  /// «кофе»» —, the live rows and the archived ones, in Russian and in English. It said
  /// «Действия с шаблоном» on every row, so VoiceOver could not tell the rows apart.
  func testTemplateRowMenusNameTheirRow() throws {
    let references = try XCTUnwrap(environment.references)
    try references.save(Template(text: "кофе", useCount: 7))
    try references.save(Template(text: "такси", useCount: 3, archived: true))
    let before = environment.language.choice
    defer { environment.language.choice = before }
    for choice in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = choice
      let deps = AppDependencies(
        environment: environment, store: TransactionsStore(),
        compute: ComputeStore(calendar: .system))
      let window = show(
        TemplatesSettingsView().appDependencies(deps), size: CGSize(width: 620, height: 420))
      let showArchive = environment.language("templates.showArchive", table: "Settings")
      var box: NSObject?
      waitFor {
        box = Self.elements(in: window, role: "AXCheckBox").first {
          Self.spoken($0).contains(showArchive)
        }
        return box != nil
      }
      _ = (try XCTUnwrap(box, "no «\(showArchive)»") as AnyObject).accessibilityPerformPress?()
      let live = SettingsRowMenu.label("кофе", environment)
      let archived = SettingsRowMenu.label("такси", environment)
      XCTAssertNotEqual(live, "references.rowMenu", "\(choice.rawValue)")
      XCTAssertTrue(live.contains("кофе"), live)
      var heard: [String] = []
      waitFor {
        heard = Self.elements(inRowsOf: window) { _ in true }.map(Self.spoken)
        return heard.contains { $0.contains(live) } && heard.contains { $0.contains(archived) }
      }
      XCTAssertTrue(
        heard.contains { $0.contains(live) }, "\(choice.rawValue): no «\(live)»: \(heard)")
      XCTAssertTrue(
        heard.contains { $0.contains(archived) },
        "\(choice.rawValue): no «\(archived)»: \(heard)")
      window.close()
    }
  }

  /// Settings → Оформление → «Плитки «Обзора»»: the tiles and the groups are moved by dragging
  /// them — every tile row and every group name takes a drop —, no arrow buttons are left in the
  /// rows, and VoiceOver moves a tile by the actions «Выше», «Ниже» and «Перенести в «…»» of its
  /// row, a group by «Группу выше» and «Группу ниже»: the first tile of a group has no «Выше»,
  /// the last no «Ниже», the first group no «Группу выше».
  func testTheTilesAreDraggedAndVoiceOverMovesThemByActions() throws {
    environment.overviewLayout = .standard
    let deps = AppDependencies(
      environment: environment, store: TransactionsStore(),
      compute: ComputeStore(calendar: .system))
    let window = show(
      AppearanceSettingsView().appDependencies(deps), size: CGSize(width: 620, height: 900))
    let up = environment.language("settings.entry.moveUp", table: "Settings")
    let down = environment.language("settings.entry.moveDown", table: "Settings")
    func moveTo(_ group: OverviewTileGroup) -> String {
      environment.format(
        "settings.tiles.moveTo", table: "Settings",
        OverviewTileText.groupName(of: group, environment))
    }
    func element(_ identifier: String) -> NSObject? {
      (Self.everything(in: window) + Self.elements(inRowsOf: window) { _ in true }).first {
        Self.attribute($0, "accessibilityIdentifier") as? String == identifier
      }
    }
    func row(_ tile: OverviewTile) -> NSObject? { element("settings.tiles.\(tile.rawValue)") }
    waitFor { row(.limits) != nil }
    func actions(_ found: NSObject?) -> [String] {
      guard let found else { return [] }
      let custom =
        Self.attribute(found, "accessibilityCustomActions") as? [NSAccessibilityCustomAction]
      return (custom ?? []).map(\.name)
    }
    XCTAssertEqual(
      Set(actions(row(.canSave))), [up, down, moveTo(.plan), moveTo(.analysis)], "a middle tile")
    XCTAssertEqual(
      Set(actions(row(.limits))), [down, moveTo(.money), moveTo(.analysis)],
      "the first tile of «План»")
    // The tiles of 2.0 follow the cushion in «Деньги»: the last of them is the last of the group.
    XCTAssertEqual(
      Set(actions(row(.savingsRate))), [up, moveTo(.plan), moveTo(.analysis)],
      "the last tile of «Деньги»")

    let buttons =
      (Self.elements(in: window, role: "AXButton")
      + Self.elements(inRowsOf: window, role: "AXButton")).map(Self.spoken)
    XCTAssertFalse(
      buttons.contains { $0.contains(up) || $0.contains(down) }, "an arrow is left: \(buttons)")

    // The grouped form is drawn by SwiftUI, not a table, so a list's move would do nothing in
    // it: each tile and each group name is a place to drop on — AppKit holds one dragging
    // destination for each.
    func views(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    let destinations = (window.contentView.map(views) ?? []).filter {
      String(describing: type(of: $0)).contains("DraggingDestination")
        && !$0.registeredDraggedTypes.isEmpty
    }
    XCTAssertEqual(
      destinations.count, OverviewTile.allCases.count + OverviewTileGroup.allCases.count,
      "a drop place for each tile and each group")

    let found = try XCTUnwrap(row(.canSave))
    let custom =
      Self.attribute(found, "accessibilityCustomActions") as? [NSAccessibilityCustomAction]
    _ = try XCTUnwrap(custom?.first { $0.name == up }).handler?()
    waitFor { environment.overviewLayout.tiles(in: .money).first == .canSave }
    XCTAssertEqual(
      Array(environment.overviewLayout.tiles(in: .money).prefix(2)), [.canSave, .monthToDate])
    _ = try XCTUnwrap(custom?.first { $0.name == moveTo(.analysis) }).handler?()
    waitFor { environment.overviewLayout.group(of: .canSave) == .analysis }
    XCTAssertEqual(environment.overviewLayout.tiles(in: .analysis).last, .canSave)

    let groupUp = environment.language("settings.tiles.groupUp", table: "Settings")
    let groupDown = environment.language("settings.tiles.groupDown", table: "Settings")
    waitFor { element("settings.tiles.group.money") != nil }
    XCTAssertEqual(actions(element("settings.tiles.group.money")), [groupDown])
    XCTAssertEqual(Set(actions(element("settings.tiles.group.plan"))), [groupUp, groupDown])
  }

  /// Every card of Overview is titled by the name its tile has in Settings, in both languages:
  /// the forecast of spending says it is about spending — «Прогноз расхода до конца месяца».
  func testEveryCardOfOverviewIsTitledByTheNameOfItsTile() throws {
    let deps = AppDependencies(
      environment: environment, store: TransactionsStore(),
      compute: ComputeStore(calendar: .system))
    let before = environment.language.choice
    defer { environment.language.choice = before }
    for choice in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = choice
      // The tiles that wait to be added have no card yet.
      for tile in OverviewTile.allCases where tile.isShownUnnamed {
        let name = OverviewTileText.name(of: tile, environment)
        let window = show(
          OverviewCardView(tile: tile, actions: OperationActions())
            .appDependencies(deps).padding(),
          size: CGSize(width: 420, height: 320))
        var heard: [String] = []
        waitFor {
          heard = Self.everything(in: window).flatMap(Self.words)
          return heard.contains(name)
        }
        XCTAssertTrue(
          heard.contains(name), "\(tile), \(choice.rawValue): «\(name)» not in \(heard)")
        window.close()
      }
    }
    environment.language.choice = .russian
    XCTAssertEqual(
      OverviewTileText.name(of: .spendingForecast, environment), "Прогноз расхода до конца месяца")
    environment.language.choice = .english
    XCTAssertEqual(
      OverviewTileText.name(of: .spendingForecast, environment),
      "Spending forecast to the end of the month")
  }

  // MARK: Helpers

  /// The texts of one element as VoiceOver can read them, each on its own.
  private static func words(_ object: NSObject) -> [String] {
    ["accessibilityLabel", "accessibilityTitle", "accessibilityValue", "accessibilityHelp"]
      .compactMap { attribute(object, $0) as? String }
      .filter { !$0.isEmpty }
  }

  /// Every element of `role` in the rows of the lists of the window. A SwiftUI list is a table
  /// of AppKit, and its rows are reached through the table rather than through the tree above.
  private static func elements(inRowsOf window: NSWindow, role: String) -> [NSObject] {
    elements(inRowsOf: window) { attribute($0, "accessibilityRole") as? String == role }
  }

  private static func elements(
    inRowsOf window: NSWindow, where matches: (NSObject) -> Bool
  ) -> [NSObject] {
    func tables(in view: NSView) -> [NSTableView] {
      (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables)
    }
    var found: [NSObject] = []
    func walk(_ element: Any, depth: Int) {
      guard depth < 40, let object = element as? NSObject else { return }
      if matches(object) { found.append(object) }
      for child in attribute(object, "accessibilityChildren") as? [Any] ?? [] {
        walk(child, depth: depth + 1)
      }
    }
    for table in window.contentView.map(tables) ?? [] {
      for row in 0..<table.numberOfRows {
        if let view = table.rowView(atRow: row, makeIfNecessary: true) { walk(view, depth: 0) }
      }
    }
    return found
  }

  /// Every element of the window, in the order VoiceOver reads them.
  private static func everything(in window: NSWindow) -> [NSObject] {
    var found: [NSObject] = []
    func walk(_ element: Any, depth: Int) {
      guard depth < 60, let object = element as? NSObject else { return }
      found.append(object)
      for child in attribute(object, "accessibilityChildren") as? [Any] ?? [] {
        walk(child, depth: depth + 1)
      }
    }
    if let root = window.contentView { walk(root, depth: 0) }
    return found
  }

  /// The pressable control under the element that carries `identifier`: SwiftUI may hang the
  /// identifier on the row that holds the switch.
  private static func control(identified identifier: String, in window: NSWindow) -> AnyObject? {
    var found: AnyObject?
    func walk(_ node: AnyObject, depth: Int) {
      guard found == nil, depth < 60 else { return }
      if node.accessibilityIdentifier?() == identifier {
        found = pressable(in: node, depth: 0)
        return
      }
      for child in node.accessibilityChildren?() ?? [] {
        walk(child as AnyObject, depth: depth + 1)
      }
    }
    if let root = window.contentView { walk(root, depth: 0) }
    return found
  }

  private static func pressable(in node: AnyObject, depth: Int) -> AnyObject? {
    let role = node.accessibilityRole?()
    if role == .checkBox || role == .button || node.accessibilitySubrole?() == .switch {
      return node
    }
    guard depth < 10 else { return nil }
    for child in node.accessibilityChildren?() ?? [] {
      if let found = pressable(in: child as AnyObject, depth: depth + 1) { return found }
    }
    return nil
  }

  private static func isOn(_ control: AnyObject) -> Bool? {
    guard let object = control as? NSObject else { return nil }
    switch attribute(object, "accessibilityValue") {
    case let number as NSNumber: return number.boolValue
    case let text as String: return text == "1"
    default: return nil
    }
  }

  private func show<Content: View>(_ view: Content, size: CGSize) -> NSWindow {
    // dependencies: every caller hands them to the view it gives here
    let window = NSWindow(contentViewController: NSHostingController(rootView: view))
    window.setContentSize(size)
    window.isReleasedWhenClosed = false
    window.orderFront(nil)
    windows.append(window)
    settle(0.5)
    return window
  }

  private func settle(_ seconds: TimeInterval = 0.2) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  private func waitFor(_ condition: () -> Bool, seconds: TimeInterval = 5) {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline { settle(0.05) }
  }

  private static func attribute(_ object: NSObject, _ name: String) -> Any? {
    guard object.responds(to: NSSelectorFromString(name)) else { return nil }
    return object.value(forKey: name)
  }

  /// Every element of `role` in the window, in the order VoiceOver reads them.
  private static func elements(in window: NSWindow, role: String) -> [NSObject] {
    var found: [NSObject] = []
    func walk(_ element: Any, depth: Int) {
      guard depth < 60, let object = element as? NSObject else { return }
      if attribute(object, "accessibilityRole") as? String == role { found.append(object) }
      for child in attribute(object, "accessibilityChildren") as? [Any] ?? [] {
        walk(child, depth: depth + 1)
      }
    }
    if let root = window.contentView { walk(root, depth: 0) }
    return found
  }

  /// What VoiceOver says for an element: its label, its title and the title of the element
  /// that names it.
  private static func spoken(_ object: NSObject) -> String {
    var words: [String] = []
    for name in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
      if let text = attribute(object, name) as? String, !text.isEmpty { words.append(text) }
    }
    if let title = attribute(object, "accessibilityTitleUIElement") as? NSObject {
      for name in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
        if let text = attribute(title, name) as? String, !text.isEmpty { words.append(text) }
      }
    }
    return words.joined(separator: " | ")
  }
}

/// What the pin of a template says, read without the accessibility tree, so it runs where the
/// tree is not built (the CI runner) too: a pinned row offers to unpin, the others to pin, in
/// different words in both languages.
@MainActor
final class TemplatePinCaptionTests: XCTestCase {
  func testThePinOfAPinnedTemplateOffersToUnpinInBothLanguages() {
    let language = AppLanguage()
    let before = language.choice
    defer { language.choice = before }
    let pin = TemplatesSettingsView.pinCaptionKey(pinned: false)
    let unpin = TemplatesSettingsView.pinCaptionKey(pinned: true)
    XCTAssertNotEqual(pin, unpin, "both rows say the same whatever their state")
    let expected: [AppLanguage.Choice: (String, String)] = [
      .english: ("Pin", "Unpin"), .russian: ("Закрепить", "Открепить"),
    ]
    for (choice, words) in expected {
      language.choice = choice
      XCTAssertEqual(language(pin, table: "Settings"), words.0, "\(choice.rawValue)")
      XCTAssertEqual(language(unpin, table: "Settings"), words.1, "\(choice.rawValue)")
    }
  }
}
