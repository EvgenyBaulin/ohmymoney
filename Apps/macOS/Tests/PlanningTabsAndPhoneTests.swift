import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// What the frames of Planning ask beyond the numbers: a tab shows its block alone, «все» of a
/// card leads to its tab; the iPhone frame — one line of the free sum under the title, no tabs, no
/// month, seven days of the next fourteen on the screen; and below zero the card says the plans
/// ask more than there is, with separate shortages and a daily recovery guide.
@MainActor
final class PlanningTabsAndPhoneTests: XCTestCase {
  private var windows: [NSWindow] = []
  private var suites: [String] = []

  override func tearDown() async throws {
    for window in windows {
      window.contentView = nil
      window.close()
    }
    windows = []
    for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
    suites = []
  }

  private func layout() throws -> PlanningLayoutStore {
    let suite = "ohmymoney.tests.planning-tabs.\(UUID().uuidString)"
    suites.append(suite)
    return PlanningLayoutStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
  }

  private func environment() -> AppEnvironment {
    let environment = AppEnvironment()
    environment.language.choice = .russian
    return environment
  }

  private let main = UUID()

  /// One counted account of `money`; a bill of `bill` in a week, a subscription, an expected
  /// salary, a limit, a goal and an event, so every block has its rows.
  private func dataset(today: DateOnly, money: Int64, bill: Int64) -> Dataset {
    let counted = Reconciliation(
      date: today.adding(days: -1), reconciledAt: Date().addingTimeInterval(-86_400),
      actualTotalRubE4: AmountE4(whole: money), kind: .accounts)
    let balance = ReconciledBalance(
      reconciliationId: counted.id, accountId: main, currency: .rub,
      actualE4: AmountE4(whole: money))
    let due = today.adding(days: 7)
    return Dataset(
      paymentMethods: [PaymentMethod(id: main, name: "Main", currency: .rub, isDefault: true)],
      goals: [
        Goal(name: "Trip", targetE4: AmountE4(whole: 90_000), targetDate: today.adding(days: 60))
      ],
      planning: PlanningBook(
        scheduled: [
          ScheduledPayment(
            name: "Rent", amountE4: AmountE4(whole: bill), day: due.day, nextDate: due),
          ScheduledPayment(
            name: "Music", kind: .subscription, amountE4: AmountE4(whole: 300),
            day: today.adding(days: 2).day, nextDate: today.adding(days: 2)),
        ],
        expected: [
          ExpectedIncome(
            name: "Salary", kind: .recurring, totalE4: AmountE4(whole: 100_000), freq: .monthly,
            day: today.adding(days: 5).day)
        ],
        reconciliations: [counted], reconciledBalances: [balance]))
  }

  private func dependencies(
    _ environment: AppEnvironment, money: Int64 = 200_000, bill: Int64 = 30_000
  ) -> (AppDependencies, DataSnapshot) {
    let compute = ComputeStore(calendar: .system, rebuildsInline: true)
    let snapshot = DataSnapshot.build(
      dataset: dataset(today: environment.today, money: money, bill: bill), calendar: .system,
      today: environment.today, context: SnapshotContext(), version: DataVersion(load: 0))
    compute.applyLight(snapshot)
    return (
      AppDependencies(environment: environment, store: TransactionsStore(), compute: compute),
      snapshot
    )
  }

  // MARK: - Below zero

  /// 5,000 ₽ on the account and a bill of 30,000 ₽ in a week: free money is zero,
  /// the payment shortage is explicit, and recovery replaces the normal daily allowance.
  func testThePlansAskingMoreThanThereIsSayItIsShort() throws {
    let environment = environment()
    let (_, snapshot) = dependencies(environment, money: 5_000, bill: 30_000)
    let (free, _) = OverviewHeadline.configured(snapshot)
    let grey = try XCTUnwrap(free.grey)
    XCTAssertLessThan(grey, .zero, "the bill asks more than the account holds")
    let figures = try XCTUnwrap(PlanningView.freeFigures(snapshot, picked: nil, environment))
    XCTAssertEqual(figures.title, "Сейчас свободно")
    XCTAssertEqual(figures.main.figure, environment.money.rounded(.zero))
    XCTAssertEqual(figures.metrics.first?.words, "Сейчас свободно")
    let recovery = try XCTUnwrap(figures.recovery)
    XCTAssertTrue(recovery.contains("На платежи не хватает \(environment.money.rounded(-grey))"))
    XCTAssertTrue(recovery.contains("Чтобы выйти в ноль"))
    XCTAssertFalse(figures.columns.contains { $0.id == "daily" }, "no figure for a day")
    XCTAssertFalse(figures.metrics.contains { $0.id == "daily" })
    XCTAssertEqual(figures.line, "Сейчас свободно \(figures.main.figure)\n\(recovery)")

    let enough = try XCTUnwrap(
      PlanningView.freeFigures(dependencies(environment).1, picked: nil, environment))
    XCTAssertEqual(enough.title, "Сейчас свободно")
    XCTAssertTrue(enough.line.hasPrefix("Сейчас свободно "), enough.line)
    XCTAssertTrue(enough.line.contains("/день"), enough.line)
  }

  // MARK: - The tabs

