import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// What the window tests of Calendar, Capital and Purchases share: a database in memory, a book
/// with every feature, the main window at the size of a frame — or one screen alone, laid out by
/// the phone's or the tablet's design —, the frames of its parts read through accessibility, and
/// a picture of the window kept with the result, to lay beside the frame.
@MainActor
class SectionFigmaHarness: XCTestCase {
  var environment: AppEnvironment!
  var store: TransactionsStore!
  var compute: ComputeStore!
  var directory: URL!
  var suiteName: String!
  var defaults: UserDefaults!
  var windows: [NSWindow] = []
  private var dataDirectoryBefore: String?
  private var languageBefore: AppLanguage.Choice?
  private var entryStyleBefore: EntryStyle?

  struct NotFound: Error {}

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-section-figma-\(UUID().uuidString)", isDirectory: true)
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
    suiteName = "ohmymoney-section-figma-\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    compute.applyLight(book(today: environment.today))
    entryStyleBefore = environment.entryStyle
    environment.entryStyle = .line
    languageBefore = environment.language.choice
    environment.language.choice = .russian
  }

  /// The book the screen is drawn over; a section adds what its frame needs.
  func book(today: DateOnly) -> DataSnapshot {
    PlanningFigmaWindowTests.snapshot(today: today)
  }

  override func tearDown() async throws {
    for window in windows {
      window.contentViewController = nil
      window.close()
    }
    windows = []
    if let languageBefore { environment?.language.choice = languageBefore }
    if let entryStyleBefore { environment?.entryStyle = entryStyleBefore }
    if let environment { await environment.close() }
    defaults?.removePersistentDomain(forName: suiteName)
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  var deps: AppDependencies {
    AppDependencies(environment: environment, store: store, compute: compute)
  }

  /// The main window with `section` chosen, at the size of a frame.
  func mainWindow(
    _ section: MainWindow.Section, width: CGFloat, height: CGFloat = 900
  ) -> NSWindow {
    let actions = OperationActions()
    let root =
      AppScenes.root(deps, window: .main, launches: false) { deps in
        MainWindow(deps: deps, actions: actions, opensDetails: false, selection: .section(section))
      }
      .environment(\.windowWidth, width)
      .defaultAppStorage(defaults)
    return host(root, width: width, height: height, unified: true)
  }

  /// One screen alone, laid out by the design of `idiom` in a window as wide as its frame.
  func screenWindow<Screen: View>(
    _ screen: Screen, idiom: LayoutIdiom, width: CGFloat, height: CGFloat
  ) -> NSWindow {
    let root =
      screen
      .environment(\.layoutIdiom, idiom)
      .environment(\.windowWidth, width)
      .appDependencies(deps)
      .defaultAppStorage(defaults)
    return host(root, width: width, height: height, unified: false)
  }

  private func host<Root: View>(
    _ root: Root, width: CGFloat, height: CGFloat, unified: Bool
  ) -> NSWindow {
    let controller = NSHostingController(rootView: root)
    if unified { controller.sceneBridgingOptions = [.toolbars] }
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: width, height: height),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    window.setContentSize(CGSize(width: width, height: height))
    if unified { window.toolbarStyle = .unified }
    window.orderFront(nil)
    windows.append(window)
    return window
  }

  func settle(_ window: NSWindow, passes: Int = 30) {
    for _ in 0..<passes {
      window.updateConstraintsIfNeeded()
      window.layoutIfNeeded()
      window.displayIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
  }

  /// The frame of the element with `identifier`, in the window's coordinates (y up). A control
  /// may hand its identifier down to the parts of its label: the largest of them is the control.
  func frame(of identifier: String, in window: NSWindow) throws -> CGRect {
    let deadline = Date().addingTimeInterval(5)
    repeat {
      if let root = window.contentView {
        var found: [AnyObject] = []
        Self.elements(in: root, into: &found) { $0.accessibilityIdentifier?() == identifier }
        let frames = found.compactMap { $0.accessibilityFrame?() }.filter { $0.width > 0 }
        if let largest = frames.max(by: { $0.width * $0.height < $1.width * $1.height }) {
          return window.convertFromScreen(largest)
        }
      }
      settle(window, passes: 5)
    } while Date() < deadline
    XCTFail("\(identifier) was not found")
    throw NotFound()
  }

  func find(_ identifier: String, in window: NSWindow) -> AnyObject? {
    guard let root = window.contentView else { return nil }
    var found: [AnyObject] = []
    Self.elements(in: root, into: &found) { $0.accessibilityIdentifier?() == identifier }
    return found.first
  }

  /// Many hosts at once lay a window out slowly: the page is measured only once two reads of its
  /// parts in a row agree.
  func waitUntilStill(_ identifiers: [String], in window: NSWindow) throws {
    var last = try identifiers.map { try frame(of: $0, in: window) }
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      settle(window, passes: 5)
      let now = try identifiers.map { try frame(of: $0, in: window) }
      if now == last { return }
      last = now
    }
    XCTFail("the page never stopped moving: \(identifiers)")
  }

  /// The right edge of the sidebar: the table at the left edge of the window (a screen may hold a
  /// list of its own further right).
  func sidebarEdge(in window: NSWindow) throws -> CGFloat {
    let root = try XCTUnwrap(window.contentView)
    let sidebar = try XCTUnwrap(Self.sidebarScroll(in: root), "the sidebar was not found")
    return sidebar.convert(sidebar.bounds, to: nil).maxX
  }

  /// Use the table's own scroll view. An ancestor scroll view can contain both the sidebar
  /// and the page, so merely finding any table below it mistakes the whole window for a sidebar.
  static func sidebarScroll(in root: NSView) -> NSScrollView? {
    var tables: [NSTableView] = []
    allSubviews(of: root, into: &tables)
    return tables.compactMap(\.enclosingScrollView).first { scroll in
      let rect = scroll.convert(scroll.bounds, to: root)
      return abs(rect.minX - root.bounds.minX) < 1 && rect.width > 0
    }
  }

  /// A picture of the window, kept with the result of the test.
  func attachPicture(of window: NSWindow, named name: String) throws {
    let view = try XCTUnwrap(window.contentView)
    let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    // A copy beside the host's temporary files, to lay beside the frame without the result
    // bundle.
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("section-figma", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try? png.write(to: folder.appendingPathComponent(name + ".png"))
  }

  static func allSubviews<V: NSView>(of view: NSView, into found: inout [V]) {
    if let match = view as? V { found.append(match) }
    for subview in view.subviews { allSubviews(of: subview, into: &found) }
  }

  static func elements(
    in node: AnyObject, depth: Int = 0, into found: inout [AnyObject],
    where matches: (AnyObject) -> Bool
  ) {
    if matches(node) { found.append(node) }
    guard depth < 40 else { return }
    for child in node.accessibilityChildren?() ?? [] {
      elements(in: child as AnyObject, depth: depth + 1, into: &found, where: matches)
    }
  }
}
