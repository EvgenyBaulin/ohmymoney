import AppCore
import XCTest

@testable import OhMyMoney

/// Hints near marked places and the map of spending: both off until the owner switches them on,
/// at most the nearest twenty marks watched, one notice per pause, and every word in both
/// languages. Synthetic points only.
@MainActor
final class PlaceHintsTests: XCTestCase {
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    defaults = UserDefaults(suiteName: "places-\(UUID().uuidString)")
  }

  private func point(_ step: Int) -> GeoPoint {
    GeoPoint(latitudeE7: Int64(step) * 10_000, longitudeE7: 0)!
  }

  func testBothSwitchesStartOffAndKeepTheirChoice() {
    XCTAssertFalse(PlaceHintsSettings.hintsEnabled(defaults))
    XCTAssertFalse(PlaceHintsSettings.mapEnabled(defaults))
    PlaceHintsSettings.setHints(true, defaults)
    XCTAssertTrue(PlaceHintsSettings.hintsEnabled(defaults))
    XCTAssertFalse(PlaceHintsSettings.mapEnabled(defaults), "one switch is not the other")
    PlaceHintsSettings.setMap(true, defaults)
    XCTAssertTrue(PlaceHintsSettings.mapEnabled(defaults))
  }

  func testTheLastNoticeIsKeptByMarkWithoutAnyCoordinate() {
    let id = UUID()
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    PlaceHintsSettings.remember(id, at: at, defaults)
    XCTAssertEqual(PlaceHintsSettings.lastNotified(defaults), [id: at])
    let raw = defaults.dictionary(forKey: PlaceHintsSettings.lastNoticeKey) ?? [:]
    XCTAssertEqual(Set(raw.keys), [id.uuidString])
  }

  // MARK: The twenty regions

  private final class FakeWatcher: RegionWatching {
    var watched: [String: Int] = [:]
    var watchedIdentifiers: Set<String> { Set(watched.keys) }
    func watch(identifier: String, around point: GeoPoint, radiusMeters: Int) {
      watched[identifier] = radiusMeters
    }
    func stopWatching(identifier: String) { watched[identifier] = nil }
  }

  func testOnlyTheNearestTwentyEnabledMarksAreWatched() {
    let watcher = FakeWatcher()
    let plan = PlaceRegionPlan(watcher: watcher)
    var marks = (1...30).map { PlaceMark(name: "M\($0)", point: point($0)) }
    marks[0].enabled = false
    plan.apply(marks: marks, around: point(0), enabled: true)
    XCTAssertEqual(watcher.watched.count, PlaceGeofencing.systemLimit)
    XCTAssertNil(watcher.watched[marks[0].id.uuidString], "a mark switched off is not watched")
    XCTAssertNotNil(watcher.watched[marks[1].id.uuidString])
    XCTAssertNil(watcher.watched[marks[25].id.uuidString], "a far mark waits")
  }

  func testMovingFarSwapsTheWatchedMarks() {
    let watcher = FakeWatcher()
    let plan = PlaceRegionPlan(watcher: watcher)
    let marks = (1...30).map { PlaceMark(name: "M\($0)", point: point($0)) }
    plan.apply(marks: marks, around: point(0), enabled: true)
    XCTAssertNotNil(watcher.watched[marks[0].id.uuidString])
    plan.apply(marks: marks, around: point(40), enabled: true)
    XCTAssertEqual(watcher.watched.count, PlaceGeofencing.systemLimit)
    XCTAssertNil(watcher.watched[marks[0].id.uuidString])
    XCTAssertNotNil(watcher.watched[marks[29].id.uuidString])
  }

  func testSwitchingTheHintsOffStopsEveryRegion() {
    let watcher = FakeWatcher()
    let plan = PlaceRegionPlan(watcher: watcher)
    let marks = (1...5).map { PlaceMark(name: "M\($0)", point: point($0)) }
    plan.apply(marks: marks, around: point(0), enabled: true)
    XCTAssertEqual(watcher.watched.count, 5)
    plan.apply(marks: marks, around: point(0), enabled: false)
    XCTAssertTrue(watcher.watched.isEmpty)
  }

  func testTheRadiusOfEachMarkIsWhatTheSystemIsAsked() {
    let watcher = FakeWatcher()
    let mark = PlaceMark(name: "A", point: point(1), radiusMeters: 300)
    PlaceRegionPlan(watcher: watcher).apply(marks: [mark], around: nil, enabled: true)
    XCTAssertEqual(watcher.watched[mark.id.uuidString], 300)
  }

  // MARK: What is announced

  private let ledger = Ledger(dataset: Dataset(), calendar: .utc)
  private let today = DateOnly(year: 2026, month: 11, day: 15)
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  func testNothingIsAnnouncedWhileTheHintsAreOff() {
    let mark = PlaceMark(name: "A", point: point(1), categoryId: UUID())
    XCTAssertNil(
      PlaceHintDecision.advice(
        forMark: mark.id, marks: [mark], ledger: ledger, today: today, enabled: false,
        lastNotified: [:], now: now))
  }

  func testAMarkThatIsGoneOrSwitchedOffIsNotAnnounced() {
    var mark = PlaceMark(name: "A", point: point(1), categoryId: UUID())
    XCTAssertNil(
      PlaceHintDecision.advice(
        forMark: UUID(), marks: [mark], ledger: ledger, today: today, enabled: true,
        lastNotified: [:], now: now))
    mark.enabled = false
    XCTAssertNil(
      PlaceHintDecision.advice(
        forMark: mark.id, marks: [mark], ledger: ledger, today: today, enabled: true,
        lastNotified: [:], now: now))
  }

  func testNothingIsAnnouncedWithinThePauseOrWithoutACardThatEarns() {
    let mark = PlaceMark(name: "A", point: point(1), categoryId: UUID())
    // No card with a rule in an empty book: nothing to say, with or without a recent notice.
    XCTAssertNil(
      PlaceHintDecision.advice(
        forMark: mark.id, marks: [mark], ledger: ledger, today: today, enabled: true,
        lastNotified: [:], now: now))
    XCTAssertNil(
      PlaceHintDecision.advice(
        forMark: mark.id, marks: [mark], ledger: ledger, today: today, enabled: true,
        lastNotified: [mark.id: now.addingTimeInterval(-60)], now: now))
  }

  // MARK: Words

  func testEveryWordOfTheFeatureIsInBothLanguages() {
    let keys =
      PlaceHintText.keys + [
        "places.title", "places.hints.toggle", "places.hints.footer", "places.mark.here",
        "places.mark.cannotLocate", "places.marks.header", "places.marks.empty",
        "places.map.toggle", "places.map.empty", "places.map.footer", "places.failed",
        "places.mark.radius", "places.mark.name", "places.mark.category",
        "places.mark.noCategory", "places.mark.categoryFooter", "places.mark.new",
      ]
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = AppEnvironment()
      environment.language.choice = choice
      for key in keys {
        XCTAssertNotEqual(
          environment.language(key, table: PlaceHintText.table), key, "\(choice) \(key)")
      }
    }
  }
}
