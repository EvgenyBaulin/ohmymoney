import AppCore
import AppDatabase
import SwiftUI
import UIKit
import XCTest

@testable import OhMyMoney

/// One leaf of the accessibility tree of a hosted screen: what a finger or VoiceOver can reach.
/// SwiftUI draws text and buttons without views of their own, so this tree is the only place
/// their frames can be read from in a unit test.
struct AXLeaf {
  let label: String
  let identifier: String
  /// In the coordinates of the window.
  let frame: CGRect
  let value: String
  let hint: String
  let traits: UIAccessibilityTraits
  /// Inside a scroll view that scrolls sideways: such content may stand partly off the screen.
  let scrollsSideways: Bool
  let element: NSObject

  var isControl: Bool { traits.contains(.button) || traits.contains(.link) }
}

/// Reads the accessibility tree of a window without VoiceOver. SwiftUI builds it only while an
/// accessibility client is attached, so the test turns the application-side switch on once.
@MainActor
enum AXTree {
  private static var enabled = false

  static func enable() {
    guard !enabled else { return }
    enabled = true
    guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
      let symbol = dlsym(handle, "_AXSApplicationAccessibilitySetEnabled")
    else { return }
    typealias Setter = @convention(c) (Int32) -> Void
    unsafeBitCast(symbol, to: Setter.self)(1)
  }

  static func leaves(in root: UIView, window: UIWindow) -> [AXLeaf] {
    enable()
    var found: [AXLeaf] = []
    var seen = Set<ObjectIdentifier>()
    visit(root, window: window, sideways: false, depth: 0, found: &found, seen: &seen)
    // SwiftUI keeps its scroll views inside the one hosting view, so a leaf has no scroll view
    // above it in the accessibility tree: it stands in one when its middle lies in the window
    // frame of a view that scrolls sideways.
    var rects: [CGRect] = []
    sidewaysScrollers(in: window, window: window, into: &rects)
    return found.map { leaf in
      let middle = CGPoint(x: leaf.frame.midX, y: leaf.frame.midY)
      guard !leaf.scrollsSideways, rects.contains(where: { $0.contains(middle) }) else {
        return leaf
      }
      return AXLeaf(
        label: leaf.label, identifier: leaf.identifier, frame: leaf.frame, value: leaf.value, hint: leaf.hint,
        traits: leaf.traits, scrollsSideways: true, element: leaf.element)
    }
  }

  private static func sidewaysScrollers(in view: UIView, window: UIWindow, into rects: inout [CGRect]) {
    guard !view.isHidden, view.alpha > 0.01 else { return }
    if let scroll = view as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 1 {
      rects.append(scroll.convert(scroll.bounds, to: window))
    }
    for sub in view.subviews { sidewaysScrollers(in: sub, window: window, into: &rects) }
  }

  private static func visit(
    _ object: NSObject, window: UIWindow, sideways: Bool, depth: Int,
    found: inout [AXLeaf], seen: inout Set<ObjectIdentifier>
  ) {
    guard depth < 60, seen.insert(ObjectIdentifier(object)).inserted else { return }
    var sideways = sideways
    if let view = object as? UIView {
      if view.isHidden || view.alpha < 0.01 { return }
      if let scroll = view as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 1 {
        sideways = true
      }
    }
    if object.isAccessibilityElement {
      let frame = object.accessibilityFrame
      found.append(
        AXLeaf(
          label: object.accessibilityLabel ?? "",
          identifier: (object as? UIAccessibilityIdentification)?.accessibilityIdentifier ?? "",
          frame: CGRect(
            x: frame.minX - window.frame.minX, y: frame.minY - window.frame.minY,
            width: frame.width, height: frame.height),
          value: object.accessibilityValue ?? "", hint: object.accessibilityHint ?? "",
          traits: object.accessibilityTraits, scrollsSideways: sideways, element: object))
      return
    }
    let count = object.accessibilityElementCount()
    if count != NSNotFound, count > 0 {
      for index in 0..<count {
        if let child = object.accessibilityElement(at: index) as? NSObject {
          visit(
            child, window: window, sideways: sideways, depth: depth + 1, found: &found,
            seen: &seen)
        }
      }
      return
    }
    if let view = object as? UIView {
      for sub in view.subviews {
        visit(
          sub, window: window, sideways: sideways, depth: depth + 1, found: &found, seen: &seen)
      }
    }
  }
}

