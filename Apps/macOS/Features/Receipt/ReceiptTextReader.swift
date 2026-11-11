import AppCore
import CoreGraphics
import Foundation
import Vision

/// Recognises the printed text of a picture (Vision stays in the app: the core reads the lines).
/// Used only when the picture has no QR code that is a cash receipt.
enum ReceiptTextReader {
  /// The lines of text on the picture, top to bottom, as recognised, each with Vision's confidence.
  static func lines(in image: CGImage) -> [RecognizedLine] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    // Digits and codes matter more than words: a «corrected» number is a wrong number.
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["ru-RU", "en-US"]
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    guard (try? handler.perform([request])) != nil else { return [] }
    return (request.results ?? [])
      .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
      .compactMap { observation in
        observation.topCandidates(1).first.map {
          RecognizedLine(text: $0.string, confidence: $0.confidence)
        }
      }
  }

  /// The lines of every picture of a file (a photo, or each page of a PDF).
  static func lines(inFile data: Data) -> [RecognizedLine] {
    ReceiptQRDetector.textPictures(ofFile: data).flatMap { picture in
      autoreleasepool { () -> [RecognizedLine] in
        picture().map(lines(in:)) ?? []
      }
    }
  }
}
