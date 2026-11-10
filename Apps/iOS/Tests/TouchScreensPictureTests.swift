import AppCore
import AppDatabase
import SwiftUI
import UIKit
import XCTest

@testable import OhMyMoney

/// «Обзор» and «Операции» drawn at the sizes of their frames — the phone at 440 × 956, the
/// tablet's content beside its sidebar at 1116 × 1024 — on six months of synthetic data, with a
/// picture of each kept with the result to lay beside the frame. The tablet's frame is drawn on
/// the phone the tests run on by naming its idiom (`layoutIdiom`).
@MainActor
final class TouchScreensPictureTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private var languageBefore: AppLanguage.Choice?
  private var layoutBefore: OverviewLayout?
  private var windows: [UIWindow] = []

  /// The tiles of the master frames, in their order.
  static let frameTiles: [OverviewTile] = [
    .monthToDate, .freeMoney, .canSave, .owedToMe, .iOwe, .upcoming, .limits, .monthRest,
  ]

  static let phoneSize = CGSize(width: 440, height: 956)
  /// 1366 less the sidebar of 250.
  static let padSize = CGSize(width: 1_116, height: 1_024)

  override func setUp() async throws {
    OverviewFiguresStore.shared.reset()
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-touch-figma-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
    compute = ComputeStore(calendar: .system, rebuildsInline: true)
    languageBefore = environment.language.choice
    environment.language.choice = .russian
    layoutBefore = environment.overviewLayout
    var layout = OverviewLayout.standard.showingOnly(Self.frameTiles)
    if let paired = layout.pairing(.iOwe, with: .owedToMe) { layout = paired }
    environment.overviewLayout = layout
    loadSnapshot()
  }

  override func tearDown() async throws {
    for window in windows {
      window.rootViewController = nil
      window.isHidden = true
    }
    windows = []
    if let languageBefore { environment?.language.choice = languageBefore }
    if let layoutBefore { environment?.overviewLayout = layoutBefore }
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private func loadSnapshot() {
    let today = environment.today
    let set = SampleDataGenerator(seed: 20_261_110).generate(
      months: 6, endingOn: today, calendar: .system, language: "ru"
    ).withEveryFeature(seed: 20_261_110, calendar: .system, language: "ru")
    // Three operations of this week without a category: «Что сделать сейчас» has «Разобрать»,
    // as the frames draw it.
    var waiting = 0
    let week = today.adding(days: -(DoNowSources.reviewDays - 1))
    let entries = set.entries.map { entry -> TransactionEntry in
      let day = CalendarContext.system.day(of: entry.transaction.occurredAt)
      guard waiting < 3, entry.transaction.deletedAt == nil, day >= week, day <= today,
        !entry.parts.isEmpty
      else { return entry }
      waiting += 1
      var entry = entry
      entry.parts = entry.parts.map { part in
        var part = part
        part.categoryId = nil
        return part
      }
      return entry
    }
    let dataset = Dataset(
      entries: entries, links: set.links, categories: set.categories, people: set.people,
      places: set.places, events: set.events, paymentMethods: set.paymentMethods,
      debts: set.debts, goals: set.goals, planning: set.planningBook,
      settings: AnalyticsSettings(cashbackCategoryId: set.cashbackCategoryId),
      transfers: set.transfers, accountGroups: set.accountGroups,
      accountSettings: AccountSettings(storedValues: set.settings), cards: set.cards,
      cashbackRules: set.cashbackRules, banks: set.banks, assets: set.assets,
      assetValuations: set.assetValuations,
      capitalSettings: CapitalSettings(storedValues: set.settings))
    compute.applyLight(
      DataSnapshot.build(
        dataset: dataset, calendar: .system, today: today,
        context: SnapshotContext(rubPerUnit: [.usd: 95, .eur: 103]),
        version: DataVersion(load: 0)))
  }

  private var deps: AppDependencies {
    AppDependencies(environment: environment, store: store, compute: compute)
  }

  // MARK: Hosting

  private func host<Content: View>(_ content: Content, size: CGSize) -> UIWindow {
    let controller = UIHostingController(rootView: content.appDependencies(deps))
    // A window draws only in a scene: the test host's own.
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
    window.frame = CGRect(origin: .zero, size: size)
    window.windowLevel = .alert + 1
    // The frame alone decides the room: the simulator's screen and its safe area do not.
    controller.safeAreaRegions = []
    window.rootViewController = controller
    window.isHidden = false
    controller.view.frame = window.bounds
    windows.append(window)
    settle(window)
    return window
  }

  private func settle(_ window: UIWindow, passes: Int = 30) {
    for _ in 0..<passes {
      window.layoutIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
  }

  /// A picture of the window, kept with the result of the test.
  private func attachPicture(of window: UIWindow, named name: String) {
    let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
    let image = renderer.image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let attachment = XCTAttachment(image: image)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// What the content asks for at the width of the frame is no wider than the frame. A scrolling
  /// page reports the width it was offered, so this only catches a page that asks for more; the
  /// numbers themselves are checked in `TouchScreensFigmaTests`, the picture is for the eye.
  private func assertFits(
    _ window: UIWindow, _ size: CGSize, file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let controller = try XCTUnwrap(
      window.rootViewController as? any UIHostingControllerSizing, file: file, line: line)
    let asked = controller.fittingSize(
      in: CGSize(width: size.width, height: .greatestFiniteMagnitude))
    XCTAssertLessThanOrEqual(asked.width, size.width + 0.5, file: file, line: line)
  }

  // MARK: Overview

  private func overview(idiom: LayoutIdiom, columns: Int?) -> some View {
    let screen = OverviewScreen()
    let title = environment.language("section.overview")
    let trailing: AnyView =
      idiom == .pad
      ? AnyView(PadOverviewTitleActions(deps: deps, screen: screen))
      : AnyView(
        OverviewTitleActions(deps: deps, router: PhoneRouter(), screen: screen))
    return OverviewView(actions: OperationActions(), screen: screen)
      .environment(\.overviewEditsInChrome, true)
      .environment(\.overviewTitleRow, OverviewTitleRow(title: title, trailing: trailing))
      .environment(\.overviewColumnsOverride, columns)
      .environment(\.layoutIdiom, idiom)
  }

  func testThePhonesOverviewAtTheSizeOfItsFrame() throws {
    let window = host(overview(idiom: .phone, columns: 1), size: Self.phoneSize)
    attachPicture(of: window, named: "Overview iPhone 440 × 956 (Figma 5:8097)")
    try assertFits(window, Self.phoneSize)
  }

  func testTheTabletsOverviewAtTheSizeOfItsFrame() throws {
    let window = host(overview(idiom: .pad, columns: 3), size: Self.padSize)
    attachPicture(of: window, named: "Overview iPad 1116 × 1024 (Figma 5:76205)")
    try assertFits(window, Self.padSize)
  }

  /// The tablet's Split View ½ (564:97540): 678 pt, two tiles in a row.
  func testTheTabletsSplitViewOverviewAtTheSizeOfItsFrame() throws {
    let size = CGSize(width: 678, height: 1_024)
    let window = host(overview(idiom: .pad, columns: 2), size: size)
    attachPicture(of: window, named: "Overview iPad Split View 678 × 1024 (Figma 564:97540)")
    try assertFits(window, size)
  }

  /// Slide Over, 320 pt, one tile in a row: no frame; the title row keeps «Изменить» alone.
  func testTheTabletsSlideOverOverviewFitsItsWidth() throws {
    let size = CGSize(width: 320, height: 900)
    let window = host(overview(idiom: .pad, columns: 1), size: size)
    attachPicture(of: window, named: "Overview iPad Slide Over 320 × 900")
    try assertFits(window, size)
  }

  // MARK: Operations

  private func operations(idiom: LayoutIdiom) -> some View {
    OperationsScreen(deps: deps, actions: OperationActions(), state: OperationsScreenState())
      .environment(\.layoutIdiom, idiom)
  }

  func testThePhonesOperationsAtTheSizeOfItsFrame() throws {
    let window = host(operations(idiom: .phone), size: Self.phoneSize)
    settle(window, passes: 40)
    attachPicture(of: window, named: "Operations iPhone 440 × 956 (Figma 5:7974)")
    try assertFits(window, Self.phoneSize)
  }

  func testTheTabletsOperationsAtTheSizeOfItsFrame() throws {
    let window = host(operations(idiom: .pad), size: Self.padSize)
    settle(window, passes: 40)
    attachPicture(of: window, named: "Operations iPad 1116 × 1024 (Figma 5:76343)")
    try assertFits(window, Self.padSize)
  }
}

/// The size a hosting controller asks for, whatever the type of its view.
@MainActor
private protocol UIHostingControllerSizing {
  func fittingSize(in size: CGSize) -> CGSize
}

extension UIHostingController: UIHostingControllerSizing {
  fileprivate func fittingSize(in size: CGSize) -> CGSize { sizeThatFits(in: size) }
}