/// The widths of the phones iOS 26 runs on, narrowest to widest, and their heights.
enum PhoneSize {
  static let narrow = CGSize(width: 375, height: 812)
  static let regular = CGSize(width: 402, height: 874)
  static let wide = CGSize(width: 440, height: 956)
  static let all = [narrow, regular, wide]
}

/// The iPad Pro 12.9: portrait and landscape, and the widths its Split View gives an app — a
/// half and a third of the landscape width. Slide Over is the phone's narrowest width.
enum PadSize {
  static let portrait = CGSize(width: 1_024, height: 1_366)
  static let landscape = CGSize(width: 1_366, height: 1_024)
  static let splitHalf = CGSize(width: 678, height: 1_024)
  static let splitThird = CGSize(width: 438, height: 1_024)
  static let all = [portrait, landscape, splitHalf, splitThird]
}

/// A synthetic book and a window to put a screen in, shared by the tests that walk the screens
/// of the phone. Made once per test; every screen is hosted in a window of its own and put away
/// after it has been looked at.
@MainActor
final class PhoneHarness {
  let environment: AppEnvironment
  let store: TransactionsStore
  let compute: ComputeStore
  let session: AppSession
  let lock: AppLock
  private let directory: URL
  private let dataDirectoryBefore: String?
  private let languageBefore: AppLanguage.Choice
  private let fontSizeBefore: AppFontSize
  private var windows: [UIWindow] = []
  /// The operations of the synthetic book: the editor is shown for some of them.
  private(set) var sampleEntries: [TransactionEntry] = []

  var deps: AppDependencies {
    AppDependencies(environment: environment, store: store, compute: compute)
  }

  /// `withData` false is a book with nothing in it: the empty states of every screen. `now` fixes
  /// the day the book is drawn up to and the app's clock: the screens of a snapshot do not change
  /// from one day to the next.
  static func make(
    withData: Bool = true, language: AppLanguage.Choice = .russian, now: Date? = nil
  ) async throws -> PhoneHarness {
    OverviewFiguresStore.shared.reset()
    // The session points `AppPaths` at the app's own folder; that must not outlive the test.
    let placementBefore = AppPaths.placement
    let session = AppSession(launches: false)
    AppPaths.placement = placementBefore
    let before = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-phone-screens-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    let environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    let store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
    let compute: ComputeStore
    if let now {
      environment.now = { now }
      compute = ComputeStore(calendar: .system, clock: FixedClock(now), rebuildsInline: true)
    } else {
      compute = ComputeStore(calendar: .system, rebuildsInline: true)
    }
    let harness = PhoneHarness(
      environment: environment, store: store, compute: compute, session: session,
      directory: directory, dataDirectoryBefore: before)
    environment.language.choice = language
    await harness.startPipeline(
      withData ? harness.sampleDataset(language: language == .english ? "en" : "ru") : Dataset(entries: []))
    return harness
  }

  private init(
    environment: AppEnvironment, store: TransactionsStore, compute: ComputeStore,
    session: AppSession, directory: URL, dataDirectoryBefore: String?
  ) {
    self.environment = environment
    self.store = store
    self.compute = compute
    self.session = session
    self.lock = AppLock()
    self.directory = directory
    self.dataDirectoryBefore = dataDirectoryBefore
    languageBefore = environment.language.choice
    fontSizeBefore = environment.theme.fontSize
  }

  func tearDown() async {
    closeAll()
    await compute.stop()
    environment.language.choice = languageBefore
    environment.theme.fontSize = fontSizeBefore
    await environment.close()
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    try? FileManager.default.removeItem(at: directory)
  }

