import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// Pictures of the Mac screens, laid out in test windows over synthetic books and written as PNG
/// files, so that a screen the hand cannot reach (the editor with parts, the ↓ panel split, a
/// debt's card) can still be looked at, in both languages and both themes.
///
/// It is an export, not a check, and it is off in `make test`: without
/// `OHMYMONEY_EXPORT_SCREENS=1` in the host's environment (`TEST_RUNNER_OHMYMONEY_EXPORT_SCREENS=1`
/// for `xcodebuild`) every method returns at once and passes — never skips, which the project
/// forbids on this Mac. The host is sandboxed, so the files land in its temporary directory,
/// `…/tmp/mac-screens/<ru|en>-<light|dark>/<screen>.png`; whoever runs the export copies them out.
@MainActor
final class MacScreenSnapshotExport: SectionFigmaHarness {
  static var enabled: Bool {
    ProcessInfo.processInfo.environment["OHMYMONEY_EXPORT_SCREENS"] == "1"
  }

  private var active = false

  override func setUp() async throws {
    guard Self.enabled else { return }
    active = true
    try await super.setUp()
  }

  override func tearDown() async throws {
    guard active else { return }
    try await super.tearDown()
  }

  // The book is drawn in the language of the run.
  var bookLanguage = "ru"

  override func book(today: DateOnly) -> DataSnapshot {
    let set = SampleDataGenerator(seed: 20_261_110).generate(
      months: 6, endingOn: today, calendar: .system, language: bookLanguage
    ).withEveryFeature(seed: 20_261_110, calendar: .system, language: bookLanguage)
    let dataset = Dataset(
      entries: set.entries, links: set.links, categories: set.categories, people: set.people,
      places: set.places, events: set.events, paymentMethods: set.paymentMethods,
      debts: set.debts, goals: set.goals, planning: set.planningBook,
      settings: AnalyticsSettings(cashbackCategoryId: set.cashbackCategoryId),
      transfers: set.transfers, accountGroups: set.accountGroups,
      accountSettings: AccountSettings(storedValues: set.settings), cards: set.cards,
      cashbackRules: set.cashbackRules, banks: set.banks, assets: set.assets,
      assetValuations: set.assetValuations,
      capitalSettings: CapitalSettings(storedValues: set.settings))
    return DataSnapshot.build(
      dataset: dataset, calendar: .system, today: today,
      context: SnapshotContext(rubPerUnit: [.usd: 95, .eur: 103]),
      version: DataVersion(load: 0))
  }

  // MARK: The runs

  func testEditorsRussianLight() async throws { try await editors(.russian, dark: false) }
  func testEditorsRussianDark() async throws { try await editors(.russian, dark: true) }
  func testEditorsEnglishLight() async throws { try await editors(.english, dark: false) }
  func testEditorsEnglishDark() async throws { try await editors(.english, dark: true) }

  func testMainRussianLight() throws { try main(.russian, dark: false) }
  func testMainRussianDark() throws { try main(.russian, dark: true) }
  func testMainEnglishLight() throws { try main(.english, dark: false) }
  func testMainEnglishDark() throws { try main(.english, dark: true) }

  func testSettingsRussianLight() throws { try settings(.russian, dark: false) }
  func testSettingsRussianDark() throws { try settings(.russian, dark: true) }
  func testSettingsEnglishLight() throws { try settings(.english, dark: false) }
  func testSettingsEnglishDark() throws { try settings(.english, dark: true) }

  // MARK: Setting up a run

  private struct Run {
    let folder: URL
    let dark: Bool
  }

  private func begin(_ language: AppLanguage.Choice, dark: Bool) -> Run {
    environment.language.choice = language
    bookLanguage = language == .english ? "en" : "ru"
    compute.applyLight(book(today: environment.today))
    let name = "\(language.rawValue)-\(dark ? "dark" : "light")"
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("mac-screens", isDirectory: true)
      .appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return Run(folder: folder, dark: dark)
  }

