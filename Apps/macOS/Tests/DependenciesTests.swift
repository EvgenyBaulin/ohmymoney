import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The crash of 19.09: the inspector of the Transactions window was laid out
/// without the app's environment, and `@Environment(AppEnvironment.self)` trapped inside
/// SwiftUI. Now every scene is assembled in one place, its root gets the dependencies through
/// its initializer, what is shown in a host of its own gets them handed over, and a view that
/// still misses them gets a stand-in instead of a trap.
@MainActor
final class DependenciesTests: XCTestCase {
  /// The set is the process's, not this class's: several tests here fill it on purpose, and
  /// the classes after this one read it (the problem report, the Debug badge, the layout tests).
  private var missingReadersBefore: Set<String> = []

  override func setUp() async throws {
    missingReadersBefore = AppDependencies.missingReaders
    AppDependencies.missingReaders = []
  }

  override func tearDown() async throws {
    AppDependencies.missingReaders = missingReadersBefore
  }

  private final class Seen {
    var environment: AppEnvironment?
    var store: TransactionsStore?
  }

  private struct Probe: View {
    @Dependency(\.environment) private var environment
    @Dependency(\.store) private var store
    let seen: Seen

    var body: some View {
      seen.environment = environment
      seen.store = store
      return Text(verbatim: environment.language("action.save"))
    }
  }

  private func dependencies() -> AppDependencies {
    AppDependencies(
      environment: AppEnvironment(), store: TransactionsStore(),
      compute: ComputeStore(calendar: .system))
  }

  private func roots(_ deps: AppDependencies) -> [(String, AnyView)] {
    [
      (
        "Main",
        AnyView(AppScenes.root(deps, window: .main, launches: false) { MainWindow(deps: $0) })
      ),
      (
        "Operations",
        AnyView(
          AppScenes.root(deps, window: .main, launches: false) {
            MainWindow(deps: $0, selection: .section(.operations))
          })
      ),
      (
        "Analytics",
        AnyView(
          AppScenes.root(deps, window: .analytics, launches: false) { AnalyticsWindow(deps: $0) })
      ),
      (
        "Reports",
        AnyView(AppScenes.root(deps, window: .reports, launches: false) { ReportsWindow(deps: $0) })
      ),
      (
        "Settings",
        AnyView(AppScenes.root(deps, window: .settings, launches: false) { SettingsView(deps: $0) })
      ),
    ]
  }

  private func layOut<V: View>(_ view: V, width: CGFloat = 800, height: CGFloat = 600) {
    // dependencies: the caller decides what this view was given; the stand-in test needs none
    let host = NSHostingView(rootView: view)
    host.frame = CGRect(x: 0, y: 0, width: width, height: height)
    host.layoutSubtreeIfNeeded()
  }

