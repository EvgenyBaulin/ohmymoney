import CoreKit
import Foundation
import Testing

@testable import CoreArchive

/// The archive counts the rows of a CSV file the way the CSV reader and `pandas.read_csv` read
/// them — or it refuses a manifest that is right. A byte-order mark at the very start of a file
/// is how Numbers, Excel and many editors begin UTF-8: the reader skips it, so the count skips
/// it too; one further in is text like any other.
@Suite("The rows of an archived CSV file are counted as they are read")
struct ArchiveRowCountTests {
  /// A leading mark opens no record — not on a line of its own, not before the header.
  @Test func aLeadingByteOrderMarkIsNoRow() {
    let files: [(String, Int)] = [
      ("\u{FEFF}id,name\n1,A", 1),
      ("\u{FEFF}\nid,name\n1,A", 1),
      ("\u{FEFF}\r\nid,name\r\n1,A\r\n", 1),
      ("\u{FEFF}", 0),
      ("\u{FEFF}id\n", 0),
      ("\u{FEFF}\n\n", 0),
      ("id,name\n\u{FEFF}\n", 1),
      ("id,name\n1,\u{FEFF}\n", 1),
      ("\u{FEFF}\u{FEFF}\nid\n", 1),
    ]
    for (text, rows) in files {
      #expect(ArchiveOpener.countCSVRows(Data(text.utf8)) == rows, "«\(text.debugDescription)»")
    }
  }

  /// An archive whose file starts with the mark and whose manifest counts the rows the reader
  /// reads opens; one row more or less is refused.
  @Test func aFileThatStartsWithTheMarkIsCheckedByItsRows() throws {
    let text = "\u{FEFF}\nid,name\n1,A\n2,B\n"
    for count in [1, 2, 3] {
      var builder = ArchiveBuilder(
        metadata: ArchiveBuilder.Metadata(
          appVersion: "1.1.0", schemaVersion: 4,
          createdAt: DateOnly(year: 2026, month: 9, day: 26), platform: "macOS",
          rowCounts: ["notes": count]))
      try builder.add(path: ArchivePaths.csv(table: "notes"), text: text)
      let opens = (try? ArchiveOpener.open(try builder.build(), supportedSchemaVersion: 4)) != nil
      #expect(opens == (count == 2), "counted \(count)")
    }
  }
}
