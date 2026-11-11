import UIKit
import XCTest

@testable import OhMyMoney

@MainActor
final class ReceiptCameraTests: XCTestCase {
  func testCameraHandsOverAFullSizeJPEGForTheReceiptReader() throws {
    var received: Data?
    let camera = AttachmentCamera { received = $0 }
    let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image { context in
      UIColor.white.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
    }
    camera.makeCoordinator().imagePickerController(
      UIImagePickerController(), didFinishPickingMediaWithInfo: [.originalImage: image])
    let restored = try XCTUnwrap(UIImage(data: XCTUnwrap(received)))
    XCTAssertEqual(restored.size.width, image.size.width * image.scale)
    XCTAssertEqual(restored.size.height, image.size.height * image.scale)
  }

  func testCancellingTheCameraDoesNotProduceAReceipt() {
    var calls = 0
    let camera = AttachmentCamera { data in
      calls += 1
      XCTAssertNil(data)
    }
    camera.makeCoordinator().imagePickerControllerDidCancel(UIImagePickerController())
    XCTAssertEqual(calls, 1)
  }
}