  /// Lays a scene root out the way the app does: in a window. A root laid out in a bare
  /// hosting view is not the same thing — the settings root alone logs seven «Invalid view
  /// geometry» there and none in a window, because its `TabView` has no window to measure
  /// against.
  private func inWindow<V: View>(_ view: V, width: CGFloat, height: CGFloat) {
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    // dependencies: the roots are built by `AppScenes.root`, which hands them over
    window.contentView = NSHostingView(rootView: view)
    window.orderFront(nil)
    defer {
      window.contentView = nil
      window.close()
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    window.layoutIfNeeded()
  }

  func testAViewShownWithoutTheDependenciesGetsAStandInRatherThanATrap() {
    let seen = Seen()
    layOut(Probe(seen: seen))
    XCTAssertEqual(seen.environment?.isPlaceholder, true)
    // And the test sees who got it: the net under every other test of this file.
    XCTAssertFalse(AppDependencies.missingReaders.isEmpty)
    // The stand-in does not change what anything says, and so cannot change any size: in
    // Debug the window wears a badge instead (`standInBadge`).
    XCTAssertEqual(
      seen.environment?.language("action.save"), AppEnvironment().language("action.save"))
  }

  /// The badge of a missing dependency must not invalidate itself from inside the update that
  /// drew it. `Dependency.wrappedValue` is read while a view's `body` runs, and it used to
  /// write the observable set the badge reads — «Modifying state during view update», the
  /// classic one.
  func testAViewWithoutDependenciesWritesNoStateDuringTheUpdate() {
    let probe = LogProbe()
    let before = probe.counts(of: [LogProbe.Message.stateDuringUpdate])

    // The badge is what observes the set, so the offender and the observer are both on screen.
    inWindow(Probe(seen: Seen()).standInBadge(), width: 400, height: 300)
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

    XCTAssertFalse(AppDependencies.missingReaders.isEmpty, "the stand-in was not reached")
    probe.assertQuiet(
      about: [LogProbe.Message.stateDuringUpdate], comparedWith: before,
      "a view shown without the dependencies")
  }

  /// Nothing written through the stand-in can land anywhere, so every attempt says so — in
  /// the log, and on screen. A quietly lost edit is worse than a crash.
  func testTheStandInRefusesEveryWriteAndSaysSo() throws {
    let probe = LogProbe()
    let before = probe.counts(of: ["a write was refused"])
    let stand = AppDependencies.missing(in: "OhMyMoney/Test.swift")
    let draft = TransactionDraft(
      amount: AmountE4(whole: 250), note: "coffee", parts: [PartDraft(amount: AmountE4(whole: 250))]
    )
    let entry = try draft.materialize()

    XCTAssertFalse(stand.store.save(entry))
    XCTAssertEqual(stand.store.saveEdit(entry), .refused)
    XCTAssertFalse(stand.store.delete(id: entry.id))
    XCTAssertFalse(stand.store.delete(ids: [entry.id]))
    // The stand-in is made once per process, so it is named after whoever went without
    // first; what matters is that the screen has something to show.
    XCTAssertNotNil(stand.store.refusal, "the screen has nothing to show")
    if !probe.isBlind {
      let deadline = Date().addingTimeInterval(2)
      while probe.count("a write was refused") == (before["a write was refused"] ?? 0),
        Date() < deadline
      {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      }
      XCTAssertGreaterThan(
        probe.count("a write was refused"), before["a write was refused"] ?? 0,
        "the log says nothing")
    }

    // The editor of such a window says why, instead of looking as if it had saved.
    let editor = TransactionEditorModel(entry: entry, environment: stand.environment)
    XCTAssertFalse(editor.save(store: stand.store, environment: stand.environment))
    XCTAssertEqual(editor.errorKey, "entry.error.noDependencies")

    stand.store.forgetRefusal()
    XCTAssertNil(stand.store.refusal)
  }

  func testTheDependenciesHandedOverReachTheView() {
    let deps = dependencies()
    let seen = Seen()
    layOut(Probe(seen: seen).appDependencies(deps))
    XCTAssertTrue(seen.environment === deps.environment)
    XCTAssertTrue(seen.store === deps.store)
    XCTAssertEqual(seen.environment?.isPlaceholder, false)
  }

  /// The boundary that crashed: content of an inspector is laid out by a host of its own.
  /// Handed over explicitly, the dependencies reach it on every macOS.
  func testContentOfAnInspectorGetsTheDependenciesHandedToIt() {
    let deps = dependencies()
    let seen = Seen()
    let root = NavigationSplitView {
      Text(verbatim: "sidebar")
    } detail: {
      Text(verbatim: "detail")
        .inspector(isPresented: .constant(true)) {
          Probe(seen: seen).appDependencies(deps)
        }
    }
    .appDependencies(deps)
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: root)
    window.orderFront(nil)
    defer { window.close() }
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    window.contentView?.layoutSubtreeIfNeeded()
    XCTAssertTrue(seen.environment === deps.environment)
  }

