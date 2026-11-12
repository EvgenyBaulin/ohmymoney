import SwiftUI
import UniformTypeIdentifiers

/// File selection belongs to the button, keeping the entry bar's view type small.
struct EntryAttachmentButton: View {
  let environment: AppEnvironment
  let iconSize: CGFloat
  @Environment(\.themeSurfaces) private var surfaces
  @State private var picking = false

  var body: some View {
    Button {
      picking = true
    } label: {
      Image(systemName: "paperclip")
        .appFont(AppFont.system(size: iconSize, weight: .medium))
        .frame(width: iconSize + 2, height: iconSize + 2)
    }
    .buttonStyle(.plain)
    .foregroundStyle(surfaces.secondary)
    .help(environment.language("import.attachment.help", table: "Import"))
    .accessibilityLabel(
      Text(verbatim: environment.language("import.attachment.add", table: "Import"))
    )
    .accessibilityIdentifier("entry.attachment")
    .disabled(!EntryImportReceiving.isAllowed(environment))
    .fileImporter(
      isPresented: $picking,
      allowedContentTypes: [.commaSeparatedText, .plainText, .pdf, .spreadsheet, .image],
      allowsMultipleSelection: true
    ) { result in
      guard case .success(let urls) = result, EntryImportReceiving.isAllowed(environment) else {
        return
      }
      environment.entryImports.append(urls: urls)
    }
  }
}
