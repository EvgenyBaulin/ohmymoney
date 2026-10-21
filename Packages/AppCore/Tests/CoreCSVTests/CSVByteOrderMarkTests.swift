import Foundation
import Testing

@testable import CoreCSV

/// One byte-order mark at the very start of a file says «UTF-8» and is no text: the reader skips
/// exactly that one, as `pandas.read_csv` does. Any other — a second one right after it, one
/// further in — is a character of the file like any other, so a header that begins with one
/// keeps it, and the archive's count of rows sees the same lines the reader reads.
@Suite("A byte-order mark is skipped once, at the start only")
struct CSVByteOrderMarkTests {
  @Test func onlyTheFirstMarkIsSkipped() throws {
    #expect(try CSVReader.rows(from: Data("\u{FEFF}id\n1".utf8)) == [["id"], ["1"]])
    #expect(
      try CSVReader.rows(from: Data("\u{FEFF}\u{FEFF}id\n1".utf8)) == [["\u{FEFF}id"], ["1"]])
    #expect(
      try CSVReader.rows(from: Data("\u{FEFF}\u{FEFF}\nid\n1".utf8)) == [
        ["\u{FEFF}"], ["id"], ["1"],
      ])
    #expect(try CSVReader.rows(from: Data("id\n\u{FEFF}1".utf8)) == [["id"], ["\u{FEFF}1"]])
    #expect(try CSVReader.rows(from: Data("\u{FEFF}".utf8)) == [])
  }

  /// Bytes that are no UTF-8 after the mark are still refused.
  @Test func bytesThatAreNoUTF8AreRefused() {
    #expect(throws: CSVError.invalidEncoding) {
      try CSVReader.rows(from: Data([0xEF, 0xBB, 0xBF, 0x41, 0xFF, 0x0A]))
    }
    #expect(throws: CSVError.invalidEncoding) { try CSVReader.rows(from: Data([0xC3])) }
  }
}
