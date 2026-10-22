import Foundation
import PDFKit

/// Reads the text layer of a PDF statement into lines laid out the way the page is: the cells of
/// one table row stand on one line, left to right. The reader of a statement (`CoreCSV`) works on
/// such lines. PDFKit hands back text column by column; here every piece of text is put back
/// where its position on the page says.
enum StatementPDFText {
  /// Pieces whose baselines are closer than this (in points) are one line.
  static let lineTolerance: CGFloat = 2.5

  /// One piece of text with where it stands on its page.
  struct Fragment: Equatable {
    var text: String
    var minX: CGFloat
    var maxX: CGFloat
    var y: CGFloat
  }

  /// The lines of a document, page after page. Empty when the file has no text layer (a scan).
  static func lines(of document: PDFDocument) -> [String] {
    var result: [String] = []
    for index in 0..<document.pageCount {
      guard let page = document.page(at: index) else { continue }
      let selection = page.selection(for: page.bounds(for: .mediaBox))
      let fragments: [Fragment] = (selection?.selectionsByLine() ?? []).compactMap { piece in
        guard let text = piece.string?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
          return nil
        }
        let bounds = piece.bounds(for: page)
        return Fragment(text: text, minX: bounds.minX, maxX: bounds.maxX, y: bounds.minY)
      }
      result += layout(fragments)
    }
    return result
  }

  static func lines(at url: URL) -> [String] {
    guard let document = PDFDocument(url: url) else { return [] }
    return lines(of: document)
  }

  static func lines(from data: Data) -> [String] {
    guard let document = PDFDocument(data: data) else { return [] }
    return lines(of: document)
  }

  /// The pieces of one page as lines: top to bottom, and each line left to right with a few
  /// spaces between pieces that were apart on the page. Pure, so a test can lay out a page it
  /// made up.
  static func layout(_ fragments: [Fragment]) -> [String] {
    let ordered = fragments.sorted { $0.y > $1.y }
    var rows: [[Fragment]] = []
    var rowY: CGFloat = 0
    for fragment in ordered {
      if let last = rows.last, abs(rowY - fragment.y) <= lineTolerance {
        rows[rows.count - 1] = last + [fragment]
      } else {
        rows.append([fragment])
        rowY = fragment.y
      }
    }
    return rows.map { row in
      var line = ""
      var previousEnd: CGFloat?
      for fragment in row.sorted(by: { $0.minX < $1.minX }) {
        if let previousEnd {
          line += fragment.minX - previousEnd > 10 ? "    " : " "
        }
        line += fragment.text
        previousEnd = fragment.maxX
      }
      return line
    }
  }
}
