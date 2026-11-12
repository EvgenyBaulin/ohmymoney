import CoreGraphics
import Foundation
import ImageIO
import XCTest

/// Pictures of whole screens compared with references kept in the repository
/// (`Apps/<platform>/Tests/Snapshots/<name>.png`, flat: the test bundle has no folders).
///
/// A picture is brought to a fixed width first (a reference is half the size of a Mac window and
/// the same size as a phone's one: small in the repository, and the resampling averages away the
/// edge noise of text drawn at another scale), then compared pixel by pixel: a pixel differs when
/// any channel is off by more than `channelThreshold`, and the screen fails when more than
/// `maxDifferingShare` of its pixels differ. A failure keeps the picture, the reference and a
/// picture of the difference (red where they part) with the result of the test.
///
/// With `OHMYMONEY_RECORD_SNAPSHOTS=1` in the host's environment (`TEST_RUNNER_…` for
/// `xcodebuild`) nothing is compared: the references are written, into the sources when the host
/// may write there, else into its temporary folder, whose path goes to the test's log.
enum ScreenSnapshots {
  static let recordKey = "OHMYMONEY_RECORD_SNAPSHOTS"
  /// Share of pixels allowed to differ.
  static let maxDifferingShare = 0.005
  /// A channel (0…255) may be off by this much before a pixel counts as different.
  static let channelThreshold = 24

  /// The «now» every snapshot run lives in: the synthetic book is generated up to this day, so
  /// the pictures do not change from one day to the next.
  static let fixedNow = Date(timeIntervalSince1970: 1_794_301_200)  // 2026-11-10 09:00 UTC

  /// The themes the screens are kept for: the first, the Contrast theme (the one «Increase
  /// contrast» swaps in), and one with a strong colour of its own. The 30 are checked for
  /// legibility and independence of layout elsewhere; here a picture of a few shows that a
  /// colour or a margin has not moved.
  static let themeNumbers = ["01", "09", "15"]

  static var isRecording: Bool {
    ProcessInfo.processInfo.environment[recordKey] == "1"
  }

  /// Width of the references: a phone is kept as it is drawn, a Mac window and a tablet halved.
  enum ReferenceWidth {
    static let phone = 402
    static let tablet = 683
    static let mac = 720
  }

  /// RGBA, premultiplied, 8 bits per channel, rows top to bottom.
  struct Pixels: Equatable {
    var width: Int
    var height: Int
    var bytes: [UInt8]
  }

  struct Comparison {
    let differing: Int
    let total: Int
    let diff: Pixels?
    var share: Double { total == 0 ? 0 : Double(differing) / Double(total) }
  }

  // MARK: Pixels

  /// The PNG brought to `width` pixels across, its height in proportion.
  static func pixels(fromPNG data: Data, width: Int) -> Pixels? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width > 0
    else { return nil }
    let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
    return draw(image, width: width, height: height)
  }

  static func pixels(from image: CGImage) -> Pixels? {
    draw(image, width: image.width, height: image.height)
  }

  private static func draw(_ image: CGImage, width: Int, height: Int) -> Pixels? {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.interpolationQuality = .high
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    return drawn ? Pixels(width: width, height: height, bytes: bytes) : nil
  }

  static func png(from pixels: Pixels) -> Data? {
    var bytes = pixels.bytes
    let image: CGImage? = bytes.withUnsafeMutableBytes { buffer in
      CGContext(
        data: buffer.baseAddress, width: pixels.width, height: pixels.height,
        bitsPerComponent: 8, bytesPerRow: pixels.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }
    guard let image else { return nil }
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data, "public.png" as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
  }

  // MARK: Comparing

  /// Pictures of different sizes never match; the caller reports that before asking.
  static func compare(
    _ actual: Pixels, with expected: Pixels, threshold: Int = channelThreshold
  ) -> Comparison {
    precondition(actual.width == expected.width && actual.height == expected.height)
    var differing = 0
    var diff = actual
    let count = actual.width * actual.height
    for pixel in 0..<count {
      let base = pixel * 4
      var worst = 0
      for channel in 0..<4 {
        worst = max(
          worst, abs(Int(actual.bytes[base + channel]) - Int(expected.bytes[base + channel])))
      }
      if worst > threshold {
        differing += 1
        diff.bytes[base] = 255
        diff.bytes[base + 1] = 0
        diff.bytes[base + 2] = 0
        diff.bytes[base + 3] = 255
      } else {
        // The matching part stays visible but pale, so the red stands out.
        for channel in 0..<3 {
          diff.bytes[base + channel] = UInt8(128 + Int(actual.bytes[base + channel]) / 2)
        }
        diff.bytes[base + 3] = 255
      }
    }
    return Comparison(differing: differing, total: count, diff: differing > 0 ? diff : nil)
  }

  // MARK: Verifying a screen

  private final class BundleAnchor {}

  /// Compares the picture of a screen with the reference called `name`, or records it.
  /// A recording goes to the `Snapshots` folder next to the calling file.
  @MainActor
  static func verify(
    png data: Data, name: String, width: Int, test: XCTestCase, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard let actual = pixels(fromPNG: data, width: width) else {
      XCTFail("«\(name)»: the picture could not be read", file: file, line: line)
      return
    }
    if isRecording {
      record(actual, name: name, file: file, line: line)
      return
    }
    guard let url = Bundle(for: BundleAnchor.self).url(forResource: name, withExtension: "png"),
      let stored = try? Data(contentsOf: url), let expected = pixels(fromPNG: stored, width: width)
    else {
      attach(png(from: actual), "\(name) (actual)", to: test)
      XCTFail(
        "«\(name)»: no reference picture; record with \(recordKey)=1", file: file, line: line)
      return
    }
    guard actual.height == expected.height else {
      attach(png(from: actual), "\(name) (actual)", to: test)
      XCTFail(
        "«\(name)»: the screen is \(actual.height) pt tall at the reference width, was \(expected.height)",
        file: file, line: line)
      return
    }
    let result = compare(actual, with: expected)
    guard result.share > maxDifferingShare else { return }
    attach(png(from: actual), "\(name) (actual)", to: test)
    attach(stored, "\(name) (reference)", to: test)
    attach(result.diff.flatMap { png(from: $0) }, "\(name) (difference)", to: test)
    XCTFail(
      "«\(name)»: \(String(format: "%.2f", result.share * 100)) % of the pixels differ, "
        + "\(String(format: "%.2f", maxDifferingShare * 100)) % is allowed",
      file: file, line: line)
  }

  @MainActor
  private static func attach(_ data: Data?, _ name: String, to test: XCTestCase) {
    guard let data else { return }
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
    attachment.name = name
    attachment.lifetime = .keepAlways
    test.add(attachment)
  }

  private static func record(_ pixels: Pixels, name: String, file: StaticString, line: UInt) {
    guard let data = png(from: pixels) else {
      XCTFail("«\(name)»: the picture could not be written", file: file, line: line)
      return
    }
    let sources = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
      .appendingPathComponent("Snapshots", isDirectory: true)
    let fallback = FileManager.default.temporaryDirectory
      .appendingPathComponent("recorded-snapshots", isDirectory: true)
    for folder in [sources, fallback] {
      do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("\(name).png"))
        if folder == fallback { print("snapshot recorded to \(folder.path)") }
        return
      } catch { continue }
    }
    XCTFail("«\(name)»: the reference could not be written", file: file, line: line)
  }
}