  /// The question asked before a category goes is a sheet, laid out by a host of its own like
  /// every sheet: it gets the dependencies where it is presented, or its
  /// picker and its three buttons read the stand-in.
  func testTheSheetThatDeletesACategoryGetsTheDependenciesHandedToIt() throws {
    let deps = dependencies()
    let question = CategoriesSettingsView.CategoryDeletion(
      category: CoreKit.Category(kind: .expense, name: "Books"), children: 0, live: 3, binned: 0)
    let window = NSWindow(
      contentViewController: NSHostingController(
        rootView: CategoriesSettingsView(asking: question).appDependencies(deps)))
    window.isReleasedWhenClosed = false
    window.orderFront(nil)
    defer {
      if let sheet = window.attachedSheet { window.endSheet(sheet) }
      window.close()
    }
    let deadline = Date().addingTimeInterval(5)
    while window.attachedSheet == nil, Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    let sheet = try XCTUnwrap(window.attachedSheet, "the question was not shown")
    sheet.contentView?.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    XCTAssertEqual(AppDependencies.missingReaders, [], "the question went without the dependencies")
  }

  /// Every root of a scene is made by the one assembly point with the same dependencies, and
  /// lays out at the smallest, the default and a large size of its window.
  func testEveryRootOfASceneLaysOutWithTheDependenciesOfTheApp() {
    let probe = LogProbe()
    let quiet = [LogProbe.Message.invalidGeometry, LogProbe.Message.layoutWhileLayingOut]
    let before = probe.counts(of: quiet)
    let deps = dependencies()
    let sizes: [(CGFloat, CGFloat)] = [(820, 480), (1120, 760), (1600, 1000)]
    for (width, height) in sizes {
      for (_, root) in roots(deps) { inWindow(root, width: width, height: height) }
    }
    // No view below any root fell back to the stand-in, and nothing was laid out into a
    // negative width or asked to lay out while it was already laying out.
    XCTAssertEqual(AppDependencies.missingReaders, [])
    probe.assertQuiet(about: quiet, comparedWith: before, "laying out the roots of the scenes")
  }

  /// The very view the Transactions window puts into its inspector, laid out inside a real
  /// `.inspector` whose outer view has no dependencies at all: it must hand them over itself,
  /// so no view of the editor reads the stand-in. Remove the hand-over from
  /// `TransactionInspector` and this fails.
  func testTheInspectorOfTransactionsHandsTheDependenciesToTheEditorItself() throws {
    let probe = LogProbe()
    let quiet = [LogProbe.Message.invalidGeometry, LogProbe.Message.layoutWhileLayingOut]
    let before = probe.counts(of: quiet)
    let deps = dependencies()
    let draft = TransactionDraft(
      amount: AmountE4(whole: 250), note: "coffee", parts: [PartDraft(amount: AmountE4(whole: 250))]
    )
    let editor = TransactionEditorModel(
      entry: try draft.materialize(), environment: deps.environment)
    let root = NavigationSplitView {
      Text(verbatim: "sidebar")
    } detail: {
      Text(verbatim: "detail")
        .inspector(isPresented: .constant(true)) {
          TransactionInspector(deps: deps, editor: editor) {}
        }
    }
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    // dependencies: none on the outside on purpose — this test is about the inspector
    // handing them over itself
    window.contentView = NSHostingView(rootView: root)
    window.orderFront(nil)
    defer { window.close() }
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    window.contentView?.layoutSubtreeIfNeeded()
    XCTAssertEqual(AppDependencies.missingReaders, [])
    probe.assertQuiet(about: quiet, comparedWith: before, "laying out the inspector")
  }
}

extension AppDependencies {
  /// A view under test with the environment the test set up and stores attached to nothing.
  static func forTests(_ environment: AppEnvironment) -> AppDependencies {
    AppDependencies(
      environment: environment, store: TransactionsStore(),
      compute: ComputeStore(calendar: .system))
  }
}
