import AppCore
import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
  import UIKit
#endif

/// A summary laid out as one page: the title and the cards. The PDF, the picture to share and
/// the print all draw this one view, so they say the same.
struct SummaryPage: View {
  let title: String
  let cards: [(title: String, lines: [String])]

  static let width: CGFloat = 540

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: title)
        .font(.system(size: 26, weight: .bold))  // font-fixed: the page is a document of a fixed size
        .padding(.bottom, 4)
      ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
        VStack(alignment: .leading, spacing: 6) {
          Text(verbatim: card.title).font(.system(size: 15, weight: .semibold))  // font-fixed: the page is a document of a fixed size
          ForEach(Array(card.lines.enumerated()), id: \.offset) { _, line in
            Text(verbatim: line).font(.system(size: 13)).monospacedDigit()  // font-fixed: the page is a document of a fixed size
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
      }
    }
    .padding(24)
    .frame(width: Self.width, alignment: .leading)
    .background(Color.white)
    .foregroundStyle(Color.black)
    .environment(\.colorScheme, .light)
  }
}

enum SummaryExport {
  /// The PDF of a page: one page as tall as its cards.
  @MainActor
  static func pdf(of page: SummaryPage) -> Data? {
    let renderer = ImageRenderer(content: page)
    renderer.proposedSize = ProposedViewSize(width: SummaryPage.width, height: nil)
    let data = NSMutableData()
    var written = false
    renderer.render { size, draw in
      guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return }
      var box = CGRect(origin: .zero, size: size)
      guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return }
      context.beginPDFPage(nil)
      draw(context)
      context.endPDFPage()
      context.closePDF()
      written = true
    }
    return written ? data as Data : nil
  }

  /// The picture of a page for sharing, as a PNG file in the temporary folder.
  @MainActor
  static func pngFile(of page: SummaryPage, name: String) -> URL? {
    let renderer = ImageRenderer(content: page)
    renderer.scale = 2
    #if canImport(UIKit)
      guard let data = renderer.uiImage?.pngData() else { return nil }
    #else
      guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let data = bitmap.representation(using: .png, properties: [:])
      else { return nil }
    #endif
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "summaries", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name).appendingPathExtension("png")
    do {
      try data.write(to: url, options: .atomic)
      return url
    } catch {
      return nil
    }
  }
}

/// The PDF as a document `fileExporter` can save.
struct SummaryPDFDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.pdf] }
  var data: Data

  init(data: Data) { self.data = data }

  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}