  fileprivate func sampleDataset(language: String) -> Dataset {
    let today = environment.today
    let set = SampleDataGenerator(seed: 20_261_112).generate(
      months: 6, endingOn: today, calendar: .system, language: language
    ).withEveryFeature(seed: 20_261_112, calendar: .system, language: language)
    sampleEntries = set.entries.filter { $0.transaction.deletedAt == nil }
    return Dataset(
      entries: set.entries, links: set.links, categories: set.categories, people: set.people,
      places: set.places, events: set.events, paymentMethods: set.paymentMethods,
      debts: set.debts, goals: set.goals, planning: set.planningBook,
      settings: AnalyticsSettings(cashbackCategoryId: set.cashbackCategoryId),
      transfers: set.transfers, accountGroups: set.accountGroups,
      accountSettings: AccountSettings(storedValues: set.settings), cards: set.cards,
      cashbackRules: set.cashbackRules, banks: set.banks, assets: set.assets,
      assetValuations: set.assetValuations,
      capitalSettings: CapitalSettings(storedValues: set.settings))
  }

  /// The app's own pipeline over the synthetic book, run to its end: every block of every
  /// screen is ready, not «Считается, ожидайте» — a picture taken before the run would show
  /// the wait, not the screen.
  fileprivate func startPipeline(_ dataset: Dataset) async {
    let calendar = CalendarContext.system
    let sources = ComputeSources(
      loadData: { mark, today, _ in
        DataSnapshot.build(
          dataset: dataset, calendar: calendar, today: today,
          context: SnapshotContext(rubPerUnit: [.usd: 95, .eur: 103]),
          version: DataVersion(load: mark))
      },
      refineRates: { RefinementResult() })
    compute.attach(sources, changes: nil)
    compute.run()
    for _ in 0..<400 where !compute.states.run.hasEnded {
      try? await Task.sleep(for: .milliseconds(50))
    }
  }

  // MARK: Windows

  /// Puts `content` in a window of exactly `size`: the frame alone decides the room, not the
  /// simulator's screen and its safe area.
  func host<Content: View>(
    _ content: Content, size: CGSize, dark: Bool = false, idiom: LayoutIdiom? = nil
  ) -> (window: UIWindow, controller: UIHostingController<AnyView>) {
    let controller = UIHostingController(
      rootView: AnyView(content.environment(\.layoutIdiom, idiom).appDependencies(deps)))
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
    // The simulator's screen is a narrow one with an inset of its own at the right, and every
    // window gets it whatever its size. The window is made that much wider, so the room the
    // screen has left is exactly `size.width`; the picture is cut to it (`picture(of:)`).
    window.frame = CGRect(origin: .zero, size: size)
    window.windowLevel = .alert + 1
    window.overrideUserInterfaceStyle = dark ? .dark : .light
    // The simulator's screen may be regular in width; a phone's window never is.
    let sizeClass: UIUserInterfaceSizeClass = size.width >= 600 ? .regular : .compact
    window.traitOverrides.horizontalSizeClass = sizeClass
    controller.traitOverrides.horizontalSizeClass = sizeClass
    window.rootViewController = controller
    window.isHidden = false
    controller.view.frame = window.bounds
    windows.append(window)
    settle(window)
    // Known only once the window is laid out: the inset is the same whatever the width.
    let extra = window.safeAreaInsets.right
    if extra > 0 {
      window.frame = CGRect(
        origin: .zero, size: CGSize(width: size.width + extra, height: size.height))
      controller.view.frame = window.bounds
    }
    Self.force(sizeClass, controller)
    settle(window)
    return (window, controller)
  }

  /// The part of the window that is the screen the test asked for: without the strip the
  /// simulator's inset takes at the right.
  func pictureBounds(of window: UIWindow) -> CGRect {
    CGRect(
      x: 0, y: 0, width: window.bounds.width - window.safeAreaInsets.right,
      height: window.bounds.height)
  }

