import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The sheet «Я в поездке» in a window: the trips to pick from are on it, a trip pressed turns the
/// mode on for it, and «Новая поездка…» opens the form with its fields. Found the way VoiceOver
/// finds controls, so these run where SwiftUI builds its accessibility tree (not on a CI runner).
@MainActor
final class TripStartSheetWindowTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var window: NSWindow!
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private var trip: Event!

  override func setUp() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("trip-sheet-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: try XCTUnwrap(environment.references),
      planning: try XCTUnwrap(environment.planning))
    compute = ComputeStore(calendar: .utc, rebuildsInline: true)
    let today = environment.today
    trip = Event(
      name: "Бали", kind: .trip, startDate: today, endDate: today.adding(days: 6),
      tripCurrency: CurrencyCode("IDR"))
    try XCTUnwrap(environment.references).save(trip)
    compute.applyLight(
      DataSnapshot.build(
        dataset: Dataset(events: [trip]), calendar: .utc, today: today,
        context: SnapshotContext(), version: DataVersion(load: 0)))
    let deps = AppDependencies(environment: environment, store: store, compute: compute)
    window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 520, height: 480), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: TripStartSheet().appDependencies(deps))
    window.makeKeyAndOrderFront(nil)
  }

  override func tearDown() async throws {
    window?.contentView = nil
    window?.close()
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private func find(_ identifier: String) -> AnyObject? {
    guard let root = window.contentView else { return nil }
    return Self.element(in: root) { $0.accessibilityIdentifier?() == identifier }
  }

  private func waitFor(_ identifier: String, timeout: TimeInterval = 10) -> AnyObject? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let found = find(identifier) { return found }
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    return find(identifier)
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

  func testTheTripsToComeAreOnTheSheetAndAPressedOneTurnsTheModeOn() throws {
    let button = try XCTUnwrap(waitFor("travel.start.trip"), "the trip is offered")
    XCTAssertNotNil(find("travel.start.new"), "and a new one can be made")
    XCTAssertNil(find("travel.start.back"), "the mode is off: nothing to come back from")
    _ = button.accessibilityPerformPress?()
    let travel = TravelRepository(writer: try XCTUnwrap(environment.stack).writer)
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline, (try travel.settings().activeEventId) == nil {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    XCTAssertEqual(try travel.settings().activeEventId, trip.id)
  }

  func testANewTripOpensItsFormWithTheFieldsOfTheTrip() throws {
    let new = try XCTUnwrap(waitFor("travel.start.new"))
    _ = new.accessibilityPerformPress?()
    XCTAssertNotNil(waitFor("travel.new.name"), "the name")
    XCTAssertNotNil(find("travel.new.budget"), "the budget")
    XCTAssertNotNil(find("travel.new.switchOn"), "the switch of the mode")
  }
}
