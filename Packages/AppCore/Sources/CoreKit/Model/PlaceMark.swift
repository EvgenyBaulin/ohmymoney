import Foundation

/// A point on the globe as whole numbers of 1e-7 degree (about a centimetre): coordinates never
/// pass through a floating-point type in the books. Latitude −90…90, longitude −180…180.
public struct GeoPoint: Hashable, Sendable, Codable {
  public static let scale: Int64 = 10_000_000

  public let latitudeE7: Int64
  public let longitudeE7: Int64

  public init?(latitudeE7: Int64, longitudeE7: Int64) {
    guard abs(latitudeE7) <= 90 * Self.scale, abs(longitudeE7) <= 180 * Self.scale else {
      return nil
    }
    self.latitudeE7 = latitudeE7
    self.longitudeE7 = longitudeE7
  }

  /// From degrees as a floating-point number; `nil` for a value off the globe or not a number.
  /// Not public: the books never see a `Double`, the phone's side converts (`GeoPoint+Location`).
  init?(latitude: Double, longitude: Double) {  // stats-only
    guard latitude.isFinite, longitude.isFinite else { return nil }
    let factor = Double(Self.scale)  // stats-only
    let scaledLatitude = (latitude * factor).rounded()  // stats-only
    let scaledLongitude = (longitude * factor).rounded()  // stats-only
    // A value far off the globe would not fit an Int64 at all: refuse it before converting.
    guard abs(scaledLatitude) <= 90 * factor, abs(scaledLongitude) <= 180 * factor else {  // stats-only
      return nil
    }
    self.init(latitudeE7: Int64(scaledLatitude), longitudeE7: Int64(scaledLongitude))
  }

  var latitude: Double { Double(latitudeE7) / Double(Self.scale) }  // stats-only
  var longitude: Double { Double(longitudeE7) / Double(Self.scale) }  // stats-only

  /// The distance over the surface in whole metres (haversine, sphere of 6 371 km): enough to
  /// order marks and to tell whether one is near, not a survey.
  public func distanceMeters(to other: GeoPoint) -> Int {
    let radius = 6_371_000.0  // stats-only
    let lat1 = latitude * .pi / 180  // stats-only
    let lat2 = other.latitude * .pi / 180  // stats-only
    let dLat = lat2 - lat1  // stats-only
    let dLon = (other.longitude - longitude) * .pi / 180  // stats-only
    let halfLat = sin(dLat / 2)  // stats-only
    let halfLon = sin(dLon / 2)  // stats-only
    let a = halfLat * halfLat + cos(lat1) * cos(lat2) * halfLon * halfLon  // stats-only
    return Int((2 * radius * asin(min(1, a.squareRoot()))).rounded())
  }
}

/// A place the owner marked on the map, to be reminded of the best way to pay when near it.
///
/// It lives only in the database of the device it was made on: it is neither sent to the other
/// devices nor written into a copy, and no coordinate goes into a log.
public struct PlaceMark: Identifiable, Hashable, Sendable, Codable {
  public static let minRadius = 50
  public static let maxRadius = 1_000
  public static let defaultRadius = 150

  public var id: UUID
  public var name: String
  public var point: GeoPoint
  public var radiusMeters: Int
  /// The place of the books the mark stands for; the advice reads its history.
  public var placeId: UUID?
  /// What the owner buys here, when the place has no history to say.
  public var categoryId: UUID?
  public var enabled: Bool

  public init(
    id: UUID = UUID(), name: String, point: GeoPoint, radiusMeters: Int = defaultRadius,
    placeId: UUID? = nil, categoryId: UUID? = nil, enabled: Bool = true
  ) {
    self.id = id
    self.name = name
    self.point = point
    self.radiusMeters = min(max(radiusMeters, Self.minRadius), Self.maxRadius)
    self.placeId = placeId
    self.categoryId = categoryId
    self.enabled = enabled
  }
}

/// What the phone's region monitoring needs: which marks to watch (it allows a few) and when a
/// notice may be sent again.
public enum PlaceGeofencing {
  /// The most regions iOS lets an app watch at once.
  public static let systemLimit = 20
  /// A place is not announced again within this many seconds.
  public static let pause: TimeInterval = 6 * 3600

  /// The enabled marks nearest to `point`, nearest first, at most `limit`; ties by id.
  public static func regions(_ marks: [PlaceMark], around point: GeoPoint, limit: Int)
    -> [PlaceMark]
  {
    guard limit > 0 else { return [] }
    var ranked: [(mark: PlaceMark, meters: Int)] = []
    for mark in marks where mark.enabled {
      ranked.append((mark, mark.point.distanceMeters(to: point)))
    }
    ranked.sort { left, right in
      if left.meters != right.meters { return left.meters < right.meters }
      return left.mark.id.uuidString < right.mark.id.uuidString
    }
    return ranked.prefix(limit).map { $0.mark }
  }

  public static func shouldNotify(
    _ markId: UUID, lastNotified: [UUID: Date], now: Date
  ) -> Bool {
    guard let last = lastNotified[markId] else { return true }
    return now.timeIntervalSince(last) >= pause
  }
}