  /// «Лимиты» shows the limits alone: no free sum, no next 14 days, no other card; «Всё» shows
  /// them all, each card with «все» to its tab, and a card on its own tab has none.
  func testATabShowsItsBlockAlone() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let environment = environment()
    let (deps, _) = dependencies(environment)
    let layout = try layout()
    let alone = host(
      PlanningView(layout: layout, tab: .limits).appDependencies(deps), width: 1_100)
    attachPicture(of: alone, named: "Planning, the tab of the limits")
    XCTAssertNotNil(
      waitFor("planning.card.limits", in: alone),
      "the limits on their tab; seen: \(identifiers(in: alone))")
    XCTAssertNil(find("planning.card.limits.all", in: alone), "no «все» on its own tab")
    for gone in [
      "planning.free", "planning.ribbon", "planning.card.payments", "planning.card.goals",
    ] {
      XCTAssertNil(find(gone, in: alone), "\(gone) on the tab of the limits")
    }

    let all = host(PlanningView(layout: layout).appDependencies(deps), width: 1_100)
    for present in ["planning.free", "planning.ribbon", "planning.card.payments"] {
      XCTAssertNotNil(waitFor(present, in: all), present)
    }
    XCTAssertNotNil(find("planning.card.limits.all", in: all), "«все» leads to the tab")
    XCTAssertNil(find("planning.card.advice.all", in: all), "the hints have no tab")
  }

  // MARK: - The phone's width

  /// 390 pt, as the iPhone frame: the free sum is one line, no tabs, no month under the title,
  /// one column, and the screen settles. A picture is kept beside the frame.
  func testThePhonesWidthIsTheIPhoneFrame() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let environment = environment()
    let (deps, _) = dependencies(environment)
    let layout = try layout()
    let window = host(
      PlanningView(layout: layout).appDependencies(deps).environment(\.windowWidth, 390),
      width: 390)
    attachPicture(of: window, named: "Planning 390 (Figma iPhone 5:7751)")
    XCTAssertNotNil(waitFor("planning.free.line", in: window), "the free sum as one line")
    for gone in ["planning.free", "planning.tabs", "planning.subtitle", "planning.addButton"] {
      XCTAssertNil(find(gone, in: window), "\(gone) on a phone's width")
    }
    XCTAssertNotNil(find("planning.actions", in: window), "one menu at the title's right")
    XCTAssertNotNil(find("planning.ribbon.days", in: window))
    let payments = try XCTUnwrap(frame("planning.card.payments", in: window))
    let limits = try XCTUnwrap(frame("planning.card.limits", in: window))
    XCTAssertEqual(payments.minX, limits.minX, accuracy: 1, "one column")
    XCTAssertEqual(
      payments.width, 390 - 2 * PlanningMetrics.pageSide, accuracy: 20, "the card spans the page")

    let hosting = try XCTUnwrap(window.contentView)
    hosting.layoutSubtreeIfNeeded()
    let first = hosting.fittingSize
    settle(0.3)
    hosting.layoutSubtreeIfNeeded()
    XCTAssertEqual(hosting.fittingSize, first, "the screen settles at a phone's width")
  }

  // MARK: - Hosting

  private func settle(_ seconds: TimeInterval = 0.5) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  private func host<V: View>(_ view: V, width: CGFloat) -> NSWindow {
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: width, height: 1_200), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    windows.append(window)
    // dependencies: every caller hands them to its view with `.appDependencies`
    window.contentView = NSHostingView(rootView: view.frame(width: width, height: 1_200))
    window.makeKeyAndOrderFront(nil)
    settle()
    window.contentView?.layoutSubtreeIfNeeded()
    settle(0.2)
    return window
  }

  private func find(_ identifier: String, in window: NSWindow) -> AnyObject? {
    guard let root = window.contentView else { return nil }
    return Self.element(in: root) { $0.accessibilityIdentifier?() == identifier }
  }

  private func identifiers(in window: NSWindow) -> [String] {
    var found: [String] = []
    func walk(_ node: AnyObject, _ depth: Int) {
      if let id = node.accessibilityIdentifier?(), !id.isEmpty { found.append(id) }
      guard depth < 40 else { return }
      for child in node.accessibilityChildren?() ?? [] { walk(child as AnyObject, depth + 1) }
    }
    if let root = window.contentView { walk(root, 0) }
    return found
  }

  /// The element once the accessibility tree has it: a fresh window builds it a moment later.
  private func waitFor(_ identifier: String, in window: NSWindow) -> AnyObject? {
    let deadline = Date().addingTimeInterval(5)
    repeat {
      if let found = find(identifier, in: window) { return found }
      settle(0.1)
    } while Date() < deadline
    return nil
  }

  private func frame(_ identifier: String, in window: NSWindow) -> CGRect? {
    guard let onScreen = find(identifier, in: window)?.accessibilityFrame?() else { return nil }
    return window.convertFromScreen(onScreen)
  }

  private func attachPicture(of window: NSWindow, named name: String) {
    guard let view = window.contentView,
      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private static func element(
    in node: AnyObject, depth: Int = 0, where matches: (AnyObject) -> Bool
  ) -> AnyObject? {
    if matches(node) { return node }
    guard depth < 40 else { return nil }
    for child in node.accessibilityChildren?() ?? [] {
      if let found = element(in: child as AnyObject, depth: depth + 1, where: matches) {
        return found
      }
    }
    return nil
  }
}
