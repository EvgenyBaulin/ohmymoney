import AppCore
import AppDatabase
import CoreImage
import CoreImage.CIFilterBuiltins
import XCTest

@testable import OhMyMoney

/// The picture side of «Чек по QR»: a QR code drawn here, read back by Vision.
final class ReceiptQRDetectorTests: XCTestCase {
  private func picture(of text: String, scale: CGFloat = 12) throws -> CGImage {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    let output = try XCTUnwrap(filter.outputImage)
    let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    // A white margin, as on paper: the code must not touch the edge of the picture.
    let margin: CGFloat = 40
    let canvas = scaled.extent.insetBy(dx: -margin, dy: -margin)
    let white = CIImage(color: .white).cropped(to: canvas)
    let composed = scaled.composited(over: white)
    return try XCTUnwrap(CIContext().createCGImage(composed, from: canvas))
  }

  func testAReceiptCodeIsReadAndParsed() throws {
    let text = "t=20261029T183245&s=1250.50&fn=9960440300000000&i=12345&fp=2345678901&n=1"
    let reading = ReceiptQRDetector.reading(of: try picture(of: text))
    guard case .receipt(let receipt) = reading else {
      return XCTFail("expected a receipt, got \(reading)")
    }
    XCTAssertEqual(receipt.amountE4.raw, 12_505_000)
    XCTAssertEqual(receipt.day, DateOnly(year: 2026, month: 10, day: 29))
    XCTAssertEqual(receipt.time, TimeOfDay(hour: 18, minute: 32))
    XCTAssertEqual(receipt.second, 45)
  }

  func testACodeOfAnotherKindIsNotAReceipt() throws {
    let reading = ReceiptQRDetector.reading(of: try picture(of: "https://example.com/ticket/42"))
    XCTAssertEqual(reading, .notReceipt)
  }

  func testAPictureWithoutACodeSaysSo() throws {
    let canvas = CGRect(x: 0, y: 0, width: 300, height: 300)
    let blank = CIImage(color: .white).cropped(to: canvas)
    let image = try XCTUnwrap(CIContext().createCGImage(blank, from: canvas))
    XCTAssertEqual(ReceiptQRDetector.reading(of: image), .noCode)
  }

  func testAFileOnDiskIsOpenedAndRead() throws {
    let image = try picture(of: "t=20261029T1832&s=99.00&n=2")
    let data = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let reopened = try XCTUnwrap(ReceiptQRDetector.image(from: data as Data))
    guard case .receipt(let receipt) = ReceiptQRDetector.reading(of: reopened) else {
      return XCTFail("expected a receipt")
    }
    XCTAssertTrue(receipt.isRefund)
    XCTAssertNil(ReceiptQRDetector.image(from: Data("not a picture".utf8)))
  }

  func testDroppedPicturesAreToldFromStatements() {
    let urls = [
      URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.JPG"),
      URL(fileURLWithPath: "/tmp/c.csv"), URL(fileURLWithPath: "/tmp/d.pdf"),
    ]
    XCTAssertEqual(ReceiptPresenter.pictures(in: urls).map(\.lastPathComponent), ["a.png", "b.JPG"])
    XCTAssertEqual(
      StatementImportPresenter.statementFiles(in: urls).map(\.lastPathComponent),
      ["c.csv", "d.pdf"])
  }
}

/// The words of «Чек по QR» exist in both languages and take their arguments.
final class ReceiptTextTests: XCTestCase {
  private func bundle(_ language: String) throws -> Bundle {
    let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
    return try XCTUnwrap(Bundle(path: path))
  }

  func testEveryKeyIsTranslatedAndFormatsKeepTheirArguments() throws {
    let keys: [(String, Int)] = [
      ("receipt.menu", 0), ("receipt.title", 0), ("receipt.subtitle", 0), ("receipt.iphone", 0),
      ("receipt.iphone.hint", 0), ("receipt.iphone.menuHint", 0), ("receipt.choose", 0),
      ("receipt.photos", 0), ("receipt.scan", 0), ("receipt.drop", 0), ("receipt.reading", 0),
      ("receipt.noCode", 0), ("receipt.notReceipt", 0), ("receipt.camera.unavailable", 0),
      ("receipt.facts", 3), ("receipt.refund", 0), ("receipt.operation.generic", 0),
      ("receipt.supplement.question", 2), ("receipt.supplement.question.photo", 2),
      ("receipt.choices", 0), ("receipt.addTime", 0), ("receipt.addTimePhoto", 0),
      ("receipt.otherPurchase", 0), ("receipt.backToFound", 0), ("receipt.anotherReceipt", 0),
      ("receipt.new.summary", 3), ("receipt.new.category", 0), ("receipt.new.refundHint", 0),
      ("receipt.create", 0), ("receipt.createPhoto", 0), ("receipt.cancel", 0),
      ("receipt.done", 0), ("receipt.done.time", 1), ("receipt.done.created", 0),
      ("receipt.done.undo", 0), ("receipt.failed.notWritten", 0), ("receipt.failed.gone", 0),
      ("receipt.failed.noCategory", 0),
    ]
    for language in ["en", "ru"] {
      let bundle = try bundle(language)
      for (key, arguments) in keys {
        let text = bundle.localizedString(forKey: key, value: "MISSING", table: "Receipt")
        XCTAssertNotEqual(text, "MISSING", "\(key) in \(language)")
        for index in 1...max(arguments, 1) where arguments > 0 {
          XCTAssertTrue(
            text.contains("%\(index)$@") || (arguments == 1 && text.contains("%@")),
            "\(key) in \(language) lacks argument \(index)")
        }
      }
    }
    let russian = try bundle("ru").localizedString(
      forKey: "receipt.supplement.question.photo", value: nil, table: "Receipt")
    XCTAssertTrue(russian.contains("добавить время"))
  }
}
