import AppCore
import AppDatabase
import Foundation
import UniformTypeIdentifiers

/// The request to open the receipt reader: pictures dropped on the window, or none.
struct ReceiptRequest: Identifiable, Equatable {
  let id = UUID()
  var urls: [URL]
}

extension AppEnvironment {
  /// Whether the app keeps attachments to operations: the photo of the receipt goes with the
  /// operation it supplements.
  var receiptPhotosCanBeKept: Bool { attachments != nil }

  /// Puts the photo with the operation as a receipt. Whether it landed. The file is kept as it
  /// came; whether it stays for good is the retention setting's business.
  @discardableResult
  func keepReceiptPhoto(_ photo: ReceiptPhoto, for operation: UUID) -> Bool {
    guard let attachments else { return false }
    let type = UTType(filenameExtension: (photo.filename as NSString).pathExtension)
    return
      (try? attachments.add(
        data: photo.data, fileName: photo.filename, to: .transaction, id: operation,
        kind: .receipt, mediaType: type?.preferredMIMEType)) != nil
  }
}
