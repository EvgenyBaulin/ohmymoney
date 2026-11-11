import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

@MainActor
final class OverviewDiscrepanciesTests: XCTestCase {
  private var environment: AppEnvironment?
  private var directory: URL?
  private var dataDirectoryBefore: String?
  private var languageBefore: AppLanguage.Choice?
  private var windows: [NSWindow] = []

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-discrepancies-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    self.directory = directory
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    let environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    self.environment = environment
    languageBefore = environment.language.choice
  }

  override func tearDown() async throws {
    for window in windows {
      window.contentViewController = nil
      window.close()
    }
    if let languageBefore { environment?.language.choice = languageBefore }
    await environment?.close()
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private func host(difference: Int64, inOverview: Bool = false) throws -> NSWindow {
    let environment = try XCTUnwrap(environment)
    let account = PaymentMethod(name: "Synthetic account", kind: .card)
    let store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning, imports: environment.statementImports)
    XCTAssertTrue(store.apply(PlanningChange(upsert: PlanningRows(paymentMethods: [account]))))
    var draft = TransactionDraft(
      kind: .income,
      occurredAt: environment.calendar.startOfDay(environment.today),
      amount: AmountE4(whole: difference))
    draft.paymentMethodId = account.id
    draft.normalizeSinglePart()
    var entry = try draft.materialize(timeZone: environment.calendar.timeZone)
    entry.transaction.externalId = OperationLink.reconciliation(UUID()).externalId
    let dataset = Dataset(entries: difference == 0 ? [] : [entry], paymentMethods: [account])
    let compute = ComputeStore(calendar: environment.calendar, rebuildsInline: true)
    compute.applyLight(
      DataSnapshot.build(
        dataset: dataset, calendar: environment.calendar,
        today: environment.today, context: SnapshotContext(), version: DataVersion(load: 0)))
    let deps = AppDependencies(environment: environment, store: store, compute: compute)
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 700, height: inOverview ? 700 : 320),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let root: AnyView =
      inOverview
      ? AnyView(OverviewView(actions: OperationActions())) : AnyView(OverviewDiscrepancies())
    window.contentViewController = NSHostingController(rootView: root.appDependencies(deps))
    window.orderFront(nil)
    windows.append(window)
    return window
  }

  private func waitFor(_ identifier: String, in window: NSWindow) -> NSObject? {
    let deadline = Date().addingTimeInterval(5)
    repeat {
      window.layoutIfNeeded()
      if let element = WindowAccessibility.element(identified: identifier, in: window) {
        return element
      }
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    } while Date() < deadline
    return nil
  }

  func testTheDifferenceRowShowsInItsBlock() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let environment = try XCTUnwrap(environment)
    environment.language.choice = .russian
    let window = try host(difference: 650)
    XCTAssertNotNil(waitFor("overview.discrepancies", in: window))
    XCTAssertNotNil(waitFor("overview.reconciliation.difference", in: window))
  }

  func testTheDefaultOverviewKeepsTheReconciliationDifferenceAboveItsTiles() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let environment = try XCTUnwrap(environment)
    XCTAssertEqual(environment.overviewLayout, .macDefault)
    let window = try host(difference: 650, inOverview: true)
    let block = try XCTUnwrap(waitFor("overview.discrepancies", in: window))
    XCTAssertNotNil(waitFor("overview.reconciliation.difference", in: window))
    let tile = try XCTUnwrap(waitFor("overview.tile.monthToDate", in: window))
    XCTAssertGreaterThanOrEqual(
      WindowAccessibility.frame(of: block).minY, WindowAccessibility.frame(of: tile).maxY)
    XCTAssertNil(WindowAccessibility.element(identified: "overview.group.money", in: window))
    XCTAssertNil(WindowAccessibility.element(identified: "overview.lastRecord", in: window))
    XCTAssertFalse(
      WindowAccessibility.elements(in: window).contains { element in
        let identifier =
          WindowAccessibility.attribute(element, "accessibilityIdentifier") as? String
        return identifier?.hasPrefix("overview.statement.pending.") == true
      })
  }

  func testNoRowWaitsForAStatementDecisionAnyMore() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let window = try host(difference: 0)
    window.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    XCTAssertNil(WindowAccessibility.element(identified: "overview.discrepancies", in: window))
  }

  func testTheCaptionIsTranslatedInRussianAndEnglish() throws {
    let language = try XCTUnwrap(environment).language
    language.choice = .russian
    XCTAssertEqual(
      language("overview.reconciliation.difference", table: "Overview"), "Расхождение при сверке")
    language.choice = .english
    XCTAssertEqual(
      language("overview.reconciliation.difference", table: "Overview"), "Reconciliation difference"
    )
  }
}
