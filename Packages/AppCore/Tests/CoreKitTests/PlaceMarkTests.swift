import Foundation
import Testing

@testable import CoreKit

/// The owner's marks on the map: coordinates as whole numbers, nearest marks for the few
/// regions the phone lets an app watch, and a pause between two notices of one place.
@Suite("Place marks")
struct PlaceMarkTests {
  // Synthetic points near the equator and the meridian, where a degree is easy to count.
  private func point(_ latitude: Double, _ longitude: Double) throws -> GeoPoint {
    try #require(GeoPoint(latitude: latitude, longitude: longitude))  // stats-only
  }

  @Test func aPointKeepsSevenDecimalsAsAnInteger() throws {
    let place = try point(55.7558123, 37.6173456)
    #expect(place.latitudeE7 == 557_558_123)
    #expect(place.longitudeE7 == 376_173_456)
    #expect(place.latitude == 55.7558123)
  }

  @Test func aPointOutsideTheGlobeIsRefused() {
    #expect(GeoPoint(latitude: 91, longitude: 0) == nil)
    #expect(GeoPoint(latitude: 0, longitude: 181) == nil)
    #expect(GeoPoint(latitude: .nan, longitude: 0) == nil)
    #expect(GeoPoint(latitudeE7: -900_000_001, longitudeE7: 0) == nil)
  }

  @Test func oneThousandthOfADegreeOfLatitudeIsAboutOneHundredElevenMetres() throws {
    let meters = try point(0, 0).distanceMeters(to: try point(0.001, 0))
    #expect((110...112).contains(meters))
  }

  @Test func distanceIsSymmetricAndZeroToItself() throws {
    let a = try point(55.75, 37.61)
    let b = try point(55.76, 37.63)
    #expect(a.distanceMeters(to: a) == 0)
    #expect(a.distanceMeters(to: b) == b.distanceMeters(to: a))
  }

  @Test func theRadiusStaysWithinWhatARegionCanBe() throws {
    let here = try point(0, 0)
    #expect(PlaceMark(name: "A", point: here, radiusMeters: 5).radiusMeters == PlaceMark.minRadius)
    #expect(
      PlaceMark(name: "A", point: here, radiusMeters: 99_999).radiusMeters == PlaceMark.maxRadius)
    #expect(PlaceMark(name: "A", point: here).radiusMeters == PlaceMark.defaultRadius)
  }

  @Test func theNearestMarksAreWatchedAndOnlyEnabledOnes() throws {
    let me = try point(0, 0)
    var marks: [PlaceMark] = []
    for step in 1...30 {
      marks.append(PlaceMark(name: "M\(step)", point: try point(0.001 * Double(step), 0)))
    }
    marks[0].enabled = false
    let watched = PlaceGeofencing.regions(marks, around: me, limit: 20)
    #expect(watched.count == 20)
    #expect(!watched.contains { $0.id == marks[0].id })
    #expect(watched.first?.id == marks[1].id)
    #expect(watched.last?.id == marks[20].id)
  }

  @Test func fewerMarksThanTheLimitAreAllWatched() throws {
    let me = try point(0, 0)
    let marks = [PlaceMark(name: "A", point: try point(0.01, 0))]
    #expect(PlaceGeofencing.regions(marks, around: me, limit: 20).count == 1)
    #expect(PlaceGeofencing.regions([], around: me, limit: 20).isEmpty)
    #expect(PlaceGeofencing.regions(marks, around: me, limit: 0).isEmpty)
  }

  @Test func aPlaceIsNotNotifiedTwiceWithinThePause() {
    let id = UUID()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(PlaceGeofencing.shouldNotify(id, lastNotified: [:], now: now))
    let soon = [id: now.addingTimeInterval(-3600)]
    #expect(!PlaceGeofencing.shouldNotify(id, lastNotified: soon, now: now))
    let long = [id: now.addingTimeInterval(-PlaceGeofencing.pause - 1)]
    #expect(PlaceGeofencing.shouldNotify(id, lastNotified: long, now: now))
    // Another place is not held back by this one.
    #expect(PlaceGeofencing.shouldNotify(UUID(), lastNotified: soon, now: now))
  }

  @Test func theMarkSurvivesAnEncodeAndDecode() throws {
    let mark = PlaceMark(
      name: "Shop", point: try point(1.5, 2.5), radiusMeters: 200, placeId: UUID(),
      categoryId: UUID())
    let data = try JSONEncoder().encode(mark)
    #expect(try JSONDecoder().decode(PlaceMark.self, from: data) == mark)
  }
}
