import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The main screens of the Mac — Overview, Operations, Planning, Debts, Capital, the editor of
/// an operation with parts and the panel that splits a sum — laid out in a 1440 × 900 window over
/// a synthetic book, in three themes and in light and dark, compared with the pictures kept in
/// `Snapshots/` (`ScreenSnapshots`). The book is generated up to a fixed day, so nothing here
/// depends on today's date.
///
/// To record the references again: empty `<container>/Data/tmp/recorded-snapshots` (the Debug
/// host's container), run `make test-one T=OhMyMoneyTests/MacScreenSnapshotTests` with
/// `TEST_RUNNER_OHMYMONEY_RECORD_SNAPSHOTS=1`, copy `mac-*.png` from that folder into
/// `Apps/macOS/Tests/Snapshots/` (the host is sandboxed and cannot write into the sources) and
/// look at the pictures before committing.
@MainActor
final class MacScreenSnapshotTests: SectionFigmaHarness {
  private var themeBefore: ThemeID?

  override func setUp() async throws {
    try await super.setUp()
    themeBefore = environment.theme.themeID
    environment.now = { ScreenSnapshots.fixedNow }
    compute = ComputeStore(
      calendar: .system, clock: FixedClock(ScreenSnapshots.fixedNow), rebuildsInline: true)
    await runPipeline()
  }

  /// The app's own pipeline over the synthetic book, run to its end: a block that waits for the
  /// full run would otherwise show «Считается, ожидайте» in the picture.
  private func runPipeline() async {
    let snapshot = book(today: environment.today)
    compute.attach(
      ComputeSources(
        loadData: { mark, today, _ in
          DataSnapshot.build(
            dataset: snapshot.dataset, calendar: .system, today: today,
            context: SnapshotContext(rubPerUnit: [.usd: 95, .eur: 103]),
            version: DataVersion(load: mark))
        },
        refineRates: { RefinementResult() }),
      changes: nil)
    compute.run()
    for _ in 0..<400 where !compute.states.run.hasEnded {
      try? await Task.sleep(for: .milliseconds(50))
    }
  }

  override func tearDown() async throws {
    if let themeBefore { environment?.theme.themeID = themeBefore }
    try await super.tearDown()
  }

