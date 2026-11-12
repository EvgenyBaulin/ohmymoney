import AppCore
import SwiftUI
import UniformTypeIdentifiers

/// A local photo only: browsing wishes never starts a network request for a product picture.
struct WishPhotoPreview: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  let wishId: UUID
  @State private var photo: AttachedFile?

  static func firstPhoto(in files: [AttachedFile]) -> AttachedFile? {
    files.filter { file in
      guard !file.isInTrash else { return false }
      let type =
        file.mediaType.flatMap { UTType(mimeType: $0) }
        ?? UTType(filenameExtension: (file.fileName as NSString).pathExtension)
      return type?.conforms(to: .image) == true
    }.sorted { ($0.addedAt, $0.id.uuidString) < ($1.addedAt, $1.id.uuidString) }.first
  }

  var body: some View {
    Group {
      if let photo {
        AttachmentThumbnail(file: photo, service: environment.attachments, side: 64)
          .accessibilityIdentifier("purchases.wish.photo")
      }
    }
    .task(id: compute.generation) {
      let files =
        (try? environment.attachments?.repository.attachments(of: .wish, id: wishId)) ?? []
      photo = Self.firstPhoto(in: files)
    }
  }
}
