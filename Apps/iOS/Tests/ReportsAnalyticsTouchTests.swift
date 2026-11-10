import AppCore
import AppDatabase
import SwiftUI
import UIKit
import XCTest

@testable import OhMyMoney

/// «Отчёты» and «Аналитика» drawn at the sizes of their frames — the phone at 440 × 956
/// (6:111711, 5:6837), the tablet's content beside its sidebar at 1116 × 1024 (6:155364,
/// 5:77469) — on six months of synthetic data, with a picture of each kept with the result to lay
/// beside the frame. The tablet's frame is drawn on the phone the tests run on by naming its
/// idiom (`layoutIdiom`).
@MainActor
final class ReportsAnalyticsTouchTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private var languageBefore: AppLanguage.Choice?
  private var windows: [UIWindow] = []

  static let phoneSize = CGSize(width: 440, height: 956)
  /// 1366 less the sidebar of 250.
  static let padSize = CGSize(width: 1_116, height: 1_024)

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-touch-reports-\(UUID().uuidString)", isDirectory: true)
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
    let today = environment.today
    let set = SampleDataGenerator(seed: 20_261_110).generate(
      months: 6, endingOn: today, calendar: .system, language: "ru"
    ).withEveryFeature(seed: 20_261_110, calendar: .system, language: "ru")
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
    compute.applyLight(
      DataSnapshot.build(
        dataset: dataset, calendar: .system, today: today,
        context: SnapshotContext(rubPerUnit: [.usd: 95, .eur: 103]),
        version: DataVersion(load: 0)))
  }

  override func tearDown() async throws {
    for window in windows {
      window.rootViewController = nil
      window.isHidden = true
    }
    windows = []
    if let languageBefore { environment?.language.choice = languageBefore }
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private var deps: AppDependencies {
    AppDependencies(environment: environment, store: store, compute: compute)
  }

  private func host<Content: View>(_ content: Content, size: CGSize) -> UIWindow {
    let controller = UIHostingController(rootView: content.appDependencies(deps))
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
    window.frame = CGRect(origin: .zero, size: size)
    window.windowLevel = .alert + 1
    controller.safeAreaRegions = []
    window.rootViewController = controller
    window.isHidden = false
    controller.view.frame = window.bounds
    windows.append(window)
    settle(window)
    return window
  }

  private func settle(_ window: UIWindow, passes: Int = 40) {
    for _ in 0..<passes {
      window.layoutIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
  }

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

  // MARK: Reports

  private func reports(_ idiom: LayoutIdiom) -> some View {
    ReportsWindow(deps: deps).environment(\.layoutIdiom, idiom)
  }

  func testThePhonesReportsAtTheSizeOfItsFrame() throws {
    let window = host(reports(.phone), size: Self.phoneSize)
    attachPicture(of: window, named: "Reports iPhone 440 × 956 (Figma 6:111711)")
  }

  func testTheTabletsReportsAtTheSizeOfItsFrame() throws {
    let window = host(reports(.pad), size: Self.padSize)
    attachPicture(of: window, named: "Reports iPad 1116 × 1024 (Figma 6:155364)")
  }

  // MARK: Analytics

  private func analytics(_ idiom: LayoutIdiom) -> some View {
    AnalyticsWindow(deps: deps).environment(\.layoutIdiom, idiom)
  }

  func testThePhonesAnalyticsAtTheSizeOfItsFrame() throws {
    let window = host(analytics(.phone), size: Self.phoneSize)
    attachPicture(of: window, named: "Analytics iPhone 440 × 956 (Figma 5:6837)")
  }

  func testTheTabletsAnalyticsAtTheSizeOfItsFrame() throws {
    let window = host(analytics(.pad), size: Self.padSize)
    attachPicture(of: window, named: "Analytics iPad 1116 × 1024 (Figma 5:77469)")
  }
}
