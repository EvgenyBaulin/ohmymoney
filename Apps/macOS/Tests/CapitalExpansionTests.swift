import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// «Из чего складывается» folds every block into one row: which blocks there are, what each
/// row says (total and share), that all are folded at first, and how what the owner opened is
/// kept on this Mac (`capital.expanded`) — ids that name no block are dropped.
@MainActor
final class CapitalExpansionTests: XCTestCase {
  private let sber = UUID()
  private let tinkoff = UUID()
  private let wise = UUID()
  private let deposit = UUID()
  private let dacha = UUID()
  private let dachaGroup = UUID()
  private let car = UUID()
  private let anya = UUID()
  private let mortgage = UUID()

  private func rub(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }

  private func line(
    _ source: CapitalLine.Source, _ group: CapitalLine.Group, _ name: String, _ whole: Int64?,
    groupId: UUID? = nil, kind: AssetKind? = nil, issue: CapitalLine.Issue? = nil
  ) -> CapitalLine {
    CapitalLine(
      source: source, group: group, name: name, currency: .rub,
      amount: whole.map { rub($0) }, amountRub: issue == nil ? whole.map { rub($0) } : nil,
      accountGroupId: groupId, assetKind: kind, issue: issue)
  }

  private var model: CapitalViewModel {
    let have = [
      line(.account(sber), .accounts, "Сбер", 300_000),
      line(.account(tinkoff), .accounts, "Тинькофф", -50_000),
      line(.account(wise), .accounts, "Wise", nil, issue: .unanchored),
      line(.account(deposit), .deposits, "Вклад", 500_000),
      line(.account(dacha), .outOfSummary, "Касса дачи", 100_000, groupId: dachaGroup),
      line(.asset(car), .assets, "Машина", 1_000_000, kind: .vehicle),
      line(.debt(anya), .owedToMe, "Аня", 100_000),
    ]
    let owe = [line(.debt(mortgage), .iOwe, "Ипотека", 1_500_000)]
    let now = CapitalPoint(day: DateOnly(year: 2026, month: 10, day: 11), isNow: true)
    return CapitalViewModel(
      capital: CapitalSnapshot(
        points: [now], now: now, breakdown: CapitalBreakdown(have: have, owe: owe),
        changeThisMonth: nil),
      accountGroups: [AccountGroup(id: dachaGroup, name: "Дача", inSummary: false)])
  }

  private func defaults() throws -> UserDefaults {
    try XCTUnwrap(UserDefaults(suiteName: "ohmymoney.tests.capital.expanded.\(UUID())"))
  }

  // MARK: - The blocks

  func testTheBlocksOfBothColumns() {
    let model = model
    XCTAssertEqual(
      model.haveGroups.map(\.id),
      [
        "accounts", "deposits", "outOfSummary.\(dachaGroup.uuidString)", "assets.vehicle",
        "owedToMe",
      ])
    XCTAssertEqual(model.oweGroups.map(\.id), ["iOwe"])
    for id in (model.haveGroups + model.oweGroups).map(\.id) {
      XCTAssertTrue(CapitalExpansion.isGroupId(id), id)
    }
  }

  /// The folded row says what its rows add up to — the rows without a figure add nothing, the
  /// account below zero takes its money off.
  func testTheTotalOfABlockIsTheSumOfItsRows() {
    for group in model.haveGroups + model.oweGroups {
      XCTAssertEqual(
        group.totalRub, group.rows.reduce(.zero) { $0 + ($1.line.amountRub ?? .zero) }, group.id)
    }
    XCTAssertEqual(model.haveGroups.first?.totalRub, rub(250_000))
    XCTAssertEqual(model.haveGroups.first?.rows.count, 3)
  }

  /// The share of a block is the shares of its rows added up: the column still makes 100 %.
  func testTheShareOfABlockIsTheSharesOfItsRows() throws {
    let model = model
    for group in model.haveGroups {
      let shares = group.rows.compactMap(\.shareBp)
      XCTAssertEqual(group.shareBp, shares.isEmpty ? nil : shares.reduce(0, +), group.id)
    }
    XCTAssertEqual(model.haveGroups.compactMap(\.shareBp).reduce(0, +), Shares.whole)
    XCTAssertEqual(model.oweGroups.first?.shareBp, Shares.whole)
    // Сбер 300,000 of 2,000,000 positive: 15 %; Тинькофф below zero and Wise without a figure
    // have no share.
    XCTAssertEqual(model.haveGroups.first?.shareBp, 1_500)
  }

