import XCTest

@testable import OhMyMoney

/// The comparison the screen snapshots rest on, over synthetic pictures: it must let noise
/// through and stop a changed colour or a moved block.
final class ScreenSnapshotsTests: XCTestCase {
  private typealias Pixels = ScreenSnapshots.Pixels

  private func flat(_ width: Int, _ height: Int, _ value: UInt8) -> Pixels {
    var bytes = [UInt8](repeating: value, count: width * height * 4)
    for pixel in 0..<(width * height) { bytes[pixel * 4 + 3] = 255 }
    return Pixels(width: width, height: height, bytes: bytes)
  }

  private func paint(_ pixels: inout Pixels, x: Range<Int>, y: Range<Int>, _ value: UInt8) {
    for row in y {
      for column in x {
        let base = (row * pixels.width + column) * 4
        pixels.bytes[base] = value
        pixels.bytes[base + 1] = value
        pixels.bytes[base + 2] = value
      }
    }
  }

  func testIdenticalPicturesDoNotDiffer() {
    let result = ScreenSnapshots.compare(flat(100, 100, 200), with: flat(100, 100, 200))
    XCTAssertEqual(result.differing, 0)
    XCTAssertNil(result.diff)
  }

  func testAColourShiftUnderTheThresholdIsNoise() {
    let shifted = flat(100, 100, UInt8(200 + ScreenSnapshots.channelThreshold))
    XCTAssertEqual(ScreenSnapshots.compare(shifted, with: flat(100, 100, 200)).differing, 0)
  }

  func testAChangedColourOverTheWholeScreenFails() {
    let result = ScreenSnapshots.compare(flat(100, 100, 40), with: flat(100, 100, 200))
    XCTAssertEqual(result.share, 1, accuracy: 0.0001)
    XCTAssertGreaterThan(result.share, ScreenSnapshots.maxDifferingShare)
  }

  func testAMovedBlockOfAFewPointsFails() {
    var before = flat(200, 200, 255)
    paint(&before, x: 20..<120, y: 20..<60, 30)
    var after = flat(200, 200, 255)
    // The same bar, four pixels lower: two thin stripes of 100 × 4 differ.
    paint(&after, x: 20..<120, y: 24..<64, 30)
    let result = ScreenSnapshots.compare(after, with: before)
    XCTAssertEqual(result.differing, 800)
    XCTAssertGreaterThan(result.share, ScreenSnapshots.maxDifferingShare)
  }

  func testAFewStrayPixelsAreWithinTheAllowance() {
    var after = flat(200, 200, 255)
    paint(&after, x: 0..<10, y: 0..<10, 0)  // 100 of 40 000 pixels: 0.25 %
    let result = ScreenSnapshots.compare(after, with: flat(200, 200, 255))
    XCTAssertEqual(result.differing, 100)
    XCTAssertLessThanOrEqual(result.share, ScreenSnapshots.maxDifferingShare)
  }

  func testTheDifferenceIsRedWhereThePicturesPart() throws {
    var after = flat(10, 10, 255)
    paint(&after, x: 0..<1, y: 0..<1, 0)
    let diff = try XCTUnwrap(ScreenSnapshots.compare(after, with: flat(10, 10, 255)).diff)
    XCTAssertEqual(Array(diff.bytes[0..<4]), [255, 0, 0, 255])
    XCTAssertNotEqual(Array(diff.bytes[4..<8]), [255, 0, 0, 255])
  }

  func testAPNGRoundTripsAndIsResizedToTheWidthAsked() throws {
    var picture = flat(40, 20, 255)
    paint(&picture, x: 0..<20, y: 0..<20, 0)
    let data = try XCTUnwrap(ScreenSnapshots.png(from: picture))
    let same = try XCTUnwrap(ScreenSnapshots.pixels(fromPNG: data, width: 40))
    XCTAssertEqual(same, picture)
    let half = try XCTUnwrap(ScreenSnapshots.pixels(fromPNG: data, width: 20))
    XCTAssertEqual(half.width, 20)
    XCTAssertEqual(half.height, 10)
    XCTAssertEqual(half.bytes[0], 0)
    XCTAssertEqual(half.bytes[(19) * 4], 255)
  }
}