  /// Draws the window in the theme of the run and writes its picture; the window is closed after,
  /// so that a run never holds more than a few at once.
  private func shoot(_ window: NSWindow, _ name: String, _ run: Run) throws {
    window.appearance = NSAppearance(named: run.dark ? .darkAqua : .aqua)
    settle(window, passes: 40)
    let png = try picture(of: window)
    try png.write(to: run.folder.appendingPathComponent(name + ".png"))
    window.contentViewController = nil
    window.contentView = nil
    window.close()
    windows.removeAll { $0 === window }
  }

  /// What the window shows, glass included: the compositor's picture of the window itself, which
  /// a plain `cacheDisplay` of the view leaves out (glass is drawn by the window server). The
  /// call is looked up by name — the SDK marks it obsolete — and the view's own drawing is the
  /// fallback where it is not there.
  private func picture(of window: NSWindow) throws -> Data {
    typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
      let capture = unsafeBitCast(symbol, to: Capture.self)
      // optionIncludingWindow = 1 << 3, boundsIgnoreFraming = 1 << 0
      if let image = capture(.null, 1 << 3, UInt32(window.windowNumber), 1)?.takeRetainedValue() {
        let rep = NSBitmapImageRep(cgImage: image)
        if let png = rep.representation(using: .png, properties: [:]) { return png }
      }
    }
    let view = try XCTUnwrap(window.contentView)
    let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
  }

  private var size: CGSize { CGSize(width: 1440, height: 900) }

  // MARK: Editors

  private struct Cast {
    let groceries: CoreKit.Category
    let gifts: CoreKit.Category
    let long: CoreKit.Category
    let cafe: CoreKit.Category
    let alex: Person
    let long_: Person
    let card: PaymentMethod
    let dollars: PaymentMethod
  }

  private func seedCast() throws -> Cast {
    let references = try XCTUnwrap(environment.references)
    let cast = Cast(
      groceries: CoreKit.Category(kind: .expense, name: "Groceries", quality: .good),
      gifts: CoreKit.Category(kind: .expense, name: "Gifts", quality: .neutral),
      long: CoreKit.Category(
        kind: .expense,
        name: "A very long category name that keeps going to see where the line breaks",
        quality: .bad),
      cafe: CoreKit.Category(kind: .expense, name: "Cafes", quality: .neutral),
      alex: Person(name: "Alex", relation: .friend),
      long_: Person(
        name: "Alexandra Konstantinovna Rozhdestvenskaya-Pokrovskaya", relation: .family),
      card: PaymentMethod(name: "Debit card", kind: .card, currency: .rub, isDefault: true),
      dollars: PaymentMethod(name: "Dollar card", kind: .card, currency: .usd))
    for category in [cast.groceries, cast.gifts, cast.long, cast.cafe] {
      try references.save(category)
    }
    try references.save(cast.alex)
    try references.save(cast.long_)
    try references.save(cast.card)
    try references.save(cast.dollars)
    return cast
  }

  private func day(_ offset: Int = 0) -> Date {
    environment.now().addingTimeInterval(TimeInterval(-offset * 86_400))
  }

  /// The operations the editors are shown over, by the name of their picture.
  private func scenarios(_ cast: Cast) -> [(String, TransactionDraft)] {
    func part(
      _ category: CoreKit.Category, _ whole: Int64, for whom: ForWhom = .me,
      person: Person? = nil, owed: Bool = false
    ) -> PartDraft {
      PartDraft(
        categoryId: category.id, quality: category.quality, amount: AmountE4(whole: whole),
        forWhom: whom, forPersonId: whom == .me ? nil : person?.id, reimbursable: owed,
        debtorPersonId: owed ? person?.id : nil)
    }
    func draft(
      _ total: Int64, note: String, parts: [PartDraft], account: PaymentMethod? = nil,
      currency: CurrencyCode = .rub, rate: Decimal? = nil
    ) -> TransactionDraft {
      var draft = TransactionDraft(
        occurredAt: day(), currency: currency, amount: AmountE4(whole: total),
        rate: rate, rateDate: nil, rateSource: rate == nil ? nil : .manual, note: note,
        paymentMethodId: (account ?? cast.card).id)
      draft.parts = parts
      return draft
    }
    return [
      ("plain", draft(1_250, note: "Weekly shop", parts: [part(cast.groceries, 1_250)])),
      (
        "split3",
        draft(
          3_400, note: "Shop and a gift",
          parts: [
            part(cast.groceries, 1_800), part(cast.cafe, 900), part(cast.gifts, 700),
          ])
      ),
      (
        "for-other",
        draft(
          3_400, note: "Dinner for two",
          parts: [
            part(cast.cafe, 1_700),
            part(cast.cafe, 1_700, for: .friends, person: cast.alex, owed: true),
          ])
      ),
      (
        "for-whom",
        draft(
          5_000, note: "Presents",
          parts: [
            part(cast.gifts, 2_000, for: .partner),
            part(cast.gifts, 1_500, for: .family, person: cast.long_),
            part(cast.groceries, 1_500),
          ])
      ),
      (
        "long-names",
        draft(
          4_200, note: "Dinner with a very long description of what exactly was bought today",
          parts: [
            part(cast.long, 2_100, for: .family, person: cast.long_),
            part(cast.long, 2_100, for: .friends, person: cast.long_, owed: true),
          ])
      ),
      (
        "usd",
        draft(
          120, note: "Online order", parts: [part(cast.groceries, 120)], account: cast.dollars,
          currency: .usd, rate: 95)
      ),
    ]
  }

  private func editors(_ language: AppLanguage.Choice, dark: Bool) async throws {
    guard active else { return }
    let run = begin(language, dark: dark)
    let cast = try seedCast()
    try entryBar(run, split: true, cast: cast)
    let transactions = try XCTUnwrap(environment.transactions)
    let tree = CategoryTree([cast.groceries, cast.gifts, cast.long, cast.cafe])
    for (name, draft) in scenarios(cast) {
      let entry = try draft.materialize(rublesConverter: { try AmountE4(decimal: $0.decimal * 95) })
      try transactions.save(entry)
      for (style, width) in [(TransactionEditor.Style.sheet, 760.0), (.inspector, 360.0)] {
        let editor = TransactionEditorModel(entry: entry, environment: environment, tree: tree)
        let window = screenWindow(
          TransactionEditor(editor: editor, style: style) {}, idiom: .mac, width: width,
          height: 900)
        try shoot(window, "editor-\(style == .sheet ? "sheet" : "inspector")-\(name)", run)
      }
    }
    try entryBar(run, split: false)
  }

  /// A new operation: the line with the ↓ panel open over it (the panel scrolls inside the bar, so
  /// its footer is below the picture); and the panel alone, tall enough to show all of it, over
  /// one operation split into parts and over one with a part paid for someone.
  private func entryBar(_ run: Run, split: Bool, cast: Cast? = nil) throws {
    if !split {
      // Taller than the others: the panel gets room to show most of itself.
      let window = mainWindowOpeningPanel(.section(.overview), height: 1_400)
      settle(window, passes: 60)
      try shoot(window, "entry-panel", run)
      return
    }
    let cast = try XCTUnwrap(cast)
    for (name, paid) in [("entry-panel-split", false), ("entry-panel-for-other", true)] {
      let model = EntryDraftModel(environment: environment)
      model.reload()
      model.draft.amount = AmountE4(whole: 3_400)
      model.draft.paymentMethodId = cast.card.id
      model.draft.parts = [
        PartDraft(
          categoryId: cast.groceries.id, quality: .good, amount: AmountE4(whole: 1_800)),
        PartDraft(categoryId: cast.cafe.id, quality: .neutral, amount: AmountE4(whole: 1_600)),
      ]
      if paid {
        model.markLastPartPaidForSomeone()
        model.draft.parts[1].debtorPersonId = cast.alex.id
        model.draft.parts[1].forWhom = .friends
        model.draft.parts[1].forPersonId = cast.alex.id
      }
      let window = screenWindow(
        DetailsPanel(model: model, arrangement: .wide, hasRoomForSegments: true)
          .padding(16)
          .frame(width: 760, height: 900, alignment: .top),
        idiom: .mac, width: 760, height: 900)
      try shoot(window, name, run)
    }
  }

  private func mainWindowOpeningPanel(
    _ selection: SidebarItem, details: Bool = true, height: CGFloat? = nil
  ) -> NSWindow {
    let actions = OperationActions()
    let root =
      AppScenes.root(deps, window: .main, launches: false) { deps in
        MainWindow(deps: deps, actions: actions, opensDetails: details, selection: selection)
      }
      .environment(\.windowWidth, size.width)
      .defaultAppStorage(defaults)
    return place(root, height: height)
  }

  /// A unified window of 1440 × 900, as the main window of the app is.
  private func place<Root: View>(_ root: Root, height: CGFloat? = nil) -> NSWindow {
    let size = CGSize(width: self.size.width, height: height ?? self.size.height)
    // dependencies: the root is built by `AppScenes.root`, which hands them over
    let controller = NSHostingController(rootView: root)
    controller.sceneBridgingOptions = [.toolbars]
    let window = NSWindow(
      contentRect: CGRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    window.setContentSize(size)
    window.toolbarStyle = .unified
    window.orderFront(nil)
    windows.append(window)
    return window
  }

  // MARK: The sections, accounts, debts and the rest

  private func main(_ language: AppLanguage.Choice, dark: Bool) throws {
    guard active else { return }
    let run = begin(language, dark: dark)
    let snapshot = try XCTUnwrap(compute.snapshot)
    for section in MainWindow.Section.allCases {
      let window = mainWindowOpeningPanel(.section(section), details: false)
      try shoot(window, "section-\(section.rawValue)", run)
    }
    // Accounts: the whole, a group and an account, as the sidebar opens them.
    try shoot(
      mainWindowOpeningPanel(.allAccounts, details: false), "accounts-all", run)
    if let group = snapshot.dataset.accountGroups.first {
      try shoot(
        mainWindowOpeningPanel(.group(group.id), details: false), "accounts-group", run)
    }
    if let account = snapshot.dataset.paymentMethods.first(where: { $0.currency == .rub }) {
      try shoot(
        mainWindowOpeningPanel(.account(account.id), details: false), "accounts-account", run)
    }
    if let bank = snapshot.dataset.banks.first {
      try shoot(mainWindowOpeningPanel(.bank(bank.id), details: false), "accounts-bank", run)
    }
    // A debt's card: the Debts screen opens the one it is told to.
    if let debt = snapshot.dataset.debts.first {
      DebtsView.debtToOpen = debt.id
      try shoot(
        mainWindowOpeningPanel(.section(.debts), details: false), "debts-card", run)
      DebtsView.debtToOpen = nil
    }
    if let event = snapshot.dataset.events.first {
      let window = screenWindow(
        TripSummaryView(eventId: event.id), idiom: .mac, width: 760, height: 900)
      try shoot(window, "trip-summary", run)
    }
    let whatIf = screenWindow(
      WhatIfWindow(deps: deps), idiom: .mac, width: 1_120, height: 760)
    try shoot(whatIf, "what-if", run)
  }

  private func settings(_ language: AppLanguage.Choice, dark: Bool) throws {
    guard active else { return }
    let run = begin(language, dark: dark)
    for section in SettingsSection.allCases {
      SettingsNavigation.shared.query = ""
      SettingsNavigation.shared.section = section
      let root = AppScenes.root(deps, window: .settings, launches: false) {
        SettingsView(deps: $0)
      }
      let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: SettingsChromeMetrics.windowSize),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      window.contentViewController = NSHostingController(rootView: root)
      window.setContentSize(SettingsChromeMetrics.windowSize)
      window.isReleasedWhenClosed = false
      window.orderFront(nil)
      windows.append(window)
      try shoot(window, "settings-\(section.rawValue)", run)
    }
    SettingsNavigation.shared.section = .general
  }
}