  func picture(of window: UIWindow) -> UIImage {
    let bounds = pictureBounds(of: window)
    return UIGraphicsImageRenderer(bounds: bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
  }

  /// SwiftUI's `TabView` makes its own tab-bar controller, which reads the traits of the screen
  /// the simulator has, not of the window: on a wide screen it reserves a vertical bar at the
  /// side. Every controller under the root is told it is a phone.
  private static func force(_ sizeClass: UIUserInterfaceSizeClass, _ controller: UIViewController) {
    controller.traitOverrides.horizontalSizeClass = sizeClass
    for child in controller.children { force(sizeClass, child) }
  }

  func close(_ window: UIWindow) {
    window.rootViewController = nil
    window.isHidden = true
    windows.removeAll { $0 === window }
  }

  func closeAll() {
    for window in windows {
      window.rootViewController = nil
      window.isHidden = true
    }
    windows = []
  }

  func settle(_ window: UIWindow, passes: Int = 12) {
    AXTree.enable()
    for _ in 0..<passes {
      window.layoutIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
  }

  /// Runs the loop until the tree of the window has stood still for a few passes: a screen that
  /// loads, animates or lays out lazily is looked at only once it has come to rest.
  func settleStable(_ window: UIWindow, limit: Int = 100) {
    AXTree.enable()
    var last = ""
    var still = 0
    for pass in 0..<limit {
      window.layoutIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.03))
      guard pass >= 5 else { continue }
      let signature = leaves(of: window).map { "\($0.label)\($0.frame)" }.joined(separator: "|")
      still = signature == last ? still + 1 : 0
      last = signature
      if still >= 3 { return }
    }
  }

  func leaves(of window: UIWindow, in root: UIView? = nil) -> [AXLeaf] {
    // The strip the simulator's inset takes at the right is no part of the screen: its toolbar
    // draws there as a column of its own, which a phone does not have.
    let edge = window.bounds.width - window.safeAreaInsets.right
    return AXTree.leaves(in: root ?? window, window: window).filter { $0.frame.minX < edge - 10 }
  }

  /// A picture of the window, kept with the result of the test.
  func attachPicture(of window: UIWindow, named name: String, to test: XCTestCase) {
    let image = picture(of: window)
    let attachment = XCTAttachment(image: image)
    attachment.name = name
    attachment.lifetime = .keepAlways
    test.add(attachment)
  }
}

/// What is wrong with a screen on show. The same rules for every width, text size and theme.
@MainActor
struct PhoneLayoutAudit {
  let harness: PhoneHarness

  /// Nothing wider than the screen or cut at its sides, every control a finger wide, and the
  /// bar and the «+» each in their own place.
  func problems(
    _ shown: PhoneScreenShown, size: CGSize, reachesRightMargin: Bool = false
  ) -> [String] {
    let leaves = harness.leaves(of: shown.window, in: shown.content)
    var found: [String] = []
    if leaves.isEmpty { found.append("nothing is reachable on the screen") }
    let slack: CGFloat = 0.5
    for leaf in leaves where leaf.frame.width >= 1 && leaf.frame.height >= 1 {
      let name = "«\(leaf.label.prefix(40))»"
      if !leaf.scrollsSideways,
        leaf.frame.minX < -slack || leaf.frame.maxX > size.width + slack
      {
        found.append(
          "\(name) leaves the width: x \(Int(leaf.frame.minX)) … \(Int(leaf.frame.maxX))")
      }
    }
    // A page that stops short of the right margin was laid out for a narrower window than it
    // has: the wide things (cards, rows, fields) end near the right edge, a margin away. Asked
    // of the Overview only, as the canary of the test window itself: a page may be empty.
    let wide = leaves.filter { !$0.scrollsSideways && $0.frame.width >= size.width * 0.4 }
    if reachesRightMargin, let right = wide.map(\.frame.maxX).max(), right < size.width - 64 {
      found.append("the content stops at x \(Int(right)) of \(Int(size.width))")
    }
    if shown.hasShell { found += shellProblems(leaves, size: size) }
    return found
  }

