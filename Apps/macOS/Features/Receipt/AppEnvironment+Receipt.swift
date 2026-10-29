import AppCore
import Foundation

/// The request to open the receipt reader: pictures dropped on the window, or none.
struct ReceiptRequest: Identifiable, Equatable {
  let id = UUID()
  var urls: [URL]
}

extension AppEnvironment {
  /// Whether the app keeps attachments to operations (the photo of the receipt goes with the
  /// operation it supplements). Until the attachments are wired to the screens this is off and
  /// the reader writes the time and the sum alone.
  var receiptPhotosCanBeKept: Bool { false }

  /// Puts the photo with the operation. Whether it landed. The seam for the attachments: the
  /// reader calls it only when `receiptPhotosCanBeKept`.
  func keepReceiptPhoto(_ photo: ReceiptPhoto, for operation: UUID) -> Bool { false }
}
