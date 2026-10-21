import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// «Окна и разделы: открытие и закрытие окон, переключение разделов. Это нужно, чтобы понять,
/// на каком экране случилась ошибка». Every window's lines name the window, and a section
/// switched in it is a line of its own.
@MainActor
final class ScreenJournalTests: XCTestCase {
  private var logs: URL!
  private var defaults: UserDefaults!
  private var suite = ""
  private var windows: [NSWindow] = []

  override func setUp() async throws {
    try await super.setUp()
    logs = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-screens-\(UUID().uuidString)", isDirectory: true)
    Logbook.shared.open(directory: logs, threshold: .debug)
    suite = "ohmymoney.tests.screens.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
  }

  override func tearDown() async throws {
    for window in windows {
      window.contentViewController = nil
      window.close()
    }
    windows = []
    Logbook.shared.close()
    try? FileManager.default.removeItem(at: logs)
    defaults.removePersistentDomain(forName: suite)
    try await super.tearDown()
  }

  private func dependencies() -> AppDependencies {
    AppDependencies(
      environment: AppEnvironment(), store: TransactionsStore(),
      compute: ComputeStore(calendar: .utc))
  }

  @discardableResult
  private func show<V: View>(_ view: V) -> NSWindow {
    // dependencies: every view shown here is a root built by `AppScenes.root`
    let controller = NSHostingController(rootView: view.defaultAppStorage(defaults))
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 1120, height: 760),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    window.orderFront(nil)
    windows.append(window)
    settle()
    return window
  }

  private func settle() {
    for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
  }

  private func lines(_ name: String) -> [String] {
    Logbook.shared.lines().filter { $0.contains(" \(name) ") }
  }

  func testAWindowSaysWhichWindowItIsWhenItOpensAndCloses() {
    let window = show(
      AppScenes.root(dependencies(), window: .reports, launches: false) { _ in Color.clear })
    window.contentViewController = nil
    window.close()
    settle()

    XCTAssertTrue(
      lines("window.opened").contains { $0.hasSuffix(" window=reports") },
      "the journal cannot tell which window opened: \(lines("window.opened"))")
    XCTAssertTrue(
      lines("window.closed").contains { $0.hasSuffix(" window=reports") },
      "the journal cannot tell which window closed: \(lines("window.closed"))")
  }

  func testTheMainWindowSaysWhichSectionIsOnScreen() {
    show(AppScenes.root(dependencies(), window: .main, launches: false) { MainWindow(deps: $0) })
    NotificationCenter.default.post(name: .selectSection, object: 2)
    settle()

    let shown = lines("section.shown")
    XCTAssertTrue(
      shown.contains { $0.hasSuffix(" window=main section=overview") },
      "the section the window opened on is not in the journal: \(shown)")
    XCTAssertTrue(
      shown.contains { $0.hasSuffix(" window=main section=planning") },
      "⌘2 switched the section and the journal did not say so: \(shown)")
  }

  func testTheAnalyticsWindowSaysWhichSectionIsOnScreen() {
    show(
      AppScenes.root(dependencies(), window: .analytics, launches: false) {
        AnalyticsWindow(deps: $0)
      })
    defaults.set(AnalyticsSection.forecast.rawValue, forKey: AnalyticsWindow.sectionKey)
    settle()

    let shown = lines("section.shown")
    XCTAssertTrue(
      shown.contains { $0.hasSuffix(" window=analytics section=overview") },
      "the section the window opened on is not in the journal: \(shown)")
    XCTAssertTrue(
      shown.contains { $0.hasSuffix(" window=analytics section=forecast") },
      "a section chosen in Analytics is not in the journal: \(shown)")
  }

  /// A table of Reports is a section of its window. The longest name of a table is longer
  /// than a word of the journal may be, and it still comes out as a word, not as
  /// `<not-a-token>`.
  func testTheReportsWindowSaysWhichTableIsOnScreen() {
    show(
      AppScenes.root(dependencies(), window: .reports, launches: false) { ReportsWindow(deps: $0) })
    defaults.set(ReportTable.Kind.monthly.rawValue, forKey: ReportsSelection.tableKey)
    settle()

    let shown = lines("section.shown")
    XCTAssertTrue(
      shown.contains { $0.hasSuffix(" window=reports section=expensesBySubcategory") },
      "the table the window opened on is not in the journal: \(shown)")
    XCTAssertTrue(
      shown.contains { $0.hasSuffix(" window=reports section=monthly") },
      "a table chosen in Reports is not in the journal: \(shown)")
    XCTAssertFalse(Logbook.shared.lines().joined().contains("<not-a-"), "a name was not a word")
  }
}
