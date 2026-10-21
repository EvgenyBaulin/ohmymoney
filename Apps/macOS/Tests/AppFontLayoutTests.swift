import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// «Очень крупный» in the narrowest main window: Overview, «Операции», Planning, the ↓ panel and
/// the form at the right, in Russian and in English. The window never gets narrower than its
/// content asks for (as the scene's), that narrowest window still fits a screen of 1024 points,
/// and no control of AppKit on view stands past its edges where it did not at «Обычный».
@MainActor
final class AppFontLayoutTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var directory: URL!
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var windows: [NSWindow] = []
  private var dataDirectoryBefore: String?
  private var entryStyleBefore: Any?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    entryStyleBefore = UserDefaults.standard.object(forKey: AppEnvironment.entryStyleKey)
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-fonts-\(UUID().uuidString)", isDirectory: true)
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
    compute.onSnapshot = { [store] snapshot in store?.show(snapshot.ledger) }
    suiteName = "ohmymoney-fonts-\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    seed()
  }

  override func tearDown() async throws {
    for window in windows {
      window.contentViewController = nil
      window.close()
    }
    windows = []
    defaults?.removePersistentDomain(forName: suiteName)
    if let entryStyleBefore {
      UserDefaults.standard.set(entryStyleBefore, forKey: AppEnvironment.entryStyleKey)
    } else {
      UserDefaults.standard.removeObject(forKey: AppEnvironment.entryStyleKey)
    }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private func seed() {
    let food = CoreKit.Category(kind: .expense, name: "Продукты и всё для дома")
    let entries = (0..<30).map { day -> TransactionEntry in
      let id = UUID()
      let when = Date().addingTimeInterval(TimeInterval(-86_400 * (day % 25)))
      let amount = AmountE4(whole: Int64(1_000 + day * 1_237))
      let part = TransactionPart(
        transactionId: id, categoryId: food.id, quality: .neutral, qualitySource: .category,
        amountE4: amount)
      return TransactionEntry(
        transaction: Transaction(
          id: id, kind: .expense, occurredAt: when, amountE4: amount,
          note: "Покупка номер \(day) в большом магазине", createdAt: when, updatedAt: when),
        parts: [part])
    }
    compute.applyLight(
      DataSnapshot.build(
        dataset: Dataset(entries: entries, categories: [food]), calendar: .system,
        today: environment.today, context: SnapshotContext(), version: DataVersion(load: 0)))
  }

  /// A main window asked to be `width` wide; AppKit widens it to what its content needs.
  private func makeWindow(
    width: CGFloat, selection: SidebarItem, opensDetails: Bool
  ) -> NSWindow {
    let deps = AppDependencies(environment: environment, store: store, compute: compute)
    let root = AppScenes.root(deps, window: .main, launches: false) { deps in
      MainWindow(deps: deps, opensDetails: opensDetails, selection: selection)
    }
    .environment(\.windowWidth, width)
    .defaultAppStorage(defaults)
    let controller = NSHostingController(rootView: root)
    controller.sceneBridgingOptions = [.toolbars]
    // As the scene does: the window is never narrower than its content asks for.
    controller.sizingOptions = [.minSize]
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: width, height: 700),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    window.setContentSize(CGSize(width: width, height: 700))
    window.toolbarStyle = .unified
    window.orderFront(nil)
    windows.append(window)
    return window
  }

  private func settle(_ window: NSWindow) {
    for _ in 0..<30 {
      window.updateConstraintsIfNeeded()
      window.layoutIfNeeded()
      window.displayIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
  }

  private static func controls(in view: NSView) -> [NSControl] {
    view.subviews.flatMap { subview -> [NSControl] in
      ((subview as? NSControl).map { [$0] } ?? []) + controls(in: subview)
    }
  }

  /// The width the window settles at when asked to be as narrow as it goes, and the controls
  /// on view that its edges cut. A list scrolls under the window and is not counted; nor is a
  /// control scrolled out of sight above or below.
  private func narrowest(
    _ size: AppFontSize, _ selection: SidebarItem, opensDetails: Bool, asked: CGFloat = 400
  ) -> (width: CGFloat, outside: [String]) {
    environment.theme.fontSize = size
    let window = makeWindow(width: asked, selection: selection, opensDetails: opensDetails)
    settle(window)
    let width = window.frame.width
    var outside: [String] = []
    if let content = window.contentView {
      let bounds = content.bounds
      for control in Self.controls(in: content)
      where !control.isHidden && control.frame.width > 0 && !(control is NSTableView) {
        let frame = control.convert(control.bounds, to: nil)
        guard frame.minY >= bounds.minY, frame.maxY <= bounds.maxY else { continue }
        if control.visibleRect.isEmpty { continue }
        if frame.minX < bounds.minX - 0.5 || frame.maxX > bounds.maxX + 0.5 {
          outside.append(
            "\(type(of: control)) «\(control.stringValue)» at \(frame) in \(bounds.width)")
        }
      }
    }
    window.contentViewController = nil
    window.close()
    windows.removeAll { $0 === window }
    return (width, outside)
  }

  func testTheLargestTextNeverWidensTheNarrowestMainWindow() throws {
    let screens: [(String, SidebarItem, Bool, EntryStyle)] = [
      ("Overview", .section(.overview), false, .line),
      ("Operations", .section(.operations), false, .line),
      ("Planning", .section(.planning), false, .line),
      ("the ↓ panel", .section(.overview), true, .line),
      ("the form at the right", .section(.overview), false, .form),
    ]
    for language in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = language
      for (name, selection, opensDetails, style) in screens {
        environment.entryStyle = style
        let regular = narrowest(.regular, selection, opensDetails: opensDetails)
        let xlarge = narrowest(.xlarge, selection, opensDetails: opensDetails)
        let place = "\(name), \(language)"
        print(
          "font layout \(place): narrowest regular \(regular.width), xlarge \(xlarge.width); "
            + "cut at regular \(regular.outside.count), at xlarge \(xlarge.outside)")
        // The narrowest window at «Очень крупный» still fits the screen of a CI runner.
        XCTAssertLessThanOrEqual(xlarge.width, 1_024, "the narrowest window: \(place)")
        // Nothing the window shows at «Обычный» unseen is cut at «Очень крупный».
        XCTAssertLessThanOrEqual(
          xlarge.outside.count, regular.outside.count,
          "past the edges of the window: \(place): \(xlarge.outside)")
        // A window of 900 points — the sidebar and the narrowest entry line with room to spare
        // — shows everything at «Обычный»; at «Очень крупный» too.
        let roomy = narrowest(.regular, selection, opensDetails: opensDetails, asked: 900)
        let roomyLarge = narrowest(.xlarge, selection, opensDetails: opensDetails, asked: 900)
        print(
          "font layout \(place) at 900: cut at regular \(roomy.outside), at xlarge \(roomyLarge.outside)"
        )
        if roomy.outside.isEmpty {
          XCTAssertEqual(roomyLarge.outside, [], "past the edges of a window of 900: \(place)")
        }
      }
    }
    environment.theme.fontSize = .regular
  }
}