  /// Controls under 44 × 44 pt, by name and size. The frame is what accessibility reports: the
  /// drawn control, so a small icon with a larger hit area still lands here.
  func smallControls(_ shown: PhoneScreenShown) -> [String] {
    harness.leaves(of: shown.window, in: shown.content).compactMap { leaf in
      guard leaf.isControl, !leaf.scrollsSideways, leaf.frame.width >= 1,
        leaf.frame.height < 43.5 || leaf.frame.width < 43.5
      else { return nil }
      return "«\(leaf.label.prefix(40))» \(Int(leaf.frame.width)) × \(Int(leaf.frame.height))"
    }
  }

  private func shellProblems(_ leaves: [AXLeaf], size: CGSize) -> [String] {
    let environment = harness.environment
    let barTitles = [
      environment.language("section.overview"),
      environment.language("section.operations"),
      environment.language("section.planning"),
      environment.language("accounts.section.accounts", table: "Accounts"),
      environment.language("phone.tab.more", table: "Phone"),
    ]
    // A page may have controls of the same names (the calendar's «Обзор» and «Операции»), and
    // content runs under the bar: the bar's are the five in one row near the bottom.
    let candidates = leaves.filter {
      barTitles.contains($0.label) && $0.isControl && $0.frame.maxY > size.height - 60
    }
    // Rows are told apart by their lower edge, give or take the lift of the open tab's pill.
    let rows = Dictionary(grouping: candidates) { Int($0.frame.maxY / 12) }
    let bar = rows.values.max { Set($0.map(\.label)).count < Set($1.map(\.label)).count } ?? []
    var found: [String] = []
    if bar.count != barTitles.count {
      found.append("the bar shows \(bar.count) of \(barTitles.count) sections")
    }
    for (index, one) in bar.enumerated() {
      for other in bar[(index + 1)...] where one.frame.intersects(other.frame) {
        found.append("bar items «\(one.label)» and «\(other.label)» overlap")
      }
    }
    let plusTitle = environment.language("phone.entry.new", table: "Phone")
    if let plus = leaves.first(where: { $0.label == plusTitle }) {
      if plus.frame.maxX > size.width - PhoneEntryButton.sideMargin + 0.5 {
        found.append("the «+» is nearer the edge than the margin")
      }
      for item in bar where plus.frame.intersects(item.frame) {
        found.append("the «+» covers the bar item «\(item.label)»")
      }
      if let top = bar.map(\.frame.minY).min(), plus.frame.maxY > top {
        found.append("the «+» reaches into the bar")
      }
    }
    return found
  }

  /// Mac-only things on a phone: key combinations in what is read aloud, the symbols of the
  /// command and option keys anywhere in the labels.
  func macElements(_ shown: PhoneScreenShown) -> [String] {
    PhoneMacElements.problems(in: harness.leaves(of: shown.window, in: shown.content))
  }
}

/// Mac-only controls, by what they are called to accessibility.
enum PhoneMacElements {
  /// Nothing is let through: the palette of commands (⌘) left the phone, as it lists keyboard
  /// shortcuts a phone cannot press.
  static let awaitingOwner: Set<String> = []

  static func problems(in leaves: [AXLeaf]) -> [String] {
    let symbols = CharacterSet(charactersIn: "⌘⌥⌃⇧⌫⎋")
    let words = try? NSRegularExpression(pattern: #"\b(Cmd|Ctrl|Command)[ -]?[A-Z0-9]\b"#)
    var found: [String] = []
    for leaf in leaves {
      if awaitingOwner.contains(leaf.identifier) { continue }
      for text in [leaf.label, leaf.value, leaf.hint] where !text.isEmpty {
        let hasSymbol = text.rangeOfCharacter(from: symbols) != nil
        let hasWord =
          words?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        if hasSymbol || hasWord { found.append("«\(text.prefix(50))»") }
      }
    }
    return found
  }
}