  func testABlockWithoutAFigureHasNoShare() {
    let lone = CapitalViewModel.groups(
      [line(.account(wise), .accounts, "Wise", nil, issue: .withoutRate)],
      order: [.accounts], groupNames: [:])
    XCTAssertEqual(lone.count, 1)
    XCTAssertNil(lone.first?.shareBp)
    XCTAssertEqual(lone.first?.totalRub, .zero)
  }

  // MARK: - Folded and opened

  func testEveryBlockIsFoldedAtFirst() throws {
    let expansion = CapitalExpansion.stored(in: try defaults())
    for group in model.haveGroups + model.oweGroups {
      XCTAssertFalse(expansion.isOpen(group.id), group.id)
    }
    XCTAssertFalse(CapitalExpansion().isOpen("accounts"))
  }

  func testTogglingOpensAndFolds() {
    var expansion = CapitalExpansion()
    expansion.toggle("accounts")
    XCTAssertTrue(expansion.isOpen("accounts"))
    XCTAssertFalse(expansion.isOpen("deposits"))
    expansion.toggle("accounts")
    XCTAssertFalse(expansion.isOpen("accounts"))
    expansion.toggle("nonsense")
    XCTAssertTrue(expansion.open.isEmpty)
  }

  func testWhatIsOpenIsKeptOnThisMac() throws {
    let defaults = try defaults()
    var expansion = CapitalExpansion()
    let dacha = "outOfSummary.\(dachaGroup.uuidString)"
    expansion.toggle("deposits")
    expansion.toggle(dacha)
    expansion.store(in: defaults)
    XCTAssertEqual(CapitalExpansion.storageKey, "capital.expanded")
    XCTAssertEqual(defaults.stringArray(forKey: "capital.expanded"), [dacha, "deposits"].sorted())
    let read = CapitalExpansion.stored(in: defaults)
    XCTAssertEqual(read.open, ["deposits", dacha])
    var folded = read
    folded.toggle("deposits")
    folded.toggle(dacha)
    folded.store(in: defaults)
    XCTAssertEqual(defaults.stringArray(forKey: "capital.expanded"), [])
    XCTAssertTrue(CapitalExpansion.stored(in: defaults).open.isEmpty)
  }

  func testIdsThatNameNoBlockAreDropped() throws {
    let defaults = try defaults()
    defaults.set(
      [
        "accounts", "iOwe", "owedToMe", "outOfSummary", "outOfSummary.\(dachaGroup.uuidString)",
        "assets.realty", "assets.yacht", "outOfSummary.not-a-uuid", "accounts.extra", "bank",
        "", "deposits.",
      ], forKey: CapitalExpansion.storageKey)
    XCTAssertEqual(
      CapitalExpansion.stored(in: defaults).open,
      [
        "accounts", "iOwe", "owedToMe", "outOfSummary", "outOfSummary.\(dachaGroup.uuidString)",
        "assets.realty",
      ])
    defaults.set("accounts", forKey: CapitalExpansion.storageKey)
    XCTAssertTrue(CapitalExpansion.stored(in: defaults).open.isEmpty, "not a list")
  }

  /// The row speaks its state and what a press does, in both languages.
  func testTheWordsOfAFoldedRow() {
    func text(_ key: String, _ choice: AppLanguage.Choice) -> String {
      let environment = AppEnvironment()
      environment.language.choice = choice
      return CapitalText.t(key, environment)
    }
    let folded = CapitalBreakdownSection.stateKey(isOpen: false)
    let opened = CapitalBreakdownSection.stateKey(isOpen: true)
    XCTAssertEqual(text(folded, .russian), "свёрнуто")
    XCTAssertEqual(text(opened, .russian), "развёрнуто")
    XCTAssertEqual(text(CapitalBreakdownSection.actionKey(isOpen: false), .russian), "Развернуть")
    XCTAssertEqual(text(CapitalBreakdownSection.actionKey(isOpen: true), .russian), "Свернуть")
    XCTAssertEqual(text(folded, .english), "collapsed")
    XCTAssertEqual(text(CapitalBreakdownSection.actionKey(isOpen: false), .english), "Expand")
  }
}

