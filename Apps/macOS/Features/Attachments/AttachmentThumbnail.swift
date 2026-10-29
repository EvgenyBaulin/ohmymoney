import AppCore
import AppDatabase
import QuickLookThumbnailing
import SwiftUI

/// The picture of a file in a list: its thumbnail (the first page of a PDF, a small copy of a
/// photo) from the system, and a symbol of its kind until that is ready or when the system has
/// none. The symbol and the name always stand beside it; the picture adds, never carries.
struct AttachmentThumbnail: View {
  let file: AttachedFile
  let service: AttachmentService?
  var side: CGFloat = 44

  @Environment(\.displayScale) private var displayScale
  @State private var image: CGImage?

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary)
      if let image {
        Image(decorative: image, scale: displayScale)
          .resizable().scaledToFill()
      } else {
        Image(systemName: Self.symbol(for: file))
          .appFont(.title3)
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: side, height: side)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .accessibilityHidden(true)
    .task(id: file.contentHash) { await load() }
  }

  /// The symbol for a file the system gives no picture of.
  static func symbol(for file: AttachedFile) -> String {
    switch file.kind {
    case .receipt: "receipt"
    case .warranty: "checkmark.shield"
    case .document: "doc.text"
    case .other: "paperclip"
    }
  }

  private func load() async {
    guard let service,
      let url = AttachmentsModel.previewURL(for: file, in: service)
    else { return }
    let request = QLThumbnailGenerator.Request(
      fileAt: url, size: CGSize(width: side, height: side), scale: displayScale,
      representationTypes: .thumbnail)
    if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(
      for: request)
    {
      image = representation.cgImage
    }
  }
}
