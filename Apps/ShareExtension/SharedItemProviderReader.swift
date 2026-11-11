import AppCore
import Foundation
import UniformTypeIdentifiers

/// Platform plumbing only. The envelope, bank-message parsing and receipt rules are shared.
@MainActor
enum SharedItemProviderReader {
  /// Some hosts hand selected text over as the extension item's body, without a provider.
  static func fallbackText(in item: NSExtensionItem) throws -> SharedImportItem? {
    guard item.attachments?.isEmpty != false, let text = item.attributedContentText?.string else {
      return nil
    }
    return try SharedImportItem(kind: .text, data: Data(text.utf8))
  }

  static func read(_ provider: NSItemProvider) async throws -> SharedImportItem {
    let registered = provider.registeredTypeIdentifiers
    let candidates: [(SharedImportItem.Kind, UTType)] = [
      (.pdf, .pdf), (.image, .image), (.text, .plainText),
    ]
    for (kind, base) in candidates {
      guard let identifier = registered.first(where: { UTType($0)?.conforms(to: base) == true })
      else { continue }
      let data: Data = try await withCheckedThrowingContinuation { continuation in
        provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, error in
          if let data {
            continuation.resume(returning: data)
          } else {
            continuation.resume(throwing: error ?? SharedImportItem.Failure.invalid)
          }
        }
      }
      let ext = UTType(identifier)?.preferredFilenameExtension ?? (kind == .text ? "txt" : "bin")
      return try SharedImportItem(kind: kind, data: data, filename: "shared.\(ext)")
    }
    throw SharedImportItem.Failure.invalid
  }
}
