import AppCore
import Foundation
import ImageIO
import Vision

/// Finds QR codes in a picture. Vision stays here, in the app: the core only reads their text.
enum ReceiptQRDetector {
  /// What the QR codes on the picture say, in the order Vision found them.
  static func payloads(in image: CGImage) -> [String] {
    let request = VNDetectBarcodesRequest()
    request.symbologies = [.qr]
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do {
      try handler.perform([request])
    } catch {
      return []
    }
    return (request.results ?? []).compactMap(\.payloadStringValue)
  }

  /// What the picture holds: the first QR code that is a cash receipt, or whether there was a
  /// code at all (a link or a ticket is not a receipt, and the screen says so).
  static func reading(of image: CGImage) -> Reading {
    let found = payloads(in: image)
    if found.isEmpty { return .noCode }
    if let receipt = found.lazy.compactMap({ ReceiptQRParser.parse($0) }).first {
      return .receipt(receipt)
    }
    return .notReceipt
  }

  enum Reading: Equatable {
    case receipt(ReceiptQR)
    case notReceipt
    case noCode
  }

  /// The pixels of an image file (a photo, a screenshot), turned upright.
  static func image(at url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return image(from: source)
  }

  static func image(from data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return image(from: source)
  }

  private static func image(from source: CGImageSource) -> CGImage? {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 4096,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }
}
