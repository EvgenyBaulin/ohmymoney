import AppCore
import CoreLocation

/// The phone's side of a coordinate: whole numbers of 1e-7 degree in the books, degrees as the
/// location service and the map speak them.
extension GeoPoint {
  /// From what the location service reports; `nil` for a value off the globe or not a number.
  init?(location coordinate: CLLocationCoordinate2D) {
    let factor = Double(GeoPoint.scale)
    let latitude = (coordinate.latitude * factor).rounded()
    let longitude = (coordinate.longitude * factor).rounded()
    guard latitude.isFinite, longitude.isFinite, abs(latitude) <= 90 * factor,
      abs(longitude) <= 180 * factor
    else { return nil }
    self.init(latitudeE7: Int64(latitude), longitudeE7: Int64(longitude))
  }

  var coordinate: CLLocationCoordinate2D {
    CLLocationCoordinate2D(
      latitude: Double(latitudeE7) / Double(GeoPoint.scale),
      longitude: Double(longitudeE7) / Double(GeoPoint.scale))
  }
}
