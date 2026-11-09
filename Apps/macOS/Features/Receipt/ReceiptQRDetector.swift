import AppCore
import CoreGraphics
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

  /// What a file holds: a photo, a screenshot or the PDF of an electronic receipt.
  ///
  /// A PDF is drawn page by page, the last first: an electronic receipt has its code on the last
  /// page, after the lines. A photo is read in its full size first; a photo larger than
  /// `reducedSide` is then read by overlapping pieces of `tileSide` cut from the full size — Vision
  /// shrinks a large picture by itself, and a small code on a 48-megapixel photo is lost in that —
  /// and at last made smaller, which Vision reads better when the code fills the photo.
  static func reading(ofFile data: Data) -> Reading {
    let pictures = isPDF(data) ? pages(ofPDF: data) : sizes(ofImage: data)
    var sawCode = false
    for picture in pictures {
      let outcome = autoreleasepool { () -> Reading in
        guard let image = picture() else { return .noCode }
        return reading(ofAll: image)
      }
      switch outcome {
      case .receipt(let receipt): return .receipt(receipt)
      case .notReceipt: sawCode = true
      case .noCode: break
      }
    }
    return sawCode ? .notReceipt : .noCode
  }

  /// The picture as a whole, then — when it is larger than `reducedSide` — piece by piece.
  private static func reading(ofAll image: CGImage) -> Reading {
    var sawCode = false
    for rect in [CGRect(x: 0, y: 0, width: image.width, height: image.height)]
      + tiles(width: image.width, height: image.height)
    {
      guard let piece = rect.width == CGFloat(image.width) && rect.height == CGFloat(image.height)
        ? image : image.cropping(to: rect)
      else { continue }
      switch reading(of: piece) {
      case .receipt(let receipt): return .receipt(receipt)
      case .notReceipt: sawCode = true
      case .noCode: break
      }
    }
    return sawCode ? .notReceipt : .noCode
  }

  /// The side of a piece of a large photo, and how far the pieces overlap: a code on the border
  /// of one is whole in the next.
  static let tileSide = 2_048
  static let tileOverlap = 512

  /// The pieces a picture larger than `reducedSide` is read by; none for a smaller one.
  static func tiles(width: Int, height: Int) -> [CGRect] {
    guard max(width, height) > reducedSide else { return [] }
    func starts(_ length: Int) -> [Int] {
      guard length > tileSide else { return [0] }
      let step = tileSide - tileOverlap
      var out = Array(stride(from: 0, to: length - tileSide, by: step))
      out.append(length - tileSide)
      return out
    }
    return starts(height).flatMap { y in
      starts(width).map { x in
        CGRect(
          x: x, y: y, width: min(tileSide, width - x), height: min(tileSide, height - y))
      }
    }
  }

  /// The longest side a photo is made smaller to on the second look.
  static let reducedSide = 4_096

  /// The scale a page of a PDF is drawn at, and the longest side it may reach.
  private static let pageScale: CGFloat = 2
  private static let longestPage: CGFloat = 8_000

  static func isPDF(_ data: Data) -> Bool {
    data.prefix(5) == Data("%PDF-".utf8)
  }

  /// The photo in its full size, then made smaller when it is larger than `reducedSide`; each
  /// made only when asked for, so a code found in the first never costs the second.
  private static func sizes(ofImage data: Data) -> [() -> CGImage?] {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) > 0
    else { return [] }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
    let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
    let longest = max(width, height)
    guard longest > reducedSide else {
      return [{ image(from: source, longestSide: longest > 0 ? longest : reducedSide) }]
    }
    return [
      { image(from: source, longestSide: longest) },
      { image(from: source, longestSide: reducedSide) },
    ]
  }

  /// The pages of a PDF, the last first, each drawn white at twice its size.
  private static func pages(ofPDF data: Data) -> [() -> CGImage?] {
    guard let provider = CGDataProvider(data: data as CFData),
      let document = CGPDFDocument(provider), document.numberOfPages > 0
    else { return [] }
    return stride(from: document.numberOfPages, through: 1, by: -1).map { number in
      { document.page(at: number).flatMap(render) }
    }
  }

  private static func render(_ page: CGPDFPage) -> CGImage? {
    let box = page.getBoxRect(.mediaBox)
    guard box.width > 0, box.height > 0 else { return nil }
    let scale = min(pageScale, longestPage / max(box.width, box.height))
    let width = Int((box.width * scale).rounded(.up))
    let height = Int((box.height * scale).rounded(.up))
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -box.minX, y: -box.minY)
    context.drawPDFPage(page)
    return context.makeImage()
  }

  /// The pixels of an image file (a photo, a screenshot), turned upright.
  static func image(at url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return image(from: source, longestSide: reducedSide)
  }

  static func image(from data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return image(from: source, longestSide: reducedSide)
  }

  private static func image(from source: CGImageSource, longestSide: Int) -> CGImage? {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: longestSide,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }
}