/// «Капитал» in a window: the blocks come folded, a press on a block lists its rows and is
/// kept in `capital.expanded`, and the screen is laid out with every dependency it needs.
@MainActor
final class CapitalExpansionWindowTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var windows: [NSWindow] = []
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private var expandedBefore: Any?
  private let car = Asset(name: "Car", kind: .vehicle)

  override func setUp() async throws {
    expandedBefore = UserDefaults.standard.object(forKey: CapitalExpansion.storageKey)
    UserDefaults.standard.removeObject(forKey: CapitalExpansion.storageKey)
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-capital-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    Logbook.shared.open(
      directory: directory.appendingPathComponent("Logs", isDirectory: true), threshold: .debug)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
    compute = ComputeStore(calendar: .system, rebuildsInline: true)
  }

  override func tearDown() async throws {
    for window in windows {
      window.contentViewController = nil
      window.close()
    }
    windows = []
    Logbook.shared.close()
    if let environment { await environment.close() }
    if let expandedBefore {
      UserDefaults.standard.set(expandedBefore, forKey: CapitalExpansion.storageKey)
    } else {
      UserDefaults.standard.removeObject(forKey: CapitalExpansion.storageKey)
    }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private func settle(_ passes: Int = 10) {
    for _ in 0..<passes { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
  }

  private func snapshot() -> DataSnapshot {
    let valued = AssetValuation(
      assetId: car.id, day: CalendarContext.system.adding(days: -40, to: environment.today),
      valueE4: AmountE4(whole: 900_000))
    return DataSnapshot.build(
      dataset: Dataset(assets: [car], assetValuations: [valued]),
      calendar: .system, today: environment.today, context: SnapshotContext(),
      version: DataVersion(load: 0))
  }

  private func capitalWindow() -> NSWindow {
    let deps = AppDependencies(environment: environment, store: store, compute: compute)
    let root = AppScenes.root(deps, window: .main, launches: false) { deps in
      MainWindow(
        deps: deps, actions: OperationActions(), opensDetails: false,
        selection: .section(.capital))
    }
    .environment(\.windowWidth, 980)
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 980, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    // dependencies: handed by `AppScenes.root` above.
    window.contentViewController = NSHostingController(rootView: root)
    window.orderFront(nil)
    windows.append(window)
    settle(20)
    return window
  }

  private var missingDependencies: Bool {
    Logbook.shared.lines().contains { $0.contains("dependencies.missing") }
  }

  func testTheScreenIsLaidOutWithItsDependencies() {
    compute.applyLight(snapshot())
    let window = capitalWindow()
    window.setContentSize(CGSize(width: 700, height: 600))
    settle()
    XCTAssertFalse(missingDependencies)
  }

  func testABlockComesFoldedAndOpensOnAPress() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    compute.applyLight(snapshot())
    let window = capitalWindow()
    let block = "capital.group.assets.vehicle"
    let row = "capital.row.asset.\(car.id)"
    let button = try XCTUnwrap(WindowAccessibility.element(identified: block, in: window))
    XCTAssertNil(WindowAccessibility.element(identified: row, in: window), "folded at first")
    WindowAccessibility.press(button)
    settle()
    XCTAssertNotNil(WindowAccessibility.element(identified: row, in: window), "opened")
    XCTAssertEqual(
      UserDefaults.standard.stringArray(forKey: CapitalExpansion.storageKey), ["assets.vehicle"])

    // A new window reads what is open.
    let again = capitalWindow()
    XCTAssertNotNil(WindowAccessibility.element(identified: row, in: again), "kept")
    let pressAgain = try XCTUnwrap(WindowAccessibility.element(identified: block, in: again))
    WindowAccessibility.press(pressAgain)
    settle()
    XCTAssertNil(WindowAccessibility.element(identified: row, in: again), "folded again")
    XCTAssertEqual(UserDefaults.standard.stringArray(forKey: CapitalExpansion.storageKey), [])
  }
}
