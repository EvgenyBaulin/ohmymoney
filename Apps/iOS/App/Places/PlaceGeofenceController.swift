import AppCore
import AppDatabase
import CoreLocation
import Foundation
import UserNotifications

/// What the phone's region monitoring is asked, as the controller needs it: a seam, so a test
/// counts the regions instead of talking to the system.
@MainActor
protocol RegionWatching: AnyObject {
  var watchedIdentifiers: Set<String> { get }
  func watch(identifier: String, around point: GeoPoint, radiusMeters: Int)
  func stopWatching(identifier: String)
}

/// Keeps the phone watching the owner's nearest marks (iOS lets an app watch twenty regions) and
/// reports a mark entered. Which marks are watched is decided by the core (`PlaceGeofencing`).
@MainActor
final class PlaceRegionPlan {
  private let watcher: any RegionWatching
  init(watcher: any RegionWatching) { self.watcher = watcher }

  /// Watches exactly the nearest enabled marks around `here`, and nothing when `enabled` is off.
  func apply(marks: [PlaceMark], around here: GeoPoint?, enabled: Bool) {
    let wanted: [PlaceMark]
    if enabled {
      wanted = PlaceGeofencing.regions(
        marks, around: here ?? marks.first?.point ?? GeoPoint(latitudeE7: 0, longitudeE7: 0)!,
        limit: PlaceGeofencing.systemLimit)
    } else {
      wanted = []
    }
    let wantedIds = Set(wanted.map { $0.id.uuidString })
    for identifier in watcher.watchedIdentifiers.subtracting(wantedIds) {
      watcher.stopWatching(identifier: identifier)
    }
    for mark in wanted {
      watcher.watch(
        identifier: mark.id.uuidString, around: mark.point, radiusMeters: mark.radiusMeters)
    }
  }
}

/// The system side: `CLLocationManager`. It asks for «always» permission only when the owner
/// turns the hints on, uses region monitoring (no continuous tracking), and keeps the
/// coordinates on the phone — nothing here goes to a network or a log.
@MainActor
final class PlaceGeofenceController: NSObject, RegionWatching, CLLocationManagerDelegate {
  static let shared = PlaceGeofenceController()

  private let manager = CLLocationManager()
  private var oneShot: CheckedContinuation<GeoPoint?, Never>?
  /// Called with the id of the mark the phone says the owner came near.
  var onEnter: (@MainActor (UUID) -> Void)?
  /// Called when the phone moved far: the nearest marks may be others now.
  var onMoved: (@MainActor (GeoPoint) -> Void)?

  override init() {
    super.init()
    manager.delegate = self
  }

  var authorization: CLAuthorizationStatus { manager.authorizationStatus }

  var watchedIdentifiers: Set<String> {
    Set(manager.monitoredRegions.map(\.identifier))
  }

  func requestPermission() {
    switch manager.authorizationStatus {
    case .notDetermined: manager.requestWhenInUseAuthorization()
    case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
    default: break
    }
  }

  func watch(identifier: String, around point: GeoPoint, radiusMeters: Int) {
    guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self),
      !watchedIdentifiers.contains(identifier)
    else { return }
    let region = CLCircularRegion(
      center: point.coordinate,
      radius: CLLocationDistance(radiusMeters), identifier: identifier)
    region.notifyOnEntry = true
    region.notifyOnExit = false
    manager.startMonitoring(for: region)
  }

  func stopWatching(identifier: String) {
    for region in manager.monitoredRegions where region.identifier == identifier {
      manager.stopMonitoring(for: region)
    }
  }

  func startFollowingMoves() { manager.startMonitoringSignificantLocationChanges() }
  func stopFollowingMoves() { manager.stopMonitoringSignificantLocationChanges() }

  /// Where the phone is now, once; `nil` when the owner has not allowed it or it cannot tell.
  func currentPoint() async -> GeoPoint? {
    switch manager.authorizationStatus {
    case .denied, .restricted: return nil
    case .notDetermined: manager.requestWhenInUseAuthorization()
    default: break
    }
    return await withCheckedContinuation { continuation in
      oneShot?.resume(returning: nil)
      oneShot = continuation
      manager.requestLocation()
    }
  }

  // MARK: CLLocationManagerDelegate

  nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
    let identifier = region.identifier
    Task { @MainActor in
      if let id = UUID(uuidString: identifier) { self.onEnter?(id) }
    }
  }

  nonisolated func locationManager(
    _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
  ) {
    guard let last = locations.last, let point = GeoPoint(location: last.coordinate) else {
      return
    }
    Task { @MainActor in
      if let waiting = self.oneShot {
        self.oneShot = nil
        waiting.resume(returning: point)
      } else {
        self.onMoved?(point)
      }
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    Task { @MainActor in
      if let waiting = self.oneShot {
        self.oneShot = nil
        waiting.resume(returning: nil)
      }
    }
  }
}

/// The whole feature wired to the app: keeps the phone watching the marks while the hints are on
/// and turns «came near» into one local notice with the card to pay with.
@MainActor
final class PlaceHintsService {
  static let shared = PlaceHintsService()

  private var deps: AppDependencies?
  private let controller = PlaceGeofenceController.shared
  private lazy var plan = PlaceRegionPlan(watcher: controller)

  /// Called once the books are open, and again when the owner changes a mark or the switch.
  func resume(deps: AppDependencies) {
    self.deps = deps
    controller.onEnter = { [weak self] id in self?.entered(id) }
    controller.onMoved = { [weak self] point in self?.refresh(around: point) }
    refresh(around: nil)
  }

  func refresh(around here: GeoPoint?) {
    guard let stack = deps?.environment.stack else { return }
    let enabled = PlaceHintsSettings.hintsEnabled()
    let marks = (try? PlaceMarkRepository(stack: stack).all()) ?? []
    plan.apply(marks: marks, around: here, enabled: enabled && !marks.isEmpty)
    if enabled && marks.count > PlaceGeofencing.systemLimit {
      controller.startFollowingMoves()
    } else {
      controller.stopFollowingMoves()
    }
  }

  private func entered(_ id: UUID) {
    guard let deps, let stack = deps.environment.stack,
      let ledger = deps.compute.snapshot?.ledger
    else { return }
    let marks = (try? PlaceMarkRepository(stack: stack).all()) ?? []
    let now = Date()
    guard
      let advice = PlaceHintDecision.advice(
        forMark: id, marks: marks, ledger: ledger, today: deps.environment.today,
        enabled: PlaceHintsSettings.hintsEnabled(), lastNotified: PlaceHintsSettings.lastNotified(),
        now: now),
      let mark = marks.first(where: { $0.id == id })
    else { return }
    PlaceHintsSettings.remember(id, at: now)
    let content = UNMutableNotificationContent()
    content.title = mark.name
    content.body = PlaceHintText.body(advice, ledger: ledger, deps.environment)
    content.sound = .default
    let request = UNNotificationRequest(
      identifier: "places.hint.\(id.uuidString)", content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request)
  }

  /// Asks for the permissions the hints need; the notice permission is asked here too.
  func askPermissions() async {
    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    controller.requestPermission()
  }
}