  override func book(today: DateOnly) -> DataSnapshot {
    let set = SampleDataGenerator(seed: 20_261_110).generate(
      months: 6, endingOn: today, calendar: .system, language: "en"
    ).withEveryFeature(seed: 20_261_110, calendar: .system, language: "en")
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

  func testTheme01Light() async throws { try await run(theme: "01", dark: false) }
  func testTheme01Dark() async throws { try await run(theme: "01", dark: true) }
  func testTheme09Light() async throws { try await run(theme: "09", dark: false) }
  func testTheme09Dark() async throws { try await run(theme: "09", dark: true) }
  func testTheme15Light() async throws { try await run(theme: "15", dark: false) }
  func testTheme15Dark() async throws { try await run(theme: "15", dark: true) }

  /// The themes the runs above cover are the ones `ScreenSnapshots` names.
  func testTheRunsCoverTheNamedThemes() {
    XCTAssertEqual(ScreenSnapshots.themeNumbers, ["01", "09", "15"])
    for number in ScreenSnapshots.themeNumbers {
      XCTAssertNotNil(ThemeID(rawValue: number))
    }
  }

  private func run(theme number: String, dark: Bool) async throws {
    executionTimeAllowance = 240
    environment.language.choice = .english
    environment.theme.themeID = try XCTUnwrap(ThemeID(rawValue: number))
    let stem = "mac-\(number)-\(dark ? "dark" : "light")"
    for section in [
      MainWindow.Section.overview, .operations, .planning, .debts, .capital,
    ] {
      let window = mainWindow(section, width: 1_440, height: 900)
      try await check(window, "\(stem)-\(section.rawValue)", dark: dark)
    }
    try await checkEditor(stem: stem, dark: dark)
  }

  /// The editor of an operation that has three parts, and the panel of the entry bar with a sum split in two.
  private func checkEditor(stem: String, dark: Bool) async throws {
    let references = try XCTUnwrap(environment.references)
    let groceries = CoreKit.Category(kind: .expense, name: "Groceries", quality: .good)
    let cafe = CoreKit.Category(kind: .expense, name: "Cafes", quality: .neutral)
    let gifts = CoreKit.Category(kind: .expense, name: "Gifts", quality: .neutral)
    let card = PaymentMethod(name: "Debit card", kind: .card, currency: .rub, isDefault: true)
    for category in [groceries, cafe, gifts] { try references.save(category) }
    try references.save(card)
    func part(_ category: CoreKit.Category, _ whole: Int64) -> PartDraft {
      PartDraft(
        categoryId: category.id, quality: category.quality, amount: AmountE4(whole: whole))
    }
    var draft = TransactionDraft(
      occurredAt: environment.now(), currency: .rub, amount: AmountE4(whole: 3_400),
      rate: nil, rateDate: nil, rateSource: nil, note: "Shop and a gift",
      paymentMethodId: card.id)
    draft.parts = [part(groceries, 1_800), part(cafe, 900), part(gifts, 700)]
    let entry = try draft.materialize(rublesConverter: { try AmountE4(decimal: $0.decimal * 95) })
    try XCTUnwrap(environment.transactions).save(entry)
    let editor = TransactionEditorModel(
      entry: entry, environment: environment, tree: CategoryTree([groceries, cafe, gifts]))
    let window = screenWindow(
      TransactionEditor(editor: editor, style: .sheet) {}, idiom: .mac, width: 760, height: 900)
    try await check(window, "\(stem)-editor", dark: dark)

    // The panel of the entry bar with the same sum split into two parts.
    let model = EntryDraftModel(environment: environment)
    model.reload()
    model.draft.amount = AmountE4(whole: 3_400)
    model.draft.paymentMethodId = card.id
    model.draft.parts = [part(groceries, 1_800), part(cafe, 1_600)]
    let panel = screenWindow(
      DetailsPanel(model: model, arrangement: .wide, hasRoomForSegments: true)
        .padding(16)
        .frame(width: 760, height: 900, alignment: .top),
      idiom: .mac, width: 760, height: 900)
    try await check(panel, "\(stem)-parts", dark: dark)
  }

  // MARK: Pictures

  /// Draws the window in the scheme of the run, waits until its picture has stood still, then
  /// compares it with the reference; the window is closed after, so a run holds few at once.
  private func check(_ window: NSWindow, _ name: String, dark: Bool) async throws {
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let png = try stablePicture(of: window)
    ScreenSnapshots.verify(
      png: png, name: name, width: ScreenSnapshots.ReferenceWidth.mac, test: self)
    window.contentViewController = nil
    window.contentView = nil
    window.close()
    windows.removeAll { $0 === window }
  }

  /// A window under load lays out late: the picture is taken again until two in a row agree.
  private func stablePicture(of window: NSWindow) throws -> Data {
    var last: ScreenSnapshots.Pixels?
    var latest = Data()
    for _ in 0..<15 {
      settle(window, passes: 15)
      latest = try picture(of: window)
      let pixels = ScreenSnapshots.pixels(
        fromPNG: latest, width: ScreenSnapshots.ReferenceWidth.mac)
      if let pixels, let last, last.height == pixels.height,
        ScreenSnapshots.compare(pixels, with: last, threshold: 4).differing == 0
      {
        return latest
      }
      last = pixels
    }
    return latest
  }

  /// What the window shows, glass included: the compositor's picture of the window itself
  /// (glass is drawn by the window server, so a plain `cacheDisplay` leaves it out). The call is
  /// looked up by name — the SDK marks it obsolete — and the view's own drawing is the fallback.
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
}
